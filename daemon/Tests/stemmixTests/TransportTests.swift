import XCTest

@testable import stemmix

final class TransportTests: XCTestCase {
  private let rate = 1000
  private let liveLag = 500
  private let head = 100_000  // live edge 99_500

  private func act(_ c: TransportCommand, cursor: Int, playing: Bool = true, marks: [TrackMark] = []) -> TransportAction {
    resolve(c, cursor: cursor, head: head, playing: playing, marks: marks, rate: rate, liveLag: liveLag)
  }

  private func mark(_ f: Int) -> TrackMark { TrackMark(frame: f, title: "t\(f)", artist: "a") }

  func testToggleFlipsPlayAndPause() {
    XCTAssertEqual(act(.toggle, cursor: 0, playing: true), .pause)
    XCTAssertEqual(act(.toggle, cursor: 0, playing: false), .play)
    XCTAssertEqual(act(.play, cursor: 0), .play)
    XCTAssertEqual(act(.pause, cursor: 0), .pause)
  }

  func testNextGoesToTheNextMarkMoreThanASecondAhead() {
    let marks = [mark(10_000), mark(20_000)]
    XCTAssertEqual(act(.next, cursor: 5_000, marks: marks), .seek(10_000))
    // 10_000 is only 500 ahead of 9_500: not "more than a second", so the one after.
    XCTAssertEqual(act(.next, cursor: 9_500, marks: marks), .seek(20_000))
  }

  func testNextWithoutAMarkAheadSkipsThePlayerAndCountsMarksPastTheLiveEdgeAsAhead() {
    XCTAssertEqual(act(.next, cursor: 50_000, marks: [mark(10_000)]), .skipPlayer)
    // A song that started in the last moments sits between the live edge (99_500) and the head: still ahead.
    XCTAssertEqual(act(.next, cursor: 50_000, marks: [mark(99_800)]), .seek(99_800))
  }

  func testNextSkipsThePlayerWhenAlreadyLiveAndLiveDoesNothing() {
    XCTAssertEqual(act(.next, cursor: 99_000), .skipPlayer)
    XCTAssertEqual(act(.live, cursor: 99_500), .none)
    XCTAssertEqual(act(.live, cursor: 50_000), .seek(99_500))
  }

  func testPreviousRestartsTheCurrentSong() {
    let marks = [mark(10_000), mark(20_000)]
    XCTAssertEqual(act(.previous, cursor: 25_000, marks: marks), .seek(20_000))
    XCTAssertEqual(act(.previous, cursor: 23_000, marks: marks), .seek(20_000))  // exactly 3 s in
  }

  func testPreviousWithinThreeSecondsGoesToTheSongBefore() {
    let marks = [mark(10_000), mark(20_000)]
    XCTAssertEqual(act(.previous, cursor: 21_000, marks: marks), .seek(10_000))
  }

  func testPreviousRestartsWhenNoSongBeforeAndDoesNothingBeforeTheFirstMark() {
    XCTAssertEqual(act(.previous, cursor: 11_000, marks: [mark(10_000)]), .seek(10_000))
    XCTAssertEqual(act(.previous, cursor: 5_000, marks: [mark(10_000)]), .none)
  }

  // MARK: live edge

  func testLiveEdgeKeepsTheConfiguredLagWithoutGoingBeforeTheRecordingStart() {
    XCTAssertEqual(liveEdge(head: head, liveLag: liveLag), 99_500)
    XCTAssertEqual(liveEdge(head: 400, liveLag: liveLag), 0)
  }

  func testAtLiveIncludesOneSecondBehindTheEdgeButNotOneFrameMore() {
    XCTAssertTrue(isAtLive(cursor: 99_500, head: head, rate: rate, liveLag: liveLag))
    XCTAssertTrue(isAtLive(cursor: 98_500, head: head, rate: rate, liveLag: liveLag))
    XCTAssertFalse(isAtLive(cursor: 98_499, head: head, rate: rate, liveLag: liveLag))
    XCTAssertTrue(isAtLive(cursor: 100_000, head: head, rate: rate, liveLag: liveLag))
  }

  func testBufferedIsTheRecordingAheadOfTheCursorNeverNegative() {
    XCTAssertEqual(bufferedFrames(cursor: 40_000, head: head), 60_000)
    XCTAssertEqual(bufferedFrames(cursor: head, head: head), 0)
    XCTAssertEqual(bufferedFrames(cursor: head + 5, head: head), 0)
  }

  func testThePlayerPlaysWhileStemmixPlaysElseFillsToTheTargetUnlessHeld() {
    XCTAssertTrue(playerShouldPlay(playing: true, held: false, buffered: 500, target: 300))
    XCTAssertTrue(playerShouldPlay(playing: false, held: false, buffered: 299, target: 300))
    XCTAssertFalse(playerShouldPlay(playing: false, held: false, buffered: 300, target: 300))
    XCTAssertFalse(playerShouldPlay(playing: false, held: true, buffered: 0, target: 300))
  }

