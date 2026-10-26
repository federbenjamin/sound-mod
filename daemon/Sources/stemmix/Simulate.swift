import CoreAudio
import Foundation

/// A scripted offline run: what an IO cycle would do, without Core Audio.
struct SimulationScript: Decodable {
  struct Event: Decodable {
    let at: Double
    let stems: Int?
    let muffleHz: Double?
    let command: String?
  }

  let rate: Int
  let speed: Double
  let seconds: Double
  let events: [Event]
  /// Song starts in the recording, in seconds. With them, a simulated music player plays the recording as those
  /// songs: it posts a track change at each start, and a forwarded "next" makes it jump to the next start
  /// `skipDelay` seconds later (default 0.1). Without them the recording is one stream and "next" is never sent.
  let songs: [Double]?
  let skipDelay: Double?
  /// With it, also writes `<stemsOut>.pos.i32` (the recording frame each output frame played, -1 when the cursor did
  /// not advance one block) and `<stemsOut>.stems.f32` (drums, bass, vocals as separated at that frame, each
  /// interleaved stereo, frame after frame): the quality check compares them with a whole-song separation.
  let stemsOut: String?
}

/// `--simulate <input.f32> <output.f32> <script.json>`: plays a recording (interleaved stereo float32 at the
/// script's rate) through the real timeline, separation worker, separator and render code, at `speed` times real
/// time, applying the script's stem counts and transport commands, and writes what the speakers would get.
/// Never touches Core Audio, so it needs no permission. The separator script comes from `STEMMIX_SEPARATOR`.
/// Prints each event with the output frame it happened at, so a check can line the output up with the input.
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

  let rate = Double(script.rate)
  let songStarts = (script.songs ?? []).map { Int($0 * rate) }
  let skipDelay = Int((script.skipDelay ?? 0.1) * rate)
  var frame = 0
  var readFrame = 0
  var skipAt: Int?
  var announced = -1
  let playback = Playback(rate: script.rate) { done in
    guard !songStarts.isEmpty else {
      print("frame=\(frame) skip-player not sent: the script has no songs")
      done(false)
      return
    }
    skipAt = frame + skipDelay
    done(true)
  }
  playback.start()
  let block = 512
  let totalFrames = Int(script.seconds * Double(script.rate))
  let inputFrames = input.count / Timeline.channels
  var output = [Float](repeating: 0, count: totalFrames * Timeline.channels)
  var inBlock = [Float](repeating: 0, count: block * Timeline.channels)
  var outBlock = [Float](repeating: 0, count: block * Timeline.channels)
  let separatedCount = Stem.separated.count
  var positions = [Int32](repeating: -1, count: script.stemsOut == nil ? 0 : totalFrames)
  var stemFrames = [Float](repeating: 0, count: script.stemsOut == nil ? 0 : totalFrames * separatedCount * Timeline.channels)
  var pending = script.events.sorted { $0.at < $1.at }[...]
  var nextStatus = 0.0
  let began = Date()

  while frame < totalFrames {
    let t = Double(frame) / Double(script.rate)
    while let event = pending.first, event.at <= t {
      pending = pending.dropFirst()
      if let stems = event.stems {
        playback.setAudible(stems)
        print(String(format: "%.2fs stems=%d", t, stems))
      }
      if let hz = event.muffleHz {
        playback.setMuffling(cutoffHz: hz > 0 ? hz : nil)
        print(String(format: "%.2fs muffleHz=%.0f", t, hz))
      }
      if let text = event.command, let command = TransportCommand(rawValue: text) {
        playback.handle(command, source: "simulate", now: t)
        print(String(format: "%.2fs frame=%d command=%@", t, frame, text))
      }
    }
    if let at = skipAt, frame >= at {
      skipAt = nil
      readFrame = songStarts.first { $0 > readFrame } ?? inputFrames
      print(String(format: "%.2fs frame=%d player skipped to input=%d", t, frame, readFrame))
    }
    if let index = songStarts.lastIndex(where: { $0 <= readFrame }), index != announced {
      announced = index
      let end = index + 1 < songStarts.count ? songStarts[index + 1] : inputFrames
      playback.handle(PlayerEvent(
        state: .playing, trackID: "song\(index)", title: "Song \(index)", artist: "simulate",
        durationSeconds: Double(end - songStarts[index]) / rate, positionSeconds: Double(readFrame - songStarts[index]) / rate), now: t)
      print(String(format: "%.2fs frame=%d player-event song%d input=%d", t, frame, index, readFrame))
    }
    playback.expireForwardedSkip(now: t)
    for i in 0..<block * Timeline.channels {
      let index = readFrame * Timeline.channels + i
      inBlock[i] = readFrame + i / Timeline.channels < inputFrames ? input[index] : 0
    }
    let cursorBefore = playback.timeline.cursor.load(ordering: .acquiring)
    inBlock.withUnsafeMutableBufferPointer { inPointer in
      outBlock.withUnsafeMutableBufferPointer { outPointer in
        let bytes = UInt32(block * Timeline.channels * MemoryLayout<Float>.size)
        var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: inPointer.baseAddress))
        var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: bytes, mData: outPointer.baseAddress))
        playback.player.render(&inList, &outList, frames: block)
      }
    }
    let count = min(block, totalFrames - frame) * Timeline.channels
    if script.stemsOut != nil, playback.timeline.cursor.load(ordering: .acquiring) - cursorBefore == block {
      for i in 0..<min(block, totalFrames - frame) {
        positions[frame + i] = Int32(cursorBefore + i)
        for stem in 0..<separatedCount {
          for channel in 0..<Timeline.channels {
            stemFrames[((frame + i) * separatedCount + stem) * Timeline.channels + channel] =
              playback.timeline.separated(stem, cursorBefore + i, channel)
          }
        }
      }
    }
    output.replaceSubrange(frame * Timeline.channels..<frame * Timeline.channels + count, with: outBlock[0..<count])
    frame += block
    readFrame += block
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
  if let prefix = script.stemsOut {
    do {
      try positions.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: prefix + ".pos.i32")) }
      try stemFrames.withUnsafeBytes { try Data($0).write(to: URL(fileURLWithPath: prefix + ".stems.f32")) }
    } catch {
      print("simulate: \(error)")
      return 73
    }
  }
  print("simulate: wrote \(totalFrames) frames")
  return 0
}
