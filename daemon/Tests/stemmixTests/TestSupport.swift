import CoreAudio
import Foundation

@testable import stemmix

let contractDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("contract")

/// Runs one `Player.render` over plain arrays (interleaved stereo float32) and returns the output.
@discardableResult
func render(_ player: Player, frames: Int, input: [Float]? = nil) -> [Float] {
  var inBuf = input ?? [Float](repeating: 0, count: frames * 2)
  var outBuf = [Float](repeating: 0, count: frames * 2)
  let bytes = UInt32(frames * 2 * MemoryLayout<Float>.size)
  inBuf.withUnsafeMutableBufferPointer { i in
    outBuf.withUnsafeMutableBufferPointer { o in
      var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: i.baseAddress))
      var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: o.baseAddress))
      player.render(&inList, &outList, frames: frames)
    }
  }
  return outBuf
}