  func testAHeldPlayerIsNeverAskedToPlayEvenWhileStemmixPlays() {
    XCTAssertFalse(playerShouldPlay(playing: true, held: true, buffered: 0, target: 300))
  }

  func testAnAttachTakesTheLastAttachsIntentElseThePlayersState() {
    XCTAssertTrue(attachIntent(playerPlaying: true, resume: nil) == (true, false))
    XCTAssertTrue(attachIntent(playerPlaying: false, resume: nil) == (false, true))
    XCTAssertTrue(attachIntent(playerPlaying: true, resume: (false, false)) == (false, false))
    XCTAssertTrue(attachIntent(playerPlaying: false, resume: (true, false)) == (true, false))
  }

  func testAvailableCommandsAreExactlyTheResolverCommandsThatWouldAct() {
    let cases: [(cursor: Int, playing: Bool, marks: [TrackMark])] = [
      (99_500, true, []),
      (50_000, true, []),
      (50_000, false, [mark(10_000), mark(70_000)]),
      (21_000, true, [mark(10_000), mark(20_000)]),
    ]

    for testCase in cases {
      let commands: [TransportCommand] = [.next, .previous]
      let expected = Set(commands.filter {
        act($0, cursor: testCase.cursor, playing: testCase.playing, marks: testCase.marks) != .none
      })
      XCTAssertEqual(
        availableCommands(
          cursor: testCase.cursor,
          head: head,
          playing: testCase.playing,
          marks: testCase.marks,
          rate: rate,
          liveLag: liveLag),
        expected)
    }
  }

  // MARK: notification parsing

  private let spotify: [AnyHashable: Any] = [
    "Has Artwork": NSNumber(value: 1), "Player State": "Playing", "Playback Position": NSNumber(value: 0),
    "Track Number": NSNumber(value: 14), "Name": "Until I Bleed Out", "Album Artist": "The Weeknd",
    "Disc Number": NSNumber(value: 1), "Play Count": NSNumber(value: 0), "Artist": "The Weeknd",
    "Track ID": "spotify:track:2BcnxwxBuar5wjCaLqm5N3", "Album": "After Hours", "Duration": NSNumber(value: 190173),
    "Popularity": NSNumber(value: 64),
  ]

  func testParsesARealSpotifyNotification() throws {
    let e = try XCTUnwrap(parsePlayerEvent(spotify))
    XCTAssertEqual(e.state, .playing)
    XCTAssertEqual(e.trackID, "spotify:track:2BcnxwxBuar5wjCaLqm5N3")
    XCTAssertEqual(e.title, "Until I Bleed Out")
    XCTAssertEqual(e.artist, "The Weeknd")
    XCTAssertEqual(try XCTUnwrap(e.durationSeconds), 190.173, accuracy: 1e-9)
    XCTAssertEqual(e.positionSeconds, 0)
  }

  func testMissingOrUnknownPlayerStateParsesToNil() {
    var info = spotify
    info["Player State"] = "Buffering"
    XCTAssertNil(parsePlayerEvent(info))
    info["Player State"] = nil
    XCTAssertNil(parsePlayerEvent(info))
    info["Player State"] = "Paused"
    XCTAssertEqual(parsePlayerEvent(info)?.state, .paused)
  }

  // MARK: follower

  private func event(_ state: PlayerEvent.State, track: String = "A", duration: Double? = 100, position: Double? = 0) -> PlayerEvent {
    PlayerEvent(state: state, trackID: track, title: "T\(track)", artist: "X", durationSeconds: duration, positionSeconds: position)
  }

