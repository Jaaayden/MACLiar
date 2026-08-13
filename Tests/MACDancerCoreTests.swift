import Foundation
import XCTest

@objc private protocol TestPayloadEchoProtocol {
  func echo(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void)
  func fail(reply: @escaping (NSError?) -> Void)
}

private final class TestPayloadEchoService: NSObject, TestPayloadEchoProtocol {
  func echo(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    reply(payload, nil)
  }

  func fail(reply: @escaping (NSError?) -> Void) {
    reply(.macDancer(MACDancerError.associatedWiFiWriteRejected))
  }
}

private final class TestPayloadEchoDelegate: NSObject, NSXPCListenerDelegate {
  private let service = TestPayloadEchoService()

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = Self.interface()
    connection.exportedObject = service
    connection.activate()
    return true
  }

  static func interface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: TestPayloadEchoProtocol.self)
    let classes = NSSet(object: MDSecurePayload.self) as! Set<AnyHashable>
    interface.setClasses(
      classes,
      for: #selector(TestPayloadEchoProtocol.echo(_:reply:)),
      argumentIndex: 0,
      ofReply: false
    )
    interface.setClasses(
      classes,
      for: #selector(TestPayloadEchoProtocol.echo(_:reply:)),
      argumentIndex: 0,
      ofReply: true
    )
    return interface
  }
}

private final class StubCommandExecutor: CommandExecuting, @unchecked Sendable {
  struct Invocation: Equatable {
    let executable: URL
    let arguments: [String]
  }

  var result: CommandResult
  private(set) var invocations: [Invocation] = []

  init(result: CommandResult) {
    self.result = result
  }

  func run(executable: URL, arguments: [String]) throws -> CommandResult {
    invocations.append(Invocation(executable: executable, arguments: arguments))
    return result
  }
}

private struct StubReadOnlyInterfaceProvider: ReadOnlyInterfaceProviding {
  let snapshots: [InterfaceSnapshot]
  let observedMAC: MACAddress?

  func interfaces() throws -> [InterfaceSnapshot] { snapshots }
  func currentMAC(for interfaceID: String) throws -> MACAddress? { observedMAC }
}

@MainActor
private final class FakeDaemonClient: DaemonClientProviding {
  var onSnapshot: (@MainActor (DaemonSnapshot) -> Void)?
  var onStatusChange: (@MainActor (DaemonClientStatus) -> Void)?
  var snapshot: DaemonSnapshot
  private(set) var startCount = 0
  private(set) var stopCount = 0

  init(snapshot: DaemonSnapshot) {
    self.snapshot = snapshot
  }

  func start() { startCount += 1 }
  func stop() { stopCount += 1 }
  func emit(_ snapshot: DaemonSnapshot) { onSnapshot?(snapshot) }
  func emit(_ status: DaemonClientStatus) { onStatusChange?(status) }

