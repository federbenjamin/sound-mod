import Foundation

/// A request to the player, from any source: media keys, the music player's own state, the menu bar, or `--control`.
enum TransportCommand: String, CaseIterable {
  case play, pause, toggle, next, previous, live
}

/// What the IO thread is told to do.
enum TransportAction: Equatable {
  case none
  case play
  case pause
  case seek(Int)
}

/// A song start on the timeline, from the music player's track-change notification.
struct TrackMark: Equatable {
  let frame: Int
  let title: String
  let artist: String
}

/// The frame the cursor plays at when live: `liveLag` behind the recording head, never below 0.
func liveEdge(head: Int, liveLag: Int) -> Int { max(0, head - liveLag) }

/// Whether the cursor is within one second (`rate` frames) of the live edge, or past it.
func isAtLive(cursor: Int, head: Int, rate: Int, liveLag: Int) -> Bool {
  cursor >= liveEdge(head: head, liveLag: liveLag) - rate
}

/// Whole seconds the cursor plays behind the live edge, rounded; 0 exactly when `isAtLive`.
func secondsBehindLive(cursor: Int, head: Int, rate: Int, liveLag: Int) -> Int {
  guard !isAtLive(cursor: cursor, head: head, rate: rate, liveLag: liveLag) else { return 0 }
  return Int((Double(liveEdge(head: head, liveLag: liveLag) - cursor) / Double(rate)).rounded())
}

/// What a command means at this moment. `marks` are the song starts the recording still holds, in order.
func resolve(_ command: TransportCommand, cursor: Int, head: Int, playing: Bool, marks: [TrackMark], rate: Int, liveLag: Int) -> TransportAction {
  let edge = liveEdge(head: head, liveLag: liveLag)
  let atLive = isAtLive(cursor: cursor, head: head, rate: rate, liveLag: liveLag)
  switch command {
  case .play: return .play
  case .pause: return .pause
  case .toggle: return playing ? .pause : .play
  case .live:
    return atLive ? .none : .seek(edge)
  case .next:
    if let mark = marks.first(where: { $0.frame > cursor + rate && $0.frame < edge }) { return .seek(mark.frame) }
    return atLive ? .none : .seek(edge)
  case .previous:
    let started = marks.filter { $0.frame <= cursor }
    guard let current = started.last else { return .none }
    let restart = Int(Config.previousRestartSeconds * Double(rate))
    if cursor - current.frame < restart, started.count >= 2 { return .seek(started[started.count - 2].frame) }
    return .seek(current.frame)
  }
}

/// Which of next, previous and live would act now: those `resolve` maps to anything but `.none`.
func availableCommands(cursor: Int, head: Int, playing: Bool, marks: [TrackMark], rate: Int, liveLag: Int) -> Set<TransportCommand> {
  Set([TransportCommand.next, .previous, .live].filter {
    resolve($0, cursor: cursor, head: head, playing: playing, marks: marks, rate: rate, liveLag: liveLag) != .none
  })
}

/// One state change of the music player, parsed from its distributed notification.
struct PlayerEvent: Equatable {
  enum State: String { case playing, paused, stopped }
  let state: State
  let trackID: String?
  let title: String
  let artist: String
  let durationSeconds: Double?
  let positionSeconds: Double?
}

/// The distributed notification each player posts on every play state or track change.
let playerNotifications: [String: String] = [
  "spotify": "com.spotify.client.PlaybackStateChanged",
  "music": "com.apple.Music.playerInfo",
]

/// Reads a player notification's userInfo. Spotify's keys were read from its notifications on this Mac;
/// Apple Music's (`PersistentID`, `Total Time`) are the same shape but unverified here.
func parsePlayerEvent(_ info: [AnyHashable: Any]) -> PlayerEvent? {
  guard let stateText = info["Player State"] as? String, let state = PlayerEvent.State(rawValue: stateText.lowercased()) else { return nil }
  let id = (info["Track ID"] as? String) ?? (info["PersistentID"]).map { "\($0)" }
  let durationMs = number(info["Duration"]) ?? number(info["Total Time"])
  return PlayerEvent(
    state: state,
    trackID: id,
    title: info["Name"] as? String ?? "",
    artist: info["Artist"] as? String ?? "",
    durationSeconds: durationMs.map { $0 / 1000 },
    positionSeconds: number(info["Playback Position"]))
}

private func number(_ value: Any?) -> Double? {
  switch value {
  case let n as NSNumber: return n.doubleValue
  case let d as Double: return d
  case let i as Int: return Double(i)
  default: return nil
  }
}

/// Follows the music player: its pause and play become the player's, and each track change becomes a song mark.
/// A track change well before the old song's end is a skip made in the music player; when the cursor is behind
/// the live edge, the skip jumps the cursor to the new song.
struct PlayerFollower {
  private var lastState: PlayerEvent.State?
  private var trackID: String?
  private var trackStartedAt: TimeInterval?
  private var trackDuration: Double?

  /// The player's last reported state is paused or stopped.
  var playerPaused: Bool { lastState == .paused || lastState == .stopped }

  struct Reaction: Equatable {
    var action: TransportAction = .none
    var mark: TrackMark?
    /// The player changed into Playing with this event: from paused, stopped, or no event seen yet.
    var startedPlaying = false
  }

  mutating func handle(_ event: PlayerEvent, now: TimeInterval, head: Int, behindLive: Bool) -> Reaction {
    var reaction = Reaction()
    if event.state != .playing, lastState == .playing || lastState == nil {
      reaction.action = .pause
    } else if event.state == .playing, lastState == .paused || lastState == .stopped {
      reaction.action = .play
    }
    reaction.startedPlaying = event.state == .playing && lastState != .playing
    lastState = event.state

    if let id = event.trackID, id != trackID {
      let skipped: Bool = {
        guard trackID != nil, let started = trackStartedAt, let duration = trackDuration else { return false }
        return now - started < duration - Config.skipBeforeEndSeconds
      }()
      trackID = id
      trackDuration = event.durationSeconds
      trackStartedAt = now - (event.positionSeconds ?? 0)
      reaction.mark = TrackMark(frame: head, title: event.title, artist: event.artist)
      if skipped, behindLive, event.state == .playing { reaction.action = .seek(head) }
    }
    return reaction
  }
}
