import Foundation

// The pipe protocol with separator/stemmix_separator.py. A frame is a 4-byte little-endian header length, a JSON
// header, then `payloadBytes` of raw little-endian float32. Fixtures: contract/separator-*.json.

struct SeparatorRequest: Codable, Equatable {
  let id: Int
  let rate: Int
  let frames: Int
  let keepStart: Int
  let keepFrames: Int
  let stems: [String]
  let payloadBytes: Int
}

/// Every frame the separator sends: the ready frame at start, then one reply or error per request.
struct SeparatorReply: Codable, Equatable {
  var ready: Bool?
  var model: String?
  var id: Int?
  var stems: [String]?
  var frames: Int?
  var ms: Double?
  var error: String?
  let payloadBytes: Int
}

enum SeparatorProtocol {
  static func encodeHeader<T: Encodable>(_ header: T) throws -> Data {
    let json = try JSONEncoder().encode(header)
    var length = UInt32(json.count).littleEndian
    var data = Data(bytes: &length, count: 4)
    data.append(json)
    return data
  }

  static func headerLength(_ prefix: Data) -> Int {
    precondition(prefix.count == 4)
    return Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
  }

  static func decodeReply(_ json: Data) throws -> SeparatorReply {
    try JSONDecoder().decode(SeparatorReply.self, from: json)
  }
}
