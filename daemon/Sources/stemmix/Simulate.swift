import CoreAudio
import Foundation

/// A scripted offline run: what an IO cycle would do, without Core Audio.
struct SimulationScript: Decodable {
  struct Event: Decodable {
    let at: Double
    let stems: Int?
    let muffleHz: Double?
    let command: String?
    /// The user acting in the music player itself: "play", "pause" or "next" (with `songs`).
    let player: String?
  }

  let rate: Int
  let speed: Double
  let seconds: Double
  let events: [Event]
  /// A simulated music player plays the recording: it reads on only while playing, feeds the tap silence while
  /// paused, and posts a state event at each play state change. Stemmix's play, pause and next reach it
  /// `skipDelay` seconds later (default 0.1). With `songs` (song starts, in seconds) it posts a track change at
  /// each start and a next makes it jump to the next start; without them the recording is one stream and next is
  /// never sent.
  let songs: [Double]?
  let skipDelay: Double?
  /// Whether the music player plays at the start (default true).
  let playerPlaying: Bool?
  /// The buffer rule's target in seconds (default `Config.bufferAheadSeconds`), so a short run can reach it.
  let bufferSeconds: Double?
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
  let inputFrames = input.count / Timeline.channels
  var frame = 0
  var readFrame = 0
  var playerPlaying = script.playerPlaying ?? true
  var skipAt: Int?
  var stateAt: (playing: Bool, frame: Int)?
  var announcedSong = -1
  var announcedPlaying: Bool?
  func time() -> Double { Double(frame) / rate }
  let playback = Playback(rate: script.rate, playerPlaying: playerPlaying, bufferAheadSeconds: script.bufferSeconds ?? Config.bufferAheadSeconds) { command, done in
    print(String(format: "%.2fs frame=%d player-control command=%@", time(), frame, command.rawValue))
    switch command {
    case .next:
      guard !songStarts.isEmpty else {
        print("frame=\(frame) skip-player not sent: the script has no songs")
        done(false)
        return
      }
      skipAt = frame + skipDelay
    case .play, .pause:
      stateAt = (command == .play, frame + skipDelay)
    }
    done(true)
  }
  func nextSong() {
    readFrame = songStarts.first { $0 > readFrame } ?? inputFrames
    print(String(format: "%.2fs frame=%d player skipped to input=%d", time(), frame, readFrame))
  }
  func setPlayerPlaying(_ playing: Bool) {
    guard playing != playerPlaying else { return }
    playerPlaying = playing
    print(String(format: "%.2fs frame=%d player %@ input=%d", time(), frame, playing ? "playing" : "paused", readFrame))
  }
  playback.start()
  let block = 512
  let totalFrames = Int(script.seconds * Double(script.rate))
  var output = [Float](repeating: 0, count: totalFrames * Timeline.channels)
  var inBlock = [Float](repeating: 0, count: block * Timeline.channels)
  var outBlock = [Float](repeating: 0, count: block * Timeline.channels)
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
      switch event.player {
      case "play": setPlayerPlaying(true)
      case "pause": setPlayerPlaying(false)
      case "next" where !songStarts.isEmpty: nextSong()
      default: break
      }
    }
    if let at = skipAt, frame >= at {
      skipAt = nil
      nextSong()
    }
    if let state = stateAt, frame >= state.frame {
      stateAt = nil
      setPlayerPlaying(state.playing)
    }
    let index = songStarts.lastIndex(where: { $0 <= readFrame })
    if (index ?? -1) != announcedSong || playerPlaying != announcedPlaying {
      announcedSong = index ?? -1
      announcedPlaying = playerPlaying
      let end = index.map { $0 + 1 < songStarts.count ? songStarts[$0 + 1] : inputFrames }
      let reaction = playback.handle(PlayerEvent(
        state: playerPlaying ? .playing : .paused, trackID: index.map { "song\($0)" }, title: index.map { "Song \($0)" } ?? "",
        artist: "simulate", durationSeconds: index.map { Double(end! - songStarts[$0]) / rate },
        positionSeconds: Double(readFrame - (index.map { songStarts[$0] } ?? 0)) / rate), now: t)
      print(String(
        format: "%.2fs frame=%d player-event song=%@ state=%@ input=%d action=%@ seek=%@", t, frame, index.map { String($0) } ?? "-",
        playerPlaying ? "playing" : "paused", readFrame, "\(reaction.action)", reaction.seek.map { String($0) } ?? "-"))
    }
    playback.tick(now: t)
    for i in 0..<block * Timeline.channels {
      let index = readFrame * Timeline.channels + i
      inBlock[i] = playerPlaying && readFrame + i / Timeline.channels < inputFrames ? input[index] : 0
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
    if playerPlaying { readFrame += block }
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
