import XCTest

@testable import stemmix

final class ExpiredSessionsTests: XCTestCase {
  func testOnlyFilesOlderThanMaxAgeAreExpiredAndSorted() {
    let now = 1_000_000.0
    let sessions = [
      "zeta": SessionFile(working: true, updatedAt: now - 5_000),
      "fresh": SessionFile(working: true, updatedAt: now - 100),
      "alpha": SessionFile(working: false, updatedAt: now - 9_000),
      "edge": SessionFile(working: false, updatedAt: now - 1_000),  // exactly maxAge: kept
    ]
    XCTAssertEqual(expiredSessions(sessions, nowMs: now, maxAgeMs: 1_000), ["alpha", "zeta"])
    XCTAssertEqual(expiredSessions([:], nowMs: now, maxAgeMs: 1_000), [])
  }
}
