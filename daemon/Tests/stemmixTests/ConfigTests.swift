import XCTest

@testable import stemmix

final class ConfigTests: XCTestCase {
  func testEveryPerPlayerTableHasTheSameKeys() {
    let keys = Set(Config.playerBundlePrefixes.keys)
    XCTAssertEqual(Set(Config.playerNames.keys), keys)
    XCTAssertEqual(Set(playerNotifications.keys), keys)
    XCTAssertEqual(Set(Config.playerEvents.keys), keys)
    XCTAssertTrue(keys.contains(Config.defaultPlayer))
  }

  /// A paused cursor that far behind would be moved up past the oldest recording, losing what was buffered.
  func testTheBufferTargetFitsTheRecordingMinusItsGuard() {
    XCTAssertLessThan(Config.bufferAheadSeconds, Config.recordingSeconds - Config.recordingGuardSeconds)
  }

  func testAnUnknownPlayerKeyResolvesToTheDefaultPlayer() {
    XCTAssertEqual(Config.knownPlayer("music"), "music")
    XCTAssertEqual(Config.knownPlayer("spotify"), "spotify")
    XCTAssertEqual(Config.knownPlayer("vlc"), Config.defaultPlayer)
    XCTAssertEqual(Config.knownPlayer(""), Config.defaultPlayer)
    XCTAssertEqual(Config.knownPlayer("Music"), Config.defaultPlayer)
  }
}
