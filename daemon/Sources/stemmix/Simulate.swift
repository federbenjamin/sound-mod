import CoreAudio
import Foundation

/// A scripted offline run: what an IO cycle would do, without Core Audio.
struct SimulationScript: Decodable {
  struct Event: Decodable {
    let at: Double
    let stems: Int?
    let command: String?
  }

  let rate: Int
  let speed: Double
  let seconds: Double
  let events: [Event]
}

/// `--simulate <input.f32> <output.f32> <script.json>`: plays a recording (interleaved stereo float32 at the
/// script's rate) through the real timeline, separation worker, separator and render code, at `speed` times real
/// time, applying the script's stem counts and transport commands, and writes what the speakers would get.
/// Never touches Core Audio, so it needs no permission. The separator script comes from `STEMMIX_SEPARATOR`.
func runSimulate(_ arguments: [String]) -> Int32 {
  guard arguments.count == 3 else {
    print("usage: --simulate <input.f32> <output.f32> <script.json>")
    return 64
  }
  signal(SIGPIPE, SIG_IGN)
  let script: SimulationScript
  let input: [Float]
  do {
    script = try JSONDecoder().decode(SimulationScript.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
    input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  } catch {
    print("simulate: \(error)")
    return 66
  }

  let playback = Playback(rate: script.rate)
  playback.start()
  let block = 512
  let totalFrames = Int(script.seconds * Double(script.rate))
  let inputFrames = input.count / Timeline.channels
  var output = [Float](repeating: 0, count: totalFrames * Timeline.channels)
  var inBlock = [Float](repeating: 0, count: block * Timeline.channels)
  var outBlock = [Float](repeating: 0, count: block * Timeline.channels)
  var pending = script.events.sorted { $0.at < $1.at }[...]
  var nextStatus = 0.0
  let began = Date()

  var frame = 0
  while frame < totalFrames {
    let t = Double(frame) / Double(script.rate)
    while let event = pending.first, event.at <= t {
      pending = pending.dropFirst()
      if let stems = event.stems {
        playback.setAudible(stems)
        print(String(format: "%.2fs stems=%d", t, stems))
      }
      if let text = event.command, let command = TransportCommand(rawValue: text) {
        playback.handle(command, source: "simulate")
        print(String(format: "%.2fs command=%@", t, text))
      }
    }
    for i in 0..<block * Timeline.channels {
      let index = frame * Timeline.channels + i
      inBlock[i] = frame + i / Timeline.channels < inputFrames ? input[index] : 0
    }
    inBlock.withUnsafeMutableBufferPointer { inPointer in
      outBlock.withUnsafeMutableBufferPointer { outPointer in
        let bytes = UInt32(block * Timeline.channels * MemoryLayout<Float>.size)
        var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: inPointer.baseAddress))
        var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: outPointer.baseAddress))
        playback.player.render(&inList, &outList, frames: block)
      }
    }
    let count = min(block, totalFrames - frame) * Timeline.channels
    output.replaceSubrange(frame * Timeline.channels..<frame * Timeline.channels + count, with: outBlock[0..<count])
    frame += block
    if t >= nextStatus {
      print(String(format: "%.2fs ", t) + playback.status().line)
      nextStatus += 5
    }
    let due = began.addingTimeInterval(Double(frame) / Double(script.rate) / script.speed)
    let wait = due.timeIntervalSinceNow
    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
  }
  playback.stop()
  do {
    try output.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: arguments[1])) }
  } catch {
    print("simulate: \(error)")
    return 73
  }
  print("simulate: wrote \(totalFrames) frames")
  return 0
}