  func setPolicy(_ request: PolicyRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
  func randomize(_ request: RandomizeRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
  func restore(_ request: RestoreRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
  func cancel(_ request: CancelRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
  func updateHistory(_ request: HistoryMutationRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
  func updateAutomation(_ request: AutomationRequest, operationID: UUID) async throws -> DaemonSnapshot { snapshot }
}

@MainActor
private final class FakeDaemonService: DaemonServiceProviding {
  var registrationState: DaemonRegistrationState
  var legacyLinkLiarDetected: Bool
  private(set) var legacyRefreshCount = 0

  init(
    registrationState: DaemonRegistrationState,
    legacyLinkLiarDetected: Bool = false
  ) {
    self.registrationState = registrationState
    self.legacyLinkLiarDetected = legacyLinkLiarDetected
  }

  func refreshLegacyLinkLiarDetection() async -> Bool {
    legacyRefreshCount += 1
    return legacyLinkLiarDetected
  }
  func refreshRegistrationState() async -> DaemonRegistrationState { registrationState }
  func install() async throws { registrationState = .enabled }
  func uninstall() async throws { registrationState = .notInstalled }
  func repair() async throws { registrationState = .enabled }
  func openApprovalSettings() {}
}

final class MACDancerCoreTests: XCTestCase {
  @MainActor
  func testAppModelStartsOnDashboardAndRefreshesOnlyThroughFakeProvider() async throws {
    let defaults = UserDefaults.standard
    let priorPreference = defaults.object(forKey: "showMenuBarIcon")
    defaults.removeObject(forKey: "showMenuBarIcon")
    defer {
      if let priorPreference { defaults.set(priorPreference, forKey: "showMenuBarIcon") }
      else { defaults.removeObject(forKey: "showMenuBarIcon") }
    }

    let localInterface = interfaceSnapshot(
      name: "fixture-gui0",
      kind: .ethernet,
      active: false,
      defaultRoute: false
    )
    let provider = StubReadOnlyInterfaceProvider(
      snapshots: [localInterface],
      observedMAC: localInterface.currentMAC
    )
    let daemon = FakeDaemonClient(snapshot: snapshot(instanceID: UUID(), revision: 0))
    let service = FakeDaemonService(registrationState: .notInstalled)
    let model = AppModel(
      readOnlyRefreshController: ReadOnlyRefreshController(provider: provider),
      daemonClient: daemon,
      serviceController: service
    )

    XCTAssertEqual(model.selection, .dashboard)
    XCTAssertTrue(model.interfaces.isEmpty)
    XCTAssertEqual(daemon.startCount, 0)
    XCTAssertNil(daemon.onSnapshot)
    XCTAssertNil(daemon.onStatusChange)
    XCTAssertEqual(service.legacyRefreshCount, 0)

    model.start()
    model.start()
    try await waitForRefresh(model)

    // A missing/disabled service must never enter the privileged XPC signing
    // path during GUI startup. This keeps the window usable for unsigned and
    // Personal Team development builds as well as before first installation.
    XCTAssertEqual(daemon.startCount, 0)
    XCTAssertNotNil(daemon.onSnapshot)
    XCTAssertNotNil(daemon.onStatusChange)
    XCTAssertEqual(service.legacyRefreshCount, 1)
    XCTAssertEqual(model.daemonState, .notInstalled)
    XCTAssertEqual(model.interfaces.map(\.id), [localInterface.id])
    XCTAssertEqual(model.interfaces.first?.currentMAC, localInterface.currentMAC)
    XCTAssertNotNil(model.lastRefreshAt)
  }

  @MainActor
  func testAppModelAcceptsAuthoritativeFakeDaemonSnapshotImmediately() async throws {
    var localInterface = interfaceSnapshot(
      name: "fixture-gui1",
      kind: .ethernet,
      active: false,
      defaultRoute: false
    )
    let locallyReadAddress = try address("02:00:00:00:00:31")
    localInterface.currentMAC = locallyReadAddress
    let provider = StubReadOnlyInterfaceProvider(
      snapshots: [localInterface],
      observedMAC: locallyReadAddress
    )
    let daemon = FakeDaemonClient(snapshot: snapshot(instanceID: UUID(), revision: 0))
    let service = FakeDaemonService(registrationState: .enabled)
    let model = AppModel(
      readOnlyRefreshController: ReadOnlyRefreshController(provider: provider),
      daemonClient: daemon,
      serviceController: service
    )
    model.start()
    try await waitForRefresh(model)

    let verifiedAddress = try address("02:00:00:00:00:32")
    var daemonInterface = localInterface
    daemonInterface.currentMAC = verifiedAddress
    let authoritative = DaemonSnapshot(
      revision: 1,
      instanceID: UUID(),
      heartbeat: Date(),
      interfaces: [daemonInterface],
      pendingOperationIDs: [],
      automation: AutomationSettings(),
      lastError: nil
    )
    daemon.emit(DaemonClientStatus(
      reachability: .reachable,
      health: .healthy,
      version: MACDancerConstants.protocolVersion,
      diagnostic: nil
    ))
    daemon.emit(authoritative)

    XCTAssertEqual(model.interfaces.first?.currentMAC, verifiedAddress)
    XCTAssertEqual(model.snapshot?.instanceID, authoritative.instanceID)
    XCTAssertEqual(model.daemonHealth, .healthy)
  }

  func testMACAddressParsesAndNormalizesFortyEightBitAddresses() throws {
    let address = try XCTUnwrap(MACAddress("AA-BB-CC-DD-EE-FF"))

    XCTAssertEqual(address.stringValue, "aa:bb:cc:dd:ee:ff")
    XCTAssertEqual(address.bytes, [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
    XCTAssertNil(MACAddress("aa:bb:cc:dd:ee"))
    XCTAssertNil(MACAddress("not an address"))
    XCTAssertNil(MACAddress("AA-bb.cc:DD ee/ff"))
    XCTAssertNil(MACAddress(bytes: [0x02, 0x00]))
  }

  func testMACAddressDecodingCannotBypassStrictSixByteValidation() throws {
    let decoder = JSONDecoder()

    XCTAssertThrowsError(try decoder.decode(MACAddress.self, from: Data("\"02:00:00:00:00\"".utf8)))
    XCTAssertThrowsError(try decoder.decode(MACAddress.self, from: Data("\"02:00:00:00:00:01:02\"".utf8)))
    XCTAssertThrowsError(try decoder.decode(MACAddress.self, from: Data("\"AA-bb.cc:DD ee/ff\"".utf8)))
    XCTAssertEqual(
      try decoder.decode(MACAddress.self, from: Data("\"020000000001\"".utf8)),
      try address("02:00:00:00:00:01")
    )
  }

  func testAddressValidityDistinguishesUnicastAndReservedAddresses() throws {
    let localUnicast = try address("02:00:00:00:00:01")
    let multicast = try address("01:00:5e:00:00:01")
    let broadcast = try address("ff:ff:ff:ff:ff:ff")
    let zero = try address("00:00:00:00:00:00")

    XCTAssertTrue(localUnicast.isUnicast)
    XCTAssertTrue(localUnicast.isLocallyAdministered)
    XCTAssertTrue(localUnicast.isValidAssignable)
    XCTAssertFalse(multicast.isUnicast)
    XCTAssertFalse(multicast.isValidAssignable)
    XCTAssertTrue(broadcast.isBroadcast)
    XCTAssertFalse(broadcast.isValidAssignable)
    XCTAssertTrue(zero.isAllZero)
    XCTAssertFalse(zero.isValidAssignable)
  }

  func testLocalGenerationProducesLAAUnicastAndAvoidsConflicts() throws {
    let excluded = try address("02:10:20:30:40:50")
    var suppliedCandidates: [[UInt8]] = [
      [0x01, 0x10, 0x20, 0x30, 0x40, 0x50],
      [0xfc, 0x11, 0x22, 0x33, 0x44, 0x55]
    ]

    let generated = try MACAddress.randomLocallyAdministered(
      excluding: [excluded],
      attempts: suppliedCandidates.count,
      fill: { buffer in
        let next = suppliedCandidates.removeFirst()
        for (index, byte) in next.enumerated() { buffer[index] = byte }
        return 0
      }
    )

    XCTAssertEqual(generated.stringValue, "fe:11:22:33:44:55")
    XCTAssertTrue(generated.isUnicast)
    XCTAssertTrue(generated.isLocallyAdministered)
    XCTAssertTrue(generated.isValidAssignable)
    XCTAssertNotEqual(generated, excluded)
    XCTAssertTrue(suppliedCandidates.isEmpty)
  }

  func testLocalGenerationNormalizesEveryFirstOctetToLAAUnicast() throws {
    for firstOctet in UInt8.min...UInt8.max {
      let generated = try MACAddress.randomLocallyAdministered(
        attempts: 1,
        fill: { buffer in
          let bytes: [UInt8] = [firstOctet, 0x10, 0x20, 0x30, 0x40, 0x50]
          for (index, byte) in bytes.enumerated() { buffer[index] = byte }
          return 0
        }
      )

      XCTAssertEqual(generated.bytes[0], (firstOctet & 0xfc) | 0x02)
      XCTAssertTrue(generated.isUnicast)
      XCTAssertTrue(generated.isLocallyAdministered)
      XCTAssertTrue(generated.isValidAssignable)
    }
  }

  func testTenThousandSecureRandomAddressesPreserveLAAUnicastInvariants() throws {
    var generated = Set<MACAddress>()
    for _ in 0..<10_000 {
      let address = try MACAddress.randomLocallyAdministered(excluding: generated)
      XCTAssertEqual(address.bytes.count, 6)
      XCTAssertTrue(address.isUnicast)
      XCTAssertTrue(address.isLocallyAdministered)
      XCTAssertTrue(address.isValidAssignable)
      generated.insert(address)
    }
    XCTAssertEqual(generated.count, 10_000)
  }

  func testLocalGenerationFailsInsteadOfReusingAnExcludedAddress() throws {
    let excluded = try address("02:aa:bb:cc:dd:ee")
    let fill: (UnsafeMutableRawBufferPointer) -> Int32 = { buffer in
      let bytes: [UInt8] = [0x00, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
      return 0
    }

    XCTAssertThrowsError(
      try MACAddress.randomLocallyAdministered(excluding: [excluded], attempts: 2, fill: fill)
    ) { error in
      XCTAssertEqual(error as? MACDancerError, .exhaustedRandomAttempts)
    }
  }

  func testVendorCompatibleGenerationPreservesVendorOUIAndAvoidsConflicts() throws {
    let oui: [UInt8] = [0x00, 0x1c, 0x42]
    let excluded = try address("00:1c:42:12:34:56")
    var suffixes: [[UInt8]] = [[0x12, 0x34, 0x56], [0xab, 0xcd, 0xef]]

    let generated = try MACAddress.randomVendorCompatible(
      oui: oui,
      excluding: [excluded],
      attempts: suffixes.count,
      fill: { buffer in
        let next = suffixes.removeFirst()
        for (index, byte) in next.enumerated() { buffer[index] = byte }
        return 0
      }
    )

    XCTAssertEqual(Array(generated.bytes.prefix(3)), oui)
    XCTAssertEqual(generated.stringValue, "00:1c:42:ab:cd:ef")
    XCTAssertTrue(generated.isUnicast)
    XCTAssertTrue(generated.isValidAssignable)
    XCTAssertNotEqual(generated, excluded)
    XCTAssertTrue(suffixes.isEmpty)
  }

  func testVendorCompatibleGenerationRejectsMalformedOrMulticastOUI() {
    let fill: (UnsafeMutableRawBufferPointer) -> Int32 = { _ in 0 }

    XCTAssertThrowsError(
      try MACAddress.randomVendorCompatible(oui: [0x01, 0x23, 0x45], fill: fill)
    ) { error in
      XCTAssertEqual(error as? MACDancerError, .invalidMACAddress("01:23:45"))
    }

    XCTAssertThrowsError(
      try MACAddress.randomVendorCompatible(oui: [0x00, 0x11], fill: fill)
    ) { error in
      XCTAssertEqual(error as? MACDancerError, .invalidMACAddress("00:11"))
    }


    XCTAssertThrowsError(
      try MACAddress.randomVendorCompatible(oui: [0x02, 0x11, 0x22], fill: fill)
    ) { error in
      XCTAssertEqual(error as? MACDancerError, .invalidMACAddress("02:11:22"))
    }
  }

  func testHistoryIsBoundedAndDeduplicatedPerInterface() throws {
    var firstInterfaceHistory = HistoryLedger()
    var secondInterfaceHistory = HistoryLedger()

    for index in 0...HistoryLedger.limit {
      firstInterfaceHistory.record(historyEntry(address: try address(number: index), at: index))
    }
    let evictedAddress = try address(number: 0)
    let sharedAddress = try address(number: 7)
    secondInterfaceHistory.record(historyEntry(address: sharedAddress, at: 1))

    XCTAssertEqual(firstInterfaceHistory.entries.count, HistoryLedger.limit)
    XCTAssertFalse(firstInterfaceHistory.entries.contains { $0.address == evictedAddress })
    XCTAssertEqual(secondInterfaceHistory.entries.map(\.address), [sharedAddress])

    let original = try XCTUnwrap(firstInterfaceHistory.entries.first { $0.address == sharedAddress })
    firstInterfaceHistory.record(
      HistoryEntry(
        address: sharedAddress,
        source: .historyRestore,
        firstUsedAt: Date(timeIntervalSince1970: 999),
        lastUsedAt: Date(timeIntervalSince1970: 9_999),
        operation: .restoreHistory
      )
    )

    let updated = try XCTUnwrap(firstInterfaceHistory.entries.first { $0.address == sharedAddress })
    XCTAssertEqual(firstInterfaceHistory.entries.count, HistoryLedger.limit)
    XCTAssertEqual(updated.firstUsedAt, original.firstUsedAt)
    XCTAssertEqual(updated.lastUsedAt, Date(timeIntervalSince1970: 9_999))
    XCTAssertEqual(updated.source, .historyRestore)
    XCTAssertEqual(secondInterfaceHistory.entries.map(\.address), [sharedAddress])
  }

  func testHistoryDecodingNormalizesMoreThanTwentyAndDuplicateEntries() throws {
    let duplicatedAddress = try address(number: 3)
    var fixture: [HistoryEntry] = []
    for index in 0...HistoryLedger.limit {
      fixture.append(historyEntry(address: try address(number: index), at: index))
    }
    fixture.append(
      HistoryEntry(
        address: duplicatedAddress,
        source: .historyRestore,
        firstUsedAt: Date(timeIntervalSince1970: 999),
        lastUsedAt: Date(timeIntervalSince1970: 9_999),
        operation: .restoreHistory
      )
    )

    let decoded = try JSONDecoder().decode(HistoryLedger.self, from: JSONEncoder().encode(fixture))
    let entry = try XCTUnwrap(decoded.entries.first { $0.address == duplicatedAddress })

    XCTAssertEqual(decoded.entries.count, HistoryLedger.limit)
    XCTAssertEqual(decoded.entries.filter { $0.address == duplicatedAddress }.count, 1)
    XCTAssertEqual(entry.firstUsedAt, Date(timeIntervalSince1970: 3))
    XCTAssertEqual(entry.lastUsedAt, Date(timeIntervalSince1970: 9_999))
    XCTAssertEqual(entry.source, .historyRestore)
  }

  func testSafetyPolicyDefersAutomaticDefaultRouteAndActiveWiFi() throws {
    let defaultRoute = interfaceSnapshot(
      name: "en0",
      kind: .ethernet,
      active: true,
      defaultRoute: true
    )
    let activeWiFi = interfaceSnapshot(
      name: "en1",
      kind: .wifi,
      active: true,
      defaultRoute: false
    )
    let inactiveEthernet = interfaceSnapshot(
      name: "en2",
      kind: .ethernet,
      active: false,
      defaultRoute: false
    )

    XCTAssertEqual(
      SafetyPolicy.decision(for: defaultRoute, automatic: true, confirmedDisruption: false),
      .deferred("The interface carries the default route.")
    )
    XCTAssertEqual(
      SafetyPolicy.decision(for: activeWiFi, automatic: true, confirmedDisruption: false),
      .deferred("Active Wi-Fi is never modified automatically.")
    )
    XCTAssertEqual(
      SafetyPolicy.decision(for: inactiveEthernet, automatic: true, confirmedDisruption: false),
      .allowed
    )
  }

  func testSafetyPolicyRequiresConfirmationForManualDisruptiveRequests() throws {
    let activeInterface = interfaceSnapshot(
      name: "en4",
      kind: .ethernet,
      active: true,
      defaultRoute: false
    )

    XCTAssertEqual(
      SafetyPolicy.decision(for: activeInterface, automatic: false, confirmedDisruption: false),
      .denied("Connectivity interruption must be confirmed.")
    )
    XCTAssertEqual(
      SafetyPolicy.decision(for: activeInterface, automatic: false, confirmedDisruption: true),
      .allowed
    )
  }

  func testAssociatedWiFiIsDeferredEvenWhenLinkFlagsAreNotActive() {
    var associatedWiFi = interfaceSnapshot(
      name: "en5",
      kind: .wifi,
      active: false,
      defaultRoute: false
    )
    associatedWiFi.isWiFiAssociated = true

    XCTAssertEqual(
      SafetyPolicy.decision(for: associatedWiFi, automatic: true, confirmedDisruption: false),
      .deferred("Active Wi-Fi is never modified automatically.")
    )
  }

  func testAutomationPlannerQueuesOnlyConfiguredTransitionsAndCoalescesIDs() {
    var active = interfaceSnapshot(name: "en6", kind: .ethernet, active: true, defaultRoute: false)
    active.policy = .random
    var inactive = active
    inactive.isActive = false
    var systemManaged = interfaceSnapshot(name: "en7", kind: .ethernet, active: false, defaultRoute: false)
    systemManaged.policy = .systemManaged

    let settings = AutomationSettings(
      rotateAfterWake: true,
      rotateWhenInterfaceBecomesInactive: true,
      prepareRotationBeforeSleep: true,
      vendorCompatibility: false
    )
    let current = [inactive.id: inactive, systemManaged.id: systemManaged]

    XCTAssertEqual(
      AutomationPlanner.interfaceIDsToQueue(
        for: .beforeSleep,
        settings: settings,
        current: current
      ),
      [inactive.id]
    )
    XCTAssertEqual(
      AutomationPlanner.interfaceIDsToQueue(
        for: .afterWake,
        settings: settings,
        current: current
      ),
      [inactive.id]
    )
    XCTAssertEqual(
      AutomationPlanner.interfaceIDsToQueue(
        for: .networkChange,
        settings: settings,
        previous: [active.id: active],
        current: current
      ),
      [inactive.id]
    )
    XCTAssertTrue(
      AutomationPlanner.interfaceIDsToQueue(
        for: .networkChange,
        settings: AutomationSettings(),
        previous: [active.id: active],
        current: current
      ).isEmpty
    )
  }

  func testSecurePayloadRoundTripsSnapshotWithMillisecondDates() throws {
    let snapshot = DaemonSnapshot(
      revision: 42,
      instanceID: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
      heartbeat: Date(timeIntervalSince1970: 1_700_000_000.125),
      interfaces: [
        interfaceSnapshot(name: "en7", kind: .ethernet, active: false, defaultRoute: false)
      ],
      pendingOperationIDs: [],
      lastError: nil
    )

    let payload = try MDSecurePayload(snapshot)
    let archived = try NSKeyedArchiver.archivedData(
      withRootObject: payload,
      requiringSecureCoding: true
    )
    let restoredPayload = try XCTUnwrap(
      NSKeyedUnarchiver.unarchivedObject(ofClass: MDSecurePayload.self, from: archived)
    )
    let decoded = try restoredPayload.decode(DaemonSnapshot.self)

    XCTAssertEqual(decoded, snapshot)
  }

  func testXPCObjectiveCRuntimeNamesAreStableAcrossSwiftModules() {
    // Shared is compiled once into the GUI module and once into the daemon
    // module. These names must not contain either Swift module name, because
    // NSXPC compares the complete Objective-C reply-block signature.
    XCTAssertEqual(NSStringFromClass(MDSecurePayload.self), "MACDancerSecurePayload")
    XCTAssertEqual(
      NSStringFromProtocol(MACDancerClientProtocol.self),
      "MACDancerClientXPCProtocol"
    )
    XCTAssertEqual(
      NSStringFromProtocol(MACDancerDaemonProtocol.self),
      "MACDancerDaemonXPCProtocol"
    )
  }

  func testSecurePayloadRejectsIncompatibleProtocolVersion() throws {
    let payload = MDSecurePayload(
      data: Data("{}".utf8),
      protocolVersion: MACDancerConstants.protocolVersion + 1
    )

    XCTAssertThrowsError(try payload.decode(ConfigurationDocument.self)) { error in
      XCTAssertEqual(
        error as? MACDancerError,
        .incompatibleProtocol(
          expected: MACDancerConstants.protocolVersion,
          actual: MACDancerConstants.protocolVersion + 1
        )
      )
    }
  }

  func testRestoreRequestPreservesExplicitGlobalAddressConfirmation() throws {
    let request = RestoreRequest(
      interfaceID: "fixture-global",
      kind: .specified,
      targetAddress: try address("00:11:22:33:44:66"),
      confirmedDisruption: true,
      confirmedGlobalAddressRisk: true
    )

    let decoded = try MDSecurePayload(request).decode(RestoreRequest.self)
    XCTAssertEqual(decoded, request)
    XCTAssertTrue(decoded.confirmedGlobalAddressRisk)
  }

  func testAnonymousXPCListenerRoundTripsVersionedSecurePayload() throws {
    let listener = NSXPCListener.anonymous()
    let delegate = TestPayloadEchoDelegate()
    listener.delegate = delegate
    listener.activate()
    defer { listener.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = TestPayloadEchoDelegate.interface()
    connection.activate()
    defer { connection.invalidate() }

    let request = OperationEnvelope(
      operationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      request: PolicyRequest(interfaceID: "en8", policy: .random)
    )
    let payload = try MDSecurePayload(request)
    let expectation = expectation(description: "anonymous XPC reply")
    var decoded: OperationEnvelope<PolicyRequest>?
    var replyError: Error?

    let proxy = try XCTUnwrap(
      connection.remoteObjectProxyWithErrorHandler { error in
        replyError = error
        expectation.fulfill()
      } as? TestPayloadEchoProtocol
    )
    proxy.echo(payload) { reply, error in
      defer { expectation.fulfill() }
      if let error {
        replyError = error
        return
      }
      do {
        decoded = try XCTUnwrap(reply).decode(OperationEnvelope<PolicyRequest>.self)
      } catch {
        replyError = error
      }
    }

    wait(for: [expectation], timeout: 2)
    XCTAssertNil(replyError)
    XCTAssertEqual(decoded?.operationID, request.operationID)
    XCTAssertEqual(decoded?.request, request.request)
  }

  func testAnonymousXPCListenerPreservesUserFacingDaemonError() throws {
    let listener = NSXPCListener.anonymous()
    let delegate = TestPayloadEchoDelegate()
    listener.delegate = delegate
    listener.activate()
    defer { listener.invalidate() }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = TestPayloadEchoDelegate.interface()
    connection.activate()
    defer { connection.invalidate() }

    let expectation = expectation(description: "anonymous XPC error reply")
    var receivedError: NSError?
    let proxy = try XCTUnwrap(
      connection.remoteObjectProxyWithErrorHandler { error in
        receivedError = error as NSError
        expectation.fulfill()
      } as? TestPayloadEchoProtocol
    )
    proxy.fail { error in
      receivedError = error
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 2)
    let error = try XCTUnwrap(receivedError)
    XCTAssertEqual(error.domain, MACDancerConstants.appIdentifier)
    XCTAssertEqual(error.code, MACDancerError.associatedWiFiWriteRejected.xpcErrorCode)
    XCTAssertEqual(
      error.userInfo[MACDancerConstants.errorKindUserInfoKey] as? String,
      MACDancerRemoteErrorKind.associatedWiFiWriteRejected.rawValue
    )
    XCTAssertEqual(
      error.localizedDescription,
      MACDancerError.associatedWiFiWriteRejected.localizedDescription
    )
  }

  func testSnapshotRevisionTrackerRejectsOldSameInstanceAndAcceptsRestart() {
    let firstID = UUID()
    let secondID = UUID()
    var tracker = SnapshotRevisionTracker()

    XCTAssertTrue(tracker.accepts(snapshot(instanceID: firstID, revision: 5)))
    XCTAssertFalse(tracker.accepts(snapshot(instanceID: firstID, revision: 4)))
    XCTAssertTrue(tracker.accepts(snapshot(instanceID: firstID, revision: 5)))
    XCTAssertTrue(tracker.accepts(snapshot(instanceID: secondID, revision: 0)))
    XCTAssertFalse(tracker.accepts(snapshot(instanceID: firstID, revision: 6)))
    XCTAssertEqual(tracker.instanceID, secondID)
    XCTAssertEqual(tracker.revision, 0)
  }

  func testConfigurationDecodingDefaultsNewAutomationFields() throws {
    let legacyFixture = Data(#"{"policies":{},"histories":{},"pendingOperations":[]}"#.utf8)
    let document = try JSONDecoder().decode(ConfigurationDocument.self, from: legacyFixture)
    XCTAssertEqual(document.automation, AutomationSettings())
  }

  func testLegacyPendingOperationDecodingDefaultsMissingDeviceKey() throws {
    let fixture = Data(#"""
    {
      "id":"11111111-2222-3333-4444-555555555555",
      "interfaceID":"fixture-legacy",
      "kind":"randomize",
      "state":"pending",
      "requestedAddress":null,
      "observedAddress":"02:00:00:00:00:01",
      "startedAt":0,
      "completedAt":null,
      "message":"legacy"
    }
    """#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let operation = try decoder.decode(OperationResult.self, from: fixture)
    XCTAssertNil(operation.deviceKey)
  }

  func testConfigurationDocumentFixtureRoundTripsWithoutPersistenceAdapter() throws {
    let managedAddress = try address("02:00:00:00:00:77")
    var history = HistoryLedger()
    history.record(historyEntry(address: managedAddress, at: 7))
    let document = ConfigurationDocument(
      policies: ["en7": .specified(managedAddress)],
      histories: ["en7": history],
      pendingOperations: [],
      automation: AutomationSettings(
        rotateAfterWake: true,
        rotateWhenInterfaceBecomesInactive: false,
        prepareRotationBeforeSleep: true,
        vendorCompatibility: false
      )
    )

    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(ConfigurationDocument.self, from: encoded)

    XCTAssertEqual(decoded, document)
  }

  func testConfigurationStoreAtomicallyRoundTripsAndPreservesDataAcrossInstances() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MACDancerStoreTests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("configuration.json")
    defer { try? FileManager.default.removeItem(at: root) }

    let managedAddress = try address("02:00:00:00:00:88")
    var history = HistoryLedger()
    history.record(historyEntry(address: managedAddress, at: 88))
    let expected = ConfigurationDocument(
      policies: ["en8": .specified(managedAddress)],
      histories: ["en8": history],
      pendingOperations: [],
      automation: AutomationSettings(rotateAfterWake: true)
    )

    try ConfigurationStore(fileURL: fileURL).save(expected)
    XCTAssertEqual(
      try ConfigurationStore(fileURL: fileURL).load(ConfigurationDocument.self),
      expected
    )

    let fileMode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    let directoryMode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    XCTAssertEqual(fileMode, 0o600)
    XCTAssertEqual(directoryMode, 0o700)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") }
    )
  }

  func testMACSetterReportsSuccessOnlyAfterMatchingReadback() throws {
    let target = try address("02:aa:bb:cc:dd:ee")
    let executor = StubCommandExecutor(result: CommandResult(
      exitCode: 0,
      standardOutput: "",
      standardError: ""
    ))
    let provider = StubReadOnlyInterfaceProvider(snapshots: [], observedMAC: target)
    let setter = MACSetter(commandExecutor: executor, interfaceProvider: provider)

    XCTAssertEqual(
      setter.apply(interfaceID: "fixture0", targetAddress: target),
      .success(interfaceID: "fixture0", requested: target, observed: target)
    )
    XCTAssertEqual(executor.invocations.count, 1)
    XCTAssertEqual(executor.invocations.first?.arguments, ["fixture0", "ether", target.stringValue])
  }

  func testMACSetterRejectsCommandFailureAndReadbackMismatch() throws {
    let target = try address("02:10:20:30:40:50")
    let different = try address("02:10:20:30:40:51")
    let rejectedExecutor = StubCommandExecutor(result: CommandResult(
      exitCode: 1,
      standardOutput: "",
      standardError: "driver rejected fixture request"
    ))
    let matchingProvider = StubReadOnlyInterfaceProvider(snapshots: [], observedMAC: target)

    XCTAssertEqual(
      MACSetter(commandExecutor: rejectedExecutor, interfaceProvider: matchingProvider)
        .apply(interfaceID: "fixture1", targetAddress: target),
      .failure(
        interfaceID: "fixture1",
        requested: target,
        reason: .commandRejected(exitCode: 1, standardError: "driver rejected fixture request")
      )
    )

    let acceptedExecutor = StubCommandExecutor(result: CommandResult(
      exitCode: 0,
      standardOutput: "",
      standardError: ""
    ))
    let mismatchProvider = StubReadOnlyInterfaceProvider(snapshots: [], observedMAC: different)
    XCTAssertEqual(
      MACSetter(commandExecutor: acceptedExecutor, interfaceProvider: mismatchProvider)
        .apply(interfaceID: "fixture2", targetAddress: target),
      .mismatch(interfaceID: "fixture2", requested: target, observed: different)
    )
  }

  private func address(_ value: String) throws -> MACAddress {
    try XCTUnwrap(MACAddress(value))
  }

  private func address(number: Int) throws -> MACAddress {
    try address(String(format: "02:00:00:00:%02x:%02x", number >> 8, number & 0xff))
  }

  private func historyEntry(address: MACAddress, at second: Int) -> HistoryEntry {
    let timestamp = Date(timeIntervalSince1970: TimeInterval(second))
    return HistoryEntry(
      address: address,
      source: .generatedLocal,
      firstUsedAt: timestamp,
      lastUsedAt: timestamp,
      operation: .randomize
    )
  }

  private func interfaceSnapshot(
    name: String,
    kind: InterfaceKind,
    active: Bool,
    defaultRoute: Bool
  ) -> InterfaceSnapshot {
    InterfaceSnapshot(
      bsdName: name,
      displayName: name,
      kind: kind,
      currentMAC: try? address("02:00:00:00:00:01"),
      hardwareMAC: try? address("00:11:22:33:44:55"),
      isActive: active,
      isWiFiAssociated: kind == .wifi && active,
      isDefaultRoute: defaultRoute,
      policy: .random,
      history: HistoryLedger(),
      lastOperation: nil,
      errorMessage: nil
    )
  }

  private func snapshot(instanceID: UUID, revision: UInt64) -> DaemonSnapshot {
    DaemonSnapshot(
      revision: revision,
      instanceID: instanceID,
      heartbeat: Date(),
      interfaces: [],
      pendingOperationIDs: [],
      automation: AutomationSettings(),
      lastError: nil
    )
  }

  @MainActor
  private func waitForRefresh(_ model: AppModel) async throws {
    for _ in 0..<200 {
      if !model.isRefreshing { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out waiting for the fake read-only refresh.")
  }
}
