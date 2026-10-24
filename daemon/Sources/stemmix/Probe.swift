import CoreAudio
import Foundation

// TCC's own check and request for System Audio Recording. Private SPI (no public API exists), as AudioCap uses.
private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
private let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private let audioCaptureService = "kTCCServiceAudioCapture" as CFString

enum CapturePermission: String {
  case authorized, denied, unknown, unavailable
}

func capturePermission() -> CapturePermission {
  guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessPreflight") else { return .unavailable }
  switch unsafeBitCast(symbol, to: PreflightFn.self)(audioCaptureService, nil) {
  case 0: return .authorized
  case 1: return .denied
  default: return .unknown
  }
}

/// Asks TCC for the permission, which shows the system dialog when none was answered; nil when it timed out.
func requestCapturePermission(timeout: TimeInterval) -> Bool? {
  guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessRequest") else { return nil }
  let done = DispatchSemaphore(value: 0)
  let answer = Answer()
  unsafeBitCast(symbol, to: RequestFn.self)(audioCaptureService, nil) { granted in
    answer.set(granted)
    done.signal()
  }
  return done.wait(timeout: .now() + timeout) == .timedOut ? nil : answer.get()
}

private final class Answer: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?
  func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
  func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LevelMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks = 0
  private var samples = 0
  private var sumSq = 0.0
  private var peak: Float = 0

  func add(_ input: UnsafePointer<AudioBufferList>) {
    var localSum = 0.0
    var localCount = 0
    var localPeak: Float = 0
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
      guard let data = buffer.mData else { continue }
      let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
      let p = data.assumingMemoryBound(to: Float.self)
      for i in 0..<count {
        localSum += Double(p[i] * p[i])
        localPeak = max(localPeak, abs(p[i]))
      }
      localCount += count
    }
    lock.lock()
    callbacks += 1
    samples += localCount
    sumSq += localSum
    peak = max(peak, localPeak)
    lock.unlock()
  }

  func summary() -> String {
    lock.lock()
    defer { lock.unlock() }
    let rms = samples > 0 ? sqrt(sumSq / Double(samples)) : 0
    let rmsText = rms > 0 ? String(format: "%.1fdBFS", 20 * log10(rms)) : "silent"
    let peakText = peak > 0 ? String(format: "%.1fdBFS", 20 * log10(Double(peak))) : "silent"
    return "callbacks=\(callbacks) samples=\(samples) rms=\(rmsText) peak=\(peakText)"
  }

  var heardSound: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sumSq > 0
  }
}

private func say(_ text: String) {
  print(text)
  fflush(stdout)
  Log.line("probe \(text)")
}

/// `--probe [bundle-prefix] [seconds]`: reports the permission, then (only when authorized) taps the player
/// unmuted for a few seconds and reports what arrived. Exit 0 means sound was captured.
func runProbe(_ arguments: [String]) -> Int32 {
  let prefix = arguments.first ?? Config.playerBundlePrefixes[Config.defaultPlayer]!
  let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 5
  let permission = capturePermission()
  say("permission=\(permission.rawValue)")
  let targets = playerProcessObjects(bundlePrefix: prefix)
  say("player=\(prefix) objects=\(targets) outputting=\(isOutputting(targets))")
  guard permission == .authorized else {
    say("result=not-authorized")
    return 3
  }
  guard !targets.isEmpty else {
    say("result=no-player-process")
    return 2
  }
  do {
    let tap = try ProcessTap(targets: targets, output: .current(), mute: .unmuted)
    let meter = LevelMeter()
    try tap.start { input, output, _ in
      meter.add(input)
      for buffer in UnsafeMutableAudioBufferListPointer(output) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
    }
    Thread.sleep(forTimeInterval: seconds)
    tap.stop(wait: Config.exitTeardownWait)
    say("result \(meter.summary())")
    return meter.heardSound ? 0 : 4
  } catch {
    say("result=error \(error)")
    return 5
  }
}

/// `--request`: asks TCC for the permission (the system dialog appears if unanswered), then reports the state.
func runRequest() -> Int32 {
  say("permission-before=\(capturePermission().rawValue)")
  let granted = requestCapturePermission(timeout: 120)
  say("request-answer=\(granted.map { $0 ? "granted" : "denied" } ?? "no answer in 120s")")
  say("permission-after=\(capturePermission().rawValue)")
  return capturePermission() == .authorized ? 0 : 3
}
