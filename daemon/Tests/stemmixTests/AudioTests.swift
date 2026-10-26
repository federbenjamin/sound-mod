import XCTest

@testable import stemmix

final class AudioTests: XCTestCase {
  func testMissedFramesCountsOnlyTheSkippedCycles() {
    XCTAssertEqual(missedFrames(expected: nil, sampleTime: 4096), 0)
    XCTAssertEqual(missedFrames(expected: 4096, sampleTime: 4096), 0)
    XCTAssertEqual(missedFrames(expected: 4096, sampleTime: 8192), 4096)
    XCTAssertEqual(missedFrames(expected: 8192, sampleTime: 8000), 0)
  }
}
