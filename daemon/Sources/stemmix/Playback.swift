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
  /// Asks the music player to skip to its next track, then reports on the main thread whether it was sent.
  private let skipPlayer: (@escaping (Bool) -> Void) -> Void
  /// Set while a forwarded "next" waits for the player's track change.
  private var awaitingSkipUntil: TimeInterval?

  init(rate: Int, skipPlayer: @escaping (@escaping (Bool) -> Void) -> Void) {
    self.skipPlayer = skipPlayer
    timeline = Timeline(rate: rate, recordingSeconds: Config.recordingSeconds, stemsSeconds: Config.stemsSeconds)
    let player = Player(timeline: timeline)
    self.player = player
    // The separator's cold start takes seconds; the cursor waited at the attach point meanwhile. Start at the
    // live edge instead of that far behind.
    worker = SeparationWorker(timeline: timeline) { [timeline] in
      let head = timeline.head.load(ordering: .acquiring)
      player.send(.seek(max(0, head - player.shape.liveLag)))
      Log.line("separator first-ready: cursor to the live edge (recorded \(String(format: "%.2fs", Double(head) / Double(timeline.rate))))")
    }
  }

  func start() { worker.start() }
  func stop() { worker.stop() }

  var playing: Bool { player.playing.load(ordering: .relaxed) }

  @discardableResult
  func handle(_ command: TransportCommand, source: String, now: TimeInterval) -> TransportAction {
    let head = timeline.head.load(ordering: .acquiring)
    let cursor = timeline.cursor.load(ordering: .acquiring)
    let action = resolve(command, cursor: cursor, head: head, playing: playing, marks: keptMarks(head: head), rate: timeline.rate, liveLag: player.shape.liveLag)
    if action == .skipPlayer, awaitingSkipUntil != nil {
      Log.line("transport source=\(source) command=\(command.rawValue) action=none: a forwarded next is still waiting")
      return .none
    }
    if action == .skipPlayer {
      // Silence from now: the cursor waits at the head, then jumps to the new song's start when it is marked.
      player.send(.seek(head))
      awaitingSkipUntil = now + Config.forwardedSkipTimeout
      skipPlayer { [weak self] sent in
        guard let self, !sent, awaitingSkipUntil != nil else { return }
        // The player was never asked: put the cursor back where it was.
        awaitingSkipUntil = nil
        player.send(.seek(cursor))
      }
    } else {
      player.send(action)
    }
    Log.line("transport source=\(source) command=\(command.rawValue) action=\(describe(action)) behind=\(seconds(head - cursor))")
    return action
  }

  func handle(_ event: PlayerEvent, now: TimeInterval) {
    let head = timeline.head.load(ordering: .acquiring)
    let cursor = timeline.cursor.load(ordering: .acquiring)
    let behindLive = head - cursor > player.shape.liveLag + timeline.rate
    let awaitingSkip = awaitingSkipUntil.map { now < $0 } ?? false
    let reaction = follower.handle(event, now: now, head: head, behindLive: behindLive, awaitingSkip: awaitingSkip)
    if let mark = reaction.mark {
      marks.append(mark)
      awaitingSkipUntil = nil
    }
    marks = keptMarks(head: head)
    player.send(reaction.action)
    if let frame = reaction.seek { player.send(.seek(frame)) }
    Log.line("player-event state=\(event.state.rawValue) track=\(event.trackID ?? "-") mark=\(reaction.mark.map { String($0.frame) } ?? "-") action=\(describe(reaction.action)) seek=\(reaction.seek.map(seconds) ?? "-")")
  }

  /// Stops waiting for a forwarded "next" the player never answered with a track change.
  func expireForwardedSkip(now: TimeInterval) {
    guard let until = awaitingSkipUntil, now >= until else { return }
    awaitingSkipUntil = nil
    Log.line("transport forward=next result=timeout: no track change within \(Int(Config.forwardedSkipTimeout))s")
  }

  func setAudible(_ count: Int) { player.audible.store(count, ordering: .relaxed) }

  /// The low-pass cutoff the player glides to; nil for no filter.
  func setMuffling(cutoffHz: Double?) { player.cutoffMilliHz.store(Int(((cutoffHz ?? 0) * 1000).rounded()), ordering: .relaxed) }

  /// The song under the cursor, if its start was seen.
  var currentSong: TrackMark? {
    let cursor = timeline.cursor.load(ordering: .relaxed)
    return marks.last { $0.frame <= cursor }
  }

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

  private func seconds(_ frames: Int) -> String { String(format: "%.2fs", Double(frames) / Double(timeline.rate)) }

  private func describe(_ action: TransportAction) -> String {
    switch action {
    case .none: return "none"
    case .play: return "play"
    case .pause: return "pause"
    case let .seek(frame): return "seek:\(seconds(frame))"
    case .skipPlayer: return "skip-player"
    }
  }
}
