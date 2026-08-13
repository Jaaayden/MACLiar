import Foundation
import Security

struct MACAddress: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
  let bytes: [UInt8]

  init?(_ value: String) {
    let normalized = value.lowercased()
    let compact: String
    if normalized.count == 12, normalized.allSatisfy(\.isHexDigit) {
      compact = normalized
    } else {
      let separator: Character
      if normalized.contains(":") { separator = ":" }
      else if normalized.contains("-") { separator = "-" }
      else { return nil }
      let groups = normalized.split(separator: separator, omittingEmptySubsequences: false)
      guard groups.count == 6, groups.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
      compact = groups.joined()
    }
    var parsed: [UInt8] = []
    parsed.reserveCapacity(6)
    var index = compact.startIndex
    for _ in 0..<6 {
      let next = compact.index(index, offsetBy: 2)
      guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
      parsed.append(byte)
      index = next
    }
    self.bytes = parsed
  }

  init?(bytes: [UInt8]) {
    guard bytes.count == 6 else { return nil }
    self.bytes = bytes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let parsed = MACAddress(value) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a strict 48-bit MAC address.")
    }
    self = parsed
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(stringValue)
  }

  var stringValue: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
  var description: String { stringValue }
  var isUnicast: Bool { bytes.first.map { $0 & 0x01 == 0 } ?? false }
  var isLocallyAdministered: Bool { bytes.first.map { $0 & 0x02 != 0 } ?? false }
  var isBroadcast: Bool { bytes.allSatisfy { $0 == 0xff } }
  var isAllZero: Bool { bytes.allSatisfy { $0 == 0x00 } }
  var isValidAssignable: Bool { isUnicast && !isBroadcast && !isAllZero }

  static func < (lhs: MACAddress, rhs: MACAddress) -> Bool {
    lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
  }

  static func randomLocallyAdministered(
    excluding excluded: Set<MACAddress> = [],
    attempts: Int = 128,
    fill: (UnsafeMutableRawBufferPointer) -> Int32 = { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
  ) throws -> MACAddress {
    for _ in 0..<attempts {
      var candidateBytes = [UInt8](repeating: 0, count: 6)
      let status = candidateBytes.withUnsafeMutableBytes(fill)
      guard status == errSecSuccess else { throw MACDancerError.randomSourceFailure(status) }
      candidateBytes[0] = (candidateBytes[0] & 0xfc) | 0x02
      guard let candidate = MACAddress(bytes: candidateBytes),
            candidate.isValidAssignable,
            !excluded.contains(candidate) else { continue }
      return candidate
    }
    throw MACDancerError.exhaustedRandomAttempts
  }

  static func randomVendorCompatible(
    oui: [UInt8],
    excluding excluded: Set<MACAddress> = [],
    attempts: Int = 128,
    fill: (UnsafeMutableRawBufferPointer) -> Int32 = { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
  ) throws -> MACAddress {
    guard oui.count == 3, oui[0] & 0x03 == 0 else {
      throw MACDancerError.invalidMACAddress(oui.map { String(format: "%02x", $0) }.joined(separator: ":"))
    }
    for _ in 0..<attempts {
      var suffix = [UInt8](repeating: 0, count: 3)
      let status = suffix.withUnsafeMutableBytes(fill)
      guard status == errSecSuccess else { throw MACDancerError.randomSourceFailure(status) }
      guard let candidate = MACAddress(bytes: oui + suffix),
            candidate.isValidAssignable,
            !excluded.contains(candidate) else { continue }
      return candidate
    }
    throw MACDancerError.exhaustedRandomAttempts
  }
}
