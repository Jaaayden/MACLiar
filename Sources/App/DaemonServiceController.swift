import Foundation
import ServiceManagement

/// Owns the ServiceManagement registration boundary for the privileged
/// daemon.  It intentionally does not contact the daemon and never invokes a
/// MAC-changing operation.
@MainActor
final class DaemonServiceController: DaemonServiceProviding {
  private let plistName: String
  private let service: SMAppService
  private let legacyDetector: @Sendable () -> Bool
  private(set) var registrationState: DaemonRegistrationState = .unknown
  private(set) var legacyLinkLiarDetected = false

  init(
    plistName: String = MACDancerConstants.daemonPlistName,
    legacyDetector: @escaping @Sendable () -> Bool = {
      LegacyServiceDetector.isInstalledOrActive()
    }
  ) {
    self.plistName = plistName
    service = .daemon(plistName: plistName)
    self.legacyDetector = legacyDetector
  }

  func refreshRegistrationState() async -> DaemonRegistrationState {
    let plistName = plistName
    let state = await Task.detached(priority: .utility) {
      Self.registrationState(for: SMAppService.daemon(plistName: plistName).status)
    }.value
    registrationState = state
    return state
  }

  nonisolated private static func registrationState(for status: SMAppService.Status) -> DaemonRegistrationState {
    switch status {
    case .notRegistered:
      .notInstalled
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .unknown
    }
  }

  /// Runs the potentially blocking launchd inspection away from MainActor and
  /// exposes only its cached result to normal UI/status update paths.
  func refreshLegacyLinkLiarDetection() async -> Bool {
    let detector = legacyDetector
    let detected = await Task.detached(priority: .utility) {
      detector()
    }.value
    legacyLinkLiarDetected = detected
    return detected
  }

  func install() async throws {
    guard !(await refreshLegacyLinkLiarDetection()) else {
      throw MACDancerError.commandFailed(
        "LinkLiar's legacy daemon is still installed. Remove or disable it before enabling MACDancer automation."
      )
    }

    switch await refreshRegistrationState() {
    case .enabled, .requiresApproval:
      return
    case .unknown, .notInstalled, .notFound:
      try service.register()
      _ = await refreshRegistrationState()
    }
  }

  /// Unregistering only stops future daemon launches.  It intentionally does
  /// not restore an interface MAC and does not delete daemon configuration or
  /// history.
  func uninstall() async throws {
    let state = await refreshRegistrationState()
    guard state != .notInstalled, state != .notFound else { return }
    try await unregisterAndWait()
    _ = await refreshRegistrationState()
  }

  /// Re-register after an executable/plist update or a dead daemon.  The
  /// asynchronous unregister completion is important: ServiceManagement
  /// documents that re-registration should wait until the old daemon exits.
  func repair() async throws {
    guard !(await refreshLegacyLinkLiarDetection()) else {
      throw MACDancerError.commandFailed(
        "LinkLiar's legacy daemon is still installed. MACDancer will not repair or enable competing automation."
      )
    }

    switch await refreshRegistrationState() {
    case .enabled:
      try await unregisterAndWait()
      try await waitForUnregistrationToSettle()
      try await registerAfterUnregistration()
      _ = await refreshRegistrationState()
    case .notInstalled, .notFound, .unknown:
      try service.register()
      _ = await refreshRegistrationState()
    case .requiresApproval:
      openApprovalSettings()
    }
  }

  func openApprovalSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func unregisterAndWait() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      service.unregister { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// `unregister`'s completion can arrive before the background item database
  /// has finished publishing the new state. Registering in that narrow window
  /// intermittently fails with `SMAppServiceErrorDomain` code 1 on Sequoia.
  /// Wait for the observable state and keep the retry bounded so a broken
  /// ServiceManagement database never leaves the UI task hanging.
  private func waitForUnregistrationToSettle() async throws {
    for _ in 0..<40 {
      switch await refreshRegistrationState() {
      case .notInstalled, .notFound:
        // Give backgroundtaskmanagementd one more run-loop turn after its
        // public status changes before attempting to register again.
        try await Task.sleep(nanoseconds: 100_000_000)
        return
      case .enabled, .requiresApproval, .unknown:
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }

    throw MACDancerError.commandFailed(
      "Timed out waiting for the previous background service registration to be removed."
    )
  }

  private func registerAfterUnregistration() async throws {
    do {
      try service.register()
    } catch {
      let nsError = error as NSError
      // The typed domain constant is macOS 15-only even though SMAppService
      // itself is supported on our macOS 14 deployment target.
      guard nsError.domain == "SMAppServiceErrorDomain", nsError.code == 1 else {
        throw error
      }

      // macOS 14/15 can still report a transient EPERM after the status has
      // changed. A single delayed retry is safe and avoids an unbounded loop.
      try await Task.sleep(nanoseconds: 1_000_000_000)
      try service.register()
    }
  }
}
