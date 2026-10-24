/// The stems in the order working sessions unmute them. The model separates drums, bass and vocals;
/// "other" is the recording minus those three, so every stem on is the recording exactly.
enum Stem: Int, CaseIterable {
  case drums, bass, other, vocals

  /// The stems the separator returns, in the order the timeline stores them.
  static let separated: [Stem] = [.drums, .bass, .vocals]

  var name: String { String(describing: self) }
}

/// How many stems k working sessions of n hear: n sessions hear them all, and any working session hears one.
func audibleStems(working k: Int, tracks n: Int) -> Int {
  guard k > 0, n > 0 else { return 0 }
  let all = Stem.allCases.count
  return min(all, (k * all + n - 1) / n)
}
