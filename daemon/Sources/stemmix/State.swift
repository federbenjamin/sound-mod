import Foundation

// The contract with the session sources: `contract/README.md` names this shape; `contract/session.json` is the
// fixture both sides test against.
struct SessionFile: Decodable, Equatable {
  let working: Bool
  let updatedAt: Double
}

/// The settings, written by the menu's Settings submenu and read every tick.
struct ConfigFile: Codable, Equatable {
  let tracks: Int
  let player: String
  let mode: ListeningMode
  let mufflingMax: Double
  let mufflingMin: Double

  init(tracks: Int, player: String, mode: ListeningMode = Config.defaultMode, mufflingMax: Double = Config.defaultMufflingMax, mufflingMin: Double = Config.defaultMufflingMin) {
    self.tracks = tracks
    self.player = player
    self.mode = mode
    self.mufflingMax = mufflingMax
    self.mufflingMin = mufflingMin
  }

  private enum Key: String, CodingKey { case tracks, player, mode, muffling_max, muffling_min }

  /// A key the file lacks takes its default.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    tracks = try c.decodeIfPresent(Int.self, forKey: .tracks) ?? Config.defaultTracks
    player = try c.decodeIfPresent(String.self, forKey: .player) ?? Config.defaultPlayer
    mode = try c.decodeIfPresent(ListeningMode.self, forKey: .mode) ?? Config.defaultMode
    mufflingMax = try c.decodeIfPresent(Double.self, forKey: .muffling_max) ?? Config.defaultMufflingMax
    mufflingMin = try c.decodeIfPresent(Double.self, forKey: .muffling_min) ?? Config.defaultMufflingMin
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(tracks, forKey: .tracks)
    try c.encode(player, forKey: .player)
    try c.encode(mode, forKey: .mode)
    try c.encode(mufflingMax, forKey: .muffling_max)
    try c.encode(mufflingMin, forKey: .muffling_min)
  }

  func with(_ setting: Setting) -> ConfigFile {
    switch setting {
    case let .tracks(n): return ConfigFile(tracks: n, player: player, mode: mode, mufflingMax: mufflingMax, mufflingMin: mufflingMin)
    case let .player(key): return ConfigFile(tracks: tracks, player: key, mode: mode, mufflingMax: mufflingMax, mufflingMin: mufflingMin)
    case let .mode(m): return ConfigFile(tracks: tracks, player: player, mode: m, mufflingMax: mufflingMax, mufflingMin: mufflingMin)
    case let .mufflingMax(level): return ConfigFile(tracks: tracks, player: player, mode: mode, mufflingMax: level, mufflingMin: mufflingMin)
    case let .mufflingMin(level): return ConfigFile(tracks: tracks, player: player, mode: mode, mufflingMax: mufflingMax, mufflingMin: level)
    }
  }
}

/// One setting's new value, as the menu picks it.
enum Setting: Equatable {
  case tracks(Int)
  case player(String)
  case mode(ListeningMode)
  case mufflingMax(Double)
  case mufflingMin(Double)
}

struct Counts: Equatable {
  let live: Int
  let working: Int
}

/// Counts live sessions, and working ones with a hold: a session that stops working still counts until it has been
/// not-working for `holdSeconds`, so the short gaps between an agent's turns and tool calls do not flicker the count.
struct WorkingEase {
  private var lastWorkingMs: [String: Double] = [:]

  mutating func summarize(sessions: [String: SessionFile], nowMs: Double, staleMs: Double, holdSeconds: Double) -> Counts {
    let live = sessions.filter { nowMs - $0.value.updatedAt < staleMs }
    lastWorkingMs = lastWorkingMs.filter { live[$0.key] != nil }
    for (id, session) in live where session.working { lastWorkingMs[id] = nowMs }
    return Counts(live: live.count, working: lastWorkingMs.values.filter { nowMs - $0 < holdSeconds * 1000 }.count)
  }
}

/// Session files the plugin left behind (a session that crashed or was killed never writes its end).
func expiredSessions(_ sessions: [String: SessionFile], nowMs: Double, maxAgeMs: Double) -> [String] {
  sessions.filter { nowMs - $0.value.updatedAt > maxAgeMs }.map(\.key).sorted()
}

struct StateFiles {
  let decoder = JSONDecoder()

  func config() -> ConfigFile {
    guard let data = try? Data(contentsOf: Config.configFile),
      let parsed = try? decoder.decode(ConfigFile.self, from: data)
    else { return ConfigFile(tracks: Config.defaultTracks, player: Config.defaultPlayer) }
    return parsed
  }

  func saveConfig(_ config: ConfigFile) throws {
    try FileManager.default.createDirectory(at: Config.stateDir, withIntermediateDirectories: true)
    try JSONEncoder().encode(config).write(to: Config.configFile, options: .atomic)
  }

  func sessions() -> [String: SessionFile] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: Config.sessionsDir.path) else { return [:] }
    var found: [String: SessionFile] = [:]
    for name in names where name.hasSuffix(".json") {
      let url = Config.sessionsDir.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url), let parsed = try? decoder.decode(SessionFile.self, from: data) else { continue }
      found[String(name.dropLast(5))] = parsed
    }
    return found
  }
}
