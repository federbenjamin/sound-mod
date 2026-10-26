import Foundation

// The contract with the plugin: `contract/README.md` names these two shapes;
// `contract/session.json` and `contract/config.json` are the fixtures both sides test against.
struct SessionFile: Decodable, Equatable {
  let working: Bool
  let updatedAt: Double
}

struct ConfigFile: Decodable, Equatable {
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

  /// A key a source does not write yet takes its default, so an older plugin still drives a newer daemon.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    tracks = try c.decodeIfPresent(Int.self, forKey: .tracks) ?? Config.defaultTracks
    player = try c.decodeIfPresent(String.self, forKey: .player) ?? Config.defaultPlayer
    mode = try c.decodeIfPresent(ListeningMode.self, forKey: .mode) ?? Config.defaultMode
    mufflingMax = try c.decodeIfPresent(Double.self, forKey: .muffling_max) ?? Config.defaultMufflingMax
    mufflingMin = try c.decodeIfPresent(Double.self, forKey: .muffling_min) ?? Config.defaultMufflingMin
  }
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

struct StateReader {
  let decoder = JSONDecoder()

  func config() -> ConfigFile {
    guard let data = try? Data(contentsOf: Config.configFile),
      let parsed = try? decoder.decode(ConfigFile.self, from: data)
    else { return ConfigFile(tracks: Config.defaultTracks, player: Config.defaultPlayer) }
    return parsed
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
