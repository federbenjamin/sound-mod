import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

enum CoreAudioError: Error, CustomStringConvertible {
  case status(OSStatus, String)
  case unsupported(String)
  case notAuthorized(CapturePermission)

  var description: String {
    switch self {
    case let .status(code, what): return "\(what) failed OSStatus \(code)"
    case let .unsupported(what): return what
    case let .notAuthorized(permission): return "not authorized (permission \(permission.rawValue))"
    }
  }
}

func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  var addr = address(selector, scope: scope)
  AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
  return value
}

func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
  var ref: Unmanaged<CFString>? = nil
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var addr = address(selector)
  guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let ref else { return "" }
  return ref.takeRetainedValue() as String
}

func readObjectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
  var addr = address(selector, scope: scope)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
  return ids
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

/// Core Audio process objects whose bundle id starts with the prefix, sorted so the set compares stably.
func playerProcessObjects(bundlePrefix: String) -> [AudioObjectID] {
  readObjectList(systemObject, kAudioHardwarePropertyProcessObjectList)
    .filter { readString($0, kAudioProcessPropertyBundleID).hasPrefix(bundlePrefix) }
    .sorted()
}

func isOutputting(_ objects: [AudioObjectID]) -> Bool {
  objects.contains { readUInt32($0, kAudioProcessPropertyIsRunningOutput) != 0 }
}

struct OutputDevice: Equatable {
  let id: AudioObjectID
  let uid: String

  static func current() -> OutputDevice {
    let id = readUInt32(systemObject, kAudioHardwarePropertyDefaultOutputDevice)
    return OutputDevice(id: id, uid: readString(id, kAudioDevicePropertyDeviceUID))
  }
}

/// The render callback: the tap's input buffers and the output device's buffers for one IO cycle.
typealias RenderBlock = (_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, _ frames: Int) -> Void

/// A process tap on the player, read through a private aggregate device that also owns the default output,
/// so one IO cycle reads the player and writes the speakers. `init` makes the tap and reads its format;
/// `start` builds the aggregate and runs IO; `stop` tears down on its own thread, since a stop can block in
/// coreaudiod and the control loop must not.
final class ProcessTap {
  let targets: [AudioObjectID]
  let output: OutputDevice
  private(set) var tapFormat = AudioStreamBasicDescription()
  private let tapUUID = UUID()
  private var tapID: AudioObjectID = kAudioObjectUnknown
  private var aggregateID: AudioObjectID = kAudioObjectUnknown
  private var procID: AudioDeviceIOProcID?
  /// Frames of input the IO thread never saw: cycles Core Audio skipped because one ran late. Read and reset by
  /// the control loop.
  let droppedFrames = Atomic<Int>(0)

