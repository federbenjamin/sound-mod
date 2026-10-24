import XCTest

@testable import stemmix

final class SeparatorProtocolTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data { try Data(contentsOf: contractDir.appendingPathComponent(name)) }

  func testRequestFixtureDecodesAndItsPayloadIsFramesTimesStereoFloat32() throws {
    let r = try JSONDecoder().decode(SeparatorRequest.self, from: fixture("separator-request.json"))
    XCTAssertEqual(r.id, 7)
    XCTAssertEqual(r.stems, ["drums", "bass", "vocals"])
    XCTAssertEqual(r.payloadBytes, r.frames * 2 * 4)
  }

  func testRequestReEncodesWithALittleEndianLengthPrefix() throws {
    let r = try JSONDecoder().decode(SeparatorRequest.self, from: fixture("separator-request.json"))
    let data = try SeparatorProtocol.encodeHeader(r)
    let json = data.dropFirst(4)
    let prefix = Array(data.prefix(4))
    XCTAssertEqual(Int(prefix[0]) | Int(prefix[1]) << 8 | Int(prefix[2]) << 16 | Int(prefix[3]) << 24, json.count)
    XCTAssertEqual(SeparatorProtocol.headerLength(Data(prefix)), json.count)
    XCTAssertEqual(try JSONDecoder().decode(SeparatorRequest.self, from: Data(json)), r)
  }

  func testLengthPrefixIsLittleEndianForHeadersLongerThan255Bytes() throws {
    let r = SeparatorRequest(id: 1, rate: 48000, frames: 1, keepStart: 0, keepFrames: 1, stems: (0..<40).map { "stem\($0)" }, payloadBytes: 8)
    let data = try SeparatorProtocol.encodeHeader(r)
    let n = data.count - 4
    XCTAssertGreaterThan(n, 255)
    XCTAssertEqual([UInt8](data.prefix(4)), [UInt8(n & 0xff), UInt8(n >> 8), 0, 0])
  }

  func testReadyReplyFixtureDecodes() throws {
    let r = try SeparatorProtocol.decodeReply(fixture("separator-ready.json"))
    XCTAssertEqual(r.ready, true)
    XCTAssertEqual(r.model, "htdemucs")
    XCTAssertEqual(r.stems, ["drums", "bass", "other", "vocals"])
    XCTAssertEqual(r.payloadBytes, 0)
  }

  func testResponseReplyFixtureDecodesWithAThreeStemPayload() throws {
    let r = try SeparatorProtocol.decodeReply(fixture("separator-response.json"))
    XCTAssertEqual(r.id, 7)
    XCTAssertEqual(r.frames, 50400)
    XCTAssertEqual(r.ms, 143.2)
    XCTAssertNil(r.error)
    XCTAssertEqual(r.payloadBytes, (r.frames ?? 0) * 2 * 4 * (r.stems?.count ?? 0))
  }

  func testErrorReplyFixtureDecodes() throws {
    let r = try SeparatorProtocol.decodeReply(fixture("separator-error.json"))
    XCTAssertEqual(r.id, 7)
    XCTAssertEqual(r.error, "ValueError: slice 0+10 outside window of 5")
    XCTAssertEqual(r.payloadBytes, 0)
    XCTAssertNil(r.ready)
  }
}