  func testPlayingToPausedPauses() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing), now: 0, head: 0, behindLive: false)
    XCTAssertEqual(f.handle(event(.paused), now: 10, head: 100, behindLive: false).action, .pause)
  }

  func testPausedToPlayingPlays() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing), now: 0, head: 0, behindLive: false)
    _ = f.handle(event(.paused), now: 10, head: 100, behindLive: false)
    XCTAssertEqual(f.handle(event(.playing), now: 20, head: 200, behindLive: false).action, .play)
  }

  func testNaturalSongEndMarksTheNewSongWithoutAnAction() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: true)
    let r = f.handle(event(.playing, track: "B"), now: 98, head: 98_000, behindLive: true)
    XCTAssertEqual(r.action, .none)
    XCTAssertEqual(r.mark, TrackMark(frame: 98_000, title: "TB", artist: "X"))
  }

  func testSkipWhileBehindLiveSeeksToTheHead() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: true)
    let r = f.handle(event(.playing, track: "B"), now: 30, head: 30_000, behindLive: true)
    XCTAssertEqual(r.seek, 30_000)
    XCTAssertEqual(r.action, .play)
    XCTAssertEqual(r.mark?.frame, 30_000)
  }

  func testSkipWhileLivePlaysAndMarksWithoutASeek() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: false)
    let r = f.handle(event(.playing, track: "B"), now: 30, head: 30_000, behindLive: false)
    XCTAssertEqual(r.action, .play)
    XCTAssertNil(r.seek)
    XCTAssertNotNil(r.mark)
  }

  func testAwaitingSkipSeeksToTheHeadOnANewTrackEvenWhileLive() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: false)
    f.expect(.trackChange, until: 33)
    let r = f.handle(event(.playing, track: "B"), now: 30, head: 30_000, behindLive: false)
    XCTAssertEqual(r.seek, 30_000)
    XCTAssertEqual(r.action, .none)
    XCTAssertEqual(r.mark, TrackMark(frame: 30_000, title: "TB", artist: "X"))
  }

  func testAwaitingSkipSeeksOnANaturalSongEnd() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: true)
    f.expect(.trackChange, until: 101)
    let r = f.handle(event(.playing, track: "B"), now: 98, head: 98_000, behindLive: true)
    XCTAssertEqual(r.seek, 98_000)
    XCTAssertEqual(r.mark?.frame, 98_000)
  }

  func testAwaitingSkipDoesNotSeekOnARepeatedEventForTheSameTrack() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing), now: 0, head: 0, behindLive: false)
    f.expect(.trackChange, until: 8)
    let r = f.handle(event(.playing), now: 5, head: 5_000, behindLive: false)
    XCTAssertEqual(r.action, .none)
    XCTAssertNil(r.seek)
    XCTAssertNil(r.mark)
  }

  func testAwaitingSkipFromPausedKeepsThePlayStateAlongsideTheSeek() {
    var f = PlayerFollower(playerPlaying: false)
    _ = f.handle(event(.paused, track: "A"), now: 0, head: 0, behindLive: false)
    f.expect(.trackChange, until: 33)
    let r = f.handle(event(.playing, track: "B"), now: 30, head: 30_000, behindLive: false)
    XCTAssertEqual(r.action, .play)
    XCTAssertEqual(r.seek, 30_000)
  }

  func testRepeatedEventsForTheSameTrackAddNoMark() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing), now: 0, head: 0, behindLive: false)
    XCTAssertNil(f.handle(event(.playing), now: 5, head: 5_000, behindLive: false).mark)
  }

  func testAnOwnPauseOrPlayIsFollowedSilently() {
    var f = PlayerFollower(playerPlaying: true)
    f.expect(.paused, until: 3)
    XCTAssertEqual(f.handle(event(.paused), now: 1, head: 0, behindLive: false).action, .none)
    XCTAssertTrue(f.playerPaused)
    f.expect(.playing, until: 13)
    let resumed = f.handle(event(.playing), now: 11, head: 0, behindLive: false)
    XCTAssertEqual(resumed.action, .none)
    XCTAssertTrue(resumed.startedPlaying)
    XCTAssertFalse(f.playerPaused)
  }

  func testAnEchoAfterItsWindowIsTheUsers() {
    var f = PlayerFollower(playerPlaying: true)
    f.expect(.paused, until: 3)
    XCTAssertEqual(f.expire(at: 3.5), [.paused])
    XCTAssertEqual(f.handle(event(.paused), now: 4, head: 0, behindLive: false).action, .pause)
  }

  func testAWithdrawnEchoClaimsNothing() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100), now: 0, head: 0, behindLive: true)
    f.expect(.trackChange, until: 33)
    f.withdraw(.trackChange, at: 30)
    XCTAssertFalse(f.isExpecting(.trackChange, at: 30))
    let r = f.handle(event(.playing, track: "B"), now: 30, head: 30_000, behindLive: true)
    XCTAssertEqual(r.action, .play)
  }

  /// Stemmix pauses the player for 100 s mid-song; by wall clock the song would have ended, by play time it has not.
  func testAPickAfterAPauseIsJudgedByPlayTime() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100, position: 0), now: 0, head: 0, behindLive: true)
    f.expect(.paused, until: 53)
    _ = f.handle(event(.paused, track: "A", position: nil), now: 50, head: 50_000, behindLive: true)
    f.expect(.playing, until: 153)
    _ = f.handle(event(.playing, track: "A", position: nil), now: 150, head: 50_000, behindLive: true)
    let r = f.handle(event(.playing, track: "B"), now: 170, head: 70_000, behindLive: true)
    XCTAssertEqual(r.action, .play)
    XCTAssertEqual(r.seek, 70_000)
  }

  func testASongEndAfterAPauseIsNotAPick() {
    var f = PlayerFollower(playerPlaying: true)
    _ = f.handle(event(.playing, track: "A", duration: 100, position: 0), now: 0, head: 0, behindLive: true)
    f.expect(.paused, until: 53)
    _ = f.handle(event(.paused, track: "A", position: 50), now: 50, head: 50_000, behindLive: true)
    f.expect(.playing, until: 153)
    _ = f.handle(event(.playing, track: "A", position: 50), now: 150, head: 50_000, behindLive: true)
    let r = f.handle(event(.playing, track: "B"), now: 196, head: 96_000, behindLive: true)
    XCTAssertEqual(r.action, .none)
    XCTAssertNil(r.seek)
    XCTAssertNotNil(r.mark)
  }
}
