import XCTest

@testable import stemmix

final class PendingEchoesTests: XCTestCase {
  func testAClaimConsumesTheOldestMatchingEchoInsideItsWindow() {
    var echoes = PendingEchoes<PlayerEcho>()
    echoes.expect(.paused, until: 3)
    echoes.expect(.paused, until: 5)
    XCTAssertTrue(echoes.claim(.paused, at: 1))
    XCTAssertTrue(echoes.isPending(.paused, at: 4))
    XCTAssertFalse(echoes.isPending(.playing, at: 4))
    XCTAssertTrue(echoes.claim(.paused, at: 4))
    XCTAssertFalse(echoes.claim(.paused, at: 4))
  }

  func testAKeyOnlyClaimsItsOwnKind() {
    var echoes = PendingEchoes<PlayerEcho>()
    echoes.expect(.trackChange, until: 3)
    XCTAssertFalse(echoes.claim(.playing, at: 1))
    XCTAssertTrue(echoes.claim(.trackChange, at: 1))
  }

  func testExpireDropsPassedWindowsAndNamesThem() {
    var echoes = PendingEchoes<PlayerEcho>()
    echoes.expect(.playing, until: 3)
    echoes.expect(.trackChange, until: 10)
    XCTAssertEqual(echoes.expire(at: 3), [])
    XCTAssertEqual(echoes.expire(at: 3.1), [.playing])
    XCTAssertFalse(echoes.claim(.playing, at: 3.1))
    XCTAssertFalse(echoes.isEmpty)
  }
}

final class PlayerSendQueueTests: XCTestCase {
  func testANextWhileOneIsPendingIsBusyAndNeverWaitsOnAStateSend() {
    var queue = PlayerSendQueue<Int>()
    guard case .send = queue.submit(.next, done: 1) else { return XCTFail("first next goes out") }
    guard case .busy = queue.submit(.next, done: 2) else { return XCTFail("second next is busy") }
    guard case .send = queue.submit(.pause, done: 3) else { return XCTFail("a pause beside a next goes out") }
    XCTAssertNil(queue.finished(.next))
    guard case .send = queue.submit(.next, done: 4) else { return XCTFail("a next after the first finished goes out") }
  }

  func testTheLatestPlayOrPauseIsKeptAndSentNextAndAnEarlierKeptOneIsSuperseded() {
    var queue = PlayerSendQueue<Int>()
    guard case .send = queue.submit(.pause, done: 1) else { return XCTFail("first state send goes out") }
    guard case let .kept(none) = queue.submit(.play, done: 2), none == nil else { return XCTFail("play is kept") }
    guard case let .kept(superseded) = queue.submit(.pause, done: 3), let superseded else { return XCTFail("pause supersedes") }
    XCTAssertEqual(superseded.command, .play)
    XCTAssertEqual(superseded.done, 2)
    let next = queue.finished(.pause)
    XCTAssertEqual(next?.command, .pause)
    XCTAssertEqual(next?.done, 3)
    XCTAssertNil(queue.finished(.pause))
    guard case .send = queue.submit(.play, done: 4) else { return XCTFail("idle again: play goes out") }
  }
}

/// The buffer rule end to end through Playback, with a fake player in place of Spotify: it takes the commands
/// it is sent (unless `takes` is false), and its real state is what Core Audio would report.
final class PlaybackTests: XCTestCase {
  private let rate = 1_000
  private var sent: [PlayerCommand] = []
  private var takes = true
  private var spotifyPlaying = true

  private func makePlayback(playerPlaying: Bool = true, resume: (playing: Bool, held: Bool)? = nil) -> Playback {
    spotifyPlaying = playerPlaying
    return Playback(rate: rate, playerPlaying: playerPlaying, resume: resume, bufferAheadSeconds: 2) { [unowned self] command, done in
      sent.append(command)
      if takes, command != .next { spotifyPlaying = command == .play }
      done(takes)
    }
  }

  private func tick(_ playback: Playback, now: TimeInterval) { playback.tick(now: now, playerOutputting: spotifyPlaying) }

  private func record(_ playback: Playback, seconds: Int) {
    let samples = [Float](repeating: 0.5, count: seconds * rate * Timeline.channels)
    samples.withUnsafeBufferPointer { playback.timeline.record(interleaved: $0.baseAddress!, frames: seconds * rate) }
  }

  /// The fake player posts its state; a user action in it also changes its real state.
  @discardableResult
  private func post(
    _ playback: Playback, _ state: PlayerEvent.State, now: TimeInterval, track: String = "A", position: Double? = nil
  ) -> PlayerFollower.Reaction {
    spotifyPlaying = state == .playing
    return playback.handle(
      PlayerEvent(state: state, trackID: track, title: "T", artist: "X", durationSeconds: 100, positionSeconds: position), now: now)
  }

  func testAPauseFromTheKeysKeepsThePlayerPlayingUntilTheTargetThenPausesIt() {
    let playback = makePlayback()
    post(playback, .playing, now: 0)
    playback.handle(.pause, source: "test", now: 1)
    tick(playback, now: 1)
    XCTAssertEqual(sent, [])
    record(playback, seconds: 2)
    tick(playback, now: 2)
    XCTAssertEqual(sent, [.pause])
    // The player's answer is the own echo: stemmix stays paused and not held.
    XCTAssertEqual(post(playback, .paused, now: 2.5).action, .none)
    XCTAssertFalse(playback.playerHeld)
    tick(playback, now: 3)
    XCTAssertEqual(sent, [.pause])
  }

