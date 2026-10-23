import Foundation

enum Log {
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  static func line(_ text: String) {
    let row = "\(formatter.string(from: Date())) \(text)\n"
    let url = Config.logFile
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(row.utf8))
  }
}
