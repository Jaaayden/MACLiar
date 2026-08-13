import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

struct CommandResult: Equatable, Sendable {
  let exitCode: Int32
  let standardOutput: String
  let standardError: String
}

protocol CommandExecuting: Sendable {
  func run(executable: URL, arguments: [String]) throws -> CommandResult
}

#if !MACDANCER_CORE_TESTS
struct ProcessCommandExecutor: CommandExecuting {
  /// `nil` is reserved for callers that explicitly need to wait for process
  /// completion. UI-adjacent probes always provide a short hard timeout.
  let timeout: TimeInterval?

  init(timeout: TimeInterval? = nil) {
    self.timeout = timeout
  }

  func run(executable: URL, arguments: [String]) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error

    let capturedOutput = LockedData()
    let capturedError = LockedData()
    let readers = DispatchGroup()
    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }
    try process.run()
    // The parent never writes through these descriptors. Closing its copies
    // lets readers observe EOF even when launch fails or a child is killed.
    output.fileHandleForWriting.closeFile()
    error.fileHandleForWriting.closeFile()

    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      capturedOutput.value = output.fileHandleForReading.readDataToEndOfFile()
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      capturedError.value = error.fileHandleForReading.readDataToEndOfFile()
      readers.leave()
    }

    if let timeout {
      guard termination.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        if termination.wait(timeout: .now() + 0.25) == .timedOut {
          Darwin.kill(process.processIdentifier, SIGKILL)
          _ = termination.wait(timeout: .now() + 0.25)
        }
        throw MACDancerError.commandFailed(
          "\(executable.lastPathComponent) did not finish within \(String(format: "%.1f", timeout)) seconds."
        )
      }
    } else {
      process.waitUntilExit()
    }
    readers.wait()
    return CommandResult(
      exitCode: process.terminationStatus,
      standardOutput: String(decoding: capturedOutput.value, as: UTF8.self),
      standardError: String(decoding: capturedError.value, as: UTF8.self)
    )
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()
  var value: Data {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

/// Read-only detection for the legacy LinkLiar service. Modern SMAppService
/// registrations need not leave a plist in `/Library/LaunchDaemons`, so a
/// fixed `launchctl print` query complements the protected-path check.
struct LegacyServiceDetector {
  static func isInstalledOrActive(
    identifier: String = MACDancerConstants.legacyDaemonIdentifier,
    fileManager: FileManager = .default,
    commandExecutor: any CommandExecuting = ProcessCommandExecutor(timeout: 1.5)
  ) -> Bool {
    let filename = identifier + ".plist"
    if ["/Library/LaunchDaemons", "/Library/LaunchAgents"].contains(where: { directory in
      fileManager.fileExists(atPath: URL(fileURLWithPath: directory).appendingPathComponent(filename).path)
    }) {
      return true
    }

    do {
      let result = try commandExecutor.run(
        executable: URL(fileURLWithPath: "/bin/launchctl", isDirectory: false),
        arguments: ["print", "system/\(identifier)"]
      )
      return result.exitCode == 0
    } catch {
      // An unavailable launchd probe is not proof that a competing privileged
      // service is absent. Fail closed and keep MACDancer read-only.
      return true
    }
  }
}
#endif

protocol ReadOnlyInterfaceProviding: Sendable {
  func interfaces() throws -> [InterfaceSnapshot]
  func currentMAC(for interfaceID: String) throws -> MACAddress?
}

struct SystemReadOnlyInterfaceProvider: ReadOnlyInterfaceProviding {
  func interfaces() throws -> [InterfaceSnapshot] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
      throw MACDancerError.commandFailed("getifaddrs failed: \(String(cString: strerror(errno)))")
    }
    defer { freeifaddrs(pointer) }

    struct LinkState {
      var currentMAC: MACAddress?
      var isActive: Bool
      var errorMessage: String?
    }

    let defaultNames = Self.defaultRouteInterfaces()
    let wifiClient = CWWiFiClient.shared()
    let wifiNames = Set(wifiClient.interfaces()?.map(\.interfaceName) ?? [])
    let systemInterfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
    var linkStates: [String: LinkState] = [:]

    for sequence in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let item = sequence.pointee
      guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
      let name = String(cString: item.ifa_name)
      let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee
      let flags = Int32(item.ifa_flags)
      let active = flags & IFF_UP != 0 && flags & IFF_RUNNING != 0

      guard link.sdl_alen == 6 else {
        linkStates[name] = LinkState(
          currentMAC: nil,
          isActive: active,
          errorMessage: "macOS reported an unsupported link-address length for \(name)."
        )
        continue
      }
      let base = UnsafeRawPointer(address)
        .advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data)! + Int(link.sdl_nlen))
      let bytes = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: 6))
      linkStates[name] = LinkState(
        currentMAC: MACAddress(bytes: bytes),
        isActive: active,
        errorMessage: nil
      )
    }

    var snapshotsByName: [String: InterfaceSnapshot] = [:]
    for systemInterface in systemInterfaces {
      guard let name = SCNetworkInterfaceGetBSDName(systemInterface) as String? else { continue }
      let state = linkStates[name]
      let isWifi = wifiNames.contains(name)
        || (SCNetworkInterfaceGetInterfaceType(systemInterface) as String?) == (kSCNetworkInterfaceTypeIEEE80211 as String)
      let interfaceType = SCNetworkInterfaceGetInterfaceType(systemInterface) as String?
      let kind: InterfaceKind = isWifi
        ? .wifi
        : (interfaceType == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .other)
      let wifiInterface = isWifi ? wifiClient.interface(withName: name) : nil
      let hardwareMAC = (SCNetworkInterfaceGetHardwareAddressString(systemInterface) as String?)
        .flatMap(MACAddress.init)
        ?? wifiInterface?.hardwareAddress().flatMap(MACAddress.init)
      snapshotsByName[name] = InterfaceSnapshot(
        bsdName: name,
        displayName: (SCNetworkInterfaceGetLocalizedDisplayName(systemInterface) as String?) ?? name,
        kind: kind,
        currentMAC: state?.currentMAC,
        hardwareMAC: hardwareMAC,
        isActive: state?.isActive ?? false,
        isWiFiAssociated: wifiInterface?.ssid() != nil || wifiInterface?.bssid() != nil,
        isDefaultRoute: defaultNames.contains(name),
        policy: .systemManaged,
        history: HistoryLedger(),
        lastOperation: nil,
        errorMessage: state == nil
          ? "macOS did not report a current link-layer address for \(name)."
          : state?.errorMessage
      )
    }
    return snapshotsByName.values.sorted { $0.bsdName < $1.bsdName }
  }

  func currentMAC(for interfaceID: String) throws -> MACAddress? {
    try interfaces().first { $0.bsdName == interfaceID }?.currentMAC
  }

  private static func defaultRouteInterfaces() -> Set<String> {
    guard let store = SCDynamicStoreCreate(nil, "MACDancer.ReadOnly" as CFString, nil, nil) else { return [] }
    let keys = [
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4),
      SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)
    ]
    return Set(keys.compactMap { key in
      (SCDynamicStoreCopyValue(store, key) as? [String: Any])?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    })
  }
}
