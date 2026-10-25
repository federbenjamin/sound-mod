import Foundation

/// One attach's playback: the timeline, its IO side, the separation worker, the song marks, and the one entry
/// every transport command goes through, whatever its source. Lives on the main thread; the IO thread only
/// sees `player`.
final class Playback {
  let timeline: Timeline
  let player: Player
  private let worker: SeparationWorker
  private var follower = PlayerFollower()
  private(set) var marks: [TrackMark] = []
  /// The last play or pause this playback sent; the IO thread applies it a cycle later, or never when its
  /// proc is dead. The truth for toggle and Now Playing.
  private(set) var intendsPlaying = true

  init(rate: Int) {
    timeline = Timeline(rate: rate, recordingSeconds: Config.recordingSeconds, stemsSeconds: Config.stemsSeconds)
    let player = Player(timeline: timeline)
    self.player = player
    // The separator's cold start takes seconds; the cursor waited at the attach point meanwhile. Start at the
    // live edge instead of that far behind.
    worker = SeparationWorker(timeline: timeline) { [timeline] in
      let head = timeline.head.load(ordering: .acquiring)
      player.send(.seek(liveEdge(head: head, liveLag: player.shape.liveLag)))
      Log.line("separator first-ready: cursor to the live edge (recorded \(String(format: "%.2fs", Double(head) / Double(timeline.rate))))")
    }
  }

  func start() { worker.start() }
  func stop() { worker.stop() }

  private var playing: Bool { player.playing.load(ordering: .relaxed) }

  @discardableResult
  func handle(_ command: TransportCommand, source: String) -> TransportAction {
    let c = commandContext()
    let action = resolve(command, cursor: c.cursor, head: c.head, playing: c.playing, marks: c.marks, rate: c.rate, liveLag: c.liveLag)
    send(action)
    Log.line("transport source=\(source) command=\(command.rawValue) action=\(describe(action)) behind=\(seconds(c.head - c.cursor))")
    return action
  }

  @discardableResult
  func handle(_ event: PlayerEvent, now: TimeInterval) -> PlayerFollower.Reaction {
    let head = timeline.head.load(ordering: .acquiring)
    let cursor = timeline.cursor.load(ordering: .acquiring)
    let behindLive = !isAtLive(cursor: cursor, head: head, rate: timeline.rate, liveLag: player.shape.liveLag)
    let reaction = follower.handle(event, now: now, head: head, behindLive: behindLive)
    if let mark = reaction.mark { marks.append(mark) }
    marks = keptMarks(head: head)
    send(reaction.action)
    Log.line("player-event state=\(event.state.rawValue) track=\(event.trackID ?? "-") mark=\(reaction.mark.map { String($0.frame) } ?? "-") action=\(describe(reaction.action))")
    return reaction
  }

  func setAudible(_ count: Int) { player.audible.store(count, ordering: .relaxed) }

  /// The low-pass cutoff the player glides to; nil for no filter.
  func setMuffling(cutoffHz: Double?) { player.cutoffMilliHz.store(Int(((cutoffHz ?? 0) * 1000).rounded()), ordering: .relaxed) }

  /// The song under the cursor, if its start was seen.
  var currentSong: TrackMark? { song(at: timeline.cursor.load(ordering: .relaxed)) }

  /// What the menu shows of this playback. Plain loads only: `status()` drains the level line's meters.
  func snapshot() -> PlaybackSnapshot {
    let c = commandContext()
    return PlaybackSnapshot(
      playing: c.playing,
      playerPaused: follower.playerPaused,
      song: song(at: c.cursor),
      secondsBehindLive: secondsBehindLive(cursor: c.cursor, head: c.head, rate: c.rate, liveLag: c.liveLag),
      available: availableCommands(cursor: c.cursor, head: c.head, playing: c.playing, marks: c.marks, rate: c.rate, liveLag: c.liveLag))
  }

  /// What `resolve` reads, from one load each of the head and the cursor; the menu's `availableCommands` reads
  /// the same, so a greyed item never disagrees with its command.
  private struct CommandContext {
    let head: Int
    let cursor: Int
    let playing: Bool
    let marks: [TrackMark]
    let rate: Int
    let liveLag: Int
  }

  private func commandContext() -> CommandContext {
    let head = timeline.head.load(ordering: .acquiring)
    let cursor = timeline.cursor.load(ordering: .acquiring)
    return CommandContext(head: head, cursor: cursor, playing: intendsPlaying, marks: keptMarks(head: head), rate: timeline.rate, liveLag: player.shape.liveLag)
  }

  private func song(at cursor: Int) -> TrackMark? { marks.last { $0.frame <= cursor } }

  /// One log line: levels, how far behind the head the cursor plays, how much is separated ahead, waits, and
  /// the separator's speed. `inputSamples` is the tap's sample count since the last call.
  func status() -> (line: String, inputSamples: Int) {
    let levels = player.takeLevels()
    let stats = worker.takeStats()
    let head = timeline.head.load(ordering: .acquiring)
    let cursor = timeline.cursor.load(ordering: .acquiring)
    let generation = timeline.generation.load(ordering: .acquiring)
    let ahead = timeline.frontier(for: generation).map { seconds($0 - cursor) } ?? "none"
    let waiting = player.waitingFrames.exchange(0, ordering: .relaxed)
    func db(_ value: Double?) -> String { value.map { String(format: "%.1fdBFS", $0) } ?? "none" }
    let line = "level in=\(db(levels.input)) out=\(db(levels.output)) samples=\(levels.inputSamples) state=\(playing ? "playing" : "paused") behind=\(seconds(head - cursor)) separated-ahead=\(ahead) waited=\(seconds(waiting)) separator-ms=\(stats.medianMs.map { String(format: "%.0f", $0) } ?? "none") slices=\(stats.count) failures=\(stats.failures)"
    return (line, levels.inputSamples)
  }

  /// Song marks still inside the recording, plus the one the oldest kept audio belongs to.
  private func keptMarks(head: Int) -> [TrackMark] {
    let oldest = timeline.oldestRecorded(head: head)
    guard let firstKept = marks.firstIndex(where: { $0.frame >= oldest }) else { return marks.suffix(1) }
    return Array(marks[max(firstKept - 1, 0)...])
  }

  private func send(_ action: TransportAction) {
    switch action {
    case .play: intendsPlaying = true
    case .pause: intendsPlaying = false
    case .none, .seek: break
    }
    player.send(action)
  }

  private func seconds(_ frames: Int) -> String { String(format: "%.2fs", Double(frames) / Double(timeline.rate)) }

  private func describe(_ action: TransportAction) -> String {
    switch action {
    case .none: return "none"
    case .play: return "play"
    case .pause: return "pause"
    case let .seek(frame): return "seek:\(seconds(frame))"
    }
  }
}
