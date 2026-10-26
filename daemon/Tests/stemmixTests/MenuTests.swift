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
      config: ConfigFile(tracks: 4, player: "spotify"),
      audible: 2,
      cutoffHz: 3607.6,
      inputSamples: 480
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

  func testDetachLogReasonNamesASwitchedPlayerEvenWhenTheNewOneIsNotRunning() {
    XCTAssertEqual(detachLogReason(on: false, playerSettingChanged: true, playerRunning: false, targetsChanged: true), "off")
    XCTAssertEqual(detachLogReason(on: true, playerSettingChanged: true, playerRunning: false, targetsChanged: true), "player-setting")
    XCTAssertEqual(detachLogReason(on: true, playerSettingChanged: false, playerRunning: false, targetsChanged: true), "player-quit")
    XCTAssertEqual(detachLogReason(on: true, playerSettingChanged: false, playerRunning: true, targetsChanged: true), "player-changed")
    XCTAssertEqual(detachLogReason(on: true, playerSettingChanged: false, playerRunning: true, targetsChanged: false), "output-changed")
  }

  func testAttachedMenuReflectsPlaybackInItsIconAndOffersAllMenuActions() {
    let content = menuContent(attachedSnapshot())

    XCTAssertEqual(content.icon, .playing)
    XCTAssertEqual(content.iconText, "2/4")
    XCTAssertEqual(content.song, "The Song — The Artist")
    XCTAssertEqual(content.state, "Playing, 4:32 buffered")
    XCTAssertEqual(content.sessions, "2 of 3 sessions working")
    XCTAssertEqual(content.hearing, "Hearing: drums, bass, muffled at 3.6 kHz")
    XCTAssertEqual(content.items.map(\.title), [
      "Pause", "Next", "Previous", "Open log", "Turn Stemmix Off", "Restart Stemmix", "Quit Stemmix",
    ])
    XCTAssertEqual(content.items.map(\.action), [
      .transport(.toggle), .transport(.next), .transport(.previous),
      .openLog, .toggleOnOff, .restart, .quit,
    ])
    XCTAssertEqual(content.items.map(\.isEnabled), [true, true, true, true, true, true, true])
  }

  func testAttachedPausedMenuUsesPausedIconAndDisablesUnavailableNavigation() {
    let content = menuContent(attachedSnapshot(playing: false, available: []))

    XCTAssertEqual(content.icon, .paused)
    XCTAssertEqual(content.state, "Paused, 4:32 buffered")
    XCTAssertEqual(content.items[0].title, "Play")
    XCTAssertEqual(content.items.map(\.isEnabled), [true, false, false, true, true, true, true])
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
        config: ConfigFile(tracks: 4, player: "spotify"),
        audible: 0,
        cutoffHz: nil,
        inputSamples: nil
      ))

      XCTAssertEqual(content.icon, .detached)
      XCTAssertNil(content.iconText)
      XCTAssertEqual(content.song, "Not attached")
      XCTAssertEqual(content.state, state)
      XCTAssertEqual(content.sessions, "0 of 1 session working")
      XCTAssertNil(content.hearing)
      XCTAssertEqual(content.items.map(\.title), [
        "Play", "Next", "Previous", "Open log", reason == .off ? "Turn Stemmix On" : "Turn Stemmix Off", "Restart Stemmix", "Quit Stemmix",
      ])
      XCTAssertEqual(content.items.map(\.isEnabled), [false, false, false, true, true, true, true])
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
      config: ConfigFile(tracks: 4, player: "music"),
      audible: 0,
      cutoffHz: nil,
      inputSamples: 0
    ))
    let pausedShort = menuContent(MenuSnapshot(
      attachment: .attached(PlaybackSnapshot(
        playing: false,
        song: TrackMark(frame: 0, title: "Title only", artist: ""),
        bufferedSeconds: 3,
        available: []
      )),
      counts: Counts(live: 2, working: 0),
      config: ConfigFile(tracks: 4, player: "music"),
      audible: 0,
      cutoffHz: nil,
      inputSamples: nil
    ))

    XCTAssertEqual(silent.song, "Unknown song")
    XCTAssertEqual(silent.state, "No audio from Music")
    XCTAssertEqual(silent.hearing, "Hearing: nothing")
    XCTAssertEqual(pausedShort.song, "Title only")
    XCTAssertEqual(pausedShort.state, "Paused, 0:03 buffered")
  }

  /// StatusMenu builds its items and separators once from MenuLayout, so every content must fit that layout.
  func testEveryMenuContentFillsTheLayoutStatusMenuBuilds() {
    let detached = [DetachReason.off, .playerNotRunning, .needsPermission, .attaching].map { reason in
      MenuSnapshot(
        attachment: .detached(reason), counts: Counts(live: 0, working: 0), config: ConfigFile(tracks: 4, player: "spotify"), audible: 0,
        cutoffHz: nil, inputSamples: nil)
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
      XCTAssertEqual(content.settings.map(\.options.count), MenuLayout.settings.map(\.options.count))
      XCTAssertEqual(content.settings.flatMap(\.options).map(\.action), MenuLayout.settings.flatMap(\.options).map { .set($0) })
    }
    XCTAssertEqual(MenuLayout.actionGroups.map(\.count), [3, 1, 1, 2])
  }

  func testSettingsShowEachValueCheckTheCurrentOneAndGreyMufflingWithoutIt() {
    func settings(_ config: ConfigFile) -> [SettingsGroup] {
      menuContent(MenuSnapshot(
        attachment: .detached(.off), counts: Counts(live: 0, working: 0), config: config, audible: 0,
        cutoffHz: nil, inputSamples: nil)).settings
    }
    let both = settings(ConfigFile(tracks: 3, player: "music", mode: .both, mufflingMax: 7, mufflingMin: 5.5))

    XCTAssertEqual(both.map(\.title), [
      "Full song at: 3 sessions", "Player: Music", "Mode: Both", "Muffling at 1 session: 7", "Muffling at 3 sessions: 5.5",
    ])
    XCTAssertEqual(both.map(\.isEnabled), [true, true, true, true, true])
    XCTAssertEqual(both.map { $0.options.filter(\.isChecked).map(\.title) }, [["3 sessions"], ["Music"], ["Both"], ["7 (651 Hz)"], []])
    XCTAssertEqual(both[0].options.first?.title, "1 session")
    XCTAssertEqual(both[2].options.map(\.toolTip), [
      "Fewer working sessions, fewer instruments.", "Every instrument plays, more muffled with fewer working sessions.",
      "Fewer instruments, and muffled.",
    ])
    XCTAssertEqual(both[1].options.map(\.title), ["Spotify", "Music"])
    XCTAssertEqual(both[2].options.map(\.title), ["Instruments", "Muffled", "Both"])
    XCTAssertEqual(both[3].options.first?.title, "0 (none)")
    XCTAssertEqual(both[3].options.last?.title, "10 (150 Hz)")

    let instruments = settings(ConfigFile(tracks: 4, player: "spotify"))
    XCTAssertEqual(instruments.map(\.isEnabled), [true, true, true, false, false])
    let oneTrack = settings(ConfigFile(tracks: 1, player: "spotify", mode: .muffled))
    XCTAssertEqual(oneTrack.map(\.isEnabled), [true, true, true, false, true], "one track never hears the 1-session level apart")
  }

  func testHearingLineNamesTheInstrumentsInWords() {
    XCTAssertEqual(hearingLine(audible: 0, cutoffHz: 651), "Hearing: nothing")
    XCTAssertEqual(hearingLine(audible: 1, cutoffHz: nil), "Hearing: drums")
    XCTAssertEqual(hearingLine(audible: 3, cutoffHz: nil), "Hearing: drums, bass, other instruments")
    XCTAssertEqual(hearingLine(audible: 4, cutoffHz: 651), "Hearing: everything, muffled at 651 Hz")
    XCTAssertEqual(hearingLine(audible: 4, cutoffHz: 1732.1), "Hearing: everything, muffled at 1.7 kHz")
  }

  func testBufferedLabelIsMinutesAndTwoDigitSeconds() {
    XCTAssertEqual(bufferedLabel(0), "0:00")
    XCTAssertEqual(bufferedLabel(5), "0:05")
    XCTAssertEqual(bufferedLabel(272), "4:32")
    XCTAssertEqual(bufferedLabel(300), "5:00")
    XCTAssertEqual(bufferedLabel(3661), "61:01")
  }
}
