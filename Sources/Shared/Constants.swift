import Foundation

enum MACDancerConstants {
  static let appIdentifier = "local.macdancer.MACDancer"
  static let daemonIdentifier = "local.macdancer.MACDancer.daemon"
  static let daemonPlistName = "local.macdancer.MACDancer.daemon.plist"
  static let legacyDaemonIdentifier = "io.github.halo.LinkLiar.linkdaemon"
  static let protocolVersion = 1
  static let maximumPayloadSize = 1_048_576
  static let errorKindUserInfoKey = "local.macdancer.MACDancer.errorKind"
}

enum MACDancerRemoteErrorKind: String, Sendable {
  case associatedWiFiWriteRejected
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
  case associatedWiFiWriteRejected

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
    case .associatedWiFiWriteRejected:
      "macOS or the Wi-Fi driver did not accept the MAC change while Wi-Fi is connected. MACDancer did not disconnect or reconnect Wi-Fi. Disconnect Wi-Fi, wait until the interface is no longer associated, then try again."
    }
  }

  /// Stable codes for errors transported over XPC. Swift's synthesized NSError
  /// domain and case numbers are module-dependent and are not a wire protocol.
  var xpcErrorCode: Int {
    switch self {
    case .invalidMACAddress: 1001
    case .randomSourceFailure: 1002
    case .exhaustedRandomAttempts: 1003
    case .interfaceNotFound: 1004
    case .unsafeAutomaticOperation: 1005
    case .disruptionConfirmationRequired: 1006
    case .commandFailed: 1007
    case .readbackMismatch: 1008
    case .daemonUnavailable: 1009
    case .invalidPayload: 1010
    case .incompatibleProtocol: 1011
    case .persistence: 1012
    case .associatedWiFiWriteRejected: 1013
    }
  }
}
