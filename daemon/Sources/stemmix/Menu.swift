/// What the menu shows of one attach's playback, read once per tick.
struct PlaybackSnapshot: Equatable {
  let playing: Bool
  let song: TrackMark?
  /// Whole seconds of recording ahead of the cursor.
  let bufferedSeconds: Int
  let available: Set<TransportCommand>
}

enum DetachReason: Equatable { case off, playerNotRunning, needsPermission, attaching }

/// Why the daemon is detached, from the two halves of its attach decision and the last refused permission.
func detachReason(on: Bool, playerRunning: Bool, permission: CapturePermission?) -> DetachReason {
  if !on { return .off }
  if !playerRunning { return .playerNotRunning }
  if permission != nil { return .needsPermission }
  return .attaching
}

/// The log's reason for dropping an attach: the first of the switch, the player setting, the player quitting, its
/// processes changing, the output device changing.
func detachLogReason(on: Bool, playerSettingChanged: Bool, playerRunning: Bool, targetsChanged: Bool) -> String {
  if !on { return "off" }
  if playerSettingChanged { return "player-setting" }
  if !playerRunning { return "player-quit" }
  return targetsChanged ? "player-changed" : "output-changed"
}

/// Everything the menu shows, built by the daemon each tick and shown only when it changed.
struct MenuSnapshot: Equatable {
  enum Attachment: Equatable {
    case detached(DetachReason)
    case attached(PlaybackSnapshot)
  }
  let attachment: Attachment
  let counts: Counts
  let config: ConfigFile
  let audible: Int
  let cutoffHz: Double?
  /// The last level line's sample count; nil until the first after an attach.
  let inputSamples: Int?
}

enum MenuIcon: Equatable { case detached, playing, paused }

enum MenuAction: Equatable {
  case toggleOnOff
  case transport(TransportCommand)
  case set(Setting)
  case openLog, restart, quit
}

struct MenuItem: Equatable {
  let title: String
  let isEnabled: Bool
  let action: MenuAction
  var isChecked = false
  var toolTip: String? = nil
}

/// One submenu of Settings: its title with the current value, and one item per option of its `SettingKind`.
struct SettingsGroup: Equatable {
  let title: String
  let isEnabled: Bool
  let options: [MenuItem]
}

struct MenuContent: Equatable {
  let icon: MenuIcon
  /// Beside the icon: how full the song is, working sessions out of `tracks`; nil while detached.
  let iconText: String?
  let song: String
  let state: String
  let sessions: String
  /// nil: hidden.
  let hearing: String?
  /// One per action of `MenuLayout.actionGroups`, in its order.
  let items: [MenuItem]
  /// One per group of `MenuLayout.settings`, in its order.
  let settings: [SettingsGroup]

  /// The info lines in menu order, `MenuLayout.infoLines` of them; nil: hidden.
  var lines: [String?] { [song, state, sessions, hearing] }
}

/// The menu's shape, built once by StatusMenu and filled by `menuContent`: the info lines, then each group of
/// action items after a separator, with the Settings submenu heading the `settingsGroup`th.
enum MenuLayout {
  static let infoLines = 4
  static let actionGroups: [[MenuAction]] = [
    [.transport(.toggle), .transport(.next), .transport(.previous)],
    [.openLog],
    [.toggleOnOff],
    [.restart, .quit],
  ]
  static let settingsGroup = 1
  static let settings = SettingKind.allCases
}

/// The Settings submenus, in menu order.
enum SettingKind: CaseIterable {
  case tracks, player, mode, mufflingMax, mufflingMin

  var options: [Setting] {
    switch self {
    case .tracks: return (1...8).map { .tracks($0) }
    case .player: return ["spotify", "music"].map { .player($0) }
    case .mode: return ListeningMode.allCases.map { .mode($0) }
    case .mufflingMax: return (0...10).map { .mufflingMax(Double($0)) }
    case .mufflingMin: return (0...10).map { .mufflingMin(Double($0)) }
    }
  }
}

/// The time buffered ahead, as m:ss.
func bufferedLabel(_ seconds: Int) -> String { "\(seconds / 60):" + String(format: "%02d", seconds % 60) }

/// One action's item; the transport items act only while attached (`playback` not nil).
private func menuItem(_ action: MenuAction, playback: PlaybackSnapshot?, on: Bool) -> MenuItem {
  switch action {
  case .toggleOnOff: return MenuItem(title: on ? "Turn Stemmix Off" : "Turn Stemmix On", isEnabled: true, action: action)
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
  case let .set(setting): return MenuItem(title: "", isEnabled: false, action: .set(setting))
  case .openLog: return MenuItem(title: "Open log", isEnabled: true, action: action)
  case .restart: return MenuItem(title: "Restart Stemmix", isEnabled: true, action: action)
  case .quit: return MenuItem(title: "Quit Stemmix", isEnabled: true, action: action)
  }
}

/// A setting's number as the menu shows it: 7, 5.5.
private func settingNumber(_ value: Double) -> String {
  value == value.rounded() ? String(Int(value)) : String(value)
}

