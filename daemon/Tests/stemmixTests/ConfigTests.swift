import XCTest

@testable import stemmix

final class ConfigTests: XCTestCase {
  func testEveryPerPlayerTableHasTheSameKeys() {
    let keys = Set(Config.playerBundlePrefixes.keys)
    XCTAssertEqual(Set(Config.playerNames.keys), keys)
    XCTAssertEqual(Set(playerNotifications.keys), keys)
    XCTAssertTrue(keys.contains(Config.defaultPlayer))
  }

  func testAnUnknownPlayerKeyResolvesToTheDefaultPlayer() {
    XCTAssertEqual(Config.knownPlayer("music"), "music")
    XCTAssertEqual(Config.knownPlayer("spotify"), "spotify")
    XCTAssertEqual(Config.knownPlayer("vlc"), Config.defaultPlayer)
    XCTAssertEqual(Config.knownPlayer(""), Config.defaultPlayer)
    XCTAssertEqual(Config.knownPlayer("Music"), Config.defaultPlayer)
  }
}
