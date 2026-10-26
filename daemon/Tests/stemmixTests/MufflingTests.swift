import XCTest

@testable import stemmix

final class MufflingTests: XCTestCase {
  func testMaxIsHeardAtOneSessionAndMinAtTracks() throws {
    func hz(_ k: Int) -> Double? {
      mufflingCutoffHz(level: mufflingLevel(working: k, tracks: 4, max: 10, min: 0))
    }
    XCTAssertEqual(try XCTUnwrap(hz(1)), 150, accuracy: 1e-6)
    XCTAssertEqual(try XCTUnwrap(hz(2)), 766, accuracy: 1)
    XCTAssertEqual(try XCTUnwrap(hz(3)), 3915, accuracy: 1)
    XCTAssertNil(hz(4), "a full house hears the unfiltered mix")
    XCTAssertEqual(mufflingLevel(working: 1, tracks: 1, max: 8, min: 2), 2, "one track: one session is the full song")
  }

  func testDefaultKnobsMuffleOneWorkingSessionToAbout1732Hz() throws {
    let level = mufflingLevel(working: 1, tracks: 4, max: Config.defaultMufflingMax, min: Config.defaultMufflingMin)
    // Level 5; 20000 * (150/20000)^0.5 = 1732.1 Hz.
    XCTAssertEqual(level, 5, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(mufflingCutoffHz(level: level)), 1732.1, accuracy: 1)
  }

  func testMufflingLevelClampsKnobsAndFallsBackToMinWithNoTracks() {
    XCTAssertEqual(mufflingLevel(working: 0, tracks: 4, max: 99, min: 0), 10)
    XCTAssertEqual(mufflingLevel(working: 0, tracks: 4, max: -5, min: -5), 0)
    XCTAssertEqual(mufflingLevel(working: 4, tracks: 4, max: 10, min: 99), 10)
    XCTAssertEqual(mufflingLevel(working: 4, tracks: 4, max: 10, min: -3), 0)
    XCTAssertEqual(mufflingLevel(working: 2, tracks: 0, max: 8, min: 3), 3)
    XCTAssertEqual(mufflingLevel(working: 2, tracks: 0, max: 8, min: 30), 10)
    // More working sessions than tracks does not extrapolate past min.
    XCTAssertEqual(mufflingLevel(working: 9, tracks: 4, max: 8, min: 2), 2)
  }

  func testMuffledModeHearsEveryStemUnlessNoSessionIsWorking() {
    XCTAssertEqual((0...5).map { audibleStems(mode: .muffled, working: $0, tracks: 4) }, [0, 4, 4, 4, 4, 4])
  }

  func testInstrumentsAndBothModesKeepTheStemSchedule() {
    for mode in [ListeningMode.instruments, .both] {
      for tracks in [2, 4, 5] {
        for k in 0...6 {
          XCTAssertEqual(audibleStems(mode: mode, working: k, tracks: tracks), audibleStems(working: k, tracks: tracks))
        }
      }
    }
  }

  func testInstrumentsModeNeverFiltersWhateverTheKnobsSay() {
    let config = ConfigFile(tracks: 4, player: "spotify", mode: .instruments, mufflingMax: 10, mufflingMin: 10)
    for k in 0...4 { XCTAssertNil(mufflingCutoffHz(config: config, working: k)) }
  }

  func testMufflingModesFilterFromTheKnobs() throws {
    for mode in [ListeningMode.muffled, .both] {
      let config = ConfigFile(tracks: 4, player: "spotify", mode: mode, mufflingMax: 10, mufflingMin: 0)
      XCTAssertEqual(try XCTUnwrap(mufflingCutoffHz(config: config, working: 2)), 766, accuracy: 1)
      XCTAssertNil(mufflingCutoffHz(config: config, working: 4))
    }
  }
}
