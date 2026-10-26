import AppKit
import CoreAudio
import Foundation

/// The control loop: reads the session files, decides whether the tap is attached and how many stems play,
/// routes every transport command into the playback, and logs every change. Audio lives in Playback.
final class Daemon {
  private let reader = StateReader()
  private var tap: ProcessTap?
  private var playback: Playback?
  private var nowPlaying: NowPlaying?
  private let playerControl = PlayerControl()
  private var lastAudible: Int?
  private var lastCutoff: Double??
  private var lastCounts: Counts?
  private var lastSessions: [String: Bool] = [:]
  private var workingEase = WorkingEase()
  private var lastLiveAt = Date.distantPast
  private var nextAttachAt = Date.distantPast
  private var nextLevelAt = Date.distantPast
  private var nextPruneAt = Date.distantPast
  private var silentSince: Date?
  private var lastPermission: CapturePermission?
  private var lastSong: TrackMark?
  private var lastPlaying: Bool?
  private var playerObserver: NSObjectProtocol?
  private var observedPlayer: String?

  private var signalSources: [DispatchSourceSignal] = []

  func run() {
    guard Self.takeInstanceLock() else {
      Log.line("start refused pid=\(ProcessInfo.processInfo.processIdentifier): another stemmix daemon holds the lock")
      exit(0)
    }
    Log.line("start pid=\(ProcessInfo.processInfo.processIdentifier)")
    // A separator that dies mid-write must be an EPIPE, not a SIGPIPE that kills the daemon with a tap running.
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [self] in
        Log.line("signal \(sig): detaching before exit")
        playback?.stop()
        tap?.stop(wait: Config.exitTeardownWait)
        tap = nil
        exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
    nowPlaying = NowPlaying { [weak self] command in self?.handle(command, source: "media-key") }
    DistributedNotificationCenter.default().addObserver(forName: Config.controlNotification, object: nil, queue: .main) { [weak self] note in
      guard let text = note.object as? String, let command = TransportCommand(rawValue: text) else { return }
      self?.handle(command, source: "control")
    }
    let timer = Timer(timeInterval: Config.pollInterval, repeats: true) { [self] _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    // An accessory app (no Dock icon) so the system treats the daemon as an app that can be Now Playing.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
  }

  private func handle(_ command: TransportCommand, source: String) {
    guard let playback else {
      Log.line("transport source=\(source) command=\(command.rawValue) ignored: not attached")
      return
    }
    playback.handle(command, source: source, now: Date().timeIntervalSince1970)
  }

  private func tick() {
    let now = Date()
    let config = reader.config()
    let sessions = reader.sessions()
    let counts = workingEase.summarize(
      sessions: sessions, nowMs: now.timeIntervalSince1970 * 1000, staleMs: Config.sessionStaleMs, holdSeconds: Config.workingHoldSeconds)
    logSessionChanges(sessions)
    if counts.live > 0 { lastLiveAt = now }
    if now >= nextPruneAt {
      nextPruneAt = now.addingTimeInterval(60)
      for id in expiredSessions(sessions, nowMs: now.timeIntervalSince1970 * 1000, maxAgeMs: Config.sessionFileMaxAgeMs) {
        try? FileManager.default.removeItem(at: Config.sessionsDir.appendingPathComponent("\(id).json"))
        Log.line("session id=\(id) pruned")
      }
    }
    observePlayer(config.player)

    let prefix = Config.playerBundlePrefixes[config.player] ?? Config.playerBundlePrefixes[Config.defaultPlayer]!
    let targets = playerProcessObjects(bundlePrefix: prefix)
    let output = OutputDevice.current()
    let wantAttached = now.timeIntervalSince(lastLiveAt) < Config.detachAfterIdle && !targets.isEmpty

    if let current = tap, !wantAttached || current.targets != targets || current.output != output {
      detach(reason: !wantAttached ? "idle" : (current.targets != targets ? "player-changed" : "output-changed"))
    }
    if tap == nil, wantAttached, now >= nextAttachAt {
      attach(targets: targets, output: output, player: config.player)
    }

    guard let playback else { return }
    playback.expireForwardedSkip(now: now.timeIntervalSince1970)
    if now >= nextLevelAt {
      let status = playback.status()
      let dropped = tap?.droppedFrames.exchange(0, ordering: .relaxed) ?? 0
      Log.line(status.line + String(format: " dropped=%.2fs", Double(dropped) / Double(playback.timeline.rate)))
      nextLevelAt = now.addingTimeInterval(Config.levelInterval)
      // A tap that delivers no samples at all while the player outputs is dead (a coreaudiod restart, a stale
      // aggregate): rebuild it rather than sit on it.
      if status.inputSamples == 0, isOutputting(targets) {
        silentSince = silentSince ?? now
        if now.timeIntervalSince(silentSince!) >= Config.deadTapAfter {
          silentSince = nil
          detach(reason: "no-samples")
          return
        }
      } else {
        silentSince = nil
      }
    }
    let audible = audibleStems(mode: config.mode, working: counts.working, tracks: config.tracks)
    let cutoff = mufflingCutoffHz(config: config, working: counts.working)
    if audible != lastAudible || cutoff != lastCutoff || counts != lastCounts {
      playback.setAudible(audible)
      playback.setMuffling(cutoffHz: cutoff)
      let names = Stem.allCases.prefix(audible).map(\.name).joined(separator: "+")
      let muffle = cutoff.map { String(format: "%.0fHz", $0) } ?? "none"
      Log.line("count working=\(counts.working) live=\(counts.live) tracks=\(config.tracks) mode=\(config.mode.rawValue) stems=\(audible) (\(names.isEmpty ? "silent" : names)) muffle=\(muffle)")
      lastAudible = audible
      lastCutoff = .some(cutoff)
      lastCounts = counts
    }
    let song = playback.currentSong
    let playing = playback.playing
    if song != lastSong || playing != lastPlaying {
      nowPlaying?.update(title: song?.title, artist: song?.artist, playing: playing)
      lastSong = song
      lastPlaying = playing
    }
  }

  private func attach(targets: [AudioObjectID], output: OutputDevice, player: String) {
    var created: (ProcessTap, Playback)?
    do {
      let tap = try ProcessTap(targets: targets, output: output)
      let playback = Playback(rate: Int(tap.tapFormat.mSampleRate)) { [weak self] done in
        self?.playerControl.skipToNextTrack(player: player, done: done)
      }
      created = (tap, playback)
      playback.start()
      try tap.start { input, output, frames in playback.player.render(input, output, frames: frames) }
      self.tap = tap
      self.playback = playback
      lastAudible = nil
      lastCutoff = nil
      lastSong = nil
      lastPlaying = nil
      nowPlaying?.claim()
      let formats = tap.outputStreamFormats().map { "\(Int($0.mSampleRate))Hz/\($0.mChannelsPerFrame)ch/\($0.mBitsPerChannel)bit" }.joined(separator: ",")
      Log.line("attach player=\(player) objects=\(targets) tap=\(Int(tap.tapFormat.mSampleRate))Hz/\(tap.tapFormat.mChannelsPerFrame)ch output=\(output.uid) streams=\(formats) io-buffer=\(tap.bufferFrames)")
    } catch let CoreAudioError.notAuthorized(permission) {
      // Never let coreaudiod ask TCC on our behalf: ProcessTap refuses until the permission is granted.
      if permission != lastPermission { Log.line("permission \(permission.rawValue)") }
      lastPermission = permission
      nextAttachAt = Date().addingTimeInterval(Config.permissionRecheck)
    } catch {
      created?.1.stop()
      created?.0.stop()
      nextAttachAt = Date().addingTimeInterval(Config.attachRetry)
      Log.line("attach-failed player=\(player) error=\(error)")
    }
  }

  /// Follows the configured player's play state and track changes through its distributed notification.
  private func observePlayer(_ player: String) {
    guard player != observedPlayer else { return }
    if let playerObserver { DistributedNotificationCenter.default().removeObserver(playerObserver) }
    observedPlayer = player
    guard let name = playerNotifications[player] else { return }
    playerObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
      guard let event = parsePlayerEvent(note.userInfo ?? [:]) else { return }
      self?.playback?.handle(event, now: Date().timeIntervalSince1970)
    }
  }

