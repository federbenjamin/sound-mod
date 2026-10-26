import Foundation
import Synchronization

/// Keeps separated audio ahead of the cursor: picks the next slice (`nextJob`), sends its window to the
/// separator, and writes the result into the timeline. Owns the separator process: starts it, restarts it after
/// a failure, and stops it with the worker.
final class SeparationWorker: @unchecked Sendable {
  private let timeline: Timeline
  private let shape: WindowShape
  private let stopped = Atomic<Bool>(false)
  private let finished = DispatchSemaphore(value: 0)
  private var thread: Thread?

  /// Separator compute times since the last read, in ms, and failures.
  private let statsLock = NSLock()
  private var times: [Double] = []
  private var failures = 0

  /// Called once, on the worker thread, when the first separator of this attach is ready.
  private let onFirstReady: () -> Void
  /// Whether the player is playing; read on the worker thread before each slice.
  private let isPlaying: () -> Bool

  init(timeline: Timeline, isPlaying: @escaping () -> Bool, onFirstReady: @escaping () -> Void) {
    self.timeline = timeline
    self.isPlaying = isPlaying
    self.onFirstReady = onFirstReady
    shape = WindowShape(rate: timeline.rate)
  }

  func start() {
    let thread = Thread { [self] in run(); finished.signal() }
    thread.name = "stemmix.separation"
    thread.qualityOfService = .userInitiated
    self.thread = thread
    thread.start()
  }

  /// Stops the worker and the separator; waits for the current request (bounded by its own timeout).
  func stop() {
    guard thread != nil else { return }
    stopped.store(true, ordering: .releasing)
    _ = finished.wait(timeout: .now() + Config.separatorRequestTimeout + 2)
    thread = nil
  }

  /// (median ms, count, failures) since the last call.
  func takeStats() -> (medianMs: Double?, count: Int, failures: Int) {
    statsLock.lock()
    defer { times.removeAll(keepingCapacity: true); failures = 0; statsLock.unlock() }
    let sorted = times.sorted()
    return (sorted.isEmpty ? nil : sorted[sorted.count / 2], sorted.count, failures)
  }

  private func run() {
    let names = Stem.separated.map(\.name)
    let window = UnsafeMutablePointer<Float>.allocate(capacity: shape.window * Timeline.channels)
    let slice = UnsafeMutablePointer<Float>.allocate(capacity: names.count * (shape.hop + shape.fade) * Timeline.channels)
    defer { window.deallocate(); slice.deallocate() }
    var separator: SeparatorClient?
    defer { separator?.terminate() }
    var retryAt = Date.distantPast
    var generation = -1
    var frontier = 0
    var first = true
    var everReady = false

    while !stopped.load(ordering: .acquiring) {
      if separator == nil {
        guard Date() >= retryAt else { usleep(50_000); continue }
        do {
          guard let script = separatorScript() else { throw SeparatorError.missing("separator script in the app bundle") }
          separator = try SeparatorClient(python: Config.separatorPython, script: script)
          if !everReady {
            everReady = true
            onFirstReady()
          }
        } catch {
          Log.line("separator start-failed error=\(error)")
          retryAt = Date().addingTimeInterval(Config.separatorRestartBackoff)
          continue
        }
      }

      let current = timeline.generation.load(ordering: .acquiring)
      let cursor = timeline.cursor.load(ordering: .acquiring)
      // A jump, or the cursor moved up past the separated audio with the oldest recording: restart at the cursor.
      if current != generation || frontier < cursor {
        generation = current
        frontier = cursor
        first = true
        timeline.publishFrontier(frontier, generation: generation)
      }
      let head = timeline.head.load(ordering: .acquiring)
      guard let job = nextJob(head: head, cursor: cursor, frontier: frontier, playing: isPlaying(), shape: shape) else {
        usleep(20_000)
        continue
      }

      timeline.copyRecording(from: job.windowStart, frames: shape.window, into: window)
      do {
        let ms = try separator!.separate(window: window, frames: shape.window, rate: timeline.rate, keepStart: job.keepStart, keepFrames: job.keepFrames, stems: names, output: slice)
        statsLock.lock()
        times.append(ms)
        statsLock.unlock()
      } catch {
        Log.line("separator request-failed error=\(error); restarting it")
        statsLock.lock()
        failures += 1
        statsLock.unlock()
        separator?.terminate()
        separator = nil
        retryAt = Date().addingTimeInterval(Config.separatorRestartBackoff)
        continue
      }
      // A jump while the request ran makes this slice stale.
      guard timeline.generation.load(ordering: .acquiring) == generation else { continue }
      timeline.writeSlice(at: job.sliceStart, frames: job.keepFrames, fade: shape.fade, first: first, from: slice)
      first = false
      frontier = job.sliceStart + shape.hop
      timeline.publishFrontier(frontier, generation: generation)
    }
  }
}
