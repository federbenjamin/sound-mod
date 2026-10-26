import XCTest

@testable import stemmix

final class MenuTests: XCTestCase {
  private func attachedSnapshot(
    playing: Bool = true,
    available: Set<TransportCommand> = [.next, .previous]
  ) -> MenuSnapshot {
    MenuSnapshot(
      attachment: .attached(PlaybackSnapshot(
        playing: playing,
        song: TrackMark(frame: 12_000, title: "The Song", artist: "The Artist"),
        bufferedSeconds: 272,
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

  func testDetachReasonNamesTheFirstBlockingAttachConditionAndLastRefusal() {
    XCTAssertEqual(detachReason(on: false, playerRunning: true, permission: .authorized), .off)
    XCTAssertEqual(detachReason(on: true, playerRunning: false, permission: .authorized), .playerNotRunning)
    XCTAssertEqual(detachReason(on: true, playerRunning: true, permission: .denied), .needsPermission)
    XCTAssertEqual(detachReason(on: true, playerRunning: true, permission: nil), .attaching)
  }

  func testAttachedMenuReflectsPlaybackInItsIconAndOffersAllMenuActions() {
    let content = menuContent(attachedSnapshot())

    XCTAssertEqual(content.icon, .playing)
    XCTAssertEqual(content.song, "The Song — The Artist")
    XCTAssertEqual(content.state, "Playing, 4:32 buffered")
    XCTAssertEqual(content.sessions, "2 of 3 sessions working")
    XCTAssertEqual(content.stems, "Stems: drums+bass, muffled at 3608Hz")
    XCTAssertEqual(content.mediaKeys, "Media keys: Stemmix")
    XCTAssertEqual(content.items.map(\.title), [
      "Turn Stemmix Off", "Pause", "Next", "Previous", "Open log", "Restart Stemmix", "Quit Stemmix",
    ])
    XCTAssertEqual(content.items.map(\.action), [
      .toggleOnOff, .transport(.toggle), .transport(.next), .transport(.previous),
      .openLog, .restart, .quit,
    ])
    XCTAssertEqual(content.items.map(\.isEnabled), [true, true, true, true, true, true, true])
  }

  func testAttachedPausedMenuUsesPausedIconAndDisablesUnavailableNavigation() {
    let content = menuContent(attachedSnapshot(playing: false, available: []))

    XCTAssertEqual(content.icon, .paused)
    XCTAssertEqual(content.state, "Paused, 4:32 buffered")
    XCTAssertEqual(content.items[1].title, "Play")
    XCTAssertEqual(content.items.map(\.isEnabled), [true, true, false, false, true, true, true])
  }

  func testDetachedMenuNamesEachAttachBlockerAndHidesAttachedDetails() {
    let cases: [(DetachReason, String)] = [
      (.off, "Off"),
      (.playerNotRunning, "Spotify is not running"),
      (.needsPermission, "Needs System Audio Recording permission"),
      (.attaching, "Attaching"),
    ]

    for (reason, state) in cases {
      let content = menuContent(MenuSnapshot(
        attachment: .detached(reason),
        counts: Counts(live: 1, working: 0),
        player: "Spotify",
        audible: 0,
        cutoffHz: nil,
        inputSamples: nil,
        mediaKeys: nil
      ))

      XCTAssertEqual(content.icon, .detached)
      XCTAssertEqual(content.song, "Not attached")
      XCTAssertEqual(content.state, state)
      XCTAssertEqual(content.sessions, "0 of 1 session working")
      XCTAssertNil(content.stems)
      XCTAssertNil(content.mediaKeys)
      XCTAssertEqual(content.items.map(\.title), [
        reason == .off ? "Turn Stemmix On" : "Turn Stemmix Off", "Play", "Next", "Previous", "Open log", "Restart Stemmix", "Quit Stemmix",
      ])
      XCTAssertEqual(content.items.map(\.isEnabled), [true, false, false, false, true, true, true])
    }
  }

  func testAttachedMenuUsesExactFallbackStringsForSilentInputSongAndMediaKeys() {
    let silent = menuContent(MenuSnapshot(
      attachment: .attached(PlaybackSnapshot(
        playing: true,
        song: nil,
        bufferedSeconds: 0,
        available: []
      )),
      counts: Counts(live: 2, working: 0),
      player: "Music",
      audible: 0,
      cutoffHz: nil,
      inputSamples: 0,
      mediaKeys: .lost
    ))
    let pausedShort = menuContent(MenuSnapshot(
      attachment: .attached(PlaybackSnapshot(
        playing: false,
        song: TrackMark(frame: 0, title: "Title only", artist: ""),
        bufferedSeconds: 3,
        available: []
      )),
      counts: Counts(live: 2, working: 0),
      player: "Music",
      audible: 0,
      cutoffHz: nil,
      inputSamples: nil,
      mediaKeys: nil
    ))

    XCTAssertEqual(silent.song, "Unknown song")
    XCTAssertEqual(silent.state, "No audio from Music")
    XCTAssertEqual(silent.stems, "Stems: silent")
    XCTAssertEqual(silent.mediaKeys, "Media keys: another app")
    XCTAssertEqual(pausedShort.song, "Title only")
    XCTAssertEqual(pausedShort.state, "Paused, 0:03 buffered")
    XCTAssertNil(pausedShort.mediaKeys)
  }

  /// StatusMenu builds its items and separators once from MenuLayout, so every content must fit that layout.
  func testEveryMenuContentFillsTheLayoutStatusMenuBuilds() {
    let detached = [DetachReason.off, .playerNotRunning, .needsPermission, .attaching].map { reason in
      MenuSnapshot(
        attachment: .detached(reason), counts: Counts(live: 0, working: 0), player: "Spotify", audible: 0,
        cutoffHz: nil, inputSamples: nil, mediaKeys: nil)
    }
    let attached = [
      attachedSnapshot(),
      attachedSnapshot(playing: false, available: []),
      attachedSnapshot(available: [.next]),
    ]
    let layoutActions = Array(MenuLayout.actionGroups.joined())

    for snapshot in detached + attached {
      let content = menuContent(snapshot)
      XCTAssertEqual(content.items.count, MenuLayout.actionGroups.map(\.count).reduce(0, +))
      XCTAssertEqual(content.items.map(\.action), layoutActions)
      XCTAssertEqual(content.lines.count, MenuLayout.infoLines)
    }
    XCTAssertEqual(MenuLayout.actionGroups.map(\.count), [1, 3, 1, 2])
  }

  func testBufferedLabelIsMinutesAndTwoDigitSeconds() {
    XCTAssertEqual(bufferedLabel(0), "0:00")
    XCTAssertEqual(bufferedLabel(5), "0:05")
    XCTAssertEqual(bufferedLabel(272), "4:32")
    XCTAssertEqual(bufferedLabel(300), "5:00")
    XCTAssertEqual(bufferedLabel(3661), "61:01")
  }
}