  /// One daemon per user: a second copy (a Finder double-click on the app) would tap the player a second time.
  /// The lock is held for the process's life and released by the kernel when it exits.
  private static func takeInstanceLock() -> Bool {
    try? FileManager.default.createDirectory(at: Config.stateDir, withIntermediateDirectories: true)
    let fd = open(Config.lockFile.path, O_RDWR | O_CREAT, 0o644)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
  }

  private func detach(reason: String) {
    silentSince = nil
    nowPlaying?.release()
    playback?.stop()
    tap?.stop()
    tap = nil
    playback = nil
    lastAudible = nil
    lastCutoff = nil
    Log.line("detach reason=\(reason)")
  }

  private func logSessionChanges(_ sessions: [String: SessionFile]) {
    let current = sessions.mapValues(\.working)
    for (id, working) in current where lastSessions[id] != working {
      Log.line("session id=\(id) working=\(working)")
    }
    for id in lastSessions.keys where current[id] == nil {
      Log.line("session id=\(id) gone")
    }
    lastSessions = current
  }
}

@main
enum Main {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--probe": exit(runProbe(Array(arguments.dropFirst())))
    case "--request": exit(runRequest())
    case "--record": exit(runRecord(Array(arguments.dropFirst())))
    case "--control": exit(runControl(Array(arguments.dropFirst())))
    case "--simulate": exit(runSimulate(Array(arguments.dropFirst())))
    default: Daemon().run()
    }
  }
}

/// `--control <command>`: sends a transport command to the running daemon.
func runControl(_ arguments: [String]) -> Int32 {
  guard let text = arguments.first, TransportCommand(rawValue: text) != nil else {
    print("usage: --control \(TransportCommand.allCases.map(\.rawValue).joined(separator: "|"))")
    return 64
  }
  DistributedNotificationCenter.default().postNotificationName(Config.controlNotification, object: text, userInfo: nil, deliverImmediately: true)
  return 0
}
