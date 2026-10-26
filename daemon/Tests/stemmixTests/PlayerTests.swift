import XCTest

@testable import stemmix

final class PlayerTests: XCTestCase {
  /// Rate 1000: the transport fade is 10 frames, the stem gain ramp 400, the recording guard 15000.
  private let preloaded = 5000

  private func mix(_ frame: Int, _ ch: Int) -> Float { Float((frame * 7 + ch * 3) % 101) / 100 + 0.1 }

  /// A timeline with `preloaded` recorded frames and stems published up to the end of them (generation 0).
  private func makeRig(recordingSeconds: Double = 40) -> (Timeline, Player) {
    let t = Timeline(rate: 1000, recordingSeconds: recordingSeconds, stemsSeconds: 20)
    var rec = [Float]()
    for f in 0..<preloaded { rec += [mix(f, 0), mix(f, 1)] }
    rec.withUnsafeBufferPointer { t.record(interleaved: $0.baseAddress!, frames: preloaded) }
    // drums, bass, vocals each a distinct fraction of the mix, so "other" is the remainder.
    var src = [Float]()
    for k in [0.2, 0.3, 0.1] {
      for f in 0..<preloaded { src += [mix(f, 0) * Float(k), mix(f, 1) * Float(k)] }
    }
    src.withUnsafeBufferPointer { t.writeSlice(at: 0, frames: preloaded, fade: 0, first: true, from: $0.baseAddress!) }
    t.publishFrontier(preloaded, generation: 0)
    return (t, Player(timeline: t))
  }

  /// Renders `blocks` blocks of 100 frames; returns each block's output with the cursor it started from.
  private func play(_ p: Player, _ t: Timeline, blocks: Int) -> [(cursor: Int, out: [Float])] {
    (0..<blocks).map { _ in
      let c = t.cursor.load(ordering: .relaxed)
      return (c, render(p, frames: 100))
    }
  }

