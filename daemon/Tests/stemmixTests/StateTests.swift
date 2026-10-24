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
    XCTAssertEqual(config, ConfigFile(tracks: 4, player: "spotify"))
  }

  func testContractConfigFixtureCarriesTheListeningKnobs() throws {
    let config = try JSONDecoder().decode(ConfigFile.self, from: Data(contentsOf: fixtures.appendingPathComponent("config.json")))
    XCTAssertEqual(config, ConfigFile(tracks: 4, player: "spotify", mode: .instruments, mufflingMax: 7, mufflingMin: 0))
  }

  func testConfigWithoutTheNewKeysTakesTheirDefaults() throws {
    let old = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"tracks": 3, "player": "music"}"#.utf8))
    XCTAssertEqual(old, ConfigFile(tracks: 3, player: "music", mode: .instruments, mufflingMax: 7, mufflingMin: 0))
    let modeOnly = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"mode": "both"}"#.utf8))
    XCTAssertEqual(modeOnly, ConfigFile(tracks: 4, player: "spotify", mode: .both, mufflingMax: 7, mufflingMin: 0))
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
