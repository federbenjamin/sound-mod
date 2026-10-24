import CoreAudio
import Foundation

/// The control loop: reads the session files, decides whether the tap is attached and at what cutoff,
/// and logs every change. Audio work lives in Mixer and ProcessTap.
final class Daemon {
  private let reader = StateReader()
  private var tap: ProcessTap?
  private var mixer: Mixer?
  private var lastTarget: Target?
  private var lastCounts: Counts?
  private var lastSessions: [String: Bool] = [:]
  private var lastLiveAt = Date.distantPast
  private var nextAttachAt = Date.distantPast
  private var nextLevelAt = Date.distantPast
  private var silentSince: Date?
  private var lastPermission: CapturePermission?

  private var signalSources: [DispatchSourceSignal] = []

  func run() {
    guard Self.takeInstanceLock() else {
      Log.line("start refused pid=\(ProcessInfo.processInfo.processIdentifier): another stemmix daemon holds the lock")
      exit(0)
    }
    Log.line("start pid=\(ProcessInfo.processInfo.processIdentifier)")
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [self] in
        Log.line("signal \(sig): detaching before exit")
        tap?.stop(wait: Config.exitTeardownWait)
        tap = nil
        exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
    let timer = Timer(timeInterval: Config.pollInterval, repeats: true) { [self] _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.run()
  }

  private func tick() {
    let now = Date()
    let config = reader.config()
    let sessions = reader.sessions()
    let counts = summarize(sessions: Array(sessions.values), nowMs: now.timeIntervalSince1970 * 1000, staleMs: Config.sessionStaleMs)
    logSessionChanges(sessions)
    if counts.live > 0 { lastLiveAt = now }

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

    guard let mixer else { return }
    if now >= nextLevelAt {
      let level = mixer.takeLevel()
      Log.line("level in=\(level.rmsDb.map { String(format: "%.1fdBFS", $0) } ?? "none") samples=\(level.samples)")
      nextLevelAt = now.addingTimeInterval(Config.levelInterval)
      // A tap that delivers no samples at all while the player outputs is dead (a coreaudiod restart, a stale
      // aggregate): rebuild it rather than sit on it.
      if level.samples == 0, isOutputting(targets) {
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
    let k = min(counts.working, config.tracks)
    let target = Target(cutoffHz: k > 0 ? cutoffHz(working: k, tracks: config.tracks) : Config.cutoffFloorHz, gain: k > 0 ? 1 : 0)
    if target != lastTarget || counts != lastCounts {
      mixer.set(target)
      let cutoff = target.cutoffHz.map { String(format: "%.0f", $0) } ?? "bypass"
      Log.line("count working=\(counts.working) live=\(counts.live) tracks=\(config.tracks) k=\(k) cutoff=\(cutoff) gain=\(Int(target.gain))")
      lastTarget = target
      lastCounts = counts
    }
  }

  private func attach(targets: [AudioObjectID], output: OutputDevice, player: String) {
    // Never let coreaudiod ask TCC on our behalf: an unanswered System Audio Recording prompt leaves coreaudiod
    // blocked on every later tap until it restarts. Taps are made only once the permission is already granted.
    let permission = capturePermission()
    if permission != lastPermission {
      Log.line("permission \(permission.rawValue)")
      lastPermission = permission
    }
    guard permission == .authorized else {
      nextAttachAt = Date().addingTimeInterval(Config.permissionRecheck)
      return
    }
    do {
      let tap = try ProcessTap(targets: targets, output: output)
      let mixer = Mixer(tapFormat: tap.tapFormat)
      try tap.start { input, output, frames in mixer.render(input, output, frames: frames) }
      self.tap = tap
      self.mixer = mixer
      lastTarget = nil
      let formats = tap.outputStreamFormats().map { "\(Int($0.mSampleRate))Hz/\($0.mChannelsPerFrame)ch/\($0.mBitsPerChannel)bit" }.joined(separator: ",")
      Log.line("attach player=\(player) objects=\(targets) tap=\(Int(tap.tapFormat.mSampleRate))Hz/\(tap.tapFormat.mChannelsPerFrame)ch output=\(output.uid) streams=\(formats)")
    } catch {
      nextAttachAt = Date().addingTimeInterval(Config.attachRetry)
      Log.line("attach-failed player=\(player) error=\(error)")
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
    tap?.stop()
    tap = nil
    mixer = nil
    lastTarget = nil
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
    default: Daemon().run()
    }
  }
}
