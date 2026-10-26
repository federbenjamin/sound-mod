import CoreAudio
import Foundation
import Synchronization

/// The IO thread's side: records the tap into the timeline, plays the stems at the cursor, and carries out
/// transport actions. Nothing here waits or allocates; the control loop talks to it through atomics.
final class Player: @unchecked Sendable {
  let timeline: Timeline
  let shape: WindowShape

  /// How many stems to hear (0...4), set by the control loop.
  let audible = Atomic<Int>(0)
  /// The low-pass cutoff to glide to, in millihertz; 0 is no filter. Set by the control loop.
  let cutoffMilliHz = Atomic<Int>(0)
  /// Whether the player is playing (true) or paused, as the IO thread last applied it.
  let playing = Atomic<Bool>(true)
  /// Frames rendered as silence while playing because separated audio was not ready.
  let waitingFrames = Atomic<Int>(0)
  /// Level meters since the last read: sums of squares in fixed point (2^-20) and sample counts.
  let inputSumSq = Atomic<UInt64>(0)
  let inputSamples = Atomic<Int>(0)
  let outputSumSq = Atomic<UInt64>(0)
  let outputSamples = Atomic<Int>(0)
  /// Output samples past full scale (|x| > 1) since the last read: they clip at the device.
  let clippedSamples = Atomic<Int>(0)

  private let pending = Atomic<Int>(0)
  private let fadeStep: Float
  private let gainStep: Float
  private let guardFrames: Int
  private let gains: UnsafeMutablePointer<Float>
  private var wantPlaying = true
  /// Set once `prebufferFrames` of separated audio lie ahead of the cursor; cleared by a stall. Starting on a thin
  /// margin played and stalled by turns while the separator caught up.
  private var primed = false
  private let prebufferFrames: Int
  private var fade: Float = 0
  private var lowPass = LowPass(channels: Timeline.channels)
  /// The cutoff the filter is at, gliding toward the target; 0 while bypassed.
  private var cutoffHz = 0.0

  init(timeline: Timeline) {
    self.timeline = timeline
    shape = WindowShape(rate: timeline.rate)
    fadeStep = 1 / Float(Config.transportFadeSeconds * Double(timeline.rate))
    gainStep = 1 / Float(Config.stemRampSeconds * Double(timeline.rate))
    guardFrames = Int(Config.recordingGuardSeconds * Double(timeline.rate))
    prebufferFrames = Int(Config.prebufferSeconds * Double(timeline.rate))
    gains = .allocate(capacity: Stem.allCases.count)
    gains.initialize(repeating: 0, count: Stem.allCases.count)
  }

  deinit { gains.deallocate() }

  /// Hands an action to the IO thread; it applies the latest one at the start of its next cycle.
  /// A play state and a seek sent before the same cycle both apply: `pending` holds the state in bits 0-1
  /// (1 pause, 2 play), a seek flag in bit 2 and the seek's frame above it.
  func send(_ action: TransportAction) {
    switch action {
    case .none, .skipPlayer: return
    case .pause: merge { ($0 & ~3) | 1 }
    case .play: merge { ($0 & ~3) | 2 }
    case let .seek(frame): merge { ($0 & 3) | 4 | (max(frame, 0) << 3) }
    }
  }

  private func merge(_ update: (Int) -> Int) {
    var old = pending.load(ordering: .relaxed)
    while true {
      let (exchanged, current) = pending.compareExchange(expected: old, desired: update(old), ordering: .acquiringAndReleasing)
      if exchanged { return }
      old = current
    }
  }

