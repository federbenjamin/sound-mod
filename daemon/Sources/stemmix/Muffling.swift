import Foundation

/// How the song thins out with fewer working sessions: `mode` in config.json.
/// `instruments` takes stems away; `muffled` keeps every stem and low-passes the mix; `both` does both.
enum ListeningMode: String, Decodable {
  case instruments, muffled, both

  var muffles: Bool { self != .instruments }
}

/// How many stems k of n working sessions hear in `mode`. Muffled mode hears them all (and muffles instead);
/// no working session is silence in every mode.
func audibleStems(mode: ListeningMode, working k: Int, tracks n: Int) -> Int {
  switch mode {
  case .muffled: return k > 0 ? Stem.allCases.count : 0
  case .instruments, .both: return audibleStems(working: k, tracks: n)
  }
}

/// The muffling level (0 none ... 10 most) for k of n working sessions: a straight line from `max` at no
/// session to `min` at n sessions, each clamped to 0...10.
func mufflingLevel(working k: Int, tracks n: Int, max: Double, min: Double) -> Double {
  let top = Swift.min(10, Swift.max(0, max))
  let bottom = Swift.min(10, Swift.max(0, min))
  guard n > 0 else { return bottom }
  let share = Swift.min(1, Double(Swift.max(k, 0)) / Double(n))
  return top + (bottom - top) * share
}

/// The low-pass cutoff for a muffling level, log-spaced from the ceiling (level 0: nil, no filter) down to the
/// floor (level 10). At max 10 and min 0 this is the first version's filter exactly.
func mufflingCutoffHz(level: Double) -> Double? {
  let clamped = Swift.min(10, Swift.max(0, level))
  guard clamped > 0 else { return nil }
  return Config.mufflingCeilingHz * pow(Config.mufflingFloorHz / Config.mufflingCeilingHz, clamped / 10)
}

/// The cutoff to apply for the config and the count, nil for none.
func mufflingCutoffHz(config: ConfigFile, working k: Int) -> Double? {
  guard config.mode.muffles else { return nil }
  return mufflingCutoffHz(level: mufflingLevel(working: k, tracks: config.tracks, max: config.mufflingMax, min: config.mufflingMin))
}
