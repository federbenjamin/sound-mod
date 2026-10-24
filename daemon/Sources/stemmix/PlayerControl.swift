import CoreServices
import Foundation

/// Asks the music player to skip to its next track with its own AppleScript "next track" Apple event. The send
/// runs off the main thread: the first one waits on the Automation prompt for as long as it stays unanswered.
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

  private static func send(bundleID: String, eventClass: AEEventClass, eventID: AEEventID) -> String {
    let address = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    let permission = AEDeterminePermissionToAutomateTarget(address.aeDesc, eventClass, eventID, true)
    switch permission {
    case noErr: break
    case OSStatus(errAEEventNotPermitted): return "denied"
    case OSStatus(procNotFound): return "not-running"
    default: return "error=\(permission)"
    }
    let event = NSAppleEventDescriptor(
      eventClass: eventClass, eventID: eventID, targetDescriptor: address,
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    do {
      _ = try event.sendEvent(options: [.waitForReply], timeout: Config.playerControlTimeout)
      return "ok"
    } catch {
      return "error=\((error as NSError).code)"
    }
  }
}

/// A four-character Apple event code ("spfy") as its 32-bit value.
func fourCharCode(_ code: String) -> FourCharCode {
  code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
