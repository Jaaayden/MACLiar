import Foundation

enum InterfaceKind: String, Codable, Sendable { case wifi, ethernet, other }

enum InterfacePolicy: Codable, Equatable, Sendable {
  case systemManaged
  case random
  case specified(MACAddress)

  private enum CodingKeys: String, CodingKey { case kind, address }
  private enum Kind: String, Codable { case systemManaged, random, specified }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .systemManaged: self = .systemManaged
    case .random: self = .random
    case .specified: self = .specified(try container.decode(MACAddress.self, forKey: .address))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .systemManaged: try container.encode(Kind.systemManaged, forKey: .kind)
    case .random: try container.encode(Kind.random, forKey: .kind)
    case let .specified(address):
      try container.encode(Kind.specified, forKey: .kind)
      try container.encode(address, forKey: .address)
    }
  }
}

enum HistorySource: String, Codable, Sendable { case generatedLocal, vendorCompatible, userSpecified, historyRestore }
enum OperationKind: String, Codable, Sendable { case randomize, restoreHardware, restoreHistory, restoreSpecified, handoff, reconcile }
enum OperationState: String, Codable, Sendable { case pending, running, succeeded, deferred, cancelled, failed }
enum OperationFailureReason: String, Codable, Sendable { case associatedWiFiWriteRejected }

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
  var id: String { address.stringValue }
  let address: MACAddress
  var source: HistorySource
  var firstUsedAt: Date
  var lastUsedAt: Date
  var operation: OperationKind
}

struct HistoryLedger: Codable, Equatable, Sendable {
  static let limit = 20
  private(set) var entries: [HistoryEntry] = []

  init(entries: [HistoryEntry] = []) {
    for entry in entries { record(entry) }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(entries: try container.decode([HistoryEntry].self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }

  mutating func record(_ entry: HistoryEntry) {
    if let index = entries.firstIndex(where: { $0.address == entry.address }) {
      let first = entries[index].firstUsedAt
      entries.remove(at: index)
      var updated = entry
      updated.firstUsedAt = min(first, entry.firstUsedAt)
      entries.append(updated)
    } else {
      entries.append(entry)
    }
    entries.sort { $0.lastUsedAt > $1.lastUsedAt }
    if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
  }

  mutating func remove(address: MACAddress) { entries.removeAll { $0.address == address } }
  mutating func removeAll() { entries.removeAll() }
}

struct InterfaceSnapshot: Codable, Identifiable, Equatable, Sendable {
  var id: String { bsdName }
  let bsdName: String
  var displayName: String
  var kind: InterfaceKind
  var currentMAC: MACAddress?
  var hardwareMAC: MACAddress?
  var isActive: Bool
  var isWiFiAssociated: Bool
  var isDefaultRoute: Bool
  var policy: InterfacePolicy
  var history: HistoryLedger
  var lastOperation: OperationResult?
  var errorMessage: String?
}

struct OperationResult: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let interfaceID: String
  let kind: OperationKind
  let state: OperationState
  let requestedAddress: MACAddress?
  let observedAddress: MACAddress?
  let startedAt: Date
  let completedAt: Date?
  let message: String?
  let failureReason: OperationFailureReason?
  var deviceKey: String? = nil

  private enum CodingKeys: String, CodingKey {
    case id, interfaceID, kind, state, requestedAddress, observedAddress
    case startedAt, completedAt, message, failureReason, deviceKey
  }

  init(
    id: UUID,
    interfaceID: String,
    kind: OperationKind,
    state: OperationState,
    requestedAddress: MACAddress?,
    observedAddress: MACAddress?,
    startedAt: Date,
    completedAt: Date?,
    message: String?,
    failureReason: OperationFailureReason? = nil,
    deviceKey: String? = nil
  ) {
    self.id = id
    self.interfaceID = interfaceID
    self.kind = kind
    self.state = state
    self.requestedAddress = requestedAddress
    self.observedAddress = observedAddress
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.message = message
    self.failureReason = failureReason
    self.deviceKey = deviceKey
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    interfaceID = try container.decode(String.self, forKey: .interfaceID)
    kind = try container.decode(OperationKind.self, forKey: .kind)
    state = try container.decode(OperationState.self, forKey: .state)
    requestedAddress = try container.decodeIfPresent(MACAddress.self, forKey: .requestedAddress)
    observedAddress = try container.decodeIfPresent(MACAddress.self, forKey: .observedAddress)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    failureReason = try container.decodeIfPresent(OperationFailureReason.self, forKey: .failureReason)
    deviceKey = try container.decodeIfPresent(String.self, forKey: .deviceKey)
  }
}

struct DaemonSnapshot: Codable, Equatable, Sendable {
  var protocolVersion: Int = MACDancerConstants.protocolVersion
  var revision: UInt64
  var instanceID: UUID
  var heartbeat: Date
  var interfaces: [InterfaceSnapshot]
  var pendingOperationIDs: [UUID]
  var automation: AutomationSettings = AutomationSettings()
  var lastError: String?
}

enum RestoreKind: String, Codable, Sendable { case systemManaged, hardware, history, specified }

struct RestoreRequest: Codable, Equatable, Sendable {
  let interfaceID: String
  let kind: RestoreKind
  let targetAddress: MACAddress?
  let confirmedDisruption: Bool
  let confirmedGlobalAddressRisk: Bool

