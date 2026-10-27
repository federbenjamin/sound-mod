import Foundation

enum Config {
  static let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/stemmix")
  static let sessionsDir = stateDir.appendingPathComponent("sessions")
  static let configFile = stateDir.appendingPathComponent("config.json")
  static let logFile = stateDir.appendingPathComponent("stemmix.log")
  static let separatorLogFile = stateDir.appendingPathComponent("separator.log")
  static let lockFile = stateDir.appendingPathComponent("daemon.lock")
  // Present while stemmix is switched off from its menu; absent (the first run) is on.
  static let offFile = stateDir.appendingPathComponent("off")

  static let pollInterval: TimeInterval = 0.25
  static let sessionStaleMs: Double = 6_000
  // A session counts as working until it has been not-working this long: agents idle a second or two between turns.
  static let workingHoldSeconds: Double = 5
  static let sessionFileMaxAgeMs: Double = 24 * 3_600_000
  static let attachRetry: TimeInterval = 5
  static let levelInterval: TimeInterval = 10
  // Core Audio IO buffer: playback runs seconds behind the player, so latency costs nothing and slack absorbs load.
  static let ioBufferFrames = 2048
  static let exitTeardownWait: TimeInterval = 5
  static let deadTapAfter: TimeInterval = 30
  static let permissionRecheck: TimeInterval = 30

  static let defaultTracks = 4
  static let defaultPlayer = "spotify"
  static let defaultMode = ListeningMode.instruments
  // Muffling 0...10 at one working session (max) and at `tracks` working sessions (min), log-spaced between the
  // ceiling (0: no filter) and the floor (10).
  static let defaultMufflingMax = 5.0
  static let defaultMufflingMin = 0.0
  static let mufflingFloorHz = 150.0
  static let mufflingCeilingHz = 20_000.0
  // How fast the cutoff glides to a new target.
  static let mufflingGlideSeconds = 0.1
  static let playerBundlePrefixes: [String: String] = [
    "spotify": "com.spotify",
    "music": "com.apple.Music",
  ]

  // The separator: a Python process running HTDemucs, installed by install.sh.
  static let separatorPython = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/stemmix/venv/bin/python")
  static let separatorScriptName = "stemmix_separator.py"
  static let separatorReadyTimeout: TimeInterval = 60
  static let separatorRequestTimeout: TimeInterval = 10
  static let separatorRestartBackoff: TimeInterval = 5

  // The sliding window. HTDemucs sees `windowSeconds`; each request keeps `hopSeconds` (plus the crossfade)
  // ending at least `minRightSeconds` before the window's edge, up to `maxRightSeconds` when audio is buffered.
  static let windowSeconds = 7.8
  static let hopSeconds = 1.0
  static let fadeSeconds = 0.05
  static let minRightSeconds = 3.0
  static let maxRightSeconds = 3.5
  static let lookaheadSeconds = 8.0
  // Headroom over the separator's compute time when placing the cursor at the live edge.
  static let computeMarginSeconds = 0.25

  // The timeline: how much recording is kept for a paused player, and how much separated audio is held.
  static let recordingSeconds = 360.0
  static let recordingGuardSeconds = 15.0
  static let stemsSeconds = 20.0
  // Separated audio ahead of the cursor before playback starts, and again after a stall.
  static let prebufferSeconds = 5.0

  static let stemRampSeconds = 1.0
  static let transportFadeSeconds = 0.01
  // A track change this far before the song's end is a skip, not the song finishing.
  static let skipBeforeEndSeconds = 5.0
  // "Previous" within this far into a song goes to the song before it.
  static let previousRestartSeconds = 3.0
  // After stemmix's own play, pause or next to the player, its state or track change within this long is the
  // answer, not the user's; a forwarded "next" holds the cursor at the head this long.
  static let playerEchoWindow: TimeInterval = 3
  // How long a player Apple event may wait for its reply; the first one waits on the Automation prompt.
  static let playerControlTimeout: TimeInterval = 30
  // Each player's bundle ID and the Apple events for its AppleScript "next track", "play" and "pause" (read from
  // its sdef).
  static let playerEvents: [String: (bundleID: String, eventClass: String, next: String, play: String, pause: String)] = [
    "spotify": ("com.spotify.client", "spfy", "Next", "Play", "Paus"),
    "music": ("com.apple.Music", "hook", "Next", "Play", "Paus"),
  ]
  // While stemmix is paused the player keeps playing, muted, until this much is buffered ahead of the cursor. Below
  // the recording minus its guard, or the cursor would be moved up past the oldest of it.
  static let bufferAheadSeconds = 300.0
  // Less separated audio than this ahead of the cursor after the player's queue ended is nothing left to play.
  static let drainedSeconds = 0.1

  static let controlNotification = Notification.Name("com.benjaminfeder.stemmix.control")

  // The Darwin notification mediaremoted posts on every move of the Now Playing slot (the media keys).
  static let nowPlayingPathChanged = "com.apple.MediaRemote.activePlayerPathDidChange"
  // A slot move this soon after stemmix's own set into Playing is stemmix's own.
  static let nowPlayingChangeWindow: TimeInterval = 1
  // At most one retake of a lost slot this often, so an app that also retakes on loss cannot loop with us.
  static let nowPlayingRetakeCooldown: TimeInterval = 30

  // The menu bar icon, SF Symbols drawn as templates; detached dims the playing symbol.
  static let menuSymbolDetached = "waveform"
  static let menuSymbolPlaying = "waveform"
  static let menuSymbolPaused = "pause.circle"
  // The names the menu shows for the `player` keys of config.json.
  static let playerNames: [String: String] = ["spotify": "Spotify", "music": "Music"]

  /// The `player` key of config.json when stemmix knows it, else the default player. Every per-player table
  /// (`playerBundlePrefixes`, `playerNames`, `playerNotifications`) has these keys.
  static func knownPlayer(_ key: String) -> String { playerBundlePrefixes[key] == nil ? defaultPlayer : key }
}
