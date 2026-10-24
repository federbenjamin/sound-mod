import XCTest

@testable import stemmix

final class FilterTests: XCTestCase {
  private let rate = 48_000.0

  /// RMS of the second half of the output over the input's, in dB; the first half lets the filter settle.
  private func gainDb(tone hz: Double) -> Double {
    var filter = LowPass(channels: 1)
    filter.set(hz: 1000, rate: rate)
    let n = Int(rate)
    var inSum = 0.0, outSum = 0.0
    for i in 0..<n {
      let x = Float(sin(2 * Double.pi * hz * Double(i) / rate))
      let y = filter.process(channel: 0, x)
      if i >= n / 2 {
        inSum += Double(x) * Double(x)
        outSum += Double(y) * Double(y)
      }
    }
    return 10 * log10(outSum / inSum)
  }

  func testToneBelowTheCutoffPassesWithinOneDb() {
    XCTAssertEqual(gainDb(tone: 100), 0, accuracy: 1)
  }

  func testToneFarAboveTheCutoffIsAttenuatedByMoreThanSixtyDb() {
    XCTAssertLessThan(gainDb(tone: 10_000), -60)
  }

  func testResetClearsFilterState() {
    var filter = LowPass(channels: 2)
    filter.set(hz: 1000, rate: rate)
    for i in 0..<500 { for c in 0..<2 { _ = filter.process(channel: c, i.isMultiple(of: 2) ? 1 : -1) } }
    filter.reset()
    for _ in 0..<50 { for c in 0..<2 { XCTAssertEqual(filter.process(channel: c, 0), 0) } }
  }

  func testChannelsFilterIndependently() {
    var filter = LowPass(channels: 2)
    filter.set(hz: 1000, rate: rate)
    for _ in 0..<200 { _ = filter.process(channel: 0, 1) }
    XCTAssertEqual(filter.process(channel: 1, 0), 0, "channel 0's signal leaked into channel 1")
  }
}
