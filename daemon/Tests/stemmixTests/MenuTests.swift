import XCTest

@testable import stemmix

final class MenuTests: XCTestCase {
  private func attachedSnapshot(
    playing: Bool = true,
    available: Set<TransportCommand> = [.next, .previous, .live]
  ) -> MenuSnapshot {
    MenuSnapshot(
      attachment: .attached(PlaybackSnapshot(
        playing: playing,
        playerPaused: !playing,
        song: TrackMark(frame: 12_000, title: "The Song", artist: "The Artist"),
        secondsBehindLive: 4,
        available: available
      )),
      counts: Counts(live: 3, working: 2),
      player: "Spotify",
      audible: 2,
      cutoffHz: 3607.6,
      inputSamples: 480,
      mediaKeys: .held
    )
  }

  func testStemNamesKeepsTheCountLineVocabularyAtEveryBoundary() {
    XCTAssertEqual(stemNames(audible: -1), "silent")
    XCTAssertEqual(stemNames(audible: 0), "silent")
    XCTAssertEqual(stemNames(audible: 1), "drums")
    XCTAssertEqual(stemNames(audible: 2), "drums+bass")
    XCTAssertEqual(stemNames(audible: 3), "drums+bass+other")
    XCTAssertEqual(stemNames(audible: 4), "drums+bass+other+vocals")
    XCTAssertEqual(stemNames(audible: 8), "drums+bass+other+vocals")
  }

  func testCutoffLabelRoundsToTheUnchangedCountLineText() {
    XCTAssertEqual(cutoffLabel(nil), "none")
    XCTAssertEqual(cutoffLabel(3607.6), "3608Hz")
    XCTAssertEqual(cutoffLabel(0), "0Hz")
  }

  func testDetachReasonNamesTheBlockingAttachCondition() {
    XCTAssertEqual(detachReason(sessionOpen: false, playerRunning: true, permission: .authorized), .noSession)
    XCTAssertEqual(detachReason(sessionOpen: true, playerRunning: false, permission: .authorized), .playerNotRunning)
    XCTAssertEqual(detachReason(sessionOpen: true, playerRunning: true, permission: .denied), .needsPermission)
    XCTAssertEqual(detachReason(sessionOpen: true, playerRunning: true, permission: .authorized), .attaching)
  }

  func testAttachedMenuReflectsPlaybackInItsIconAndOffersAllMenuActions() {
    let content = menuContent(attachedSnapshot())

    XCTAssertEqual(content.icon, .playing)
    XCTAssertEqual(content.items.map(\.action), [
      .transport(.toggle), .transport(.next), .transport(.previous), .transport(.live),
      .openLog, .restart, .quit,
    ])
    XCTAssertEqual(content.items.map(\.isEnabled), [true, true, true, true, true, true, true])
  }

  func testAttachedPausedMenuUsesPausedIconAndDisablesUnavailableNavigation() {
    let content = menuContent(attachedSnapshot(playing: false, available: []))

    XCTAssertEqual(content.icon, .paused)
    XCTAssertEqual(content.items.map(\.isEnabled), [true, false, false, false, true, true, true])
  }
}
