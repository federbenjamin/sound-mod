import AppKit
import CoreServices

/// Asks the music player to skip to its next track with its own AppleScript "next track" Apple event. The send
/// runs off the main thread, so the first one can wait on the Automation prompt without stalling the control loop.
final class PlayerControl {
  private let queue = DispatchQueue(label: "stemmix.player-control")
  /// Main thread only. A press while a send is pending (the prompt still up) is dropped, so that answering the
  /// prompt never fires a burst of queued skips.
  private var sending = false

  /// `done` runs on the main thread with whether the player took the event.
  func skipToNextTrack(player: String, done: @escaping (Bool) -> Void) {
    guard let target = Config.playerNextTrack[player] else {
      Log.line("transport forward=next player=\(player) result=unsupported")
      done(false)
      return
    }
    guard !sending else {
      Log.line("transport forward=next player=\(player) result=busy")
      done(false)
      return
    }
    sending = true
    queue.async {
      let result = Self.send(bundleID: target.bundleID, eventClass: fourCharCode(target.eventClass), eventID: fourCharCode(target.eventID))
      DispatchQueue.main.async {
        self.sending = false
        Log.line("transport forward=next player=\(player) result=\(result)")
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
