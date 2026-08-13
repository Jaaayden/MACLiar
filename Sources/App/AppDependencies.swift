import Foundation

enum DaemonReachability: String, Equatable, Sendable {
  case unknown
  case connecting
  case reachable
  case interrupted
  case unavailable
}

enum DaemonHealth: String, Equatable, Sendable {
  case unknown
  case healthy
  case stale
  case incompatible
  case unhealthy
}

struct DaemonClientStatus: Equatable, Sendable {
  var reachability: DaemonReachability = .unknown
  var health: DaemonHealth = .unknown
  var version: Int?
  var diagnostic: String?
}

enum DaemonRegistrationState: String, Equatable, Sendable {
  case unknown
  case notInstalled
  case enabled
  case requiresApproval
  case notFound
}

@MainActor
protocol DaemonClientProviding: AnyObject {
  var onSnapshot: (@MainActor (DaemonSnapshot) -> Void)? { get set }
  var onStatusChange: (@MainActor (DaemonClientStatus) -> Void)? { get set }

  func start()
  func stop()
  func setPolicy(_ request: PolicyRequest, operationID: UUID) async throws -> DaemonSnapshot
  func randomize(_ request: RandomizeRequest, operationID: UUID) async throws -> DaemonSnapshot
  func restore(_ request: RestoreRequest, operationID: UUID) async throws -> DaemonSnapshot
  func cancel(_ request: CancelRequest, operationID: UUID) async throws -> DaemonSnapshot
  func updateHistory(_ request: HistoryMutationRequest, operationID: UUID) async throws -> DaemonSnapshot
  func updateAutomation(_ request: AutomationRequest, operationID: UUID) async throws -> DaemonSnapshot
}

extension DaemonClientProviding {
  func setPolicy(_ request: PolicyRequest) async throws -> DaemonSnapshot {
    try await setPolicy(request, operationID: UUID())
  }

  func randomize(_ request: RandomizeRequest) async throws -> DaemonSnapshot {
    try await randomize(request, operationID: UUID())
  }

  func restore(_ request: RestoreRequest) async throws -> DaemonSnapshot {
    try await restore(request, operationID: UUID())
  }

  func cancel(_ request: CancelRequest) async throws -> DaemonSnapshot {
    try await cancel(request, operationID: UUID())
  }

  func updateHistory(_ request: HistoryMutationRequest) async throws -> DaemonSnapshot {
    try await updateHistory(request, operationID: UUID())
  }

  func updateAutomation(_ request: AutomationRequest) async throws -> DaemonSnapshot {
    try await updateAutomation(request, operationID: UUID())
  }
}

@MainActor
protocol DaemonServiceProviding: AnyObject {
  var registrationState: DaemonRegistrationState { get }
  var legacyLinkLiarDetected: Bool { get }

  func refreshRegistrationState() async -> DaemonRegistrationState
  func refreshLegacyLinkLiarDetection() async -> Bool
  func install() async throws
  func uninstall() async throws
  func repair() async throws
  func openApprovalSettings()
}
