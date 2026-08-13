import Combine
import Foundation

let MACDancerLanguagePreferenceKey = "preferredLanguage"
let MACDancerMenuBarIconPreferenceKey = "showMenuBarIcon"

enum AppSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case dashboard
  case interfaces
  case automation
  case settings

  var id: String { rawValue }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case english
  case simplifiedChinese

  var id: String { rawValue }
}

enum DaemonLifecycleState: String, Equatable, Sendable {
  case checking
  case notInstalled
  case awaitingApproval
  case ready
  case unavailable
}

struct AppAlert: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let message: String

  init(title: String, message: String) {
    id = UUID()
    self.title = title
    self.message = message
  }
}

enum RecoverySheet: Identifiable, Equatable, Sendable {
  case randomize(interfaceID: String)
  case handoff(interfaceID: String)
  case hardware(interfaceID: String)
  case history(interfaceID: String, address: String)
  case specified(interfaceID: String)

  var id: String {
    switch self {
    case let .randomize(interfaceID): "randomize-\(interfaceID)"
    case let .handoff(interfaceID): "handoff-\(interfaceID)"
    case let .hardware(interfaceID): "hardware-\(interfaceID)"
    case let .history(interfaceID, address): "history-\(interfaceID)-\(address)"
    case let .specified(interfaceID): "specified-\(interfaceID)"
    }
  }
}

/// GUI state and the only application-facing entry point for daemon actions.
///
/// Interface Refresh is intentionally owned by `ReadOnlyRefreshController`
/// and is entirely independent from this daemon client.  A stopped daemon can
/// therefore never make the visible MAC address stale after a local refresh.
@MainActor
final class AppModel: ObservableObject {
  @Published var selection: AppSection = .dashboard
  @Published var preferredLanguage: AppLanguage {
    didSet { UserDefaults.standard.set(preferredLanguage.rawValue, forKey: MACDancerLanguagePreferenceKey) }
  }

  @Published private(set) var interfaces: [InterfaceSnapshot] = []
  @Published private(set) var snapshot: DaemonSnapshot?
  @Published private(set) var daemonState: DaemonLifecycleState = .checking
  @Published private(set) var daemonRegistration: DaemonRegistrationState = .unknown
  @Published private(set) var daemonReachability: DaemonReachability = .unknown
  @Published private(set) var daemonHealth: DaemonHealth = .unknown
  @Published private(set) var daemonVersion: Int?
  @Published private(set) var daemonDiagnostic: String?
  @Published private(set) var legacyLinkLiarDetected = false
  @Published private(set) var automationSettings = AutomationSettings()

  @Published private(set) var refreshGeneration: UInt64 = 0
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastRefreshAt: Date?
  @Published private(set) var activeOperationInterfaceIDs: Set<String> = []
  @Published private(set) var isUpdatingAutomation = false

  @Published var alert: AppAlert?
  @Published private(set) var alerts: [AppAlert] = []
  @Published var presentedRecovery: RecoverySheet?

  private let readOnlyRefreshController: ReadOnlyRefreshController
  private let daemonClient: any DaemonClientProviding
  private let serviceController: any DaemonServiceProviding
  private var isConfigured = false
  private var refreshTask: Task<Void, Never>?
  private var refreshRequestedWhileInFlight = false
  private var serviceRefreshTask: Task<Void, Never>?
  private var serviceRefreshGeneration: UInt64 = 0
  private var legacyDetectionCompleted = false
  private var snapshotTracker = SnapshotRevisionTracker()

#if !MACDANCER_CORE_TESTS
  init() {
    preferredLanguage = AppLanguage(
      rawValue: UserDefaults.standard.string(forKey: MACDancerLanguagePreferenceKey) ?? ""
    ) ?? .system
    readOnlyRefreshController = ReadOnlyRefreshController()
    daemonClient = DaemonClient()
    serviceController = DaemonServiceController()
  }
#endif

  init(
    readOnlyRefreshController: ReadOnlyRefreshController,
    daemonClient: any DaemonClientProviding,
    serviceController: any DaemonServiceProviding
  ) {
    preferredLanguage = AppLanguage(
      rawValue: UserDefaults.standard.string(forKey: MACDancerLanguagePreferenceKey) ?? ""
    ) ?? .system
    self.readOnlyRefreshController = readOnlyRefreshController
    self.daemonClient = daemonClient
    self.serviceController = serviceController
  }