  func testPlayResumesThePlayerAtOnce() {
    let playback = makePlayback()
    post(playback, .playing, now: 0)
    playback.handle(.pause, source: "test", now: 1)
    record(playback, seconds: 3)
    tick(playback, now: 1)
    post(playback, .paused, now: 1.2)
    playback.handle(.play, source: "test", now: 2)
    tick(playback, now: 2)
    XCTAssertEqual(sent, [.pause, .play])
    XCTAssertEqual(post(playback, .playing, now: 2.2).action, .none)
    XCTAssertTrue(playback.intendsPlaying)
  }

  func testAPauseMadeInThePlayerPausesStemmixAndHoldsUntilAPlay() {
    let playback = makePlayback()
    post(playback, .playing, now: 0)
    XCTAssertEqual(post(playback, .paused, now: 1).action, .pause)
    XCTAssertFalse(playback.intendsPlaying)
    XCTAssertTrue(playback.playerHeld)
    tick(playback, now: 2)
    XCTAssertEqual(sent, [], "a held pause gets no refill")
    playback.handle(.toggle, source: "media-key", now: 3)
    tick(playback, now: 3)
    XCTAssertFalse(playback.playerHeld)
    XCTAssertEqual(sent, [.play])
  }

  func testAPlayMadeInThePlayerPlaysStemmix() {
    let playback = makePlayback(playerPlaying: false)
    XCTAssertFalse(playback.intendsPlaying)
    XCTAssertTrue(playback.playerHeld, "a player paused at the attach is the user's pause")
    XCTAssertEqual(post(playback, .playing, now: 1).action, .play)
    XCTAssertTrue(playback.intendsPlaying)
    tick(playback, now: 1)
    XCTAssertEqual(sent, [])
  }

  func testAPlayerThatDoesNotTakeTheEventIsNotAskedAgainEveryTick() {
    takes = false
    let playback = makePlayback()
    post(playback, .playing, now: 0)
    playback.handle(.pause, source: "test", now: 0)
    record(playback, seconds: 3)
    tick(playback, now: 1)
    tick(playback, now: 1.25)
    tick(playback, now: 10)
    XCTAssertEqual(sent, [.pause])
    // Stemmix's own wanted state changing asks again.
    playback.handle(.play, source: "test", now: 11)
    tick(playback, now: 11)
    playback.handle(.pause, source: "test", now: 12)
    tick(playback, now: 12)
    XCTAssertEqual(sent, [.pause, .pause])
  }

  func testASongPickedInThePlayerWhileStemmixIsPausedPlaysItFromTheHead() {
    let playback = makePlayback()
    post(playback, .playing, now: 0, position: 0)
    playback.handle(.pause, source: "test", now: 1)
    record(playback, seconds: 10)
    let reaction = post(playback, .playing, now: 10, track: "B", position: 0)
    XCTAssertEqual(reaction.action, .play)
    XCTAssertEqual(reaction.seek, 10_000)
    XCTAssertTrue(playback.intendsPlaying)
  }

  func testASongPickedInThePlayerAfterAHeldPauseClearsTheHold() {
    let playback = makePlayback()
    post(playback, .playing, now: 0, position: 0)
    post(playback, .paused, now: 5)
    XCTAssertTrue(playback.playerHeld)
    XCTAssertEqual(post(playback, .playing, now: 8, track: "B", position: 0).action, .play)
    XCTAssertFalse(playback.playerHeld)
  }

  func testTheQueueEndingInThePlayerKeepsStemmixPlayingAndAsksNothing() {
    let playback = makePlayback()
    post(playback, .playing, now: 0, position: 0)
    let end = post(playback, .paused, now: 99, position: 99)
    XCTAssertEqual(end.action, .none)
    XCTAssertTrue(end.ended)
    XCTAssertTrue(playback.intendsPlaying)
    XCTAssertTrue(playback.playerHeld)
    tick(playback, now: 100)
    XCTAssertEqual(sent, [])
    XCTAssertTrue(post(playback, .stopped, now: 101).ended == false, "a repeat of the same state is no change")
  }

  func testAWrongBeliefIsCorrectedFromTheOutputAndTheRuleAsksAgain() {
    let playback = makePlayback()
    // The attach read the player as playing, but it is paused and posts nothing.
    spotifyPlaying = false
    tick(playback, now: 0)
    tick(playback, now: 2.9)
    XCTAssertEqual(sent, [])
    tick(playback, now: 3)
    XCTAssertEqual(sent, [.play])
  }

  func testAReattachKeepsThePausedIntentWhileThePlayerFills() {
    let playback = makePlayback(playerPlaying: true, resume: (playing: false, held: false))
    XCTAssertFalse(playback.intendsPlaying)
    XCTAssertFalse(playback.playerHeld)
    XCTAssertTrue(playback.playerFillsUnheard)
  }
}
