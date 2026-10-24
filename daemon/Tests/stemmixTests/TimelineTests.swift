import XCTest

@testable import stemmix

final class TimelineTests: XCTestCase {
  private func ramp(_ from: Int, _ count: Int) -> [Float] {
    (0..<count * 2).map { Float(from * 2 + $0) }
  }

  // MARK: recording

  func testRecordRoundTripsAcrossRingWrap() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)  // capacity 1000
    for start in [0, 700] {
      let data = ramp(start, 700)
      data.withUnsafeBufferPointer { t.record(interleaved: $0.baseAddress!, frames: 700) }
    }
    XCTAssertEqual(t.head.load(ordering: .relaxed), 1400)
    XCTAssertEqual(t.oldestRecorded(head: 1400), 400)
    for frame in [400, 999, 1000, 1001, 1399] {
      XCTAssertEqual(t.recorded(frame, 0), Float(frame * 2))
      XCTAssertEqual(t.recorded(frame, 1), Float(frame * 2 + 1))
    }
  }

  func testPlanarRecordInterleavesChannels() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)
    let l: [Float] = [1, 2, 3], r: [Float] = [-1, -2, -3]
    l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in t.record(left: lp.baseAddress!, right: rp.baseAddress!, frames: 3) } }
    XCTAssertEqual((0..<3).map { t.recorded($0, 0) }, l)
    XCTAssertEqual((0..<3).map { t.recorded($0, 1) }, r)
  }

  func testCopyRecordingZeroFillsBeforeZeroAndPastHead() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)
    ramp(1, 100).withUnsafeBufferPointer { t.record(interleaved: $0.baseAddress!, frames: 100) }
    // Frame f holds 2(f+1) / 2(f+1)+1, so every real sample is non-zero.
    var out = [Float](repeating: 9, count: 2 * 20)
    t.copyRecording(from: -5, frames: 20, into: &out)
    XCTAssertEqual(Array(out[0..<10]), [Float](repeating: 0, count: 10))
    XCTAssertEqual(out[10], 2)  // frame 0
    XCTAssertEqual(out[11], 3)

    var tail = [Float](repeating: 9, count: 2 * 10)
    t.copyRecording(from: 95, frames: 10, into: &tail)
    var expected = [Float]()
    for f in 95..<100 { expected += [Float(2 * f + 2), Float(2 * f + 3)] }
    XCTAssertEqual(Array(tail[0..<10]), expected)
    XCTAssertEqual(Array(tail[10..<20]), [Float](repeating: 0, count: 10))
  }

  func testCopyRecordingZeroFillsBeforeOldestRecorded() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)
    for start in [0, 600, 1200] {
      ramp(start, 600).withUnsafeBufferPointer { t.record(interleaved: $0.baseAddress!, frames: 600) }
    }
    // head 1800, oldest 800
    var out = [Float](repeating: 9, count: 2 * 10)
    t.copyRecording(from: 795, frames: 10, into: &out)
    XCTAssertEqual(Array(out[0..<10]), [Float](repeating: 0, count: 10))
    var out2 = [Float](repeating: 9, count: 2 * 4)
    t.copyRecording(from: 800, frames: 4, into: &out2)
    XCTAssertEqual(out2, [1600, 1601, 1602, 1603, 1604, 1605, 1606, 1607])
  }

  // MARK: frontier

  func testFrontierIsOnlyVisibleToItsOwnGeneration() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)
    t.publishFrontier(4321, generation: 3)
    XCTAssertEqual(t.frontier(for: 3), 4321)
    XCTAssertNil(t.frontier(for: 2))
    XCTAssertNil(t.frontier(for: 4))
    XCTAssertNil(t.frontier(for: 0))
  }

  func testJumpMovesCursorAndBumpsGeneration() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 1)
    t.publishFrontier(100, generation: 0)
    t.jump(to: 42)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 42)
    XCTAssertEqual(t.generation.load(ordering: .relaxed), 1)
    XCTAssertNil(t.frontier(for: 1))
  }

  // MARK: slices

  func testSliceWeightsOfNeighboursSumToOneAcrossOverlap() {
    let frames = 105, fade = 5, hop = 100
    for i in 0..<fade {
      let tail = sliceWeight(hop + i, frames: frames, fade: fade, first: false)
      let head = sliceWeight(i, frames: frames, fade: fade, first: false)
      XCTAssertEqual(tail + head, 1, accuracy: 1e-6, "offset \(i)")
    }
  }

  func testFirstSliceOfAGenerationHasNoRampIn() {
    XCTAssertEqual(sliceWeight(0, frames: 105, fade: 5, first: true), 1)
    XCTAssertEqual(sliceWeight(0, frames: 105, fade: 5, first: false), 0)
    XCTAssertEqual(sliceWeight(104, frames: 105, fade: 5, first: true), 0.2, accuracy: 1e-6)
  }

  private func constantSlice(_ value: Float, frames: Int) -> [Float] {
    [Float](repeating: value, count: Timeline.channels * frames * Stem.separated.count)
  }

  func testNeighbouringSlicesSumToTheSourceAcrossTheOverlap() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 2)
    let frames = 105, fade = 5, hop = 100
    constantSlice(1, frames: frames).withUnsafeBufferPointer { t.writeSlice(at: 0, frames: frames, fade: fade, first: true, from: $0.baseAddress!) }
    constantSlice(1, frames: frames).withUnsafeBufferPointer { t.writeSlice(at: hop, frames: frames, fade: fade, first: false, from: $0.baseAddress!) }
    for stem in 0..<Stem.separated.count {
      for frame in 0..<(hop + frames) where frame < hop + frames - fade {
        for ch in 0..<2 { XCTAssertEqual(t.separated(stem, frame, ch), 1, accuracy: 1e-6, "stem \(stem) frame \(frame)") }
      }
    }
  }

  func testSliceDataReadsBackPerStemAfterTheStemsRingWraps() {
    let t = Timeline(rate: 1000, recordingSeconds: 1, stemsSeconds: 2)  // stem capacity 2000
    let frames = 300
    var source = [Float]()
    for stem in 0..<Stem.separated.count {
      for i in 0..<frames { source += [Float(stem * 1000 + i + 1), Float(-(stem * 1000 + i + 1))] }
    }
    let start = 1900  // wraps at frame 2000
    source.withUnsafeBufferPointer { t.writeSlice(at: start, frames: frames, fade: 0, first: true, from: $0.baseAddress!) }
    for stem in 0..<Stem.separated.count {
      for i in [0, 99, 100, 101, 299] {
        XCTAssertEqual(t.separated(stem, start + i, 0), Float(stem * 1000 + i + 1))
        XCTAssertEqual(t.separated(stem, start + i, 1), -Float(stem * 1000 + i + 1))
      }
    }
  }
}
