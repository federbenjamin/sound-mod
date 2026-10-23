import Foundation

/// Low-pass cutoff for k working sessions of n tracks, log-spaced from the floor to the ceiling;
/// nil at k >= n means bypass (the full mix). k <= 0 is silence, handled by gain, so it gets the floor.
func cutoffHz(working k: Int, tracks n: Int) -> Double? {
  guard n > 0, k < n else { return nil }
  let ratio = Config.cutoffCeilingHz / Config.cutoffFloorHz
  return Config.cutoffFloorHz * pow(ratio, Double(max(k, 0)) / Double(n))
}
