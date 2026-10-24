import Foundation
import MediaPlayer

/// Makes the daemon the system's Now Playing app while it plays, so media keys, Control Center and headphone
/// buttons reach the player that is sounding. Released on detach so they go back to the music player.
final class NowPlaying {
  private let onCommand: (TransportCommand) -> Void
  private var claimed = false

  init(onCommand: @escaping (TransportCommand) -> Void) {
    self.onCommand = onCommand
  }

  func claim() {
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
    update(title: nil, artist: nil, playing: true)
    Log.line("now-playing claimed")
  }

  func update(title: String?, artist: String?, playing: Bool) {
    guard claimed else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title ?? "Stemmix",
      MPMediaItemPropertyArtist: artist ?? "",
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
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
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    Log.line("now-playing released")
  }
}
