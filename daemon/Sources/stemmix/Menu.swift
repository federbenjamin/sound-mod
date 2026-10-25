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
  /// Play/Pause, Next, Previous, Back to live, Open log, Restart Stemmix, Quit Stemmix.
  let items: [MenuItem]
}

func menuContent(_ snapshot: MenuSnapshot) -> MenuContent {
  let player = snapshot.player
  let counts = snapshot.counts
  let sessions = "\(counts.working) of \(counts.live) \(counts.live == 1 ? "session" : "sessions") working"
  let fixed = [
    MenuItem(title: "Open log", isEnabled: true, action: .openLog),
    MenuItem(title: "Restart Stemmix", isEnabled: true, action: .restart),
    MenuItem(title: "Quit Stemmix", isEnabled: true, action: .quit),
  ]
  let seeks: [(String, TransportCommand)] = [("Next", .next), ("Previous", .previous), ("Back to live", .live)]

  switch snapshot.attachment {
  case let .detached(reason):
    let state: String
    switch reason {
    case .noSession: state = "No session open"
    case .playerNotRunning: state = "\(player) is not running"
    case .needsPermission: state = "Needs System Audio Recording permission"
    case .attaching: state = "Attaching"
    }
    let transport = [MenuItem(title: "Play", isEnabled: false, action: .transport(.toggle))]
      + seeks.map { MenuItem(title: $0.0, isEnabled: false, action: .transport($0.1)) }
    return MenuContent(icon: .detached, song: "Not attached", state: state, sessions: sessions, stems: nil, mediaKeys: nil, items: transport + fixed)

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
    let transport = [MenuItem(title: playback.playing ? "Pause" : "Play", isEnabled: true, action: .transport(.toggle))]
      + seeks.map { MenuItem(title: $0.0, isEnabled: playback.available.contains($0.1), action: .transport($0.1)) }
    return MenuContent(
      icon: playback.playing ? .playing : .paused, song: song, state: state, sessions: sessions, stems: stems,
      mediaKeys: mediaKeys, items: transport + fixed)
  }
}
