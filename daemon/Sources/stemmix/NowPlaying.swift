import Foundation
import MediaPlayer
import notify

/// Makes the daemon the system's Now Playing app while attached, so media keys, Control Center and headphone
/// buttons reach the player that is sounding. mediaremoted hands the slot to the client that most recently
/// changed into Playing, so each claim and retake pulses the state through Playing. Released on detach so the
/// keys go back to the music player.
final class NowPlaying {
  private let onCommand: (TransportCommand) -> Void
  private var claimed = false
  /// The last `playbackState` this process set.
  private var state: MPNowPlayingPlaybackState = .unknown
  private var watch = SlotWatch()
  private var observing = false
  private var token: Int32 = 0

  init(onCommand: @escaping (TransportCommand) -> Void) {
    self.onCommand = onCommand
    let status = notify_register_dispatch(Config.nowPlayingPathChanged, &token, DispatchQueue.main) { [weak self] _ in
      self?.pathChanged()
    }
    observing = status == NOTIFY_STATUS_OK
    if !observing { Log.line("now-playing observer-failed status=\(status)") }
  }

  deinit {
    if observing { notify_cancel(token) }
  }

  /// Who holds the media keys, as the daemon believes; nil while not claimed or without the observer.
  var mediaKeys: SlotBelief? { claimed && observing ? watch.belief : nil }

  func claim(playing: Bool) {
    guard !claimed else { return }
    claimed = true
    let center = MPRemoteCommandCenter.shared()
    let commands: [(MPRemoteCommand, TransportCommand)] = [
      (center.playCommand, .play),
      (center.pauseCommand, .pause),
      (center.togglePlayPauseCommand, .toggle),
      (center.nextTrackCommand, .next),
      (center.previousTrackCommand, .previous),
    ]
    for (remote, command) in commands {
      remote.isEnabled = true
      remote.addTarget { [weak self] _ in
        DispatchQueue.main.async { self?.onCommand(command) }
        return .success
      }
    }
    setInfo(title: nil, artist: nil, playing: playing)
    pulse(playing: playing)
    watch.tookSlot(at: Self.now())
    Log.line("now-playing claimed playing=\(playing)")
  }

  func update(title: String?, artist: String?, playing: Bool) {
    guard claimed else { return }
    setInfo(title: title, artist: artist, playing: playing)
    let wasPlaying = state == .playing
    set(playing ? .playing : .paused)
    if playing, !wasPlaying { watch.tookSlot(at: Self.now()) }
  }

  /// Takes the slot back: one change into Playing, ending on `playing`.
  func retake(playing: Bool, reason: String) {
    guard claimed else { return }
    pulse(playing: playing)
    watch.tookSlot(at: Self.now())
    Log.line("now-playing retaken reason=\(reason) playing=\(playing)")
  }

  /// Judges the slot-change posts that no own set answered; called on every attached tick.
  func settle(playing: Bool) {
    guard claimed, case let .lost(allowed)? = watch.settle(now: Self.now()) else { return }
    Log.line("now-playing lost retake=\(allowed ? "yes" : "no")")
    if allowed { retake(playing: playing, reason: "lost") }
  }

  func release() {
    guard claimed else { return }
    claimed = false
    let center = MPRemoteCommandCenter.shared()
    for remote in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand] {
      remote.removeTarget(nil)
      remote.isEnabled = false
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    set(.stopped)
    watch = SlotWatch()
    Log.line("now-playing released")
  }

  private func pathChanged() {
    // Unclaimed, the post is release's own move back to the previous holder.
    guard claimed, watch.pathChanged(at: Self.now()) == .held else { return }
    Log.line("now-playing held")
  }

  /// A same-value set never reaches mediaremoted, so pause first when the last set was Playing; the sets reach
  /// it as separate transitions within one run-loop turn (design doc, choice 18).
  private func pulse(playing: Bool) {
    if state == .playing { set(.paused) }
    set(.playing)
    if !playing { set(.paused) }
  }

  private func set(_ newState: MPNowPlayingPlaybackState) {
    MPNowPlayingInfoCenter.default().playbackState = newState
    state = newState
  }

  private func setInfo(title: String?, artist: String?, playing: Bool) {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title ?? "Stemmix",
      MPMediaItemPropertyArtist: artist ?? "",
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
  }

  /// Monotonic, so a clock change cannot stretch or skip the window and the cooldown.
  private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
