import Foundation

/// One attach's playback: the timeline, its IO side, the separation worker, the song marks, the one entry
/// every transport command goes through, whatever its source, and the buffer rule that plays and pauses the
/// music player to keep the recording ahead of the cursor filled. Lives on the main thread; the IO thread only
/// sees `player`.
final class Playback {
  let timeline: Timeline
  let player: Player
  private let worker: SeparationWorker
  private var follower: PlayerFollower
  private(set) var marks: [TrackMark] = []
  /// The last play or pause this playback sent; the IO thread applies it a cycle later, or never when its
  /// proc is dead. The truth for toggle and Now Playing.
  private(set) var intendsPlaying: Bool
  /// A pause made in the music player itself: the player stays paused, with no refill, until a play from any
  /// source. A pause from the keys, the menu or `--control` still fills the buffer.
  private(set) var playerHeld: Bool
  /// The player state the buffer rule last asked for; cleared when the player moves by itself. Without it a player
  /// that never takes the event (a denied permission, nothing queued) would be asked again every tick.
  private var askedPlayerPlaying: Bool?
  private let bufferAheadFrames: Int
  /// Sends a command to the music player, then reports on the main thread whether it took it.
  private let control: (PlayerCommand, @escaping (Bool) -> Void) -> Void

  /// When the player's state and the belief have disagreed, with no own command waiting for its answer.
  private var mismatchSince: TimeInterval?

  /// `playerPlaying`: whether the music player plays at the attach. `resume`: the last attach's play state and
  /// hold, for a re-attach inside one daemon run (`attachIntent`).
  init(
    rate: Int, playerPlaying: Bool, resume: (playing: Bool, held: Bool)? = nil, bufferAheadSeconds: Double,
    control: @escaping (PlayerCommand, @escaping (Bool) -> Void) -> Void
  ) {
    self.control = control
    let intent = attachIntent(playerPlaying: playerPlaying, resume: resume)
    intendsPlaying = intent.playing
    playerHeld = intent.held
    follower = PlayerFollower(playerPlaying: playerPlaying)
    timeline = Timeline(rate: rate, recordingSeconds: Config.recordingSeconds, stemsSeconds: Config.stemsSeconds)
    bufferAheadFrames = Int(bufferAheadSeconds * Double(rate))
    let player = Player(timeline: timeline)
    if !intent.playing { player.send(.pause) }
    self.player = player
    // The separator's cold start takes seconds; the cursor waited at the attach point meanwhile. Start at the
    // live edge instead of that far behind.
    worker = SeparationWorker(timeline: timeline, isPlaying: { player.playing.load(ordering: .relaxed) }) { [timeline] in
      let head = timeline.head.load(ordering: .acquiring)
      player.send(.seek(liveEdge(head: head, liveLag: player.shape.liveLag)))
      Log.line("separator first-ready: cursor to the live edge (recorded \(String(format: "%.2fs", Double(head) / Double(timeline.rate))))")
    }
  }

  func start() { worker.start() }
  func stop() { worker.stop() }

  private var playing: Bool { player.playing.load(ordering: .relaxed) }

  @discardableResult
  func handle(_ command: TransportCommand, source: String, now: TimeInterval) -> TransportAction {
    let c = commandContext()
    let action = resolve(command, cursor: c.cursor, head: c.head, playing: c.playing, marks: c.marks, rate: c.rate, liveLag: c.liveLag)
    if action == .skipPlayer, follower.isExpecting(.trackChange, at: now) {
      Log.line("transport source=\(source) command=\(command.rawValue) action=none: a forwarded next is still waiting")
      return .none
    }
    if action == .skipPlayer {
      // Silence from now: the cursor waits at the head, then jumps to the new song's start when it is marked.
      player.send(.seek(c.head))
      follower.expect(.trackChange, until: now + Config.playerEchoWindow)
      control(.next) { [weak self] sent in
        guard let self, !sent, follower.isExpecting(.trackChange, at: now) else { return }
        // The player was never asked: put the cursor back where it was.
        follower.withdraw(.trackChange, at: now)
        player.send(.seek(c.cursor))
      }
    } else {
      send(action)
    }
    Log.line("transport source=\(source) command=\(command.rawValue) action=\(describe(action)) buffered=\(seconds(bufferedFrames(cursor: c.cursor, head: c.head)))")
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
    switch reaction.action {
    case .play, .pause:
      // The player moved by itself: the buffer rule's last ask no longer describes it.
      askedPlayerPlaying = nil
      if reaction.action == .pause { playerHeld = true }
    case .none, .seek, .skipPlayer: break
    }
    if reaction.ended {
      askedPlayerPlaying = nil
      playerHeld = true
    }
    send(reaction.action)
    if let frame = reaction.seek { player.send(.seek(frame)) }
    Log.line("player-event state=\(event.state.rawValue) track=\(event.trackID ?? "-") mark=\(reaction.mark.map { String($0.frame) } ?? "-") action=\(describe(reaction.action)) seek=\(reaction.seek.map(seconds) ?? "-")")
    return reaction
  }

