import AppKit
import CoreServices

/// Which player command goes out now, which waits, which is dropped. A next while one is pending (the prompt still
/// up) is dropped, so that answering the prompt never fires a burst of queued skips. A play or pause while one is
/// pending is kept and sent after it, replacing an earlier kept one: the latest wanted state always reaches the
/// player. A next and a play or pause never wait on each other.
struct PlayerSendQueue<Done> {
  private var sendingNext = false
  private var sendingState = false
  private var kept: (command: PlayerCommand, done: Done)?

  enum Outcome {
    case send
    case busy
    /// Kept for later; `superseded` is the earlier kept command's completion, never to be sent.
    case kept(superseded: (command: PlayerCommand, done: Done)?)
  }

  mutating func submit(_ command: PlayerCommand, done: Done) -> Outcome {
    switch command {
    case .next:
      guard !sendingNext else { return .busy }
      sendingNext = true
      return .send
    case .play, .pause:
      guard sendingState else {
        sendingState = true
        return .send
      }
      let superseded = kept
      kept = (command, done)
      return .kept(superseded: superseded)
    }
  }

  /// A send finished; returns the kept command to send now, if any.
  mutating func finished(_ command: PlayerCommand) -> (command: PlayerCommand, done: Done)? {
    switch command {
    case .next:
      sendingNext = false
      return nil
    case .play, .pause:
      guard let next = kept else {
        sendingState = false
        return nil
      }
      kept = nil
      return next
    }
  }
}

/// Asks the music player to skip, play or pause with its own AppleScript Apple events. Sends run off the main
/// thread, in order, so the first one can wait on the Automation prompt without stalling the control loop.
/// Main thread only.
final class PlayerControl {
  private let queue = DispatchQueue(label: "stemmix.player-control")
  private var sends = PlayerSendQueue<(Bool) -> Void>()

  /// `done` runs on the main thread with whether the player took the event.
  func send(_ command: PlayerCommand, player: String, done: @escaping (Bool) -> Void) {
    guard let target = Config.playerEvents[player] else {
      Log.line("player-control command=\(command.rawValue) player=\(player) result=unsupported")
      done(false)
      return
    }
    switch sends.submit(command, done: done) {
    case .busy:
      Log.line("player-control command=\(command.rawValue) player=\(player) result=busy")
      done(false)
    case let .kept(superseded):
      if let superseded {
        Log.line("player-control command=\(superseded.command.rawValue) player=\(player) result=superseded")
        superseded.done(false)
      }
    case .send:
      dispatch(command, player: player, target: target, done: done)
    }
  }

  /// Sends one command and waits for its reply, at most `timeout`: for a teardown, before the process exits or
  /// the tap that mutes the player goes. Waits behind any send already queued.
  func sendNow(_ command: PlayerCommand, player: String, timeout: TimeInterval) {
    guard let target = Config.playerEvents[player] else { return }
    let result = queue.sync {
      Self.send(bundleID: target.bundleID, eventClass: fourCharCode(target.eventClass), eventID: fourCharCode(Self.eventID(command, target)), timeout: timeout)
    }
    Log.line("player-control command=\(command.rawValue) player=\(player) result=\(result) before=teardown")
  }

  private func dispatch(_ command: PlayerCommand, player: String, target: PlayerEvents, done: @escaping (Bool) -> Void) {
    queue.async {
      let result = Self.send(
        bundleID: target.bundleID, eventClass: fourCharCode(target.eventClass), eventID: fourCharCode(Self.eventID(command, target)),
        timeout: Config.playerControlTimeout)
      DispatchQueue.main.async {
        Log.line("player-control command=\(command.rawValue) player=\(player) result=\(result)")
        if let next = self.sends.finished(command) { self.dispatch(next.command, player: player, target: target, done: next.done) }
        done(result == "ok")
      }
    }
  }

  private typealias PlayerEvents = (bundleID: String, eventClass: String, next: String, play: String, pause: String)

  private static func eventID(_ command: PlayerCommand, _ target: PlayerEvents) -> String {
    switch command {
    case .next: return target.next
    case .play: return target.play
    case .pause: return target.pause
    }
  }

  /// Addresses the running player by pid: addressed by bundle ID, Spotify's events (and
  /// `AEDeterminePermissionToAutomateTarget`) got no reply on macOS 26 while the same event by pid answered at once.
  /// The send itself raises the Automation prompt the first time, and its timeout bounds the wait.
  private static func send(bundleID: String, eventClass: AEEventClass, eventID: AEEventID, timeout: TimeInterval) -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return "not-running" }
    let event = NSAppleEventDescriptor(
      eventClass: eventClass, eventID: eventID,
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    do {
      _ = try event.sendEvent(options: [.waitForReply], timeout: timeout)
      return "ok"
    } catch {
      switch (error as NSError).code {
      case Int(errAEEventNotPermitted): return "denied"
      case Int(procNotFound): return "not-running"
      case Int(errAETimeout): return "timeout-waiting-for-reply"
      case let code: return "error=\(code)"
      }
    }
  }
}

/// A four-character Apple event code ("spfy") as its 32-bit value.
func fourCharCode(_ code: String) -> FourCharCode {
  code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
