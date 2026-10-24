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
}

struct Counts: Equatable {
  let live: Int
  let working: Int
}

func summarize(sessions: [SessionFile], nowMs: Double, staleMs: Double) -> Counts {
  let live = sessions.filter { nowMs - $0.updatedAt < staleMs }
  return Counts(live: live.count, working: live.filter(\.working).count)
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
