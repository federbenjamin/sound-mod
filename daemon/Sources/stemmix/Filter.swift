import Foundation

/// One second-order section, transposed direct form II.
struct Biquad {
  var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
  var z1 = 0.0, z2 = 0.0

  static func lowPass(hz: Double, rate: Double, q: Double) -> Biquad {
    let w0 = 2 * Double.pi * min(hz, rate * 0.49) / rate
    let cosw = cos(w0)
    let alpha = sin(w0) / (2 * q)
    let a0 = 1 + alpha
    return Biquad(
      b0: (1 - cosw) / 2 / a0, b1: (1 - cosw) / a0, b2: (1 - cosw) / 2 / a0,
      a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
  }

  mutating func process(_ x: Double) -> Double {
    let y = b0 * x + z1
    z1 = b1 * x - a1 * y + z2
    z2 = b2 * x - a2 * y
    return y
  }

  mutating func adopt(_ other: Biquad) {
    b0 = other.b0; b1 = other.b1; b2 = other.b2; a1 = other.a1; a2 = other.a2
  }
}

/// Linkwitz-Riley 4th-order low-pass: two cascaded Butterworth sections per channel.
struct LowPass {
  private(set) var channels: Int
  private var stages: [[Biquad]]

  init(channels: Int) {
    self.channels = channels
    stages = Array(repeating: [Biquad(), Biquad()], count: channels)
  }

  mutating func set(hz: Double, rate: Double) {
    let section = Biquad.lowPass(hz: hz, rate: rate, q: 1 / 2.0.squareRoot())
    for c in 0..<channels { stages[c][0].adopt(section); stages[c][1].adopt(section) }
  }

  mutating func process(channel: Int, _ x: Float) -> Float {
    let y = stages[channel][1].process(stages[channel][0].process(Double(x)))
    return Float(y)
  }

  mutating func reset() {
    stages = Array(repeating: [Biquad(), Biquad()], count: channels)
  }
}
