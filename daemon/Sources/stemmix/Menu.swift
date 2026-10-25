/// What the menu shows of one attach's playback, read once per tick.
struct PlaybackSnapshot: Equatable {
  let playing: Bool
  let playerPaused: Bool
  let song: TrackMark?
  let secondsBehindLive: Int
  let available: Set<TransportCommand>
}

enum DetachReason: Equatable { case noSession, playerNotRunning, needsPermission, attaching }

/// Why the daemon is detached, from the two halves of its attach decision and the last refused permission.
func detachReason(sessionOpen: Bool, playerRunning: Bool, permission: CapturePermission?) -> DetachReason {
  if !sessionOpen { return .noSession }
  if !playerRunning { return .playerNotRunning }
  if permission != nil { return .needsPermission }
  return .attaching
}

/// Everything the menu shows, built by the daemon each tick and shown only when it changed.
struct MenuSnapshot: Equatable {
  enum Attachment: Equatable {
    case detached(DetachReason)
    case attached(PlaybackSnapshot)
  }
  let attachment: Attachment
  let counts: Counts
  let player: String
  let audible: Int
  let cutoffHz: Double?
  /// The last level line's sample count; nil until the first after an attach.
  let inputSamples: Int?
  let mediaKeys: SlotBelief?
}

enum MenuIcon: Equatable { case detached, playing, paused }

enum MenuAction: Equatable {
  case transport(TransportCommand)
  case openLog, restart, quit
}

struct MenuItem: Equatable {
  let title: String
  let isEnabled: Bool
  let action: MenuAction
}

struct MenuContent: Equatable {
  let icon: MenuIcon
  let song: String
  let state: String
  let sessions: String
  /// nil: hidden.
  let stems: String?
  /// nil: hidden.
  let mediaKeys: String?
  /// One per action of `MenuLayout.actionGroups`, in its order.
  let items: [MenuItem]

  /// The info lines in menu order, `MenuLayout.infoLines` of them; nil: hidden.
  var lines: [String?] { [song, state, sessions, stems, mediaKeys] }
}

/// The menu's shape, built once by StatusMenu and filled by `menuContent`: the info lines, then each group of
/// action items after a separator.
enum MenuLayout {
  static let infoLines = 5
  static let actionGroups: [[MenuAction]] = [
    [.transport(.toggle), .transport(.next), .transport(.previous), .transport(.live)],
    [.openLog],
    [.restart, .quit],
  ]
}

/// One action's item; the transport items act only while attached (`playback` not nil).
private func menuItem(_ action: MenuAction, playback: PlaybackSnapshot?) -> MenuItem {
  switch action {
  case let .transport(command):
    let title: String
    switch command {
    case .play, .pause, .toggle: title = playback?.playing == true ? "Pause" : "Play"
    case .next: title = "Next"
    case .previous: title = "Previous"
    case .live: title = "Back to live"
    }
    let enabled = playback.map { [.play, .pause, .toggle].contains(command) || $0.available.contains(command) } ?? false
    return MenuItem(title: title, isEnabled: enabled, action: action)
  case .openLog: return MenuItem(title: "Open log", isEnabled: true, action: action)
  case .restart: return MenuItem(title: "Restart Stemmix", isEnabled: true, action: action)
  case .quit: return MenuItem(title: "Quit Stemmix", isEnabled: true, action: action)
  }
}

func menuContent(_ snapshot: MenuSnapshot) -> MenuContent {
  let player = snapshot.player
  let counts = snapshot.counts
  let sessions = "\(counts.working) of \(counts.live) \(counts.live == 1 ? "session" : "sessions") working"
  func items(_ playback: PlaybackSnapshot?) -> [MenuItem] { MenuLayout.actionGroups.joined().map { menuItem($0, playback: playback) } }

  switch snapshot.attachment {
  case let .detached(reason):
    let state: String
    switch reason {
    case .noSession: state = "No session open"
    case .playerNotRunning: state = "\(player) is not running"
    case .needsPermission: state = "Needs System Audio Recording permission"
    case .attaching: state = "Attaching"
    }
    return MenuContent(icon: .detached, song: "Not attached", state: state, sessions: sessions, stems: nil, mediaKeys: nil, items: items(nil))

  case let .attached(playback):
    let song: String
    if let mark = playback.song {
      song = mark.artist.isEmpty ? mark.title : "\(mark.title) — \(mark.artist)"
    } else {
      song = "Unknown song"
    }
    let behind = playback.secondsBehindLive
    let position = behind == 0 ? "live" : "\(behind) s behind live"
    let state: String
    if snapshot.inputSamples == 0 {
      state = "No audio from \(player)"
    } else if playback.playing {
      state = "Playing, \(position)"
    } else if playback.playerPaused {
      state = "\(player) is paused"
    } else {
      state = "Paused, \(position)"
    }
    var stems = "Stems: \(stemNames(audible: snapshot.audible))"
    if let cutoff = snapshot.cutoffHz { stems += ", muffled at \(cutoffLabel(cutoff))" }
    let mediaKeys = snapshot.mediaKeys.map { $0 == .held ? "Media keys: Stemmix" : "Media keys: another app" }
    return MenuContent(
      icon: playback.playing ? .playing : .paused, song: song, state: state, sessions: sessions, stems: stems,
      mediaKeys: mediaKeys, items: items(playback))
  }
}