  func testAllStemsAudibleOutputsTheRecordingAtTheCursorOnceTheRampSettles() {
    let (t, p) = makeRig()
    p.audible.store(4, ordering: .relaxed)
    let blocks = play(p, t, blocks: 20)
    for (cursor, out) in blocks where cursor >= 500 {
      for i in 0..<100 {
        XCTAssertEqual(out[i * 2], mix(cursor + i, 0), accuracy: 1e-5)
        XCTAssertEqual(out[i * 2 + 1], mix(cursor + i, 1), accuracy: 1e-5)
      }
    }
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 2000)
  }

  func testSomeStemsAudibleIsQuieterThanTheRecording() {
    let (t, p) = makeRig()
    p.audible.store(1, ordering: .relaxed)  // drums only: 0.2 of the mix
    let blocks = play(p, t, blocks: 10)
    let (cursor, out) = blocks[9]
    XCTAssertEqual(out[0], mix(cursor, 0) * 0.2, accuracy: 1e-5)
  }

  func testNoStemsAudibleIsSilentButTheCursorAdvances() {
    let (t, p) = makeRig()
    p.audible.store(0, ordering: .relaxed)
    let blocks = play(p, t, blocks: 10)
    XCTAssertTrue(blocks.allSatisfy { $0.out.allSatisfy { $0 == 0 } })
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 1000)
  }

  func testWithoutAFrontierOutputIsSilentCursorHoldsAndWaitingIsCounted() {
    let t = Timeline(rate: 1000, recordingSeconds: 40, stemsSeconds: 20)
    let p = Player(timeline: t)
    p.audible.store(4, ordering: .relaxed)
    let out = render(p, frames: 100, input: [Float](repeating: 0.5, count: 200))
    XCTAssertTrue(out.allSatisfy { $0 == 0 })
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 0)
    XCTAssertEqual(p.waitingFrames.load(ordering: .relaxed), 100)
    XCTAssertEqual(t.head.load(ordering: .relaxed), 100)
  }

  func testPausedPlayerDoesNotCountWaitingFrames() {
    let t = Timeline(rate: 1000, recordingSeconds: 40, stemsSeconds: 20)
    let p = Player(timeline: t)
    p.send(.pause)
    render(p, frames: 100)
    XCTAssertEqual(p.waitingFrames.load(ordering: .relaxed), 0)
  }

  func testPauseFadesOutOverTheTransportFadeThenStopsTheCursorWhileRecordingContinues() {
    let (t, p) = makeRig()
    p.audible.store(4, ordering: .relaxed)
    _ = play(p, t, blocks: 10)
    let before = t.cursor.load(ordering: .relaxed)
    let headBefore = t.head.load(ordering: .relaxed)
    p.send(.pause)
    let out = render(p, frames: 100)
    let after = t.cursor.load(ordering: .relaxed)
    XCTAssertTrue((9...11).contains(after - before), "cursor moved \(after - before)")
    XCTAssertFalse(p.playing.load(ordering: .relaxed))
    // Fading: first sample is below full level, and everything past the fade is silent.
    XCTAssertLessThan(abs(out[0]), mix(before, 0))
    let silentFrom: Int = (after - before + 1) * 2
    let tailOut: [Float] = Array(out[silentFrom..<out.count])
    XCTAssertTrue(tailOut.allSatisfy { $0 == 0 })

    render(p, frames: 100)
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), after)
    XCTAssertEqual(t.head.load(ordering: .relaxed), headBefore + 300)
  }

  func testPlayResumesFromTheSameCursor() {
    let (t, p) = makeRig()
    p.audible.store(4, ordering: .relaxed)
    _ = play(p, t, blocks: 10)
    p.send(.pause)
    render(p, frames: 100)
    let paused = t.cursor.load(ordering: .relaxed)
    render(p, frames: 100)
    p.send(.play)
    let out = render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), paused + 100)
    XCTAssertTrue(p.playing.load(ordering: .relaxed))
    XCTAssertEqual(out[50 * 2], mix(paused + 50, 0), accuracy: 1e-5)
  }

  func testSeekMovesTheCursorAndBumpsTheGeneration() {
    let (t, p) = makeRig()
    p.audible.store(4, ordering: .relaxed)
    _ = play(p, t, blocks: 3)
    p.send(.seek(500))
    let out = render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 500)
    XCTAssertEqual(t.generation.load(ordering: .relaxed), 1)
    // The old generation's frontier is stale: wait for the worker.
    XCTAssertTrue(out.allSatisfy { $0 == 0 })
    t.publishFrontier(2000, generation: 1)
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 600)
  }

  // Both sent before one IO cycle (a forwarded skip yields a play state and a seek together): neither may be lost.
  func testPauseThenSeekInOneCycleBothApply() {
    let (t, p) = makeRig()
    p.send(.pause)
    p.send(.seek(500))
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 500)
    XCTAssertFalse(p.playing.load(ordering: .relaxed))
  }

  func testSeekThenPlayInOneCycleBothApply() {
    let (t, p) = makeRig()
    p.send(.pause)
    render(p, frames: 100)
    p.send(.seek(500))
    p.send(.play)
    t.publishFrontier(2000, generation: t.generation.load(ordering: .relaxed) + 1)
    render(p, frames: 100)
    XCTAssertTrue(p.playing.load(ordering: .relaxed))
    XCTAssertEqual(t.generation.load(ordering: .relaxed), 1)
    XCTAssertGreaterThanOrEqual(t.cursor.load(ordering: .relaxed), 500)
  }

  func testTwoSeeksInOneCycleTheLaterWins() {
    let (t, p) = makeRig()
    p.send(.seek(500))
    p.send(.seek(1200))
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 1200)
  }

  func testSeekPastTheHeadClampsToTheHead() {
    let (t, p) = makeRig()
    p.send(.seek(10_000_000))
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), t.head.load(ordering: .relaxed))
  }

  func testSeekBeforeZeroClampsToZero() {
    let (t, p) = makeRig()
    _ = play(p, t, blocks: 3)
    p.send(.seek(-50))
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 0)
  }

  func testCursorOlderThanTheKeptRecordingPlusGuardIsMovedUpInTheSameGeneration() {
    let (t, p) = makeRig(recordingSeconds: 20)  // capacity 20000, guard 15000
    p.audible.store(4, ordering: .relaxed)
    // One long cycle takes the head to 5000 + 25000 = 30000: oldest kept 10000, playable from 25000.
    render(p, frames: 25_000)
    XCTAssertEqual(t.head.load(ordering: .relaxed), 30_000)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 25_000)
    // Every later cycle moves it again; a new generation each time would make every slice in flight stale.
    render(p, frames: 100)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 25_100)
    XCTAssertEqual(t.generation.load(ordering: .relaxed), 0)
  }

  func testRecordingWrapKeepsRoundTrippingThroughRender() {
    let (t, p) = makeRig(recordingSeconds: 20)
    var input = [Float]()
    for f in 0..<25_000 { input += [Float(f + 1), Float(-(f + 1))] }
    render(p, frames: 25_000, input: input)
    let head = t.head.load(ordering: .relaxed)
    XCTAssertEqual(t.recorded(head - 1, 0), 25_000)
    XCTAssertEqual(t.recorded(head - 1, 1), -25_000)
    XCTAssertEqual(t.recorded(head - 20_000, 0), Float(25_000 - 20_000 + 1))
  }
}

final class PlayerMufflingTests: XCTestCase {
  /// RMS of the last second of a 10 kHz recording played back with `cutoffMilliHz` set.
  private func tailRms(cutoffMilliHz: Int) -> Double {
    let rate = 48_000
    let frames = rate * 2
    let t = Timeline(rate: rate, recordingSeconds: 10, stemsSeconds: 5)
    var rec = [Float]()
    for f in 0..<frames {
      let v = Float(sin(2 * Double.pi * 10_000 * Double(f) / Double(rate)))
      rec += [v, v]
    }
    rec.withUnsafeBufferPointer { t.record(interleaved: $0.baseAddress!, frames: frames) }
    let silentStems = [Float](repeating: 0, count: frames * 2 * 3)
    silentStems.withUnsafeBufferPointer { t.writeSlice(at: 0, frames: frames, fade: 0, first: true, from: $0.baseAddress!) }
    t.publishFrontier(frames, generation: 0)
    let p = Player(timeline: t)
    p.audible.store(4, ordering: .relaxed)
    p.cutoffMilliHz.store(cutoffMilliHz, ordering: .relaxed)
    var sum = 0.0, count = 0
    for block in 0..<190 {
      let out = render(p, frames: 480)
      if block * 480 >= rate {
        for v in out { sum += Double(v) * Double(v); count += 1 }
      }
    }
    return (sum / Double(count)).squareRoot()
  }

  func testACutoffAt1kHzSilencesARecorded10kHzTone() {
    let open = tailRms(cutoffMilliHz: 0)
    let filtered = tailRms(cutoffMilliHz: 1_000_000)
    XCTAssertGreaterThan(open, 0.5)
    XCTAssertLessThan(20 * log10(filtered / open), -40)
  }
}