  private func configure() {
    guard !isConfigured else { return }
    isConfigured = true
    daemonClient.onSnapshot = { [weak self] snapshot in
      self?.applyDaemonSnapshot(snapshot)
    }
    daemonClient.onStatusChange = { [weak self] status in
      self?.applyDaemonStatus(status)
    }

    applyCachedServiceState()
    refreshServiceState()
    // Construction and the first rendered frame stay independent from XPC.
    // The client starts only after ServiceManagement reports an enabled
    // service and the legacy-daemon safety check completes.
    refresh()
  }

  /// The window lifecycle starts production explicitly. Tests with injected
  /// adapters can inspect the inert model first.
  func start() {
    configure()
  }

  func selectSection(_ section: AppSection) {
    guard selection != section else { return }
    selection = section
  }

  /// Starts a single local system read.  It does not call `DaemonClient`, send
  /// XPC, scan Wi-Fi, write configuration, or ask macOS to reconnect.
  func refresh() {
    guard refreshTask == nil else {
      refreshRequestedWhileInFlight = true
      return
    }
    isRefreshing = true
    refreshGeneration &+= 1
    let requestedGeneration = refreshGeneration

    refreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.readOnlyRefreshController.refresh()
      if requestedGeneration == self.refreshGeneration {
        self.lastRefreshAt = result.completedAt
        if let errorDescription = result.errorDescription {
          self.presentAlert(title: "Unable to read interfaces", message: errorDescription)
        } else {
          self.interfaces = self.mergingLocalInterfaces(result.interfaces, with: self.snapshot)
        }
      }

      self.refreshTask = nil
      self.isRefreshing = false
      if self.refreshRequestedWhileInFlight {
        self.refreshRequestedWhileInFlight = false
        self.refresh()
      }
    }
  }

  func installDaemon() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.invalidateServiceRefresh()
      do {
        try await self.serviceController.install()
        self.applyCachedServiceState(legacyCheckCompleted: true)
        self.startDaemonClientIfEligible()
      } catch {
        self.presentAlert(title: "Unable to install background service", message: error.localizedDescription)
        self.applyCachedServiceState(legacyCheckCompleted: true)
      }
    }
  }

  func uninstallDaemon() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.invalidateServiceRefresh()
      do {
        // Deliberately does not restore any MAC or remove daemon configuration.
        try await self.serviceController.uninstall()
        self.daemonClient.stop()
        self.applyCachedServiceState()
      } catch {
        self.presentAlert(title: "Unable to uninstall background service", message: error.localizedDescription)
        self.applyCachedServiceState()
      }
    }
  }

  func repairDaemon() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.invalidateServiceRefresh()
      do {
        try await self.serviceController.repair()
        self.applyCachedServiceState(legacyCheckCompleted: true)
        self.startDaemonClientIfEligible()
      } catch {
        self.presentAlert(title: "Unable to repair background service", message: error.localizedDescription)
        self.applyCachedServiceState(legacyCheckCompleted: true)
      }
    }
  }

  func openApprovalSettings() {
    serviceController.openApprovalSettings()
  }

  func openSystemSettings() {
    openApprovalSettings()
  }

  func openSettings() {
    selectSection(.settings)
  }

  /// The calling UI presents its confirmation dialog before invoking this
  /// method for active/default-route interfaces.  Callers that need a
  /// programmatic safety gate should use the overload with an explicit flag.
  func randomize(interface: InterfaceSnapshot) {
    randomize(
      interface: interface,
      confirmedDisruption: interface.isActive || interface.isDefaultRoute
    )
  }

  func randomize(interface: InterfaceSnapshot, confirmedDisruption: Bool) {
    guard ensureDaemonReadyForMutation() else { return }
    switch SafetyPolicy.decision(
      for: interface,
      automatic: false,
      confirmedDisruption: confirmedDisruption
    ) {
    case .allowed:
      let request = RandomizeRequest(
        interfaceID: interface.id,
        confirmedDisruption: confirmedDisruption,
        vendorOUI: nil
      )
      submit("Randomize MAC", interfaceID: interface.id) { [daemonClient] in
        try await daemonClient.randomize(request)
      }
    case let .denied(reason):
      presentedRecovery = .randomize(interfaceID: interface.id)
      presentAlert(title: "Confirmation required", message: reason)
    case let .deferred(reason):
      presentAlert(title: "MAC change deferred", message: reason)
    }
  }

  func setPolicy(_ request: PolicyRequest) {
    guard ensureDaemonReadyForMutation(allowSystemManaged: request.policy == .systemManaged) else { return }
    submit("Update interface policy", interfaceID: request.interfaceID, crossCheck: false) { [daemonClient] in
      try await daemonClient.setPolicy(request)
    }
  }

  func setPolicy(interfaceID: String, policy: InterfacePolicy) {
    setPolicy(PolicyRequest(interfaceID: interfaceID, policy: policy))
  }

  /// Handoff never attempts to program macOS Private Wi-Fi Address.  It first
  /// cancels MACDancer work for the interface, then makes the daemon stop
  /// managing that interface.
  func handoff(interfaceID: String, completion: (@MainActor () -> Void)? = nil) {
    presentedRecovery = nil
    guard ensureDaemonReadyForMutation(allowSystemManaged: true) else { return }
    guard !activeOperationInterfaceIDs.contains(interfaceID) else {
      presentAlert(
        title: "Operation already in progress",
        message: "Wait for the current verified result before handing off this interface."
      )
      return
    }
    activeOperationInterfaceIDs.insert(interfaceID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.activeOperationInterfaceIDs.remove(interfaceID) }
      do {
        self.applyDaemonSnapshot(try await self.daemonClient.restore(RestoreRequest(
          interfaceID: interfaceID,
          kind: .systemManaged,
          targetAddress: nil,
          confirmedDisruption: false
        )))
        self.refresh()
        completion?()
      } catch {
        self.presentAlert(title: "Unable to hand off interface", message: error.localizedDescription)
      }
    }
  }

  func restore(_ request: RestoreRequest) {
    guard ensureDaemonReadyForMutation(allowSystemManaged: request.kind == .systemManaged) else { return }
    submit("Restore MAC", interfaceID: request.interfaceID) { [daemonClient] in
      try await daemonClient.restore(request)
    }
  }

  func restoreHardware(interfaceID: String, confirmed: Bool) {
    guard let interface = interfaces.first(where: { $0.id == interfaceID }) else {
      presentAlert(title: "Interface unavailable", message: "The selected network interface is no longer available.")
      return
    }
    guard interface.hardwareMAC != nil else {
      presentAlert(title: "Hardware MAC unavailable", message: "macOS did not report a hardware MAC address for this interface.")
      return
    }
    let changesAddress = interface.currentMAC != interface.hardwareMAC
    guard confirmed || !changesAddress || !(interface.isActive || interface.isDefaultRoute) else {
      presentedRecovery = .hardware(interfaceID: interfaceID)
      return
    }
    restore(RestoreRequest(
      interfaceID: interfaceID,
      kind: .hardware,
      targetAddress: nil,
      confirmedDisruption: confirmed
    ))
  }

  func restoreHistory(interfaceID: String, address: String, confirmed: Bool) {
    guard let interface = interfaces.first(where: { $0.id == interfaceID }),
          let target = MACAddress(address),
          interface.history.entries.contains(where: { $0.address == target }) else {
      presentAlert(title: "History entry unavailable", message: "This address is not in the selected interface's saved history.")
      return
    }
    guard target.isValidAssignable else {
      presentAlert(title: "Invalid MAC address", message: "The selected history entry is not a valid unicast MAC address.")
      return
    }
    let changesAddress = interface.currentMAC != target
    guard confirmed || !changesAddress || !(interface.isActive || interface.isDefaultRoute) else {
      presentedRecovery = .history(interfaceID: interfaceID, address: address)
      return
    }
    restore(RestoreRequest(
      interfaceID: interfaceID,
      kind: .history,
      targetAddress: target,
      confirmedDisruption: confirmed
    ))
  }

  func restoreSpecified(
    interfaceID: String,
    address: String,
    confirmed: Bool,
    confirmedGlobalAddressRisk: Bool
  ) {
    guard let interface = interfaces.first(where: { $0.id == interfaceID }) else {
      presentAlert(title: "Interface unavailable", message: "The selected network interface is no longer available.")
      return
    }
    guard let target = MACAddress(address), target.isValidAssignable else {
      presentAlert(title: "Invalid MAC address", message: "Enter a valid unicast, non-zero 48-bit MAC address.")
      return
    }
    guard target.isLocallyAdministered || confirmedGlobalAddressRisk else {
      presentAlert(
        title: "Additional confirmation required",
        message: "A globally administered specified address can impersonate another device identity. Confirm that risk before continuing."
      )
      return
    }
    let changesAddress = interface.currentMAC != target
    guard confirmed || !changesAddress || !(interface.isActive || interface.isDefaultRoute) else {
      presentedRecovery = .specified(interfaceID: interfaceID)
      return
    }
    restore(RestoreRequest(
      interfaceID: interfaceID,
      kind: .specified,
      targetAddress: target,
      confirmedDisruption: confirmed,
      confirmedGlobalAddressRisk: confirmedGlobalAddressRisk
    ))
  }

  func cancel(interfaceID: String? = nil) {
    guard ensureDaemonReadyForMutation(allowSystemManaged: true) else { return }
    submit("Cancel pending operation", crossCheck: false) { [daemonClient] in
      try await daemonClient.cancel(CancelRequest(interfaceID: interfaceID))
    }
  }

  func removeHistory(interfaceID: String, address: MACAddress) {
    guard ensureDaemonReadyForMutation(allowSystemManaged: true) else { return }
    submit("Remove history entry", crossCheck: false) { [daemonClient] in
      try await daemonClient.updateHistory(HistoryMutationRequest(
        interfaceID: interfaceID,
        kind: .remove,
        address: address
      ))
    }
  }

  func clearHistory(interfaceID: String) {
    guard ensureDaemonReadyForMutation(allowSystemManaged: true) else { return }
    submit("Clear interface history", crossCheck: false) { [daemonClient] in
      try await daemonClient.updateHistory(HistoryMutationRequest(
        interfaceID: interfaceID,
        kind: .clear,
        address: nil
      ))
    }
  }

  func updateAutomation(_ settings: AutomationSettings) {
    guard !isUpdatingAutomation else { return }
    let enablesManagedBehavior = settings.rotateAfterWake
      || settings.rotateWhenInterfaceBecomesInactive
      || settings.prepareRotationBeforeSleep
      || settings.vendorCompatibility
    guard ensureDaemonReadyForMutation(allowSystemManaged: !enablesManagedBehavior) else { return }

    let previous = automationSettings
    automationSettings = settings
    isUpdatingAutomation = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isUpdatingAutomation = false }
      do {
        self.applyDaemonSnapshot(try await self.daemonClient.updateAutomation(
          AutomationRequest(settings: settings)
        ))
      } catch {
        self.automationSettings = previous
        self.presentAlert(title: "Unable to update automation", message: error.localizedDescription)
      }
    }
  }

  private func submit(
    _ title: String,
    interfaceID: String? = nil,
    crossCheck: Bool = true,
    operation: @escaping @MainActor () async throws -> DaemonSnapshot
  ) {
    if let interfaceID, activeOperationInterfaceIDs.contains(interfaceID) {
      presentAlert(
        title: "Operation already in progress",
        message: "Wait for the current verified result before requesting another MAC operation on this interface."
      )
      return
    }
    if let interfaceID { activeOperationInterfaceIDs.insert(interfaceID) }
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if let interfaceID { self.activeOperationInterfaceIDs.remove(interfaceID) }
      }
      do {
        self.applyDaemonSnapshot(try await operation())
        if crossCheck { self.refresh() }
      } catch {
        self.presentOperationError(fallbackTitle: title, error: error)
      }
    }
  }

  func isOperationInProgress(interfaceID: String) -> Bool {
    activeOperationInterfaceIDs.contains(interfaceID)
  }

  private func ensureNoLegacyConflict(allowSystemManaged: Bool = false) -> Bool {
    applyCachedServiceState()
    guard legacyDetectionCompleted || allowSystemManaged else {
      presentAlert(
        title: "Safety check in progress",
        message: "Wait for MACDancer to finish checking for the legacy LinkLiar service before changing a MAC address."
      )
      return false
    }
    guard !legacyLinkLiarDetected || allowSystemManaged else {
      presentAlert(
        title: "Legacy LinkLiar service detected",
        message: "MACDancer will not change a MAC or enable automatic policies while LinkLiar's legacy daemon is installed. Disable or remove the legacy service first."
      )
      return false
    }
    return true
  }

  private func ensureDaemonReadyForMutation(allowSystemManaged: Bool = false) -> Bool {
    guard ensureNoLegacyConflict(allowSystemManaged: allowSystemManaged) else { return false }
    guard daemonRegistration == .enabled else {
      presentAlert(
        title: "Background service required",
        message: daemonRegistration == .requiresApproval
          ? "Approve the MACDancer background service in System Settings before continuing."
          : "Install the MACDancer background service from the Dashboard before continuing."
      )
      return false
    }
    guard daemonReachability == .reachable, daemonHealth == .healthy else {
      presentAlert(
        title: "Background service unavailable",
        message: "The service is installed but is not currently healthy and reachable. Repair it from the Dashboard before continuing."
      )
      return false
    }
    return true
  }

  private func applyCachedServiceState(legacyCheckCompleted: Bool = false) {
    daemonRegistration = serviceController.registrationState
    legacyLinkLiarDetected = serviceController.legacyLinkLiarDetected
    if legacyCheckCompleted { legacyDetectionCompleted = true }
    deriveDaemonLifecycleState()
  }

  /// ServiceManagement and legacy launchd inspection can both block. Their
  /// implementations perform those reads off MainActor and return snapshots
  /// that are cached for all subsequent XPC status callbacks.
  private func refreshServiceState() {
    guard serviceRefreshTask == nil else { return }
    serviceRefreshGeneration &+= 1
    let generation = serviceRefreshGeneration
    serviceRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let registration = await self.serviceController.refreshRegistrationState()
      guard !Task.isCancelled, generation == self.serviceRefreshGeneration else { return }
      self.daemonRegistration = registration
      let detected = await self.serviceController.refreshLegacyLinkLiarDetection()
      guard !Task.isCancelled, generation == self.serviceRefreshGeneration else { return }
      self.legacyLinkLiarDetected = detected
      self.legacyDetectionCompleted = true
      self.deriveDaemonLifecycleState()
      self.startDaemonClientIfEligible()
      self.serviceRefreshTask = nil
    }
  }

  private func invalidateServiceRefresh() {
    serviceRefreshGeneration &+= 1
    serviceRefreshTask?.cancel()
    serviceRefreshTask = nil
  }

  private func startDaemonClientIfEligible() {
    guard daemonRegistration == .enabled,
          legacyDetectionCompleted,
          !legacyLinkLiarDetected else { return }
    daemonClient.start()
  }

  private func applyDaemonStatus(_ status: DaemonClientStatus) {
    daemonReachability = status.reachability
    daemonHealth = status.health
    daemonVersion = status.version
    daemonDiagnostic = status.diagnostic
    // Service state values are cached; XPC reconnects never synchronously
    // invoke ServiceManagement or launchctl on MainActor.
    daemonRegistration = serviceController.registrationState
    legacyLinkLiarDetected = serviceController.legacyLinkLiarDetected
    deriveDaemonLifecycleState()
  }

  private func applyDaemonSnapshot(_ incoming: DaemonSnapshot) {
    guard incoming.protocolVersion == MACDancerConstants.protocolVersion else {
      daemonHealth = .incompatible
      daemonVersion = incoming.protocolVersion
      daemonDiagnostic = MACDancerError.incompatibleProtocol(
        expected: MACDancerConstants.protocolVersion,
        actual: incoming.protocolVersion
      ).localizedDescription
      deriveDaemonLifecycleState()
      return
    }

    guard snapshotTracker.accepts(incoming) else { return }
    snapshot = incoming
    automationSettings = incoming.automation
    daemonReachability = .reachable
    daemonVersion = incoming.protocolVersion
    daemonHealth = Date().timeIntervalSince(incoming.heartbeat) > 60
      ? .stale
      : (incoming.lastError == nil ? .healthy : .unhealthy)
    daemonDiagnostic = incoming.lastError
    daemonRegistration = serviceController.registrationState
    legacyLinkLiarDetected = serviceController.legacyLinkLiarDetected
    // A daemon snapshot following a successful command contains the daemon's
    // verified read-back value.  Prefer it immediately so "Randomize now"
    // updates the visible address without waiting for another manual refresh.
    interfaces = mergingDaemonInterfaces(incoming.interfaces, into: interfaces)
    deriveDaemonLifecycleState()
  }

  private func mergingLocalInterfaces(
    _ localInterfaces: [InterfaceSnapshot],
    with daemonSnapshot: DaemonSnapshot?
  ) -> [InterfaceSnapshot] {
    guard let daemonSnapshot else { return localInterfaces }
    let daemonInterfaces = Dictionary(uniqueKeysWithValues: daemonSnapshot.interfaces.map { ($0.id, $0) })
    var merged = localInterfaces.map { local in
      guard let daemon = daemonInterfaces[local.id] else { return local }
      var result = local
      result.policy = daemon.policy
      result.history = daemon.history
      result.lastOperation = daemon.lastOperation
      result.errorMessage = daemon.errorMessage ?? local.errorMessage
      if daemon.hardwareMAC != nil { result.hardwareMAC = daemon.hardwareMAC }
      return result
    }

    // Before the first local read, daemon data is useful as a provisional UI
    // snapshot.  Once local data exists, never let a daemon-only interface
    // overwrite current values obtained from macOS.
    if localInterfaces.isEmpty {
      merged = daemonSnapshot.interfaces
    }
    return merged.sorted { $0.id < $1.id }
  }

  private func mergingDaemonInterfaces(
    _ daemonInterfaces: [InterfaceSnapshot],
    into visibleInterfaces: [InterfaceSnapshot]
  ) -> [InterfaceSnapshot] {
    guard !visibleInterfaces.isEmpty else {
      return daemonInterfaces.sorted { $0.id < $1.id }
    }

    let daemonByID = Dictionary(uniqueKeysWithValues: daemonInterfaces.map { ($0.id, $0) })
    var merged = visibleInterfaces.map { visible in
      guard let daemon = daemonByID[visible.id] else { return visible }
      var result = visible
      // The daemon reply is authoritative for a just-completed, verified MAC
      // write. Keep locally read topology/activity facts because they may be
      // newer than the daemon's last reconciliation.
      result.currentMAC = daemon.currentMAC
      if daemon.hardwareMAC != nil { result.hardwareMAC = daemon.hardwareMAC }
      result.policy = daemon.policy
      result.history = daemon.history
      result.lastOperation = daemon.lastOperation
      result.errorMessage = daemon.errorMessage ?? visible.errorMessage
      return result
    }
    let visibleIDs = Set(visibleInterfaces.map(\.id))
    merged.append(contentsOf: daemonInterfaces.filter { !visibleIDs.contains($0.id) })
    return merged.sorted { $0.id < $1.id }
  }

  private func deriveDaemonLifecycleState() {
    guard legacyDetectionCompleted else {
      daemonState = .checking
      return
    }
    if legacyLinkLiarDetected {
      daemonState = .unavailable
      return
    }
    switch daemonRegistration {
    case .notInstalled, .notFound:
      daemonState = .notInstalled
    case .requiresApproval:
      daemonState = .awaitingApproval
    case .enabled:
      daemonState = daemonReachability == .reachable && daemonHealth == .healthy ? .ready : .unavailable
    case .unknown:
      daemonState = .checking
    }
  }

  private func presentAlert(title: String, message: String) {
    let newAlert = AppAlert(title: title, message: message)
    alert = newAlert
    alerts.append(newAlert)
    if alerts.count > 12 {
      alerts.removeFirst(alerts.count - 12)
    }
  }

  private func presentOperationError(fallbackTitle: String, error: Error) {
    let nsError = error as NSError
    let kind = nsError.userInfo[MACDancerConstants.errorKindUserInfoKey] as? String
    guard kind == MACDancerRemoteErrorKind.associatedWiFiWriteRejected.rawValue else {
      presentAlert(title: fallbackTitle, message: error.localizedDescription)
      return
    }
    presentAlert(
      title: localizedAppString(
        "error.wifi_associated_write_rejected.title",
        "Unable to change the MAC while Wi-Fi is connected"
      ),
      message: localizedAppString(
        "error.wifi_associated_write_rejected.message",
        "macOS or the Wi-Fi driver did not accept the MAC change while this network is connected. MACDancer did not disconnect or reconnect Wi-Fi. Disconnect Wi-Fi, wait until the interface is no longer associated, then try again."
      )
    )
  }

  private func localizedAppString(_ key: String, _ defaultValue: String) -> String {
    switch preferredLanguage {
    case .english:
      defaultValue
    case .simplifiedChinese:
      if let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
         let bundle = Bundle(path: path) {
        bundle.localizedString(forKey: key, value: defaultValue, table: nil)
      } else {
        defaultValue
      }
    case .system:
      Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }
  }
}
