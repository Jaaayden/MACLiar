import Foundation

/// The result of one explicit `ifconfig … ether …` request.
///
/// A successful process exit is not considered success until the read-only
/// provider observes the requested address.  This keeps callers from updating
/// their state optimistically when a driver silently rejects a change.
enum MACSettingOutcome: Equatable, Sendable {
  case success(interfaceID: String, requested: MACAddress, observed: MACAddress)
  case mismatch(interfaceID: String, requested: MACAddress, observed: MACAddress?)
  case failure(interfaceID: String, requested: MACAddress?, reason: MACSettingFailure)
}

enum MACSettingFailure: Equatable, Sendable {
  case invalidTarget(MACAddress)
  case missingHardwareAddress
  case commandExecution(String)
  case commandRejected(exitCode: Int32, standardError: String)
  case readbackFailed(String)

  var userFacingDescription: String {
    switch self {
    case .invalidTarget:
      "The requested MAC address is not assignable."
    case .missingHardwareAddress:
      "macOS did not report a hardware MAC address for this interface."
    case let .commandExecution(message):
      "The MAC change command could not be executed: \(message)"
    case let .commandRejected(exitCode, standardError):
      standardError.isEmpty
        ? "macOS rejected the MAC change (ifconfig exited with status \(exitCode))."
        : "macOS rejected the MAC change: \(standardError)"
    case let .readbackFailed(message):
      "The MAC address could not be read back for verification: \(message)"
    }
  }
}

/// Applies an already-authorized MAC target to one interface.
///
/// This type deliberately has no wireless-management or connection-management
/// side effects, sleeps, or retries. Safety decisions, including whether an
/// active interface may be disrupted, belong to the daemon coordinator. The
/// two injected dependencies make all behavior testable with fakes.
final class MACSetter {
  static let ifconfigURL = URL(fileURLWithPath: "/sbin/ifconfig", isDirectory: false)

  private let commandExecutor: any CommandExecuting
  private let interfaceProvider: any ReadOnlyInterfaceProviding

  /// Construction is inert: no interface is read and no process is started.
#if MACDANCER_CORE_TESTS
  /// Core tests must inject a fake command boundary. The production process
  /// adapter is compiled out of that target, so an accidental test cannot
  /// reach a system executable even if it constructs this type incorrectly.
  init(
    commandExecutor: any CommandExecuting,
    interfaceProvider: any ReadOnlyInterfaceProviding
  ) {
    self.commandExecutor = commandExecutor
    self.interfaceProvider = interfaceProvider
  }
#else
  init(
    commandExecutor: any CommandExecuting = ProcessCommandExecutor(timeout: 15),
    interfaceProvider: any ReadOnlyInterfaceProviding = SystemReadOnlyInterfaceProvider()
  ) {
    self.commandExecutor = commandExecutor
    self.interfaceProvider = interfaceProvider
  }
#endif

  /// Sets exactly `targetAddress`; no implicit "reset" mode is used.
  ///
  /// Supplying an interface's hardware MAC here is therefore an explicit
  /// hardware restore operation, subject to the same process result and
  /// read-back verification as every other target.
  func apply(interfaceID: String, targetAddress: MACAddress) -> MACSettingOutcome {
    guard targetAddress.isValidAssignable else {
      return .failure(
        interfaceID: interfaceID,
        requested: targetAddress,
        reason: .invalidTarget(targetAddress)
      )
    }

    let commandResult: CommandResult
    do {
      commandResult = try commandExecutor.run(
        executable: Self.ifconfigURL,
        arguments: [interfaceID, "ether", targetAddress.stringValue]
      )
    } catch {
      return .failure(
        interfaceID: interfaceID,
        requested: targetAddress,
        reason: .commandExecution(error.localizedDescription)
      )
    }

    let standardError = commandResult.standardError
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard commandResult.exitCode == 0, standardError.isEmpty else {
      return .failure(
        interfaceID: interfaceID,
        requested: targetAddress,
        reason: .commandRejected(
          exitCode: commandResult.exitCode,
          standardError: standardError
        )
      )
    }

    let observedAddress: MACAddress?
    do {
      observedAddress = try interfaceProvider.currentMAC(for: interfaceID)
    } catch {
      return .failure(
        interfaceID: interfaceID,
        requested: targetAddress,
        reason: .readbackFailed(error.localizedDescription)
      )
    }

    guard observedAddress == targetAddress else {
      return .mismatch(
        interfaceID: interfaceID,
        requested: targetAddress,
        observed: observedAddress
      )
    }

    return .success(
      interfaceID: interfaceID,
      requested: targetAddress,
      observed: targetAddress
    )
  }

  /// Restores hardware identity by making it an explicit target address.
  ///
  /// There is intentionally no special `ifconfig` reset syntax; that would be
  /// less auditable and could not be verified against an exact requested MAC.
  func restoreHardware(for interface: InterfaceSnapshot) -> MACSettingOutcome {
    guard let hardwareAddress = interface.hardwareMAC else {
      return .failure(
        interfaceID: interface.bsdName,
        requested: nil,
        reason: .missingHardwareAddress
      )
    }

    return apply(interfaceID: interface.bsdName, targetAddress: hardwareAddress)
  }
}
