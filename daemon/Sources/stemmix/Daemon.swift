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

  func run() {
    Log.line("start pid=\(ProcessInfo.processInfo.processIdentifier)")
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

  private func detach(reason: String) {
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
    Daemon().run()
  }
}
