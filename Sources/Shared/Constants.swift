import Foundation

enum MACDancerConstants {
  static let appIdentifier = "local.macdancer.MACDancer"
  static let daemonIdentifier = "local.macdancer.MACDancer.daemon"
  static let daemonPlistName = "local.macdancer.MACDancer.daemon.plist"
  static let legacyDaemonIdentifier = "io.github.halo.LinkLiar.linkdaemon"
  static let protocolVersion = 1
  static let maximumPayloadSize = 1_048_576
}

enum MACDancerError: Error, Codable, Equatable, LocalizedError, Sendable {
  case invalidMACAddress(String)
  case randomSourceFailure(Int32)
  case exhaustedRandomAttempts
  case interfaceNotFound(String)
  case unsafeAutomaticOperation(String)
  case disruptionConfirmationRequired
  case commandFailed(String)
  case readbackMismatch(expected: String, actual: String?)
  case daemonUnavailable(String)
  case invalidPayload(String)
  case incompatibleProtocol(expected: Int, actual: Int)
  case persistence(String)

  var errorDescription: String? {
    switch self {
    case let .invalidMACAddress(value): "Invalid MAC address: \(value)"
    case let .randomSourceFailure(code): "The secure random source failed (\(code))."
    case .exhaustedRandomAttempts: "Unable to generate a non-conflicting MAC address."
    case let .interfaceNotFound(name): "Network interface \(name) was not found."
    case let .unsafeAutomaticOperation(reason): reason
    case .disruptionConfirmationRequired: "This operation can interrupt connectivity and requires confirmation."
    case let .commandFailed(message): message
    case let .readbackMismatch(expected, actual): "MAC readback did not match \(expected); observed \(actual ?? "unavailable")."
    case let .daemonUnavailable(message): message
    case let .invalidPayload(message): message
    case let .incompatibleProtocol(expected, actual): "Protocol mismatch: GUI \(expected), daemon \(actual)."
    case let .persistence(message): message
    }
  }
}
