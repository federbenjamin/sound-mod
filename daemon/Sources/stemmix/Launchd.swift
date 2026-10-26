import Foundation

/// The daemon's own launchd job label, from the environment launchd gives the job; nil outside launchd, where
/// `XPC_SERVICE_NAME` is "0", empty or absent.
func launchdLabel(environment: [String: String]) -> String? {
  guard let label = environment["XPC_SERVICE_NAME"], !label.isEmpty, label != "0" else { return nil }
  return label
}

/// The `launchctl` arguments that stop the job, which `KeepAlive` would otherwise restart.
func bootoutArguments(uid: uid_t, label: String) -> [String] { ["bootout", "gui/\(uid)/\(label)"] }

/// Whether a finished `launchctl bootout` failed. Exit 0 is the job removed, and an end by a signal is
/// launchd ending the job's process group; either way launchd's SIGTERM is on its way to the daemon.
func bootoutFailed(_ launchctl: Process) -> Bool {
  launchctl.terminationReason == .exit && launchctl.terminationStatus != 0
}
