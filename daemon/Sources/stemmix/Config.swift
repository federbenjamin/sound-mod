import Foundation

enum Config {
  static let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/stemmix")
  static let sessionsDir = stateDir.appendingPathComponent("sessions")
  static let configFile = stateDir.appendingPathComponent("config.json")
  static let logFile = stateDir.appendingPathComponent("stemmix.log")
  static let separatorLogFile = stateDir.appendingPathComponent("separator.log")
  static let lockFile = stateDir.appendingPathComponent("daemon.lock")

  static let pollInterval: TimeInterval = 0.25
  static let sessionStaleMs: Double = 6_000
  static let sessionFileMaxAgeMs: Double = 24 * 3_600_000
  static let detachAfterIdle: TimeInterval = 60
  static let attachRetry: TimeInterval = 5
  static let levelInterval: TimeInterval = 10
  static let exitTeardownWait: TimeInterval = 5
  static let deadTapAfter: TimeInterval = 30
  static let permissionRecheck: TimeInterval = 30

  static let defaultTracks = 4
  static let defaultPlayer = "spotify"
  static let defaultMode = ListeningMode.instruments
  // Muffling 0...10 at no working session (max) and at `tracks` working sessions (min), log-spaced between the
  // ceiling (0: no filter) and the floor (10).
  static let defaultMufflingMax = 7.0
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
  static let minRightSeconds = 1.5
  static let maxRightSeconds = 2.5
  static let lookaheadSeconds = 8.0
  // Headroom over the separator's compute time when placing the cursor at the live edge.
  static let computeMarginSeconds = 0.25

  // The timeline: how much recording is kept for a paused player, and how much separated audio is held.
  static let recordingSeconds = 600.0
  static let recordingGuardSeconds = 15.0
  static let stemsSeconds = 20.0

  static let stemRampSeconds = 0.4
  static let transportFadeSeconds = 0.01
  // A track change this far before the song's end is a skip, not the song finishing.
  static let skipBeforeEndSeconds = 5.0
  // "Previous" within this far into a song goes to the song before it.
  static let previousRestartSeconds = 3.0
  // "Next" with no later song recorded asks the player to skip; the cursor waits this long for its track change.
  static let forwardedSkipTimeout: TimeInterval = 3
  // How long the "next track" Apple event may wait for its reply; the first one waits on the Automation prompt.
  static let playerControlTimeout: TimeInterval = 30
  // Each player's bundle ID and the Apple event for its AppleScript "next track" (read from its sdef).
  static let playerNextTrack: [String: (bundleID: String, eventClass: String, eventID: String)] = [
    "spotify": ("com.spotify.client", "spfy", "Next"),
    "music": ("com.apple.Music", "hook", "Next"),
  ]

  static let controlNotification = Notification.Name("com.benjaminfeder.stemmix.control")
}
