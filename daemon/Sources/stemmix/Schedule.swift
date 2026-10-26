/// The sliding window in frames at the timeline's rate.
struct WindowShape: Equatable {
  let window: Int
  let hop: Int
  let fade: Int
  let minRight: Int
  let maxRight: Int
  let lookahead: Int
  let computeMargin: Int

  init(rate: Int) {
    let r = Double(rate)
    window = Int(Config.windowSeconds * r)
    hop = Int(Config.hopSeconds * r)
    fade = Int(Config.fadeSeconds * r)
    minRight = Int(Config.minRightSeconds * r)
    maxRight = Int(Config.maxRightSeconds * r)
    lookahead = Int(Config.lookaheadSeconds * r)
    computeMargin = Int(Config.computeMarginSeconds * r)
  }

  init(window: Int, hop: Int, fade: Int, minRight: Int, maxRight: Int, lookahead: Int, computeMargin: Int) {
    self.window = window
    self.hop = hop
    self.fade = fade
    self.minRight = minRight
    self.maxRight = maxRight
    self.lookahead = lookahead
    self.computeMargin = computeMargin
  }

  /// How far behind the head a cursor at the live edge plays. A slice is final once the head is `minRight` past
  /// its end and slices land a hop apart, so the frontier trails the head by up to hop + fade + minRight, plus
  /// the separator's compute time.
  var liveLag: Int { hop + fade + minRight + computeMargin }
}

/// One separation request: separate the window starting at `windowStart`, keep `keepFrames` from `keepStart`
/// within it, and write them to the timeline at `sliceStart`.
struct SeparationJob: Equatable {
  let sliceStart: Int
  let windowStart: Int
  let keepStart: Int
  let keepFrames: Int
}

/// The next slice to separate, or nil to wait: the frontier is far enough ahead of the cursor, the head has not
/// recorded enough audio past the slice, or playback is paused with the cursor `keptFrames` or more behind the
/// head. The right context grows with what is recorded, up to `maxRight`. While paused the lookahead is still
/// separated, so play after a pause starts at once; but a cursor that far behind is moved up by the recording's
/// overflow every cycle, and separating there would run the separator flat out on slices the cursor never plays.
func nextJob(head: Int, cursor: Int, frontier: Int, playing: Bool, keptFrames: Int, shape: WindowShape) -> SeparationJob? {
  guard playing || head - cursor < keptFrames, frontier < cursor + shape.lookahead else { return nil }
  let keep = shape.hop + shape.fade
  let sliceEnd = frontier + keep
  let available = head - sliceEnd
  guard available >= shape.minRight else { return nil }
  let windowEnd = sliceEnd + min(available, shape.maxRight)
  let windowStart = windowEnd - shape.window
  return SeparationJob(sliceStart: frontier, windowStart: windowStart, keepStart: frontier - windowStart, keepFrames: keep)
}
