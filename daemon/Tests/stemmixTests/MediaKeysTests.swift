import XCTest

@testable import stemmix

final class MediaKeysTests: XCTestCase {
  private func event(_ state: PlayerEvent.State, track: String = "A") -> PlayerEvent {
    PlayerEvent(
      state: state,
      trackID: track,
      title: "T\(track)",
      artist: "X",
      durationSeconds: 100,
      positionSeconds: 0)
  }

  func testOwnPathChangeInsideOneSecondWindowConfirmsHeld() {
    var watch = SlotWatch()

    XCTAssertNil(watch.belief)
    watch.tookSlot(at: 10)

    XCTAssertEqual(watch.belief, .held)
    XCTAssertEqual(watch.pathChanged(at: 10.999), .held)
    XCTAssertEqual(watch.belief, .held)
    XCTAssertNil(watch.settle(now: 12))
  }

  func testOwnSetWithoutAPathChangeKeepsTheHeldBelief() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.5), .held)

    watch.tookSlot(at: 10)

    XCTAssertNil(watch.settle(now: 11.01))
    XCTAssertEqual(watch.belief, .held)
  }

  func testUnansweredPathChangeWaitsOneSecondThenRetakesOnlyAfterCooldown() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.5), .held)

    XCTAssertNil(watch.pathChanged(at: 2))
    XCTAssertNil(watch.settle(now: 2.999))
    XCTAssertEqual(watch.settle(now: 3.001), .lost(retake: true))
    XCTAssertEqual(watch.belief, .lost)

    XCTAssertNil(watch.pathChanged(at: 5))
    XCTAssertEqual(watch.settle(now: 6.001), .lost(retake: false))

    XCTAssertNil(watch.pathChanged(at: 34))
    XCTAssertEqual(watch.settle(now: 35.001), .lost(retake: true))
  }

  func testStartedPlayingTracksEveryTransitionWithoutChangingActionOrMark() {
    var follower = PlayerFollower()

    let firstPlaying = follower.handle(event(.playing), now: 0, head: 100, behindLive: false)
    XCTAssertTrue(firstPlaying.startedPlaying)
    XCTAssertEqual(firstPlaying.action, .none)
    XCTAssertEqual(firstPlaying.mark, TrackMark(frame: 100, title: "TA", artist: "X"))

    let repeatedPlaying = follower.handle(event(.playing), now: 1, head: 200, behindLive: false)
    XCTAssertFalse(repeatedPlaying.startedPlaying)
    XCTAssertEqual(repeatedPlaying.action, .none)
    XCTAssertNil(repeatedPlaying.mark)

    let paused = follower.handle(event(.paused), now: 2, head: 300, behindLive: false)
    XCTAssertFalse(paused.startedPlaying)
    XCTAssertEqual(paused.action, .pause)
    XCTAssertNil(paused.mark)

    let resumedPlaying = follower.handle(event(.playing), now: 3, head: 400, behindLive: false)
    XCTAssertTrue(resumedPlaying.startedPlaying)
    XCTAssertEqual(resumedPlaying.action, .play)
    XCTAssertNil(resumedPlaying.mark)
  }
}
