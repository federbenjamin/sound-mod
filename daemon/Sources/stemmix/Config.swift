import Foundation

enum Config {
  static let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/stemmix")
  static let sessionsDir = stateDir.appendingPathComponent("sessions")
  static let configFile = stateDir.appendingPathComponent("config.json")
  static let logFile = stateDir.appendingPathComponent("stemmix.log")
  static let lockFile = stateDir.appendingPathComponent("daemon.lock")

  static let pollInterval: TimeInterval = 0.25
  static let sessionStaleMs: Double = 6_000
  static let detachAfterIdle: TimeInterval = 60
  static let attachRetry: TimeInterval = 5
  static let levelInterval: TimeInterval = 10
  static let exitTeardownWait: TimeInterval = 5
  static let deadTapAfter: TimeInterval = 30
  static let permissionRecheck: TimeInterval = 30

  static let cutoffFloorHz = 150.0
  static let cutoffCeilingHz = 20_000.0
  static let rampSeconds = 0.4

  static let defaultTracks = 5
  static let defaultPlayer = "spotify"
  static let playerBundlePrefixes: [String: String] = [
    "spotify": "com.spotify",
    "music": "com.apple.Music",
  ]
}
