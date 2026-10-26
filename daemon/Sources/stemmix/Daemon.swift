import AppKit
import CoreAudio
import Foundation

/// The control loop: reads the session files, decides whether the tap is attached and how many stems play,
/// routes every transport command into the playback, shows its state in the menu bar, and logs every change.
/// Audio lives in Playback.
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
  private var nextAttachAt = Date.distantPast
  private var nextLevelAt = Date.distantPast
  private var nextPruneAt = Date.distantPast
  private var silentSince: Date?
  private var lastPermission: CapturePermission?
  private var lastSong: TrackMark?
  private var lastPlaying: Bool?
  private var playerObserver: NSObjectProtocol?
  private var observedPlayer: String?
  /// The player key of the current attach.
  private var attachedPlayer: String?
  /// The last attach's play state and hold, kept for a re-attach inside this run (`attachIntent`).
  private var resume: (playing: Bool, held: Bool)?
  private var statusMenu: StatusMenu?
  private var lastMenu: MenuSnapshot?
  private var lastInputSamples: Int?
  /// Set by Quit so no tick attaches again before launchd's SIGTERM.
  private var isStopping = false

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
        shutdown(reason: "signal")
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
    statusMenu = StatusMenu { [weak self] action in self?.perform(action) }
    app.run()
  }

  private func handle(_ command: TransportCommand, source: String) {
    guard let playback else {
      Log.line("transport source=\(source) command=\(command.rawValue) ignored: not attached")
      return
    }
    playback.handle(command, source: source, now: Date().timeIntervalSince1970)
  }

  private func perform(_ action: MenuAction) {
    switch action {
    case .toggleOnOff:
      let on = !isOn
      do {
        if on {
          try FileManager.default.removeItem(at: Config.offFile)
        } else {
          try FileManager.default.createDirectory(at: Config.stateDir, withIntermediateDirectories: true)
          try Data().write(to: Config.offFile)
        }
        Log.line("switch on=\(on) source=menu")
      } catch {
        Log.line("switch on=\(on) source=menu failed error=\(error)")
      }
    case let .transport(command): handle(command, source: "menu")
    case .openLog: NSWorkspace.shared.open(Config.logFile)
    case .restart:
      Log.line("restart from the menu")
      shutdown(reason: "restart")
    case .quit: quit()
    }
  }

  /// The one teardown before exit: signals, Restart, and Quit's SIGTERM from launchd.
  private func shutdown(reason: String) {
    if tap != nil { detach(reason: reason, wait: Config.exitTeardownWait) }
    exit(0)
  }

  /// Stops the launchd job, which `KeepAlive` would otherwise restart: stopped until the next login or install.
  private func quit() {
    Log.line("quit from the menu")
    isStopping = true
    if tap != nil { detach(reason: "quit", wait: Config.exitTeardownWait) }
    guard let label = launchdLabel(environment: ProcessInfo.processInfo.environment) else { exit(0) }
    let launchctl = Process()
    launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    launchctl.arguments = bootoutArguments(uid: getuid(), label: label)
    // After a bootout that worked, isStopping stays set until launchd's SIGTERM ends the process.
    launchctl.terminationHandler = { [weak self] process in
      guard bootoutFailed(process) else { return }
      DispatchQueue.main.async {
        Log.line("quit-failed launchctl status=\(process.terminationStatus)")
        self?.isStopping = false
      }
    }
    do {
      try launchctl.run()
    } catch {
      Log.line("quit-failed error=\(error)")
      isStopping = false
    }
  }

  private func tick() {
    guard !isStopping else { return }
    let now = Date()
    let config = reader.config()
    let sessions = reader.sessions()
    let counts = workingEase.summarize(
      sessions: sessions, nowMs: now.timeIntervalSince1970 * 1000, staleMs: Config.sessionStaleMs, holdSeconds: Config.workingHoldSeconds)
    logSessionChanges(sessions)
    if now >= nextPruneAt {
      nextPruneAt = now.addingTimeInterval(60)
      for id in expiredSessions(sessions, nowMs: now.timeIntervalSince1970 * 1000, maxAgeMs: Config.sessionFileMaxAgeMs) {
        try? FileManager.default.removeItem(at: Config.sessionsDir.appendingPathComponent("\(id).json"))
        Log.line("session id=\(id) pruned")
      }
    }
    let player = Config.knownPlayer(config.player)
    observePlayer(player)

    let targets = playerProcessObjects(bundlePrefix: Config.playerBundlePrefixes[player]!)
    let output = OutputDevice.current()
    let on = isOn
    let playerRunning = !targets.isEmpty
    let wantAttached = on && playerRunning
    let audible = audibleStems(mode: config.mode, working: counts.working, tracks: config.tracks)
    let cutoff = mufflingCutoffHz(config: config, working: counts.working)

    if let current = tap, !wantAttached || current.targets != targets || current.output != output {
      detach(reason: !on ? "off" : !playerRunning ? "player-quit" : (current.targets != targets ? "player-changed" : "output-changed"))
    }
    if tap == nil, wantAttached, now >= nextAttachAt {
      attach(targets: targets, output: output, player: player)
    }

    if let playback {
      tickAttached(playback, now: now, config: config, counts: counts, targets: targets, audible: audible, cutoff: cutoff)
    }
    let menu = MenuSnapshot(
      attachment: playback.map { .attached($0.snapshot()) }
        ?? .detached(detachReason(on: on, playerRunning: playerRunning, permission: lastPermission)),
      counts: counts,
      player: Config.playerNames[player]!,
      audible: audible,
      cutoffHz: cutoff,
      inputSamples: lastInputSamples,
      mediaKeys: nowPlaying?.mediaKeys)
    if menu != lastMenu {
      statusMenu?.show(menuContent(menu))
      lastMenu = menu
    }
  }

  private func tickAttached(_ playback: Playback, now: Date, config: ConfigFile, counts: Counts, targets: [AudioObjectID], audible: Int, cutoff: Double?) {
    playback.tick(now: now.timeIntervalSince1970, playerOutputting: isOutputting(targets))
    if now >= nextLevelAt {
      let status = playback.status()
      let dropped = tap?.droppedFrames.exchange(0, ordering: .relaxed) ?? 0
      Log.line(status.line + String(format: " dropped=%.2fs", Double(dropped) / Double(playback.timeline.rate)))
      lastInputSamples = status.inputSamples
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
    if audible != lastAudible || cutoff != lastCutoff || counts != lastCounts {
      playback.setAudible(audible)
      playback.setMuffling(cutoffHz: cutoff)
      Log.line("count working=\(counts.working) live=\(counts.live) tracks=\(config.tracks) mode=\(config.mode.rawValue) stems=\(audible) (\(stemNames(audible: audible))) muffle=\(cutoffLabel(cutoff))")
      lastAudible = audible
      lastCutoff = .some(cutoff)
      lastCounts = counts
    }
    let song = playback.currentSong
    let playing = playback.intendsPlaying
    if song != lastSong || playing != lastPlaying {
      nowPlaying?.update(title: song?.title, artist: song?.artist, playing: playing)
      lastSong = song
      lastPlaying = playing
    }
    nowPlaying?.settle(playing: playing)
  }

  private func attach(targets: [AudioObjectID], output: OutputDevice, player: String) {
    var created: (ProcessTap, Playback)?
    do {
      let tap = try ProcessTap(targets: targets, output: output)
      let playback = Playback(
        rate: Int(tap.tapFormat.mSampleRate), playerPlaying: isOutputting(targets), resume: resume,
        bufferAheadSeconds: Config.bufferAheadSeconds
      ) { [weak self] command, done in
        self?.playerControl.send(command, player: player, done: done)
      }
      created = (tap, playback)
      playback.start()
      try tap.start { input, output, frames in playback.player.render(input, output, frames: frames) }
      self.tap = tap
      self.playback = playback
      attachedPlayer = player
      resume = nil
      lastPermission = nil
      lastInputSamples = nil
      // Read the first level line a full interval in: read now, before any IO cycle, it counts 0 samples.
      nextLevelAt = Date().addingTimeInterval(Config.levelInterval)
      lastAudible = nil
      lastCutoff = nil
      lastSong = nil
      lastPlaying = nil
      nowPlaying?.claim(playing: playback.intendsPlaying)
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
      // ProcessTap checks the permission before anything else can fail, so it is granted now.
      lastPermission = nil
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
      guard let self, let playback = self.playback, let event = parsePlayerEvent(note.userInfo ?? [:]) else { return }
      // After handle, so the intent already holds the follower's play; Spotify's notification comes after its
      // own change into Playing, so this pulse lands last.
      if playback.handle(event, now: Date().timeIntervalSince1970).startedPlaying {
        self.nowPlaying?.retake(playing: playback.intendsPlaying, reason: "player-started")
      }
    }
  }

  /// Switched on from the menu: no off file. On, stemmix taps the player whenever it runs.
  private var isOn: Bool { !FileManager.default.fileExists(atPath: Config.offFile.path) }

  /// One daemon per user: a second copy (a Finder double-click on the app) would tap the player a second time.
  /// The lock is held for the process's life and released by the kernel when it exits.
  private static func takeInstanceLock() -> Bool {
    try? FileManager.default.createDirectory(at: Config.stateDir, withIntermediateDirectories: true)
    let fd = open(Config.lockFile.path, O_RDWR | O_CREAT, 0o644)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
  }

  /// `wait`: how long to block on the teardown, before an exit; nil lets it finish on its own thread.
  private func detach(reason: String, wait: TimeInterval? = nil) {
    silentSince = nil
    if let playback, let player = attachedPlayer {
      // A re-attach inside this run picks up where this one was; any other detach hands the player back.
      resume = ["output-changed", "player-changed", "no-samples"].contains(reason) ? (playback.intendsPlaying, playback.playerHeld) : nil
      // The tap mutes the player: pause one that fills behind a paused stemmix before the tap goes, or it is heard
      // past where the user paused.
      if resume == nil, playback.playerFillsUnheard {
        playerControl.sendNow(.pause, player: player, timeout: Config.exitTeardownWait)
      }
    }
    nowPlaying?.release()
    playback?.stop()
    tap?.stop(wait: wait)
    tap = nil
    playback = nil
    attachedPlayer = nil
    lastInputSamples = nil
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
