import AppKit
import CoreServices

/// Asks the music player to skip, play or pause with its own AppleScript Apple events. Sends run off the main
/// thread, in order, so the first one can wait on the Automation prompt without stalling the control loop.
/// Main thread only.
final class PlayerControl {
  private let queue = DispatchQueue(label: "stemmix.player-control")
  /// A next while one is pending (the prompt still up) is dropped, so that answering the prompt never fires a
  /// burst of queued skips.
  private var sendingNext = false
  /// A play or pause while one is pending is kept and sent after it, replacing an earlier kept one: the latest
  /// wanted state always reaches the player.
  private var sendingState = false
  private var keptState: (command: PlayerCommand, done: (Bool) -> Void)?

  /// `done` runs on the main thread with whether the player took the event.
  func send(_ command: PlayerCommand, player: String, done: @escaping (Bool) -> Void) {
    guard let target = Config.playerEvents[player] else {
      Log.line("player-control command=\(command.rawValue) player=\(player) result=unsupported")
      done(false)
      return
    }
    switch command {
    case .next:
      guard !sendingNext else {
        Log.line("player-control command=next player=\(player) result=busy")
        done(false)
        return
      }
      sendingNext = true
      dispatch(command, player: player, target: target, done: done) { self.sendingNext = false }
    case .play, .pause:
      guard !sendingState else {
        if let kept = keptState {
          Log.line("player-control command=\(kept.command.rawValue) player=\(player) result=superseded")
          kept.done(false)
        }
        keptState = (command, done)
        return
      }
      sendingState = true
      dispatch(command, player: player, target: target, done: done) {
        self.sendingState = false
        guard let kept = self.keptState else { return }
        self.keptState = nil
        self.send(kept.command, player: player, done: kept.done)
      }
    }
  }

  private func dispatch(
    _ command: PlayerCommand, player: String, target: (bundleID: String, eventClass: String, next: String, play: String, pause: String),
    done: @escaping (Bool) -> Void, finished: @escaping () -> Void
  ) {
    let eventID: String
    switch command {
    case .next: eventID = target.next
    case .play: eventID = target.play
    case .pause: eventID = target.pause
    }
    queue.async {
      let result = Self.send(bundleID: target.bundleID, eventClass: fourCharCode(target.eventClass), eventID: fourCharCode(eventID))
      DispatchQueue.main.async {
        Log.line("player-control command=\(command.rawValue) player=\(player) result=\(result)")
        finished()
        done(result == "ok")
      }
    }
  }

  /// Addresses the running player by pid: addressed by bundle ID, Spotify's events (and
  /// `AEDeterminePermissionToAutomateTarget`) got no reply on macOS 26 while the same event by pid answered at once.
  /// The send itself raises the Automation prompt the first time, and its timeout bounds the wait.
  private static func send(bundleID: String, eventClass: AEEventClass, eventID: AEEventID) -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return "not-running" }
    let event = NSAppleEventDescriptor(
      eventClass: eventClass, eventID: eventID,
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    do {
      _ = try event.sendEvent(options: [.waitForReply], timeout: Config.playerControlTimeout)
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
