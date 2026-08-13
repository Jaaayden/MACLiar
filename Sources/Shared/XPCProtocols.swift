import Foundation

// App and daemon compile Shared as different Swift modules. A stable
// Objective-C runtime name is therefore required anywhere this class appears
// in an NSXPC method signature; otherwise Swift emits module-qualified names
// that the peer rejects as a different reply-block ABI.
@objc(MACDancerSecurePayload)
final class MDSecurePayload: NSObject, NSSecureCoding {
  static var supportsSecureCoding: Bool { true }
  let protocolVersion: Int
  let data: Data

  init(data: Data, protocolVersion: Int = MACDancerConstants.protocolVersion) {
    self.protocolVersion = protocolVersion
    self.data = data
    super.init()
  }

  convenience init<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    try self.init(data: encoder.encode(value))
  }

  required init?(coder: NSCoder) {
    let protocolVersion = coder.decodeInteger(forKey: "protocolVersion")
    guard protocolVersion == MACDancerConstants.protocolVersion,
          let data = coder.decodeObject(of: NSData.self, forKey: "data") as Data?,
          data.count <= MACDancerConstants.maximumPayloadSize else { return nil }
    self.protocolVersion = protocolVersion
    self.data = data
    super.init()
  }

  func encode(with coder: NSCoder) {
    coder.encode(protocolVersion, forKey: "protocolVersion")
    coder.encode(data as NSData, forKey: "data")
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    guard protocolVersion == MACDancerConstants.protocolVersion else {
      throw MACDancerError.incompatibleProtocol(expected: MACDancerConstants.protocolVersion, actual: protocolVersion)
    }
    guard data.count <= MACDancerConstants.maximumPayloadSize else {
      throw MACDancerError.invalidPayload("XPC payload is too large.")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(type, from: data)
  }
}

@objc(MACDancerClientXPCProtocol)
protocol MACDancerClientProtocol {
  func daemonDidUpdate(_ payload: MDSecurePayload)
}

@objc(MACDancerDaemonXPCProtocol)
protocol MACDancerDaemonProtocol {
  func ping(_ reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func getSnapshot(_ reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func setPolicy(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func randomizeNow(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func restore(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func cancelPendingOperations(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func updateHistory(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func updateAutomation(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
}

extension NSError {
  static func macDancer(_ error: Error) -> NSError {
    let bridged = error as NSError
    var userInfo = bridged.userInfo
    // A Swift LocalizedError can compute its description without storing it in
    // userInfo. That computation is unavailable after crossing into the other
    // Swift module, so materialize the description before replying over XPC.
    userInfo[NSLocalizedDescriptionKey] = error.localizedDescription

    guard let macDancerError = error as? MACDancerError else {
      return NSError(domain: bridged.domain, code: bridged.code, userInfo: userInfo)
    }
    if case .associatedWiFiWriteRejected = macDancerError {
      userInfo[MACDancerConstants.errorKindUserInfoKey] =
        MACDancerRemoteErrorKind.associatedWiFiWriteRejected.rawValue
    }
    return NSError(
      domain: MACDancerConstants.appIdentifier,
      code: macDancerError.xpcErrorCode,
      userInfo: userInfo
    )
  }
}
