import Foundation
import MediaPlayer

/// The daemon's belief about who holds the media keys (macOS's one Now Playing slot).
enum SlotBelief: String, Equatable { case held, lost }

enum SlotEvent: Equatable {
  /// A path change that is stemmix's own move.
  case held
  /// A path change no own set answered within the window; `retake`: the cooldown allows one retake now.
  case lost(retake: Bool)
}

/// The sets of one pulse after the last own set `last`: exactly one change into Playing, ending on `playing`.
/// A same-value set never reaches mediaremoted, so it pauses first when the last set was Playing; the sets
/// reach it as separate transitions within one run-loop turn (design doc, choice 18).
func pulseSets(after last: MPNowPlayingPlaybackState, playing: Bool) -> [MPNowPlayingPlaybackState] {
  (last == .playing ? [.paused, .playing] : [.playing]) + (playing ? [] : [.paused])
}

/// Whether an own set moves stemmix into Playing, the change mediaremoted hands the slot for.
func takesSlot(from last: MPNowPlayingPlaybackState, to new: MPNowPlayingPlaybackState) -> Bool {
  new == .playing && last != .playing
}

/// Infers who holds the Now Playing slot from stemmix's own sets into Playing and mediaremoted's path-change
/// posts, which name no holder. A post within `Config.nowPlayingChangeWindow` of an own move of the slot is
/// stemmix's own; any other post is a loss unless an own set answers it within the window.
struct SlotWatch {
  private enum OwnMove: Equatable { case slot }

  private(set) var belief: SlotBelief?
  /// Each own move's post still to come.
  private var ownChanges = PendingEchoes<OwnMove>()
  private var unexplainedChangeAt: TimeInterval?
  private var lastRetakeAt: TimeInterval?

  /// An own `playbackState` set into Playing.
  mutating func tookSlot(at now: TimeInterval) {
    // Holding with nothing unexplained, the set moves no slot, so mediaremoted posts nothing to wait for.
    if belief != .held || unexplainedChangeAt != nil {
      ownChanges.expect(.slot, until: now + Config.nowPlayingChangeWindow)
    }
    unexplainedChangeAt = nil
    belief = .held
  }

  /// The claim's release: the belief starts over, and a held slot moves back to its previous holder, a post
  /// to come that a claim right after it (a re-attach in the same tick) must not read as a loss.
  mutating func released(at now: TimeInterval) {
    var pending = ownChanges
    _ = pending.expire(at: now)
    if belief == .held { pending.expect(.slot, until: now + Config.nowPlayingChangeWindow) }
    self = SlotWatch()
    ownChanges = pending
  }

  /// A path-change post: `.held` when it is one of stemmix's own expected moves, else nil (judged by `settle`).
  mutating func pathChanged(at now: TimeInterval) -> SlotEvent? {
    if ownChanges.claim(.slot, at: now) { return .held }
    if unexplainedChangeAt == nil { unexplainedChangeAt = now }
    return nil
  }

  /// `.lost(retake:)` once a foreign post has gone a full window unanswered, else nil.
  mutating func settle(now: TimeInterval) -> SlotEvent? {
    _ = ownChanges.expire(at: now)
    guard let changedAt = unexplainedChangeAt, now - changedAt >= Config.nowPlayingChangeWindow else { return nil }
    unexplainedChangeAt = nil
    belief = .lost
    let retake = lastRetakeAt.map { now - $0 >= Config.nowPlayingRetakeCooldown } ?? true
    if retake { lastRetakeAt = now }
    return .lost(retake: retake)
  }
}
