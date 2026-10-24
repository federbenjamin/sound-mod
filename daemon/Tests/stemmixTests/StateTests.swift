import Foundation
import XCTest

@testable import stemmix

final class StateTests: XCTestCase {
  private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("contract")

  func testContractFixturesDecode() throws {
    let session = try JSONDecoder().decode(SessionFile.self, from: Data(contentsOf: fixtures.appendingPathComponent("session.json")))
    XCTAssertEqual(session, SessionFile(working: true, updatedAt: 1_700_000_000_000))
    let config = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: fixtures.appendingPathComponent("config.json")))
    XCTAssertEqual(config, ConfigFile(tracks: 5, player: "spotify"))
  }

  func testSummarizeCountsLiveAndWorkingAndStemSchedule() {
    let now = 10_000.0
    let sessions = [
      SessionFile(working: true, updatedAt: now - 1_000),
      SessionFile(working: false, updatedAt: now - 2_000),
      SessionFile(working: true, updatedAt: now - 7_000),
    ]
    XCTAssertEqual(summarize(sessions: sessions, nowMs: now, staleMs: 6_000), Counts(live: 2, working: 1))

    XCTAssertEqual((0...5).map { audibleStems(working: $0, tracks: 4) }, [0, 1, 2, 3, 4, 4])
    XCTAssertEqual((0...5).map { audibleStems(working: $0, tracks: 5) }, [0, 1, 2, 3, 4, 4])
    XCTAssertEqual((0...3).map { audibleStems(working: $0, tracks: 2) }, [0, 2, 4, 4])
  }
}
