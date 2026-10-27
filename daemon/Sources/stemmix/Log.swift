import Foundation
import Synchronization

/// The daemon's log. Only the daemon writes the files in the state folder; every other run (tests, `--simulate`,
/// `--control`) writes to stderr, so it never mixes into the running daemon's log.
enum Log {
  private static let toFile = Atomic<Bool>(false)

  /// Called once by the daemon at its start.
  static func useStateFiles() { toFile.store(true, ordering: .relaxed) }

  static var usesStateFiles: Bool { toFile.load(ordering: .relaxed) }

  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// One line per call, appended with O_APPEND so lines from the control loop and the teardown thread never overwrite each other.
  static func line(_ text: String) {
    let row = "\(formatter.string(from: Date())) \(text)\n"
    guard usesStateFiles else {
      FileHandle.standardError.write(Data(row.utf8))
      return
    }
    let url = Config.logFile
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = row.withCString { write(fd, $0, strlen($0)) }
  }
}