/// A cutoff as the menu shows it: "651 Hz", "1.7 kHz".
private func hzText(_ hz: Double) -> String {
  hz < 1000 ? String(format: "%.0f Hz", hz) : String(format: "%.1f kHz", hz / 1000)
}

/// A muffling level with the cutoff it sets: "0 (none)", "5 (1.7 kHz)", "10 (150 Hz)".
func mufflingLabel(_ level: Double) -> String {
  "\(settingNumber(level)) (\(mufflingCutoffHz(level: level).map(hzText) ?? "none"))"
}

/// What you hear, in words: "Hearing: drums, bass", "Hearing: everything, muffled at 651 Hz".
func hearingLine(audible: Int, cutoffHz: Double?) -> String {
  let names = audibleStemList(audible).map { $0 == .other ? "other instruments" : $0.name }
  var line = "Hearing: " + (names.isEmpty ? "nothing" : names.count == Stem.allCases.count ? "everything" : names.joined(separator: ", "))
  if let cutoffHz, !names.isEmpty { line += ", muffled at \(hzText(cutoffHz))" }
  return line
}

private func sessionsText(_ n: Int) -> String { "\(n) \(n == 1 ? "session" : "sessions")" }

private func modeName(_ mode: ListeningMode) -> String {
  switch mode {
  case .instruments: return "Instruments"
  case .muffled: return "Muffled"
  case .both: return "Both"
  }
}

private func modeToolTip(_ mode: ListeningMode) -> String {
  switch mode {
  case .instruments: return "Fewer working sessions, fewer instruments."
  case .muffled: return "Every instrument plays, more muffled with fewer working sessions."
  case .both: return "Fewer instruments, and muffled."
  }
}

private func settingsGroup(_ kind: SettingKind, config: ConfigFile) -> SettingsGroup {
  let title: String
  switch kind {
  case .tracks: title = "Full song at: \(sessionsText(config.tracks))"
  case .player: title = "Player: \(Config.playerNames[Config.knownPlayer(config.player)]!)"
  case .mode: title = "Mode: \(modeName(config.mode))"
  case .mufflingMax: title = "Muffling at 1 session: \(settingNumber(config.mufflingMax))"
  case .mufflingMin: title = "Muffling at \(sessionsText(config.tracks)): \(settingNumber(config.mufflingMin))"
  }
  let items = kind.options.map { option -> MenuItem in
    let label: String
    var toolTip: String?
    switch option {
    case let .tracks(n): label = sessionsText(n)
    case let .player(key): label = Config.playerNames[key] ?? key
    case let .mode(mode):
      label = modeName(mode)
      toolTip = modeToolTip(mode)
    case let .mufflingMax(level), let .mufflingMin(level): label = mufflingLabel(level)
    }
    return MenuItem(title: label, isEnabled: true, action: .set(option), isChecked: config.with(option) == config, toolTip: toolTip)
  }
  let isEnabled: Bool
  switch kind {
  case .mufflingMax: isEnabled = config.mode.muffles && config.tracks > 1
  case .mufflingMin: isEnabled = config.mode.muffles
  case .tracks, .player, .mode: isEnabled = true
  }
  return SettingsGroup(title: title, isEnabled: isEnabled, options: items)
}

func menuContent(_ snapshot: MenuSnapshot) -> MenuContent {
  let player = Config.playerNames[Config.knownPlayer(snapshot.config.player)]!
  let counts = snapshot.counts
  let sessions = "\(counts.working) of \(counts.live) \(counts.live == 1 ? "session" : "sessions") working"
  let on = snapshot.attachment != .detached(.off)
  func items(_ playback: PlaybackSnapshot?) -> [MenuItem] { MenuLayout.actionGroups.joined().map { menuItem($0, playback: playback, on: on) } }
  let settings = MenuLayout.settings.map { settingsGroup($0, config: snapshot.config) }

  switch snapshot.attachment {
  case let .detached(reason):
    let state: String
    switch reason {
    case .off: state = "Off"
    case .playerNotRunning: state = "\(player) is not running"
    case .needsPermission: state = "Needs System Audio Recording permission"
    case .attaching: state = "Attaching"
    }
    return MenuContent(
      icon: .detached, iconText: nil, song: "Not attached", state: state, sessions: sessions, hearing: nil, items: items(nil),
      settings: settings)

  case let .attached(playback):
    let song: String
    if let mark = playback.song {
      song = mark.artist.isEmpty ? mark.title : "\(mark.title) — \(mark.artist)"
    } else {
      song = "Unknown song"
    }
    let buffered = "\(bufferedLabel(playback.bufferedSeconds)) buffered"
    let state: String
    if snapshot.inputSamples == 0 {
      state = "No audio from \(player)"
    } else {
      state = "\(playback.playing ? "Playing" : "Paused"), \(buffered)"
    }
    let tracks = snapshot.config.tracks
    return MenuContent(
      icon: playback.playing ? .playing : .paused, iconText: "\(min(counts.working, tracks))/\(tracks)", song: song, state: state,
      sessions: sessions, hearing: hearingLine(audible: snapshot.audible, cutoffHz: snapshot.cutoffHz), items: items(playback),
      settings: settings)
  }
}
