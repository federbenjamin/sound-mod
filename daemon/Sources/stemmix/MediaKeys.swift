import Foundation

/// The daemon's belief about who holds the media keys (macOS's one Now Playing slot).
enum SlotBelief: String, Equatable { case held, lost }

enum SlotEvent: Equatable {
  /// A path change that is stemmix's own move.
  case held
  /// A path change no own set answered within the window; `retake`: the cooldown allows one retake now.
  case lost(retake: Bool)
}

/// Infers who holds the Now Playing slot from stemmix's own sets into Playing and mediaremoted's path-change
/// posts, which name no holder. A post within `Config.nowPlayingChangeWindow` of an own set that moved the
/// slot is stemmix's own; any other post is a loss unless an own set answers it within the window.
struct SlotWatch {
  private(set) var belief: SlotBelief?
  private var expectsOwnChangeUntil: TimeInterval?
  private var unexplainedChangeAt: TimeInterval?
  private var lastRetakeAt: TimeInterval?

  /// An own `playbackState` set into Playing.
  mutating func tookSlot(at now: TimeInterval) {
    // Holding with nothing unexplained, the set moves no slot, so mediaremoted posts nothing to wait for.
    if belief != .held || unexplainedChangeAt != nil {
      expectsOwnChangeUntil = now + Config.nowPlayingChangeWindow
    }
    unexplainedChangeAt = nil
    belief = .held
  }

  /// A path-change post: `.held` when it is stemmix's own expected move, else nil (judged by `settle`).
  mutating func pathChanged(at now: TimeInterval) -> SlotEvent? {
    if let until = expectsOwnChangeUntil, now <= until {
      expectsOwnChangeUntil = nil
      return .held
    }
    if unexplainedChangeAt == nil { unexplainedChangeAt = now }
    return nil
  }

  /// `.lost(retake:)` once a foreign post has gone a full window unanswered, else nil.
  mutating func settle(now: TimeInterval) -> SlotEvent? {
    if let until = expectsOwnChangeUntil, now > until { expectsOwnChangeUntil = nil }
    guard let changedAt = unexplainedChangeAt, now - changedAt >= Config.nowPlayingChangeWindow else { return nil }
    unexplainedChangeAt = nil
    belief = .lost
    let retake = lastRetakeAt.map { now - $0 >= Config.nowPlayingRetakeCooldown } ?? true
    if retake { lastRetakeAt = now }
    return .lost(retake: retake)
  }
}
