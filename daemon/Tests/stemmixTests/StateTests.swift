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
  }

  func testASettingChangesOnlyItsKeyAndTheFileKeepsTheSnakeCaseKeys() throws {
    let config = ConfigFile(tracks: 3, player: "music", mode: .both, mufflingMax: 5.5, mufflingMin: 1)
      .with(.mufflingMax(9)).with(.tracks(6))
    XCTAssertEqual(config, ConfigFile(tracks: 6, player: "music", mode: .both, mufflingMax: 9, mufflingMin: 1))
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
    XCTAssertEqual(Set(json?.keys ?? [:].keys), ["tracks", "player", "mode", "muffling_max", "muffling_min"])
    XCTAssertEqual(try JSONDecoder().decode(ConfigFile.self, from: JSONEncoder().encode(config)), config)
  }

  func testConfigWithoutTheNewKeysTakesTheirDefaults() throws {
    let old = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"tracks": 3, "player": "music"}"#.utf8))
    XCTAssertEqual(old, ConfigFile(tracks: 3, player: "music", mode: .instruments, mufflingMax: 7, mufflingMin: 0))
    let modeOnly = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"mode": "both"}"#.utf8))
    XCTAssertEqual(modeOnly, ConfigFile(tracks: 4, player: "spotify", mode: .both, mufflingMax: 7, mufflingMin: 0))
    let badMode = try JSONDecoder().decode(ConfigFile.self, from: Data(#"{"tracks": 6, "mode": "loud"}"#.utf8))
    XCTAssertEqual(badMode, ConfigFile(tracks: 6, player: "spotify"))
  }

  func testSummarizeCountsLiveAndWorkingAndStemSchedule() {
    let now = 10_000.0
    let sessions = [
      "a": SessionFile(working: true, updatedAt: now - 1_000),
      "b": SessionFile(working: false, updatedAt: now - 2_000),
      "c": SessionFile(working: true, updatedAt: now - 7_000),
    ]
    var ease = WorkingEase()
    XCTAssertEqual(ease.summarize(sessions: sessions, nowMs: now, staleMs: 6_000, holdSeconds: 10), Counts(live: 2, working: 1))

    XCTAssertEqual((0...5).map { audibleStems(working: $0, tracks: 4) }, [0, 1, 2, 3, 4, 4])
    XCTAssertEqual((0...5).map { audibleStems(working: $0, tracks: 5) }, [0, 1, 2, 3, 4, 4])
    XCTAssertEqual((0...3).map { audibleStems(working: $0, tracks: 2) }, [0, 2, 4, 4])
  }

  func testWorkingHoldKeepsABlipAndDropsALongSpell() {
    var ease = WorkingEase()
    func count(working: Bool, at nowMs: Double) -> Int {
      ease.summarize(sessions: ["a": SessionFile(working: working, updatedAt: nowMs)], nowMs: nowMs, staleMs: 6_000, holdSeconds: 10).working
    }
    XCTAssertEqual(count(working: true, at: 100_000), 1)
    XCTAssertEqual(count(working: false, at: 102_000), 1)
    XCTAssertEqual(count(working: true, at: 103_000), 1)
    XCTAssertEqual(count(working: false, at: 105_000), 1)
    XCTAssertEqual(count(working: false, at: 112_000), 1)
    XCTAssertEqual(count(working: false, at: 113_000), 0)
  }

  func testWorkingRisesAtOnceAndAStaleSessionStopsCountingAtOnce() {
    var ease = WorkingEase()
    let idle = ["a": SessionFile(working: false, updatedAt: 100_000), "b": SessionFile(working: false, updatedAt: 100_000)]
    XCTAssertEqual(ease.summarize(sessions: idle, nowMs: 100_000, staleMs: 6_000, holdSeconds: 10).working, 0)
    let risen = ["a": SessionFile(working: true, updatedAt: 100_250), "b": idle["b"]!]
    XCTAssertEqual(ease.summarize(sessions: risen, nowMs: 100_250, staleMs: 6_000, holdSeconds: 10), Counts(live: 2, working: 1))
    let stale = ["a": SessionFile(working: true, updatedAt: 100_250)]
    XCTAssertEqual(ease.summarize(sessions: stale, nowMs: 107_000, staleMs: 6_000, holdSeconds: 10), Counts(live: 0, working: 0))
  }
}