  init(
    interfaceID: String,
    kind: RestoreKind,
    targetAddress: MACAddress?,
    confirmedDisruption: Bool,
    confirmedGlobalAddressRisk: Bool = false
  ) {
    self.interfaceID = interfaceID
    self.kind = kind
    self.targetAddress = targetAddress
    self.confirmedDisruption = confirmedDisruption
    self.confirmedGlobalAddressRisk = confirmedGlobalAddressRisk
  }
}

struct RandomizeRequest: Codable, Equatable, Sendable {
  let interfaceID: String
  let confirmedDisruption: Bool
  let vendorOUI: [UInt8]?
}

struct PolicyRequest: Codable, Equatable, Sendable {
  let interfaceID: String
  let policy: InterfacePolicy
}

struct CancelRequest: Codable, Equatable, Sendable { let interfaceID: String? }

enum HistoryMutationKind: String, Codable, Sendable { case remove, clear }

struct HistoryMutationRequest: Codable, Equatable, Sendable {
  let interfaceID: String
  let kind: HistoryMutationKind
  let address: MACAddress?
}

struct AutomationRequest: Codable, Equatable, Sendable {
  let settings: AutomationSettings
}

struct OperationEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
  let operationID: UUID
  let request: Payload

  init(operationID: UUID = UUID(), request: Payload) {
    self.operationID = operationID
    self.request = request
  }
}

struct ConfigurationDocument: Codable, Equatable, Sendable {
  var policies: [String: InterfacePolicy] = [:]
  var histories: [String: HistoryLedger] = [:]
  var pendingOperations: [OperationResult] = []
  var automation = AutomationSettings()

  init(
    policies: [String: InterfacePolicy] = [:],
    histories: [String: HistoryLedger] = [:],
    pendingOperations: [OperationResult] = [],
    automation: AutomationSettings = AutomationSettings()
  ) {
    self.policies = policies
    self.histories = histories
    self.pendingOperations = pendingOperations
    self.automation = automation
  }

  private enum CodingKeys: String, CodingKey {
    case policies, histories, pendingOperations, automation
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    policies = try container.decodeIfPresent([String: InterfacePolicy].self, forKey: .policies) ?? [:]
    histories = try container.decodeIfPresent([String: HistoryLedger].self, forKey: .histories) ?? [:]
    pendingOperations = try container.decodeIfPresent([OperationResult].self, forKey: .pendingOperations) ?? []
    automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
  }
}

struct AutomationSettings: Codable, Equatable, Sendable {
  var rotateAfterWake = false
  var rotateWhenInterfaceBecomesInactive = false
  var prepareRotationBeforeSleep = false
  var vendorCompatibility = false

  init(
    rotateAfterWake: Bool = false,
    rotateWhenInterfaceBecomesInactive: Bool = false,
    prepareRotationBeforeSleep: Bool = false,
    vendorCompatibility: Bool = false
  ) {
    self.rotateAfterWake = rotateAfterWake
    self.rotateWhenInterfaceBecomesInactive = rotateWhenInterfaceBecomesInactive
    self.prepareRotationBeforeSleep = prepareRotationBeforeSleep
    self.vendorCompatibility = vendorCompatibility
  }
}

enum SafetyDecision: Equatable, Sendable { case allowed, deferred(String), denied(String) }

enum SafetyPolicy {
  static func decision(for interface: InterfaceSnapshot, automatic: Bool, confirmedDisruption: Bool) -> SafetyDecision {
    guard interface.kind != .other else { return .denied("This interface type is not supported.") }
    if automatic && interface.isDefaultRoute { return .deferred("The interface carries the default route.") }
    if automatic && interface.kind == .wifi && (interface.isActive || interface.isWiFiAssociated) {
      return .deferred("Active Wi-Fi is never modified automatically.")
    }
    if !automatic && (interface.isActive || interface.isDefaultRoute) && !confirmedDisruption {
      return .denied("Connectivity interruption must be confirmed.")
    }
    return .allowed
  }
}
