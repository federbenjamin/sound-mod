import XCTest

@testable import stemmix

final class ScheduleTests: XCTestCase {
  private let shape = WindowShape(window: 780, hop: 100, fade: 5, minRight: 150, maxRight: 250, lookahead: 800, computeMargin: 25)

  func testWaitsWhenFrontierIsLookaheadPastCursor() {
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_800, playing: true, shape: shape))
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 5_000, playing: true, shape: shape))
    XCTAssertNotNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_799, playing: true, shape: shape))
  }

  func testWaitsWhilePausedEvenWithNothingSeparatedAhead() {
    XCTAssertNil(nextJob(head: 100_000, cursor: 1_000, frontier: 1_000, playing: false, shape: shape))
  }

  func testWaitsWhenHeadIsLessThanMinRightPastSliceEnd() {
    // slice end = 1000 + 105
    XCTAssertNil(nextJob(head: 1_105 + 149, cursor: 1_000, frontier: 1_000, playing: true, shape: shape))
    XCTAssertNotNil(nextJob(head: 1_105 + 150, cursor: 1_000, frontier: 1_000, playing: true, shape: shape))
  }

  func testRightContextGrowsToMaxRightAndNoFurther() {
    let sliceEnd = 1_105
    func windowEnd(available: Int) -> Int? {
      nextJob(head: sliceEnd + available, cursor: 1_000, frontier: 1_000, playing: true, shape: shape).map { $0.windowStart + shape.window }
    }
    XCTAssertEqual(windowEnd(available: 150), sliceEnd + 150)
    XCTAssertEqual(windowEnd(available: 200), sliceEnd + 200)
    XCTAssertEqual(windowEnd(available: 250), sliceEnd + 250)
    XCTAssertEqual(windowEnd(available: 5_000), sliceEnd + 250)
  }

  func testKeepStartAndKeepFramesLocateTheSliceInTheWindow() throws {
    let job = try XCTUnwrap(nextJob(head: 100_000, cursor: 1_000, frontier: 1_000, playing: true, shape: shape))
    XCTAssertEqual(job.sliceStart, 1_000)
    XCTAssertEqual(job.keepFrames, shape.hop + shape.fade)
    XCTAssertEqual(job.keepStart, job.sliceStart - job.windowStart)
    XCTAssertEqual(job.windowStart, 1_105 + 250 - 780)
    XCTAssertEqual(job.keepStart, 1_000 - job.windowStart)
  }
}
