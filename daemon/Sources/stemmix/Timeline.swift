import Synchronization

/// The audio between the tap and the speakers: the recording, the separated stems, and the positions on it.
/// Frame 0 is the first frame recorded after an attach; every position is an absolute frame number.
///
/// Single writer per field, so the IO thread never waits:
/// - the IO thread writes the recording and moves `head`, `cursor` and `generation` (a jump bumps it);
/// - the separation worker writes the stems ring and publishes the frontier for one generation;
/// - the control loop sets `headFinal`.
/// Separated audio below the frontier never changes until the next jump, so the IO thread reads it freely.
final class Timeline: @unchecked Sendable {
  static let channels = 2

  let rate: Int
  let recordingCapacity: Int
  let stemCapacity: Int

  /// Frames recorded so far.
  let head = Atomic<Int>(0)
  /// The next frame to play.
  let cursor = Atomic<Int>(0)
  /// Bumped on every jump of the cursor; separated audio from an older generation is stale.
  let generation = Atomic<Int>(0)
  /// The music player's queue ended, so the head moves no further until a play: the worker separates up to it.
  let headFinal = Atomic<Bool>(false)
  /// (generation << 48) | frontier: separated audio is final below `frontier` for that generation.
  private let frontierPacked = Atomic<Int>(0)
  private static let frontierBits = 48
  private static let frontierMask = (1 << frontierBits) - 1
  private static let generationMask = (1 << 15) - 1

  private let recording: UnsafeMutablePointer<Float>
  private let stems: UnsafeMutablePointer<Float>

  /// Allocates and touches both rings here, off the IO thread, so the IO thread never takes a first-write fault.
  init(rate: Int, recordingSeconds: Double, stemsSeconds: Double) {
    self.rate = rate
    recordingCapacity = Int(recordingSeconds * Double(rate))
    stemCapacity = Int(stemsSeconds * Double(rate))
    let recordingCount = recordingCapacity * Self.channels
    let stemsCount = Stem.separated.count * stemCapacity * Self.channels
    recording = .allocate(capacity: recordingCount)
    recording.initialize(repeating: 0, count: recordingCount)
    stems = .allocate(capacity: stemsCount)
    stems.initialize(repeating: 0, count: stemsCount)
  }

  deinit {
    recording.deallocate()
    stems.deallocate()
  }

  // MARK: IO thread

  /// Appends interleaved stereo frames to the recording and moves the head.
  func record(interleaved source: UnsafePointer<Float>, frames: Int) {
    let start = head.load(ordering: .relaxed)
    for i in 0..<frames {
      let slot = ((start + i) % recordingCapacity) * Self.channels
      recording[slot] = source[i * Self.channels]
      recording[slot + 1] = source[i * Self.channels + 1]
    }
    head.store(start + frames, ordering: .releasing)
  }

  /// Appends separate left and right channels (a non-interleaved tap) to the recording.
  func record(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
    let start = head.load(ordering: .relaxed)
    for i in 0..<frames {
      let slot = ((start + i) % recordingCapacity) * Self.channels
      recording[slot] = left[i]
      recording[slot + 1] = right[i]
    }
    head.store(start + frames, ordering: .releasing)
  }

  /// One recorded sample; the caller keeps `frame` within the kept recording.
  @inline(__always) func recorded(_ frame: Int, _ channel: Int) -> Float {
    recording[(frame % recordingCapacity) * Self.channels + channel]
  }

  /// One separated sample (index into `Stem.separated`); the caller keeps `frame` below the frontier.
  @inline(__always) func separated(_ index: Int, _ frame: Int, _ channel: Int) -> Float {
    stems[(index * stemCapacity + frame % stemCapacity) * Self.channels + channel]
  }

  /// The first frame the recording still holds.
  func oldestRecorded(head: Int) -> Int { max(0, head - recordingCapacity) }

  /// Moves the cursor to `frame` and starts a new generation (IO thread only).
  func jump(to frame: Int) {
    cursor.store(frame, ordering: .releasing)
    generation.wrappingAdd(1, ordering: .releasing)
  }

  /// Moves the cursor forward in the same generation (IO thread only): separated audio past `frame` stays good.
  func advance(to frame: Int) {
    cursor.store(frame, ordering: .releasing)
  }

  // MARK: Separation worker

  /// Publishes that separated audio below `frontier` is final for `generation`.
  func publishFrontier(_ frontier: Int, generation: Int) {
    frontierPacked.store(((generation & Self.generationMask) << Self.frontierBits) | frontier, ordering: .releasing)
  }

  /// The frontier, if it belongs to `generation`.
  func frontier(for generation: Int) -> Int? {
    let packed = frontierPacked.load(ordering: .acquiring)
    guard packed >> Self.frontierBits == generation & Self.generationMask else { return nil }
    return packed & Self.frontierMask
  }

  /// Copies `frames` of the recording from `start` into `destination` (interleaved), with zeros for frames
  /// never recorded or already dropped.
  func copyRecording(from start: Int, frames: Int, into destination: UnsafeMutablePointer<Float>) {
    let end = head.load(ordering: .acquiring)
    let oldest = oldestRecorded(head: end)
    for i in 0..<frames {
      let frame = start + i
      let inside = frame >= oldest && frame < end
      destination[i * Self.channels] = inside ? recorded(frame, 0) : 0
      destination[i * Self.channels + 1] = inside ? recorded(frame, 1) : 0
    }
  }

  /// Writes one separated slice starting at `start`: `source` holds each separated stem in turn, `frames` of
  /// interleaved stereo. The last `fade` frames ramp down for the next slice to add onto. The first `fade` frames
  /// ramp up and add onto the previous slice's ramp-down, unless `first` (a fresh generation), which assigns.
  func writeSlice(at start: Int, frames: Int, fade: Int, first: Bool, from source: UnsafePointer<Float>) {
    for stem in 0..<Stem.separated.count {
      for i in 0..<frames {
        let weight = sliceWeight(i, frames: frames, fade: fade, first: first)
        let slot = (stem * stemCapacity + (start + i) % stemCapacity) * Self.channels
        let input = (stem * frames + i) * Self.channels
        let add = !first && i < fade
        for channel in 0..<Self.channels {
          let value = source[input + channel] * weight
          stems[slot + channel] = add ? stems[slot + channel] + value : value
        }
      }
    }
  }
}

/// The crossfade weight of frame `i` in a slice: a linear ramp up over the first `fade` frames (none for the
/// first slice of a generation) and down over the last `fade`. Overlapping ramps of neighbouring slices sum to 1.
func sliceWeight(_ i: Int, frames: Int, fade: Int, first: Bool) -> Float {
  guard fade > 0 else { return 1 }
  var weight: Float = 1
  if !first, i < fade { weight = Float(i) / Float(fade) }
  if i >= frames - fade { weight = min(weight, Float(frames - i) / Float(fade)) }
  return weight
}
