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

/// The buffer rule end to end through Playback, with a recording control closure in place of the player.
final class PlaybackTests: XCTestCase {
  private let rate = 1_000
  private var sent: [PlayerCommand] = []
  private var takes = true

  private func makePlayback(playerPlaying: Bool = true) -> Playback {
    Playback(rate: rate, playerPlaying: playerPlaying, bufferAheadSeconds: 2) { [unowned self] command, done in
      sent.append(command)
      done(takes)
    }
  }

  private func record(_ playback: Playback, seconds: Int) {
    let samples = [Float](repeating: 0.5, count: seconds * rate * Timeline.channels)
    samples.withUnsafeBufferPointer { playback.timeline.record(interleaved: $0.baseAddress!, frames: seconds * rate) }
  }

  private func event(_ state: PlayerEvent.State) -> PlayerEvent {
    PlayerEvent(state: state, trackID: "A", title: "T", artist: "X", durationSeconds: 100, positionSeconds: nil)
  }

  func testAPauseFromTheKeysKeepsThePlayerPlayingUntilTheTargetThenPausesIt() {
    let playback = makePlayback()
    playback.handle(event(.playing), now: 0)
    playback.handle(.pause, source: "test", now: 1)
    playback.tick(now: 1)
    XCTAssertEqual(sent, [])
    record(playback, seconds: 2)
    playback.tick(now: 2)
    XCTAssertEqual(sent, [.pause])
    // The player's answer is the own echo: stemmix stays paused and not held.
    XCTAssertEqual(playback.handle(event(.paused), now: 2.5).action, .none)
    XCTAssertFalse(playback.playerHeld)
    playback.tick(now: 3)
    XCTAssertEqual(sent, [.pause])
  }

  func testPlayResumesThePlayerAtOnce() {
    let playback = makePlayback()
    playback.handle(event(.playing), now: 0)
    playback.handle(.pause, source: "test", now: 1)
    record(playback, seconds: 3)
    playback.tick(now: 1)
    playback.handle(event(.paused), now: 1.2)
    playback.handle(.play, source: "test", now: 2)
    playback.tick(now: 2)
    XCTAssertEqual(sent, [.pause, .play])
    XCTAssertEqual(playback.handle(event(.playing), now: 2.2).action, .none)
    XCTAssertTrue(playback.intendsPlaying)
  }

  func testAPauseMadeInThePlayerPausesStemmixAndHoldsUntilAPlay() {
    let playback = makePlayback()
    playback.handle(event(.playing), now: 0)
    XCTAssertEqual(playback.handle(event(.paused), now: 1).action, .pause)
    XCTAssertFalse(playback.intendsPlaying)
    XCTAssertTrue(playback.playerHeld)
    playback.tick(now: 2)
    XCTAssertEqual(sent, [], "a held pause gets no refill")
    playback.handle(.toggle, source: "media-key", now: 3)
    playback.tick(now: 3)
    XCTAssertFalse(playback.playerHeld)
    XCTAssertEqual(sent, [.play])
  }

  func testAPlayMadeInThePlayerPlaysStemmix() {
    let playback = makePlayback(playerPlaying: false)
    XCTAssertFalse(playback.intendsPlaying)
    XCTAssertTrue(playback.playerHeld, "a player paused at the attach is the user's pause")
    XCTAssertEqual(playback.handle(event(.playing), now: 1).action, .play)
    XCTAssertTrue(playback.intendsPlaying)
    playback.tick(now: 1)
    XCTAssertEqual(sent, [])
  }

  func testAPlayerThatDoesNotTakeTheEventIsNotAskedAgainEveryTick() {
    takes = false
    let playback = makePlayback()
    playback.handle(event(.playing), now: 0)
    playback.handle(.pause, source: "test", now: 0)
    record(playback, seconds: 3)
    playback.tick(now: 1)
    playback.tick(now: 1.25)
    playback.tick(now: 10)
    XCTAssertEqual(sent, [.pause])
    // Stemmix's own wanted state changing asks again.
    playback.handle(.play, source: "test", now: 11)
    playback.tick(now: 11)
    playback.handle(.pause, source: "test", now: 12)
    playback.tick(now: 12)
    XCTAssertEqual(sent, [.pause, .pause])
  }
}