  /// One IO cycle.
  func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputs where buffer.mData != nil { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
    guard frames > 0 else { return }
    record(input, frames: frames)
    let head = timeline.head.load(ordering: .relaxed)
    var cursor = timeline.cursor.load(ordering: .relaxed)

    // Once the recording wraps, the oldest `guardFrames` are about to be overwritten: never play or separate there.
    let oldestPlayable = timeline.oldestRecorded(head: head) + (head > timeline.recordingCapacity ? guardFrames : 0)
    let code = pending.exchange(0, ordering: .acquiring)
    switch code & 3 {
    case 1: wantPlaying = false
    case 2: wantPlaying = true
    default: break
    }
    if code & 4 != 0 {
      cursor = min(max(code >> 3, oldestPlayable), head)
      timeline.jump(to: cursor)
      fade = 0
      lowPass.reset()
    }
    // A pause longer than the recording holds: the oldest audio is dropped, so the cursor moves up with it. This
    // runs every cycle while the cursor sits there, so it keeps the generation: a jump would make every slice in
    // flight stale and the worker would never finish one.
    if cursor < oldestPlayable {
      cursor = oldestPlayable
      timeline.advance(to: cursor)
      fade = 0
    }
    playing.store(wantPlaying, ordering: .relaxed)

    let generation = timeline.generation.load(ordering: .relaxed)
    guard let frontier = timeline.frontier(for: generation), cursor + frames <= frontier, cursor >= frontier - timeline.stemCapacity else {
      primed = false
      if wantPlaying { waitingFrames.wrappingAdd(frames, ordering: .relaxed) }
      return
    }
    if !primed {
      guard frontier - cursor >= prebufferFrames else {
        if wantPlaying { waitingFrames.wrappingAdd(frames, ordering: .relaxed) }
        return
      }
      primed = true
    }
    guard wantPlaying || fade > 0 else { return }

    let audibleCount = audible.load(ordering: .relaxed)
    let filterOn = glideCutoff(frames: frames)
    let first = outputs[0]
    guard let data = first.mData else { return }
    let out = data.assumingMemoryBound(to: Float.self)
    let channels = Int(first.mNumberChannels)
    let outFrames = min(frames, Int(first.mDataByteSize) / max(channels * MemoryLayout<Float>.size, 1))
    var played = 0
    var sumSq: Float = 0
    var clipped = 0
    for i in 0..<outFrames {
      fade = wantPlaying ? min(1, fade + fadeStep) : max(0, fade - fadeStep)
      if fade == 0, !wantPlaying { break }
      for stem in 0..<Stem.allCases.count {
        let target: Float = stem < audibleCount ? 1 : 0
        gains[stem] = gains[stem] < target ? min(target, gains[stem] + gainStep) : max(target, gains[stem] - gainStep)
      }
      let frame = cursor + i
      for channel in 0..<min(channels, Timeline.channels) {
        let mix = timeline.recorded(frame, channel)
        let drums = timeline.separated(0, frame, channel)
        let bass = timeline.separated(1, frame, channel)
        let vocals = timeline.separated(2, frame, channel)
        let other = mix - drums - bass - vocals
        var value = fade * (gains[Stem.drums.rawValue] * drums + gains[Stem.bass.rawValue] * bass
          + gains[Stem.other.rawValue] * other + gains[Stem.vocals.rawValue] * vocals)
        if filterOn { value = lowPass.process(channel: channel, value) }
        out[i * channels + channel] = value
        sumSq += value * value
        if abs(value) > 1 { clipped += 1 }
      }
      if channels > Timeline.channels {
        for channel in Timeline.channels..<channels { out[i * channels + channel] = out[i * channels + channel % Timeline.channels] }
      }
      played = i + 1
    }
    for buffer in outputs.dropFirst() where buffer.mData != nil {
      memcpy(buffer.mData, data, min(Int(buffer.mDataByteSize), Int(first.mDataByteSize)))
    }
    cursor += played
    timeline.cursor.store(cursor, ordering: .releasing)
    outputSumSq.wrappingAdd(UInt64(Double(sumSq) * 1_048_576), ordering: .relaxed)
    if clipped > 0 { clippedSamples.wrappingAdd(clipped, ordering: .relaxed) }
    outputSamples.wrappingAdd(played * min(channels, Timeline.channels), ordering: .relaxed)
  }

  /// Moves the filter's cutoff toward the target over `mufflingGlideSeconds` (in the log domain, so a jump
  /// sounds even) and sets the coefficients for this cycle. Entering from bypass starts at the ceiling with a
  /// fresh state; leaving glides up to the ceiling, then bypasses. Returns whether to filter this cycle.
  private func glideCutoff(frames: Int) -> Bool {
    let rate = Double(timeline.rate)
    let ceiling = Config.mufflingCeilingHz
    let target = Double(cutoffMilliHz.load(ordering: .relaxed)) / 1000
    if target <= 0, cutoffHz <= 0 { return false }
    if cutoffHz <= 0 {
      cutoffHz = ceiling
      lowPass.reset()
    }
    let goal = target > 0 ? min(target, ceiling) : ceiling
    let step = 1 - exp(-Double(frames) / (Config.mufflingGlideSeconds * rate))
    cutoffHz = exp(log(cutoffHz) + (log(goal) - log(cutoffHz)) * step)
    if target <= 0, cutoffHz >= ceiling * 0.95 {
      cutoffHz = 0
      return false
    }
    lowPass.set(hz: cutoffHz, rate: rate)
    return true
  }

  private func record(_ input: UnsafePointer<AudioBufferList>, frames: Int) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = inputs.first, let data = first.mData else {
      return
    }
    let p = data.assumingMemoryBound(to: Float.self)
    let right = first.mNumberChannels < 2 && inputs.count >= 2 ? inputs[1].mData?.assumingMemoryBound(to: Float.self) : nil
    var sumSq: Float = 0
    let count = frames * Int(max(first.mNumberChannels, 1))
    for i in 0..<count { sumSq += p[i] * p[i] }
    var silent = sumSq == 0
    if silent, let right {
      for i in 0..<frames where right[i] != 0 {
        silent = false
        break
      }
    }
    inputSumSq.wrappingAdd(UInt64(Double(sumSq) * 1_048_576), ordering: .relaxed)
    inputSamples.wrappingAdd(count, ordering: .relaxed)
    // A tapped player that is paused hands over exact zeros. Recording them would fill the buffer ahead of the
    // cursor with silence while stemmix holds the player paused, so the head moves only over sound.
    guard !silent else { return }
    if first.mNumberChannels >= 2 {
      timeline.record(interleaved: p, frames: frames)
    } else if let right {
      timeline.record(left: p, right: right, frames: frames)
    } else {
      timeline.record(left: p, right: p, frames: frames)
    }
  }

  /// Reads and clears the level meters: (input dBFS, output dBFS), nil where nothing was measured.
  func takeLevels() -> (input: Double?, output: Double?, inputSamples: Int) {
    func db(_ sum: UInt64, _ count: Int) -> Double? {
      guard count > 0, sum > 0 else { return nil }
      return 10 * log10(Double(sum) / 1_048_576 / Double(count))
    }
    let inSum = inputSumSq.exchange(0, ordering: .relaxed)
    let inCount = inputSamples.exchange(0, ordering: .relaxed)
    let outSum = outputSumSq.exchange(0, ordering: .relaxed)
    let outCount = outputSamples.exchange(0, ordering: .relaxed)
    return (db(inSum, inCount), db(outSum, outCount), inCount)
  }
}
