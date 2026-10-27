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
  /// No later song is recorded: ask the music player itself to skip. Carried out on the main thread, not the IO thread.
  case skipPlayer
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

/// The recording ahead of the cursor, in frames: what plays before the cursor reaches the head.
func bufferedFrames(cursor: Int, head: Int) -> Int { max(0, head - cursor) }

/// Whether the music player should be playing: never while `held` (a pause made in the player, or the player
/// ending its own queue); else always while stemmix plays; while stemmix is paused, until `target` frames are
/// buffered ahead of the cursor.
func playerShouldPlay(playing: Bool, held: Bool, buffered: Int, target: Int) -> Bool {
  if held { return false }
  if playing { return true }
  return buffered < target
}

/// Whether stemmix plays as far as its commands and menu go: not once the player's queue ended (held while
/// playing) and the separated audio has run out, so one press of play starts the player again.
func effectivelyPlaying(intendsPlaying: Bool, held: Bool, separatedAhead: Int?, rate: Int) -> Bool {
  guard intendsPlaying, held else { return intendsPlaying }
  return (separatedAhead ?? 0) >= Int(Config.drainedSeconds * Double(rate))
}

/// Stemmix's play state and hold at an attach. A re-attach inside one daemon run (a new output device, a new
/// player process, a dead tap) keeps the last attach's; else the player's state decides: a player paused then
/// was paused by the user. The player keeps playing behind a paused stemmix, so its state alone would start a
/// re-attach playing.
func attachIntent(playerPlaying: Bool, resume: (playing: Bool, held: Bool)?) -> (playing: Bool, held: Bool) {
  resume ?? (playerPlaying, !playerPlaying)
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
    if let mark = marks.first(where: { $0.frame > cursor + rate }) { return .seek(mark.frame) }
    return .skipPlayer
  case .previous:
    let started = marks.filter { $0.frame <= cursor }
    guard let current = started.last else { return .none }
    let restart = Int(Config.previousRestartSeconds * Double(rate))
    if cursor - current.frame < restart, started.count >= 2 { return .seek(started[started.count - 2].frame) }
    return .seek(current.frame)
  }
}

/// Which of next and previous would act now: those `resolve` maps to anything but `.none`.
func availableCommands(cursor: Int, head: Int, playing: Bool, marks: [TrackMark], rate: Int, liveLag: Int) -> Set<TransportCommand> {
  Set([TransportCommand.next, .previous].filter {
    resolve($0, cursor: cursor, head: head, playing: playing, marks: marks, rate: rate, liveLag: liveLag) != .none
  })
}

/// What stemmix asks of the music player itself, by Apple event.
enum PlayerCommand: String { case play, pause, next }

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

/// An event stemmix expects from the music player after its own command: the state it asked for, or the track
/// change a forwarded "next" asked for.
enum PlayerEcho: Equatable { case playing, paused, trackChange }

/// Follows the music player: its pause and play become the player's, and each track change becomes a song mark.
/// A change that answers one of stemmix's own commands (an expected echo) is followed silently. A track change
/// well before the old song's end, by the song's play time, is a song picked in the music player: it plays, and
/// when the cursor is behind the live edge it jumps to the new song. A track change an own "next" asked for jumps
/// the cursor to the new song's start.
struct PlayerFollower {
  private var lastState: PlayerEvent.State
  private var trackID: String?
  private var trackDuration: Double?
  /// The song's play position at the last event, and when that was: play time counts only while playing, so a
  /// pause stemmix made in the player does not turn a later pick into a song's natural end.
  private var positionAtLastEvent = 0.0
  private var lastEventAt: TimeInterval?
  private var echoes = PendingEchoes<PlayerEcho>()

  init(playerPlaying: Bool) { lastState = playerPlaying ? .playing : .paused }

  /// The player's last known state is paused or stopped.
  var playerPaused: Bool { lastState != .playing }

  /// The player's play state to follow (`.play`, `.pause` or `.none`), a cursor jump, and a new song's mark.
  struct Reaction: Equatable {
    var action: TransportAction = .none
    var seek: Int?
    var mark: TrackMark?
    /// The player changed into Playing with this event, whoever asked for it.
    var startedPlaying = false
    /// The player stopped by itself at the end of its queue: stemmix plays out its buffer and asks the player
    /// for nothing until a play.
    var ended = false
  }

  mutating func expect(_ echo: PlayerEcho, until: TimeInterval) { echoes.expect(echo, until: until) }
  func isExpecting(_ echo: PlayerEcho, at now: TimeInterval) -> Bool { echoes.isPending(echo, at: now) }
  /// Stops waiting for one echo: its command was never taken.
  mutating func withdraw(_ echo: PlayerEcho, at now: TimeInterval) { _ = echoes.claim(echo, at: now) }
  /// The echoes that never came within their window.
  mutating func expire(at now: TimeInterval) -> [PlayerEcho] { echoes.expire(at: now) }
  /// Whether an own play or pause still waits for its answer.
  func awaitsState(at now: TimeInterval) -> Bool { echoes.isPending(.playing, at: now) || echoes.isPending(.paused, at: now) }

  /// Takes the player's state from what Core Audio reports, when no notification told it: the belief is otherwise
  /// changed only by the player's notifications, and a wrong one would stall the buffer rule.
  mutating func correct(playerPlaying: Bool, at now: TimeInterval) {
    guard playerPlaying != !playerPaused else { return }
    positionAtLastEvent += lastState == .playing ? now - (lastEventAt ?? now) : 0
    lastEventAt = now
    lastState = playerPlaying ? .playing : .paused
  }

  mutating func handle(_ event: PlayerEvent, now: TimeInterval, head: Int, behindLive: Bool) -> Reaction {
    var reaction = Reaction()
    let wasPlaying = lastState == .playing
    let isPlaying = event.state == .playing
    let elapsed = positionAtLastEvent + (wasPlaying ? now - (lastEventAt ?? now) : 0)
    if isPlaying != wasPlaying, !echoes.claim(isPlaying ? .playing : .paused, at: now) {
      // A stop, or a pause at the song's end with no next song, is the queue running out, not the user.
      let atEnd = event.state == .stopped || (event.trackID == trackID && trackDuration.map { duration in
        (event.positionSeconds ?? elapsed) >= duration - Config.skipBeforeEndSeconds
      } ?? false)
      if !isPlaying, atEnd {
        reaction.ended = true
      } else {
        reaction.action = isPlaying ? .play : .pause
      }
    }
    reaction.startedPlaying = isPlaying && !wasPlaying
    lastState = event.state

    if let id = event.trackID, id != trackID {
      let picked: Bool = {
        guard trackID != nil, let duration = trackDuration else { return false }
        return elapsed < duration - Config.skipBeforeEndSeconds
      }()
      trackID = id
      trackDuration = event.durationSeconds
      positionAtLastEvent = event.positionSeconds ?? 0
      reaction.mark = TrackMark(frame: head, title: event.title, artist: event.artist)
      if echoes.claim(.trackChange, at: now) {
        reaction.seek = head
      } else if picked, isPlaying {
        reaction.action = .play
        if behindLive { reaction.seek = head }
      }
    } else {
      positionAtLastEvent = event.positionSeconds ?? elapsed
    }
    lastEventAt = now
    return reaction
  }
}
