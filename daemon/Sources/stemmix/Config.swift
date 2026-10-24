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

  static let controlNotification = Notification.Name("com.benjaminfeder.stemmix.control")
}
