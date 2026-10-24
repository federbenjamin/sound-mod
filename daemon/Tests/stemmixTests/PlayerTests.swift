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

  func testCursorOlderThanTheKeptRecordingPlusGuardIsMovedUp() {
    let (t, p) = makeRig(recordingSeconds: 20)  // capacity 20000, guard 15000
    p.audible.store(4, ordering: .relaxed)
    // One long cycle takes the head to 5000 + 25000 = 30000: oldest kept 10000, playable from 25000.
    render(p, frames: 25_000)
    XCTAssertEqual(t.head.load(ordering: .relaxed), 30_000)
    XCTAssertEqual(t.cursor.load(ordering: .relaxed), 25_000)
    XCTAssertEqual(t.generation.load(ordering: .relaxed), 1)
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
