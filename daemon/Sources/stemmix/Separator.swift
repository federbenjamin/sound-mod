import Foundation

enum SeparatorError: Error, CustomStringConvertible {
  case missing(String)
  case timeout(String)
  case closed(String)
  case failed(String)

  var description: String {
    switch self {
    case let .missing(what): return "missing \(what)"
    case let .timeout(what): return "timed out \(what)"
    case let .closed(what): return "pipe closed \(what)"
    case let .failed(what): return what
    }
  }
}

/// The separator child process. Every read and write has a deadline; on any error the caller terminates it and
/// starts a new one. SIGPIPE is ignored process-wide (Daemon.run), so a dead child is an EPIPE here, not a crash.
final class SeparatorClient {
  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let toChild: Int32
  private let fromChild: Int32
  private var nextID = 0
  private(set) var stems: [String] = []

  init(python: URL, script: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: python.path) else { throw SeparatorError.missing("python at \(python.path); run install.sh") }
    guard FileManager.default.fileExists(atPath: script.path) else { throw SeparatorError.missing("separator script at \(script.path)") }
    process.executableURL = python
    process.arguments = ["-I", "-B", script.path]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    var log: FileHandle?
    if Log.usesStateFiles {
      try? FileManager.default.createDirectory(at: Config.stateDir, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: Config.separatorLogFile.path) {
        FileManager.default.createFile(atPath: Config.separatorLogFile.path, contents: nil)
      }
      log = try FileHandle(forWritingTo: Config.separatorLogFile)
      log?.seekToEndOfFile()
    }
    process.standardError = log ?? FileHandle.standardError
    toChild = stdinPipe.fileHandleForWriting.fileDescriptor
    fromChild = stdoutPipe.fileHandleForReading.fileDescriptor
    try process.run()
    try? log?.close()

    let (ready, _) = try readFrame(timeout: Config.separatorReadyTimeout, payloadInto: nil, capacity: 0)
    guard ready.ready == true, let names = ready.stems else { throw SeparatorError.failed("no ready frame") }
    stems = names
    Log.line("separator ready pid=\(process.processIdentifier) model=\(ready.model ?? "?") stems=\(names.joined(separator: ","))")
  }

  deinit { terminate() }

  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  /// Separates `window` (interleaved stereo, `frames` long at `rate`) and writes the kept slice of each stem in
  /// `stems` into `output`, stem after stem. Returns the separator's own compute time in ms.
  func separate(window: UnsafePointer<Float>, frames: Int, rate: Int, keepStart: Int, keepFrames: Int, stems wanted: [String], output: UnsafeMutablePointer<Float>) throws -> Double {
    nextID += 1
    let payloadBytes = frames * Timeline.channels * MemoryLayout<Float>.size
    let request = SeparatorRequest(id: nextID, rate: rate, frames: frames, keepStart: keepStart, keepFrames: keepFrames, stems: wanted, payloadBytes: payloadBytes)
    let header = try SeparatorProtocol.encodeHeader(request)
    try header.withUnsafeBytes { try writeAll($0.baseAddress!, header.count) }
    try writeAll(UnsafeRawPointer(window), payloadBytes)

    let expected = wanted.count * keepFrames * Timeline.channels * MemoryLayout<Float>.size
    let (reply, received) = try readFrame(timeout: Config.separatorRequestTimeout, payloadInto: UnsafeMutableRawPointer(output), capacity: expected)
    if let error = reply.error { throw SeparatorError.failed("separator error: \(error)") }
    guard reply.id == nextID, received == expected else {
      throw SeparatorError.failed("reply id=\(reply.id ?? -1) bytes=\(received), wanted id=\(nextID) bytes=\(expected)")
    }
    return reply.ms ?? 0
  }

  private func readFrame(timeout: TimeInterval, payloadInto payload: UnsafeMutableRawPointer?, capacity: Int) throws -> (SeparatorReply, Int) {
    let deadline = Date().addingTimeInterval(timeout)
    var prefix = [UInt8](repeating: 0, count: 4)
    try prefix.withUnsafeMutableBytes { try readAll($0.baseAddress!, 4, deadline: deadline) }
    let length = SeparatorProtocol.headerLength(Data(prefix))
    guard length > 0, length < 1 << 20 else { throw SeparatorError.failed("bad header length \(length)") }
    var json = [UInt8](repeating: 0, count: length)
    try json.withUnsafeMutableBytes { try readAll($0.baseAddress!, length, deadline: deadline) }
    let reply = try SeparatorProtocol.decodeReply(Data(json))
    let bytes = reply.payloadBytes
    guard bytes > 0 else { return (reply, 0) }
    guard let payload, bytes <= capacity else { throw SeparatorError.failed("unexpected payload of \(bytes) bytes") }
    try readAll(payload, bytes, deadline: deadline)
    return (reply, bytes)
  }

  private func readAll(_ buffer: UnsafeMutableRawPointer, _ count: Int, deadline: Date) throws {
    var done = 0
    while done < count {
      try wait(fromChild, events: Int16(POLLIN), deadline: deadline, what: "reading")
      let n = read(fromChild, buffer + done, count - done)
      if n == 0 { throw SeparatorError.closed("reading") }
      if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw SeparatorError.failed("read errno \(errno)") }
      done += n
    }
  }

  private func writeAll(_ buffer: UnsafeRawPointer, _ count: Int) throws {
    let deadline = Date().addingTimeInterval(Config.separatorRequestTimeout)
    var done = 0
    while done < count {
      try wait(toChild, events: Int16(POLLOUT), deadline: deadline, what: "writing")
      let n = write(toChild, buffer + done, count - done)
      if n < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw errno == EPIPE ? SeparatorError.closed("writing") : SeparatorError.failed("write errno \(errno)")
      }
      done += n
    }
  }

  private func wait(_ fd: Int32, events: Int16, deadline: Date, what: String) throws {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { throw SeparatorError.timeout(what) }
      var entry = pollfd(fd: fd, events: events, revents: 0)
      let ready = poll(&entry, 1, Int32(min(remaining, 1) * 1000))
      if ready > 0 {
        if entry.revents & Int16(POLLNVAL) != 0 { throw SeparatorError.closed(what) }
        return
      }
      if ready < 0, errno != EINTR { throw SeparatorError.failed("poll errno \(errno)") }
      if !process.isRunning { throw SeparatorError.closed("\(what): separator exited \(process.terminationStatus)") }
    }
  }
}

/// Where the separator script is: inside the app bundle, or `STEMMIX_SEPARATOR` for a run outside it (--simulate).
func separatorScript() -> URL? {
  if let path = ProcessInfo.processInfo.environment["STEMMIX_SEPARATOR"] { return URL(fileURLWithPath: path) }
  return Bundle.main.url(forResource: "stemmix_separator", withExtension: "py")
}
