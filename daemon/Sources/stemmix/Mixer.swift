import CoreAudio
import Foundation

/// What the control loop asks of the render thread: a cutoff (nil = bypass) and a gain.
struct Target: Equatable {
  var cutoffHz: Double?
  var gain: Double
}

/// Owns the render-thread state: the low-pass, the ramps, and the copy from tap input to device output.
final class Mixer {
  private let lock = NSLock()
  private var target = Target(cutoffHz: nil, gain: 0)

  private let rate: Double
  private let inputChannels: Int
  private let inputInterleaved: Bool
  private var filter: LowPass
  private var currentLogCutoff: Double
  private var currentGain = 0.0
  private var scratch: [Float] = []
  private var levelSumSq = 0.0
  private var levelSamples = 0
  private let logFloor = log(Config.cutoffFloorHz)
  private let logCeiling = log(Config.cutoffCeilingHz)

  init(tapFormat: AudioStreamBasicDescription) {
    rate = tapFormat.mSampleRate
    inputChannels = Int(tapFormat.mChannelsPerFrame)
    inputInterleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    filter = LowPass(channels: inputChannels)
    currentLogCutoff = logCeiling
    filter.set(hz: Config.cutoffCeilingHz, rate: rate)
  }

  func set(_ next: Target) {
    lock.lock()
    target = next
    lock.unlock()
  }

  /// The input level since the last call: RMS in dBFS (nil with no samples), and how many samples it covers.
  func takeLevel() -> (rmsDb: Double?, samples: Int) {
    lock.lock()
    defer { lock.unlock(); levelSumSq = 0; levelSamples = 0 }
    let rms = levelSamples > 0 ? sqrt(levelSumSq / Double(levelSamples)) : 0
    return (rms > 0 ? 20 * log10(rms) : nil, levelSamples)
  }

  /// One IO cycle. Ramps toward the target, filters the tap input, and writes it to every output buffer.
  func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
    lock.lock()
    let wanted = target
    lock.unlock()

    let step = Double(frames) / (rate * Config.rampSeconds)
    let wantedLog = wanted.cutoffHz.map { log(min(max($0, Config.cutoffFloorHz), Config.cutoffCeilingHz)) } ?? logCeiling
    currentLogCutoff = approach(currentLogCutoff, wantedLog, by: step * (logCeiling - logFloor))
    currentGain = approach(currentGain, wanted.gain, by: step)
    let bypass = currentLogCutoff >= logCeiling - 1e-9
    if !bypass { filter.set(hz: exp(currentLogCutoff), rate: rate) }

    let outputs = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputs { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
    measure(input, frames: frames)
    guard frames > 0, currentGain > 0 || wanted.gain > 0 else {
      if bypass { filter.reset() }
      return
    }

    let needed = frames * inputChannels
    if scratch.count < needed { scratch = [Float](repeating: 0, count: needed) }
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let gain = Float(currentGain)
    for channel in 0..<inputChannels {
      let source: UnsafeMutablePointer<Float>
      let stride: Int
      if inputInterleaved {
        guard let data = inputs[0].mData else { return }
        source = data.assumingMemoryBound(to: Float.self).advanced(by: channel)
        stride = inputChannels
      } else {
        guard channel < inputs.count, let data = inputs[channel].mData else { return }
        source = data.assumingMemoryBound(to: Float.self)
        stride = 1
      }
      for frame in 0..<frames {
        let x = source[frame * stride]
        let y = bypass ? x : filter.process(channel: channel, x)
        scratch[frame * inputChannels + channel] = y * gain
      }
    }

    for buffer in outputs {
      guard let data = buffer.mData else { continue }
      let channels = Int(buffer.mNumberChannels)
      let out = data.assumingMemoryBound(to: Float.self)
      let outFrames = min(frames, Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))
      for frame in 0..<outFrames {
        for channel in 0..<channels {
          out[frame * channels + channel] = scratch[frame * inputChannels + min(channel, inputChannels - 1)]
        }
      }
    }
  }

  private func measure(_ input: UnsafePointer<AudioBufferList>, frames: Int) {
    let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    var sumSq = 0.0
    var count = 0
    for buffer in inputs {
      guard let data = buffer.mData else { continue }
      let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
      let p = data.assumingMemoryBound(to: Float.self)
      for i in 0..<samples { sumSq += Double(p[i] * p[i]) }
      count += samples
    }
    lock.lock()
    levelSumSq += sumSq
    levelSamples += count
    lock.unlock()
  }

  private func approach(_ current: Double, _ wanted: Double, by step: Double) -> Double {
    if abs(wanted - current) <= step { return wanted }
    return current + (wanted > current ? step : -step)
  }
}
