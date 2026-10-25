import Foundation

@main
enum Main {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--probe": exit(runProbe(Array(arguments.dropFirst())))
    case "--request": exit(runRequest())
    case "--record": exit(runRecord(Array(arguments.dropFirst())))
    case "--control": exit(runControl(Array(arguments.dropFirst())))
    case "--simulate": exit(runSimulate(Array(arguments.dropFirst())))
    default: Daemon().run()
    }
  }
}

/// `--control <command>`: sends a transport command to the running daemon.
func runControl(_ arguments: [String]) -> Int32 {
  guard let text = arguments.first, TransportCommand(rawValue: text) != nil else {
    print("usage: --control \(TransportCommand.allCases.map(\.rawValue).joined(separator: "|"))")
    return 64
  }
  DistributedNotificationCenter.default().postNotificationName(Config.controlNotification, object: text, userInfo: nil, deliverImmediately: true)
  return 0
}
