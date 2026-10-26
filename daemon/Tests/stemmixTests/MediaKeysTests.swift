import MediaPlayer
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
    var follower = PlayerFollower(playerPlaying: false)

    let firstPlaying = follower.handle(event(.playing), now: 0, head: 100, behindLive: false)
    XCTAssertTrue(firstPlaying.startedPlaying)
    XCTAssertEqual(firstPlaying.action, .play)
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

  func testEveryPulseChangesIntoPlayingExactlyOnceAndEndsOnTheTruth() {
    for last in [MPNowPlayingPlaybackState.unknown, .playing, .paused, .stopped, .interrupted] {
      for playing in [true, false] {
        let sets = pulseSets(after: last, playing: playing)
        let transitions = zip([last] + sets.dropLast(), sets)

        XCTAssertEqual(transitions.filter { takesSlot(from: $0.0, to: $0.1) }.count, 1, "after \(last.rawValue), playing \(playing)")
        XCTAssertTrue(transitions.allSatisfy { $0.0 != $0.1 }, "a same-value set never reaches mediaremoted")
        XCTAssertEqual(sets.last, playing ? .playing : .paused)
      }
    }
  }

  func testOnlyASetIntoPlayingFromAnotherStateTakesTheSlot() {
    XCTAssertTrue(takesSlot(from: .unknown, to: .playing))
    XCTAssertTrue(takesSlot(from: .paused, to: .playing))
    XCTAssertTrue(takesSlot(from: .stopped, to: .playing))
    XCTAssertFalse(takesSlot(from: .playing, to: .playing))
    XCTAssertFalse(takesSlot(from: .playing, to: .paused))
    XCTAssertFalse(takesSlot(from: .paused, to: .stopped))
  }

  /// A detach and an attach in one tick: release's move back and claim's move to stemmix both post, in
  /// either order, after the claim.
  func testSameTickReattachExpectsBothPostsAndSpendsNoRetake() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.01), .held)

    watch.released(at: 10)
    watch.tookSlot(at: 10)

    XCTAssertEqual(watch.pathChanged(at: 10.02), .held)
    XCTAssertEqual(watch.pathChanged(at: 10.03), .held)
    XCTAssertNil(watch.settle(now: 11.5))
    XCTAssertEqual(watch.belief, .held)

    XCTAssertNil(watch.pathChanged(at: 20))
    XCTAssertEqual(watch.settle(now: 21.01), .lost(retake: true))
  }

  /// A re-attach a tick later (a dead tap): release's post lands before the claim, so the claim's own post is
  /// the only one left to expect, and a foreign post right after it is still a loss.
  func testReleasePostBeforeTheClaimLeavesOnlyTheClaimsPostExpected() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.01), .held)

    watch.released(at: 10)
    XCTAssertEqual(watch.pathChanged(at: 10.1), .held)
    watch.tookSlot(at: 10.25)

    XCTAssertEqual(watch.pathChanged(at: 10.3), .held)
    XCTAssertNil(watch.pathChanged(at: 10.5))
    XCTAssertNil(watch.settle(now: 11.4))
    XCTAssertEqual(watch.settle(now: 11.6), .lost(retake: true))
  }

  func testReleaseWhileLostExpectsNoPostOfItsOwn() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.1), .held)
    XCTAssertNil(watch.pathChanged(at: 2))
    XCTAssertEqual(watch.settle(now: 3.1), .lost(retake: true))

    watch.released(at: 4)
    watch.tookSlot(at: 4)

    XCTAssertEqual(watch.pathChanged(at: 4.05), .held)
    XCTAssertNil(watch.pathChanged(at: 4.1))
    XCTAssertEqual(watch.settle(now: 5.2), .lost(retake: true))
  }

  func testAReleaseLongBeforeTheNextClaimLeavesNothingExpected() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    XCTAssertEqual(watch.pathChanged(at: 0.1), .held)

    watch.released(at: 10)
    watch.tookSlot(at: 20)

    XCTAssertEqual(watch.pathChanged(at: 20.05), .held)
    XCTAssertNil(watch.pathChanged(at: 20.1))
    XCTAssertEqual(watch.settle(now: 21.2), .lost(retake: true))
  }

  /// A claim, released before its own post came, then claimed again: both own posts are still expected.
  func testAClaimsPendingPostSurvivesAReleaseInsideItsWindow() {
    var watch = SlotWatch()
    watch.tookSlot(at: 0)
    watch.released(at: 0.2)
    watch.tookSlot(at: 0.2)

    XCTAssertEqual(watch.pathChanged(at: 0.3), .held)
    XCTAssertEqual(watch.pathChanged(at: 0.31), .held)
    XCTAssertEqual(watch.pathChanged(at: 0.32), .held)
    XCTAssertNil(watch.settle(now: 2))
    XCTAssertEqual(watch.belief, .held)
  }
}
