import Foundation

final class DaemonCoordinator: @unchecked Sendable {
  private let queue = DispatchQueue(label: "local.macdancer.MACDancer.daemon.coordinator")
  private let interfaceProvider: any ReadOnlyInterfaceProviding
  private let setter: MACSetter
  private let store: ConfigurationStore
  private let instanceID = UUID()
  private var configuration: ConfigurationDocument
  private var interfacesByID: [String: InterfaceSnapshot] = [:]
  private var revision: UInt64 = 0
  private var lastError: String?
  private var persistentFault: String?
  private var subscribers: [UUID: (DaemonSnapshot) -> Void] = [:]
  private var completedOperations: [UUID: OperationResult] = [:]
  private var pendingAutomaticInterfaces: Set<String> = []
  private var healthTimer: DispatchSourceTimer?

  init(
    interfaceProvider: any ReadOnlyInterfaceProviding = SystemReadOnlyInterfaceProvider(),
    setter: MACSetter? = nil,
    store: ConfigurationStore = ConfigurationStore()
  ) {
    self.interfaceProvider = interfaceProvider
    self.setter = setter ?? MACSetter(interfaceProvider: interfaceProvider)
    self.store = store
    do {
      configuration = try store.loadOrCreateDocument()
    } catch {
      configuration = ConfigurationDocument()
      persistentFault = "Configuration load failed: \(error.localizedDescription)"
    }
    queue.sync { reconcileLocked(reason: "daemon startup") }
    let pendingCountBeforeValidation = configuration.pendingOperations.count
    pendingAutomaticInterfaces = Set(
      configuration.pendingOperations
        .filter { $0.state == .pending || $0.state == .deferred }
        .compactMap { operation in
          guard let interface = interfacesByID[operation.interfaceID],
                operation.deviceKey == configurationKey(for: interface) else { return nil }
          return operation.interfaceID
        }
    )
    configuration.pendingOperations.removeAll { operation in
      guard operation.state == .pending || operation.state == .deferred,
            let interface = interfacesByID[operation.interfaceID] else { return true }
      return operation.deviceKey != configurationKey(for: interface)
    }
    if configuration.pendingOperations.count != pendingCountBeforeValidation {
      do { try store.save(configuration) }
      catch { persistentFault = "Configuration cleanup failed: \(error.localizedDescription)" }
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(30), repeating: .seconds(30), leeway: .seconds(2))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      self.reconcileLocked(reason: "periodic health calibration")
      self.executeSafePendingAutomaticOperationsLocked()
    }
    healthTimer = timer
    timer.resume()
  }

  deinit {
    healthTimer?.setEventHandler {}
    healthTimer?.cancel()
  }

  func snapshot(completion: @escaping (DaemonSnapshot) -> Void) {
    queue.async { completion(self.snapshotLocked()) }
  }

  @discardableResult
  func addSubscriber(_ subscriber: @escaping (DaemonSnapshot) -> Void) -> UUID {
    let id = UUID()
    queue.async {
      self.subscribers[id] = subscriber
      subscriber(self.snapshotLocked())
    }
    return id
  }

  func removeSubscriber(_ id: UUID) { queue.async { self.subscribers.removeValue(forKey: id) } }

  func reconcile(reason: String) { queue.async { self.reconcileLocked(reason: reason) } }

  func reportHealthFault(_ message: String) {
    queue.async {
      self.persistentFault = message
      self.publishLocked()
    }
  }

  func handleSystemEvent(_ event: SystemEventMonitor.Event) {
    queue.async {
      switch event {
      case .pendingSleepRotation:
        let interfaceIDs = AutomationPlanner.interfaceIDsToQueue(
          for: .beforeSleep,
          settings: self.configuration.automation,
          current: self.interfacesByID
        )
        for interfaceID in interfaceIDs {
          self.markAutomaticOperationPendingLocked(
            interfaceID: interfaceID,
            message: "Rotation was queued before sleep."
          )
        }
        if !interfaceIDs.isEmpty { self.persistAndPublishLocked() }
      case let .reconcile(reason):
        let previousInterfaces = self.interfacesByID
        self.reconcileLocked(reason: String(describing: reason))

        let trigger: AutomationTrigger?
        switch reason {
        case .wake: trigger = .afterWake
        case .networkChange: trigger = .networkChange
        case .initial, .storeRestart: trigger = nil
        }
        if let trigger {
          let interfaceIDs = AutomationPlanner.interfaceIDsToQueue(
            for: trigger,
            settings: self.configuration.automation,
            previous: previousInterfaces,
            current: self.interfacesByID
          )
          let message = trigger == .afterWake
            ? "Rotation was queued after wake."
            : "Rotation was queued when the interface became inactive."
          var queuedStateChanged = false
          for interfaceID in interfaceIDs {
            queuedStateChanged = self.markAutomaticOperationPendingLocked(
              interfaceID: interfaceID,
              message: message
            ) || queuedStateChanged
          }
          if queuedStateChanged { self.persistAndPublishLocked() }
        }
        self.executeSafePendingAutomaticOperationsLocked()
      }
    }
  }

  func setPolicy(_ envelope: OperationEnvelope<PolicyRequest>, completion: @escaping (Result<OperationResult, Error>) -> Void) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault))); return
      }
      if let prior = self.completedOperations[envelope.operationID] { completion(.success(prior)); return }
      guard self.interfacesByID[envelope.request.interfaceID] != nil else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID))); return
      }
      if let interface = self.interfacesByID[envelope.request.interfaceID] {
        switch envelope.request.policy {
        case .systemManaged:
          break
        case .random:
          guard interface.kind != .other else {
            completion(.failure(MACDancerError.commandFailed("This interface type is not supported.")))
            return
          }
        case .specified:
          completion(.failure(MACDancerError.invalidPayload(
            "A specified policy is installed only after a successful, read-back-verified restore request."
          )))
          return
        }
      }
      if envelope.request.policy != .systemManaged, self.legacyServiceDetectedLocked() {
        completion(.failure(self.legacyConflictError)); return
      }
      guard let interface = self.interfacesByID[envelope.request.interfaceID] else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID))); return
      }
      self.configuration.policies[self.configurationKey(for: interface)] = envelope.request.policy
      self.interfacesByID[envelope.request.interfaceID]?.policy = envelope.request.policy
      if envelope.request.policy == .systemManaged {
        self.clearAutomaticOperationLocked(interfaceID: envelope.request.interfaceID)
      }
      let now = Date()
      let result = OperationResult(
        id: envelope.operationID,
        interfaceID: envelope.request.interfaceID,
        kind: .reconcile,
        state: .succeeded,
        requestedAddress: nil,
        observedAddress: self.interfacesByID[envelope.request.interfaceID]?.currentMAC,
        startedAt: now,
        completedAt: now,
        message: "Policy saved."
      )
      self.finishLocked(result, completion: completion)
    }
  }

  func randomize(_ envelope: OperationEnvelope<RandomizeRequest>, completion: @escaping (Result<OperationResult, Error>) -> Void) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault))); return
      }
      if let prior = self.completedOperations[envelope.operationID] { completion(.success(prior)); return }
      guard !self.legacyServiceDetectedLocked() else {
        completion(.failure(self.legacyConflictError)); return
      }
      do {
        try self.refreshObservedInterfacesLocked()
        self.lastError = nil
        self.publishLocked()
      } catch {
        self.lastError = "Manual randomization preflight failed: \(error.localizedDescription)"
        self.publishLocked()
        completion(.failure(error))
        return
      }
      guard let interface = self.interfacesByID[envelope.request.interfaceID] else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID))); return
      }
      do {
        try self.validateManualSafetyLocked(
          interface: interface,
          confirmedDisruption: envelope.request.confirmedDisruption
        )
      } catch {
        completion(.failure(error))
        return
      }
      let excluded = Set(self.interfacesByID.values.flatMap { [$0.currentMAC, $0.hardwareMAC] }.compactMap { $0 })
        .union(interface.history.entries.map(\.address))
      do {
        let address: MACAddress
        let source: HistorySource
        if self.configuration.automation.vendorCompatibility {
          guard let oui = self.compatibilityOUI(for: interface) else {
            completion(.failure(MACDancerError.invalidMACAddress(
              "A globally administered hardware OUI is unavailable for this interface."
            )))
            return
          }
          if let requestedOUI = envelope.request.vendorOUI, requestedOUI != oui {
            completion(.failure(MACDancerError.invalidMACAddress(
              "Vendor compatibility can only use this interface's verified hardware OUI."
            )))
            return
          }
          address = try MACAddress.randomVendorCompatible(oui: oui, excluding: excluded)
          source = .vendorCompatible
        } else {
          address = try MACAddress.randomLocallyAdministered(excluding: excluded)
          source = .generatedLocal
        }
        self.applyLocked(
          operationID: envelope.operationID,
          interface: interface,
          target: address,
          kind: .randomize,
          historySource: source,
          resultingPolicy: .random,
          completion: completion
        )
      } catch { completion(.failure(error)) }
    }
  }

  func restore(_ envelope: OperationEnvelope<RestoreRequest>, completion: @escaping (Result<OperationResult, Error>) -> Void) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault))); return
      }
      if let prior = self.completedOperations[envelope.operationID] { completion(.success(prior)); return }
      guard let interface = self.interfacesByID[envelope.request.interfaceID] else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID))); return
      }
      guard interface.kind != .other else {
        completion(.failure(MACDancerError.commandFailed("This interface type is not supported.")))
        return
      }

      if envelope.request.kind == .systemManaged {
        self.configuration.policies[self.configurationKey(for: interface)] = .systemManaged
        self.interfacesByID[interface.id]?.policy = .systemManaged
        self.clearAutomaticOperationLocked(interfaceID: interface.id)
        let now = Date()
        let result = OperationResult(
          id: envelope.operationID,
          interfaceID: interface.id,
          kind: .handoff,
          state: .succeeded,
          requestedAddress: nil,
          observedAddress: interface.currentMAC,
          startedAt: now,
          completedAt: now,
          message: "MACDancer stopped writing to this interface. Choose Private Wi-Fi Address in System Settings."
        )
        self.finishLocked(result, completion: completion)
        return
      }

      guard !self.legacyServiceDetectedLocked() else {
        completion(.failure(self.legacyConflictError)); return
      }

      do {
        try self.refreshObservedInterfacesLocked()
        self.lastError = nil
        self.publishLocked()
      } catch {
        self.lastError = "Restore preflight failed: \(error.localizedDescription)"
        self.publishLocked()
        completion(.failure(error))
        return
      }

      guard let interface = self.interfacesByID[envelope.request.interfaceID] else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID))); return
      }

      let target: MACAddress?
      let operationKind: OperationKind
      let source: HistorySource?
      switch envelope.request.kind {
      case .hardware:
        target = interface.hardwareMAC
        operationKind = .restoreHardware
        source = nil
      case .history:
        target = envelope.request.targetAddress.flatMap { requested in
          interface.history.entries.contains(where: { $0.address == requested }) ? requested : nil
        }
        operationKind = .restoreHistory
        source = .historyRestore
      case .specified:
        target = envelope.request.targetAddress
        operationKind = .restoreSpecified
        source = .userSpecified
      case .systemManaged:
        return
      }
      guard let target, target.isValidAssignable else {
        completion(.failure(MACDancerError.invalidMACAddress(envelope.request.targetAddress?.stringValue ?? "missing"))); return
      }
      if envelope.request.kind == .specified,
         !target.isLocallyAdministered,
         !envelope.request.confirmedGlobalAddressRisk {
        completion(.failure(MACDancerError.invalidPayload(
          "A globally administered specified address requires an explicit second confirmation."
        )))
        return
      }
      if target != interface.currentMAC {
        do {
          try self.validateManualSafetyLocked(
            interface: interface,
            confirmedDisruption: envelope.request.confirmedDisruption
          )
        } catch {
          completion(.failure(error))
          return
        }
      }
      if self.interfacesByID.values.contains(where: {
        $0.id != interface.id && ($0.currentMAC == target || $0.hardwareMAC == target)
      }) {
        completion(.failure(MACDancerError.invalidMACAddress("The address is already used by another interface."))); return
      }
      self.applyLocked(
        operationID: envelope.operationID,
        interface: interface,
        target: target,
        kind: operationKind,
        historySource: source,
        resultingPolicy: operationKind == .restoreHardware ? .systemManaged : .specified(target),
        completion: completion
      )
    }
  }

  func cancel(_ envelope: OperationEnvelope<CancelRequest>, completion: @escaping (Result<DaemonSnapshot, Error>) -> Void) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault))); return
      }
      if let interfaceID = envelope.request.interfaceID { self.pendingAutomaticInterfaces.remove(interfaceID) }
      else { self.pendingAutomaticInterfaces.removeAll() }
      self.configuration.pendingOperations.removeAll { operation in
        envelope.request.interfaceID == nil || operation.interfaceID == envelope.request.interfaceID
      }
      self.persistAndPublishLocked()
      completion(.success(self.snapshotLocked()))
    }
  }

  func updateHistory(
    _ envelope: OperationEnvelope<HistoryMutationRequest>,
    completion: @escaping (Result<DaemonSnapshot, Error>) -> Void
  ) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault)))
        return
      }
      guard var interface = self.interfacesByID[envelope.request.interfaceID] else {
        completion(.failure(MACDancerError.interfaceNotFound(envelope.request.interfaceID)))
        return
      }

      let configurationKey = self.configurationKey(for: interface)
      var ledger = self.configuration.histories[configurationKey] ?? interface.history
      switch envelope.request.kind {
      case .remove:
        guard let address = envelope.request.address else {
          completion(.failure(MACDancerError.invalidPayload("A history address is required.")))
          return
        }
        ledger.remove(address: address)
      case .clear:
        ledger.removeAll()
      }

      self.configuration.histories[configurationKey] = ledger
      interface.history = ledger
      self.interfacesByID[interface.id] = interface
      self.persistAndPublishLocked()
      completion(.success(self.snapshotLocked()))
    }
  }

  func updateAutomation(
    _ envelope: OperationEnvelope<AutomationRequest>,
    completion: @escaping (Result<DaemonSnapshot, Error>) -> Void
  ) {
    queue.async {
      if let fault = self.persistentFault {
        completion(.failure(MACDancerError.persistence(fault)))
        return
      }
      let settings = envelope.request.settings
      let enablesManagedBehavior = settings.rotateAfterWake
        || settings.rotateWhenInterfaceBecomesInactive
        || settings.prepareRotationBeforeSleep
        || settings.vendorCompatibility
      guard !enablesManagedBehavior || !self.legacyServiceDetectedLocked() else {
        completion(.failure(self.legacyConflictError))
        return
      }

      self.configuration.automation = settings
      if !settings.rotateAfterWake,
         !settings.rotateWhenInterfaceBecomesInactive,
         !settings.prepareRotationBeforeSleep {
        self.clearAllAutomaticOperationsLocked()
      }
      self.persistAndPublishLocked()
      completion(.success(self.snapshotLocked()))
    }
  }

  private func applyLocked(
    operationID: UUID,
    interface: InterfaceSnapshot,
    target: MACAddress,
    kind: OperationKind,
    historySource: HistorySource?,
    resultingPolicy: InterfacePolicy,
    completion: @escaping (Result<OperationResult, Error>) -> Void
  ) {
    let startedAt = Date()
    let performsLinkWrite = interface.currentMAC != target
    // Refuse to touch a link unless the protected configuration path is
    // writable now. This prevents a known persistence failure from leaving a
    // changed MAC paired with an obsolete automatic policy after restart.
    do {
      try store.save(configuration)
    } catch {
      persistentFault = "Configuration preflight failed: \(error.localizedDescription)"
      publishLocked()
      completion(.failure(error))
      return
    }
    // A target that already matches the freshly observed address is a verified
    // no-op. Avoiding an unnecessary link-layer write also avoids needless
    // interface down/up behavior on active adapters.
    let outcome: MACSettingOutcome = !performsLinkWrite
      ? .success(interfaceID: interface.id, requested: target, observed: target)
      : setter.apply(interfaceID: interface.id, targetAddress: target)
    let result: OperationResult
    switch outcome {
    case let .success(_, _, observed):
      var updated = interface
      updated.currentMAC = observed
      updated.policy = resultingPolicy
      // Hardware identities are never history candidates. A no-op specified
      // request while macOS owns the interface is also omitted because public
      // APIs cannot distinguish Apple's per-network private address from any
      // other already-observed address.
      if let historySource,
         observed != updated.hardwareMAC,
         performsLinkWrite || interface.policy != .systemManaged {
        updated.history.record(HistoryEntry(
          address: observed,
          source: historySource,
          firstUsedAt: startedAt,
          lastUsedAt: Date(),
          operation: kind
        ))
        configuration.histories[configurationKey(for: interface)] = updated.history
      }
      configuration.policies[configurationKey(for: interface)] = resultingPolicy
      result = OperationResult(
        id: operationID,
        interfaceID: interface.id,
        kind: kind,
        state: .succeeded,
        requestedAddress: target,
        observedAddress: observed,
        startedAt: startedAt,
        completedAt: Date(),
        message: nil
      )
      updated.lastOperation = result
      interfacesByID[interface.id] = updated
    case let .mismatch(_, requested, observed):
      let associatedWiFiFailure = interface.kind == .wifi && interface.isWiFiAssociated
      result = OperationResult(
        id: operationID, interfaceID: interface.id, kind: kind, state: .failed,
        requestedAddress: requested, observedAddress: observed, startedAt: startedAt,
        completedAt: Date(),
        message: associatedWiFiFailure
          ? MACDancerError.associatedWiFiWriteRejected.localizedDescription
          : "The address read back from macOS did not match the requested MAC address.",
        failureReason: associatedWiFiFailure ? .associatedWiFiWriteRejected : nil
      )
      interfacesByID[interface.id]?.lastOperation = result
    case let .failure(_, requested, reason):
      let associatedWiFiFailure: Bool
      if interface.kind == .wifi,
         interface.isWiFiAssociated,
         case .commandRejected = reason {
        associatedWiFiFailure = true
      } else {
        associatedWiFiFailure = false
      }
      result = OperationResult(
        id: operationID, interfaceID: interface.id, kind: kind, state: .failed,
        requestedAddress: requested, observedAddress: interface.currentMAC, startedAt: startedAt,
        completedAt: Date(),
        message: associatedWiFiFailure
          ? MACDancerError.associatedWiFiWriteRejected.localizedDescription
          : reason.userFacingDescription,
        failureReason: associatedWiFiFailure ? .associatedWiFiWriteRejected : nil
      )
      interfacesByID[interface.id]?.lastOperation = result
    }
    finishLocked(result, completion: completion)
  }

  private func finishLocked(
    _ result: OperationResult,
    completion: @escaping (Result<OperationResult, Error>) -> Void
  ) {
    completedOperations[result.id] = result
    if completedOperations.count > 128 {
      completedOperations.removeValue(forKey: completedOperations.keys.first!)
    }
    persistAndPublishLocked()
    completion(.success(result))
  }

  private func reconcileLocked(reason: String) {
    do {
      try refreshObservedInterfacesLocked()
      lastError = nil
    } catch {
      lastError = "Reconcile failed (\(reason)): \(error.localizedDescription)"
    }
    publishLocked()
  }

  /// Refreshes all read-only interface facts without publishing. Callers use
  /// this immediately before a manual write so safety decisions cannot rely
  /// on a periodic snapshot that may be up to thirty seconds old.
  private func refreshObservedInterfacesLocked() throws {
    var observed = try interfaceProvider.interfaces()
    for index in observed.indices {
      let id = observed[index].id
      let configurationKey = configurationKey(for: observed[index])
      observed[index].policy = configuration.policies[configurationKey] ?? .systemManaged
      observed[index].history = configuration.histories[configurationKey] ?? HistoryLedger()
      observed[index].lastOperation = interfacesByID[id]?.lastOperation
    }
    interfacesByID = Dictionary(uniqueKeysWithValues: observed.map { ($0.id, $0) })
  }

  private func executeSafePendingAutomaticOperationsLocked() {
    guard persistentFault == nil, !legacyServiceDetectedLocked() else { return }
    let interfaceIDs = pendingAutomaticInterfaces.sorted()
    var pendingStateChanged = false
    for interfaceID in interfaceIDs {
      guard let interface = interfacesByID[interfaceID] else {
        pendingStateChanged = clearAutomaticOperationLocked(interfaceID: interfaceID) || pendingStateChanged
        continue
      }
      guard interface.policy == .random else {
        pendingStateChanged = clearAutomaticOperationLocked(interfaceID: interfaceID) || pendingStateChanged
        continue
      }
      let decision = SafetyPolicy.decision(
        for: interface,
        automatic: true,
        confirmedDisruption: false
      )
      guard case .allowed = decision else {
        if case let .deferred(reason) = decision {
          pendingStateChanged = markAutomaticOperationDeferredLocked(
            interfaceID: interfaceID,
            message: reason
          ) || pendingStateChanged
        } else if case let .denied(reason) = decision {
          pendingStateChanged = clearAutomaticOperationLocked(interfaceID: interfaceID) || pendingStateChanged
          interfacesByID[interfaceID]?.errorMessage = "Automatic rotation was cancelled: \(reason)"
        }
        continue
      }

      let excluded = Set(interfacesByID.values.flatMap { [$0.currentMAC, $0.hardwareMAC] }.compactMap { $0 })
        .union(interface.history.entries.map(\.address))
      do {
        let target: MACAddress
        let source: HistorySource
        if configuration.automation.vendorCompatibility {
          guard let oui = compatibilityOUI(for: interface) else {
            throw MACDancerError.invalidMACAddress(
              "A globally administered hardware OUI is unavailable for \(interface.id)."
            )
          }
          target = try MACAddress.randomVendorCompatible(oui: oui, excluding: excluded)
          source = .vendorCompatible
        } else {
          target = try MACAddress.randomLocallyAdministered(excluding: excluded)
          source = .generatedLocal
        }
        let operationID = configuration.pendingOperations
          .first(where: { $0.interfaceID == interfaceID })?.id ?? UUID()
        applyLocked(
          operationID: operationID,
          interface: interface,
          target: target,
          kind: .randomize,
          historySource: source,
          resultingPolicy: .random
        ) { _ in }
        if interfacesByID[interfaceID]?.lastOperation?.state == .succeeded {
          pendingStateChanged = clearAutomaticOperationLocked(interfaceID: interfaceID) || pendingStateChanged
        } else {
          pendingStateChanged = markAutomaticOperationDeferredLocked(
            interfaceID: interfaceID,
            message: "The requested address was not verified; the operation remains pending."
          ) || pendingStateChanged
        }
      } catch {
        pendingStateChanged = markAutomaticOperationDeferredLocked(
          interfaceID: interfaceID,
          message: error.localizedDescription
        ) || pendingStateChanged
      }
    }
    if pendingStateChanged { persistAndPublishLocked() }
  }

  private func snapshotLocked() -> DaemonSnapshot {
    DaemonSnapshot(
      revision: revision,
      instanceID: instanceID,
      heartbeat: Date(),
      interfaces: interfacesByID.values.sorted { $0.bsdName < $1.bsdName },
      pendingOperationIDs: configuration.pendingOperations.map(\.id),
      automation: configuration.automation,
      lastError: persistentFault ?? lastError
    )
  }

  private func compatibilityOUI(for interface: InterfaceSnapshot) -> [UInt8]? {
    guard let hardware = interface.hardwareMAC,
          hardware.bytes.count == 6,
          hardware.bytes[0] & 0x03 == 0 else { return nil }
    return Array(hardware.bytes.prefix(3))
  }

  /// BSD names can be reused when USB/Thunderbolt adapters are replaced. A
  /// hardware-qualified key prevents a newly attached device from inheriting
  /// another adapter's automatic policy or history.
  private func configurationKey(for interface: InterfaceSnapshot) -> String {
    "\(interface.bsdName)|\(interface.hardwareMAC?.stringValue ?? "unverified-hardware")"
  }

  private func validateManualSafetyLocked(
    interface: InterfaceSnapshot,
    confirmedDisruption: Bool
  ) throws {
    switch SafetyPolicy.decision(
      for: interface,
      automatic: false,
      confirmedDisruption: confirmedDisruption
    ) {
    case .allowed:
      return
    case let .denied(reason):
      if (interface.isActive || interface.isDefaultRoute) && !confirmedDisruption {
        throw MACDancerError.disruptionConfirmationRequired
      }
      throw MACDancerError.commandFailed(reason)
    case let .deferred(reason):
      throw MACDancerError.commandFailed(reason)
    }
  }

  @discardableResult
  private func markAutomaticOperationPendingLocked(interfaceID: String, message: String) -> Bool {
    pendingAutomaticInterfaces.insert(interfaceID)
    guard !configuration.pendingOperations.contains(where: { $0.interfaceID == interfaceID }) else {
      return false
    }
    let now = Date()
    configuration.pendingOperations.append(OperationResult(
      id: UUID(),
      interfaceID: interfaceID,
      kind: .randomize,
      state: .pending,
      requestedAddress: nil,
      observedAddress: interfacesByID[interfaceID]?.currentMAC,
      startedAt: now,
      completedAt: nil,
      message: message,
      deviceKey: interfacesByID[interfaceID].map(configurationKey(for:))
    ))
    return true
  }

  @discardableResult
  private func markAutomaticOperationDeferredLocked(interfaceID: String, message: String) -> Bool {
    pendingAutomaticInterfaces.insert(interfaceID)
    if let index = configuration.pendingOperations.firstIndex(where: { $0.interfaceID == interfaceID }) {
      let current = configuration.pendingOperations[index]
      let observed = interfacesByID[interfaceID]?.currentMAC
      guard current.state != .deferred
        || current.message != message
        || current.observedAddress != observed else { return false }
      configuration.pendingOperations[index] = OperationResult(
        id: current.id,
        interfaceID: interfaceID,
        kind: current.kind,
        state: .deferred,
        requestedAddress: current.requestedAddress,
        observedAddress: observed,
        startedAt: current.startedAt,
        completedAt: nil,
        message: message,
        deviceKey: current.deviceKey
      )
      return true
    } else {
      let now = Date()
      configuration.pendingOperations.append(OperationResult(
        id: UUID(),
        interfaceID: interfaceID,
        kind: .randomize,
        state: .deferred,
        requestedAddress: nil,
        observedAddress: interfacesByID[interfaceID]?.currentMAC,
        startedAt: now,
        completedAt: nil,
        message: message,
        deviceKey: interfacesByID[interfaceID].map(configurationKey(for:))
      ))
      return true
    }
  }

  @discardableResult
  private func clearAutomaticOperationLocked(interfaceID: String) -> Bool {
    let removedFromSet = pendingAutomaticInterfaces.remove(interfaceID) != nil
    let previousCount = configuration.pendingOperations.count
    configuration.pendingOperations.removeAll { $0.interfaceID == interfaceID }
    return removedFromSet || configuration.pendingOperations.count != previousCount
  }

  private func clearAllAutomaticOperationsLocked() {
    pendingAutomaticInterfaces.removeAll()
    configuration.pendingOperations.removeAll()
  }

  private var legacyConflictError: MACDancerError {
    .unsafeAutomaticOperation(
      "LinkLiar's legacy daemon is installed. MACDancer will remain read-only until the competing service is removed or disabled."
    )
  }

  private func legacyServiceDetectedLocked() -> Bool {
    LegacyServiceDetector.isInstalledOrActive()
  }

  private func persistAndPublishLocked() {
    do { try store.save(configuration) }
    catch { persistentFault = "Configuration save failed: \(error.localizedDescription)" }
    publishLocked()
  }

  private func publishLocked() {
    revision &+= 1
    let snapshot = snapshotLocked()
    for subscriber in subscribers.values { subscriber(snapshot) }
  }
}
