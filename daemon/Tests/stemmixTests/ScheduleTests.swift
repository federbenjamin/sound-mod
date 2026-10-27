import XCTest

@testable import stemmix

final class ScheduleTests: XCTestCase {
  private let shape = WindowShape(window: 780, hop: 100, fade: 5, minRight: 150, maxRight: 250, lookahead: 800, computeMargin: 25)
  private let kept = 200_000

  func testWaitsWhenFrontierIsLookaheadPastCursor() {
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_800, playing: true, keptFrames: kept, shape: shape))
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 5_000, playing: true, keptFrames: kept, shape: shape))
    XCTAssertNotNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_799, playing: true, keptFrames: kept, shape: shape))
  }

  func testSeparatesTheLookaheadWhilePaused() {
    XCTAssertNotNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_000, playing: false, keptFrames: kept, shape: shape))
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_800, playing: false, keptFrames: kept, shape: shape))
  }

  func testWaitsWhilePausedWhereTheOverflowMovesTheCursor() {
    XCTAssertNotNil(nextJob(head: 1_000 + kept - 1, cursor: 1_000, frontier: 1_000, playing: false, keptFrames: kept, shape: shape))
    XCTAssertNil(nextJob(head: 1_000 + kept, cursor: 1_000, frontier: 1_000, playing: false, keptFrames: kept, shape: shape))
    XCTAssertNotNil(nextJob(head: 1_000 + kept, cursor: 1_000, frontier: 1_000, playing: true, keptFrames: kept, shape: shape))
  }

  func testWaitsWhenHeadIsLessThanMinRightPastSliceEnd() {
    // slice end = 1000 + 105
    XCTAssertNil(nextJob(head: 1_105 + 149, cursor: 1_000, frontier: 1_000, playing: true, keptFrames: kept, shape: shape))
    XCTAssertNotNil(nextJob(head: 1_105 + 150, cursor: 1_000, frontier: 1_000, playing: true, keptFrames: kept, shape: shape))
  }

  func testAFinalHeadIsSeparatedToItsEndWithNoRightContext() throws {
    func job(head: Int, frontier: Int, final: Bool) -> SeparationJob? {
      nextJob(head: head, cursor: 1_000, frontier: frontier, playing: true, keptFrames: kept, shape: shape, headFinal: final)
    }
    XCTAssertNil(job(head: 1_200, frontier: 1_000, final: false), "95 past the slice is under minRight")
    let full = try XCTUnwrap(job(head: 1_200, frontier: 1_000, final: true))
    XCTAssertEqual(full.keepFrames, 105)
    XCTAssertEqual(full.windowStart + shape.window, 1_200, "the window ends at the head")
    XCTAssertEqual(full.keepStart, 1_000 - full.windowStart)

    // The worker moves the frontier to keepFrames - fade past the slice; the tail ends with the head's fade-out.
    var frontier = 1_000
    while let next = job(head: 1_200, frontier: frontier, final: true) {
      XCTAssertLessThanOrEqual(next.keepStart + next.keepFrames, shape.window)
      frontier = next.sliceStart + next.keepFrames - shape.fade
    }
    XCTAssertEqual(frontier, 1_200 - shape.fade)
  }

  func testRightContextGrowsToMaxRightAndNoFurther() {
    let sliceEnd = 1_105
    func windowEnd(available: Int) -> Int? {
      nextJob(head: sliceEnd + available, cursor: 1_000, frontier: 1_000, playing: true, keptFrames: kept, shape: shape).map { $0.windowStart + shape.window }
    }
    XCTAssertEqual(windowEnd(available: 150), sliceEnd + 150)
    XCTAssertEqual(windowEnd(available: 200), sliceEnd + 200)
    XCTAssertEqual(windowEnd(available: 250), sliceEnd + 250)
    XCTAssertEqual(windowEnd(available: 5_000), sliceEnd + 250)
  }

  func testKeepStartAndKeepFramesLocateTheSliceInTheWindow() throws {
    let job = try XCTUnwrap(nextJob(head: 100_000, cursor: 1_000, frontier: 1_000, playing: true, keptFrames: kept, shape: shape))
    XCTAssertEqual(job.sliceStart, 1_000)
    XCTAssertEqual(job.keepFrames, shape.hop + shape.fade)
    XCTAssertEqual(job.keepStart, job.sliceStart - job.windowStart)
    XCTAssertEqual(job.windowStart, 1_105 + 250 - 780)
    XCTAssertEqual(job.keepStart, 1_000 - job.windowStart)
  }
}