  /// Throws `.notAuthorized` unless System Audio Recording is already granted. Never let coreaudiod ask TCC on
  /// our behalf: an unanswered prompt leaves coreaudiod blocked on every later tap until it restarts.
  init(targets: [AudioObjectID], output: OutputDevice, mute: CATapMuteBehavior = .mutedWhenTapped) throws {
    self.targets = targets
    self.output = output
    let permission = capturePermission()
    guard permission == .authorized else { throw CoreAudioError.notAuthorized(permission) }

    let description = CATapDescription(stereoMixdownOfProcesses: targets)
    description.uuid = tapUUID
    description.muteBehavior = mute
    description.name = "stemmix"
    var tap: AudioObjectID = kAudioObjectUnknown
    var status = AudioHardwareCreateProcessTap(description, &tap)
    guard status == noErr else { throw CoreAudioError.status(status, "AudioHardwareCreateProcessTap") }
    tapID = tap

    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var formatAddr = address(kAudioTapPropertyFormat)
    status = AudioObjectGetPropertyData(tap, &formatAddr, 0, nil, &formatSize, &format)
    guard status == noErr else { stop(); throw CoreAudioError.status(status, "kAudioTapPropertyFormat") }
    tapFormat = format
    guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
      stop()
      throw CoreAudioError.unsupported("tap format is not float32 PCM (id \(format.mFormatID) flags \(format.mFormatFlags) bits \(format.mBitsPerChannel))")
    }
  }

  func start(render: @escaping RenderBlock) throws {
    let aggregate: [String: Any] = [
      kAudioAggregateDeviceNameKey: "stemmix",
      kAudioAggregateDeviceUIDKey: "stemmix-\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: output.uid,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID.uuidString]],
    ]
    var agg: AudioObjectID = kAudioObjectUnknown
    var status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
    guard status == noErr else { throw CoreAudioError.status(status, "AudioHardwareCreateAggregateDevice") }
    aggregateID = agg

    setBufferFrames(agg, Config.ioBufferFrames)

    let bytesPerFrame = Int(tapFormat.mBytesPerFrame)
    var expected: Double?
    var proc: AudioDeviceIOProcID?
    // No dispatch queue: the block runs on Core Audio's real-time IO thread. Through a queue each cycle was a
    // dispatch_sync off that thread, and under load cycles ran late and were skipped.
    status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [self] _, inInputData, inInputTime, outOutputData, _ in
      let frames = Int(inInputData.pointee.mBuffers.mDataByteSize) / max(bytesPerFrame, 1)
      let time = inInputTime.pointee
      if time.mFlags.contains(.sampleTimeValid) {
        droppedFrames.wrappingAdd(missedFrames(expected: expected, sampleTime: time.mSampleTime), ordering: .relaxed)
        expected = time.mSampleTime + Double(frames)
      }
      render(inInputData, outOutputData, frames)
    }
    guard status == noErr, let proc else { throw CoreAudioError.status(status, "AudioDeviceCreateIOProcIDWithBlock") }
    procID = proc
    status = AudioDeviceStart(agg, proc)
    guard status == noErr else { throw CoreAudioError.status(status, "AudioDeviceStart") }
  }

  /// The aggregate's IO buffer, in frames, as the device runs it.
  var bufferFrames: UInt32 { readUInt32(aggregateID, kAudioDevicePropertyBufferFrameSize) }

  func outputStreamFormats() -> [AudioStreamBasicDescription] {
    readObjectList(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).map { stream in
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      var addr = address(kAudioStreamPropertyVirtualFormat)
      AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &format)
      return format
    }
  }

  /// Hands the Core Audio objects to a teardown thread; returns at once, or after the teardown when `wait` is
  /// given (bounded: a stop can block in coreaudiod). A client that dies holding a running tap wedges coreaudiod
  /// for every later tap, so an exit always waits.
  func stop(wait: TimeInterval? = nil) {
    let aggregate = aggregateID
    let proc = procID
    let tap = tapID
    aggregateID = kAudioObjectUnknown
    procID = nil
    tapID = kAudioObjectUnknown
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
      if aggregate != kAudioObjectUnknown {
        if let proc {
          AudioDeviceStop(aggregate, proc)
          AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
      }
      if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
      Log.line("teardown done tap=\(tap) aggregate=\(aggregate)")
      done.signal()
    }
    thread.name = "stemmix.teardown"
    thread.start()
    if let wait, done.wait(timeout: .now() + wait) == .timedOut {
      Log.line("teardown timed out after \(wait)s tap=\(tap) aggregate=\(aggregate)")
    }
  }
}

/// Asks for an IO buffer of `frames`, clamped to the device's range. A refusal leaves the device's default.
private func setBufferFrames(_ device: AudioObjectID, _ frames: Int) {
  var range = AudioValueRange()
  var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
  var rangeAddr = address(kAudioDevicePropertyBufferFrameSizeRange)
  var value = UInt32(frames)
  if AudioObjectGetPropertyData(device, &rangeAddr, 0, nil, &rangeSize, &range) == noErr {
    value = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
  }
  var addr = address(kAudioDevicePropertyBufferFrameSize)
  let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  if status != noErr { Log.line("io-buffer set-failed frames=\(value) status=\(status)") }
}

/// Input frames between the sample time the last cycle ended at and the one this cycle starts at: cycles the
/// device skipped. 0 for the first cycle, and for a cycle that starts early.
func missedFrames(expected: Double?, sampleTime: Double) -> Int {
  guard let expected else { return 0 }
  return max(0, Int((sampleTime - expected).rounded()))
}
