import Foundation

enum Log {
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  /// One line per call, appended with O_APPEND so lines from the control loop and the teardown thread never overwrite each other.
  static func line(_ text: String) {
    let row = "\(formatter.string(from: Date())) \(text)\n"
    let url = Config.logFile
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = row.withCString { write(fd, $0, strlen($0)) }
  }
}