  /// Once per control-loop tick: drops the echoes the player never sent, checks the belief about the player
  /// against `playerOutputting` (Core Audio's word on whether it plays), then applies the buffer rule, asking the
  /// player to play or pause when its known state is not the one the rule wants.
  func tick(now: TimeInterval, playerOutputting: Bool) {
    for echo in follower.expire(at: now) {
      switch echo {
      case .trackChange: Log.line("player-control command=next result=timeout: no track change within \(Int(Config.playerEchoWindow))s")
      case .playing, .paused: Log.line("player-control command=\(echo == .playing ? "play" : "pause") result=timeout: no player state within \(Int(Config.playerEchoWindow))s")
      }
    }
    if playerOutputting == follower.playerPaused, !follower.awaitsState(at: now) {
      let since = mismatchSince ?? now
      mismatchSince = since
      if now - since >= Config.playerEchoWindow {
        follower.correct(playerPlaying: playerOutputting, at: now)
        askedPlayerPlaying = nil
        mismatchSince = nil
        Log.line("player-state corrected=\(playerOutputting ? "playing" : "paused"): no notification said so")
      }
    } else {
      mismatchSince = nil
    }
    let c = commandContext()
    let buffered = bufferedFrames(cursor: c.cursor, head: c.head)
    let wanted = playerShouldPlay(playing: intendsPlaying, held: playerHeld, buffered: buffered, target: bufferAheadFrames)
    guard wanted != !follower.playerPaused else {
      askedPlayerPlaying = nil
      return
    }
    guard askedPlayerPlaying != wanted else { return }
    askedPlayerPlaying = wanted
    let echo: PlayerEcho = wanted ? .playing : .paused
    follower.expect(echo, until: now + Config.playerEchoWindow)
    Log.line("buffer-rule player=\(wanted ? "play" : "pause") buffered=\(seconds(buffered)) playing=\(intendsPlaying) held=\(playerHeld)")
    control(wanted ? .play : .pause) { [weak self] sent in
      guard let self, !sent else { return }
      follower.withdraw(echo, at: now)
    }
  }

  /// Whether the player plays, muted, behind a paused stemmix: releasing the tap now would make it heard past
  /// where the user paused, so the daemon pauses it first.
  var playerFillsUnheard: Bool { !intendsPlaying && !follower.playerPaused }

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
      song: song(at: c.cursor),
      bufferedSeconds: bufferedFrames(cursor: c.cursor, head: c.head) / c.rate,
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

  /// One log line: levels, how much is buffered ahead of the cursor, how much is separated ahead, waits, and
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
    let line = "level in=\(db(levels.input)) out=\(db(levels.output)) samples=\(levels.inputSamples) state=\(playing ? "playing" : "paused") buffered=\(seconds(bufferedFrames(cursor: cursor, head: head))) separated-ahead=\(ahead) waited=\(seconds(waiting)) separator-ms=\(stats.medianMs.map { String(format: "%.0f", $0) } ?? "none") slices=\(stats.count) failures=\(stats.failures)"
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
    case .play:
      intendsPlaying = true
      playerHeld = false
    case .pause: intendsPlaying = false
    case .none, .seek, .skipPlayer: break
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
    case .skipPlayer: return "skip-player"
    }
  }
}
