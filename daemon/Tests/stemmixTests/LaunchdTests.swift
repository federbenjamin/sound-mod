import Foundation
import XCTest

@testable import stemmix

final class LaunchdTests: XCTestCase {
  func testLabelIsNilOutsideLaunchdAndTheJobLabelInside() {
    XCTAssertNil(launchdLabel(environment: ["XPC_SERVICE_NAME": "0"]))
    XCTAssertNil(launchdLabel(environment: ["XPC_SERVICE_NAME": ""]))
    XCTAssertNil(launchdLabel(environment: ["HOME": "/Users/x"]))
    XCTAssertEqual(launchdLabel(environment: ["XPC_SERVICE_NAME": "com.example.job"]), "com.example.job")
  }

  func testBootoutTargetsTheJobInTheUsersGuiDomain() {
    XCTAssertEqual(bootoutArguments(uid: 501, label: "com.example.job"), ["bootout", "gui/501/com.example.job"])
  }

  private func finished(_ script: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    try process.run()
    process.waitUntilExit()
    return process
  }

  func testOnlyANonZeroExitIsAFailedBootout() throws {
    XCTAssertFalse(bootoutFailed(try finished("exit 0")))
    XCTAssertTrue(bootoutFailed(try finished("exit 5")))
  }

  /// launchd ends the job's process group, launchctl included: a launchctl ended by SIGTERM is a bootout that
  /// worked, even though its terminationStatus is the signal's number.
  func testALaunchctlEndedBySignalIsNotAFailedBootout() throws {
    let terminated = try finished("kill -TERM $$")
    XCTAssertEqual(terminated.terminationReason, .uncaughtSignal)
    XCTAssertFalse(bootoutFailed(terminated))
    XCTAssertFalse(bootoutFailed(try finished("kill -KILL $$")))
  }
}
