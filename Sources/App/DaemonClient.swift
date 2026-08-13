import Foundation

private enum DaemonTransportError: LocalizedError {
  case timeout(seconds: Int)
  case proxy(String)
  case emptyReply

  var errorDescription: String? {
    switch self {
    case let .timeout(seconds):
      "The background service did not reply within \(seconds) seconds."
    case let .proxy(message):
      message
    case .emptyReply:
      "The background service returned an empty response."
    }
  }
}

/// Thin, authenticated client for the privileged daemon.
///
/// Every command is wrapped in `OperationEnvelope`, receives a bounded XPC
/// reply, and is deliberately *not* retried after an interruption.  Retrying a
/// destructive request would risk applying it twice.  Only the idempotent
/// snapshot subscription is retried with backoff.
@MainActor
final class DaemonClient: NSObject, DaemonClientProviding {
  typealias SnapshotHandler = @MainActor (DaemonSnapshot) -> Void
  typealias StatusHandler = @MainActor (DaemonClientStatus) -> Void

  var onSnapshot: SnapshotHandler?
  var onStatusChange: StatusHandler?

  private let machServiceName: String
  private let signingRequirementProvider: @Sendable (String) -> String?
  private let requestTimeout: TimeInterval
  private var signingRequirement: String?
  private var callbackListener: NSXPCListener?
  private var callbackReceiver: DaemonCallbackReceiver?

  private var connection: NSXPCConnection?
  private var transportPreparationTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var wantsSubscription = false
  private var retryDelay: TimeInterval = 1
  private var snapshotTracker = SnapshotRevisionTracker()
  private(set) var status = DaemonClientStatus()

  init(
    machServiceName: String = MACDancerConstants.daemonIdentifier,
    signingRequirementProvider: @escaping @Sendable (String) -> String? = { identifier in
      CodeSigningIdentity.requirement(identifier: identifier)
    },
    requestTimeout: TimeInterval = 5
  ) {
    self.machServiceName = machServiceName
    self.signingRequirementProvider = signingRequirementProvider
    self.requestTimeout = requestTimeout
    super.init()
  }

  deinit {
    transportPreparationTask?.cancel()
    reconnectTask?.cancel()
    heartbeatTask?.cancel()
    connection?.invalidate()
    callbackListener?.invalidate()
  }

  func start() {
    wantsSubscription = true
    if callbackListener != nil {
      if reconnectTask == nil { subscribeWithRetry() }
      startHeartbeatMonitor()
      return
    }
    guard transportPreparationTask == nil else { return }

    let identifier = machServiceName
    let provider = signingRequirementProvider
    transportPreparationTask = Task { @MainActor [weak self] in
      let requirement = await Task.detached(priority: .utility) {
        provider(identifier)
      }.value
      guard let self else { return }
      self.transportPreparationTask = nil
      guard self.wantsSubscription, !Task.isCancelled else { return }
      guard let requirement else {
        let error = MACDancerError.daemonUnavailable(
          "MACDancer could not determine its code-signing identity, so it will not connect to a privileged daemon."
        )
        self.publishStatus(
          reachability: .unavailable,
          health: .unhealthy,
          version: nil,
          diagnostic: error.localizedDescription
        )
        return
      }
      self.prepareCallbackTransport(signingRequirement: requirement)
      self.subscribeWithRetry()
      self.startHeartbeatMonitor()
    }
  }

  func stop() {
    wantsSubscription = false
    transportPreparationTask?.cancel()
    transportPreparationTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    connection?.invalidate()
    connection = nil
    publishStatus(reachability: .unknown, health: .unknown, version: nil, diagnostic: nil)
  }

  func ping() async throws -> DaemonSnapshot {
    try await perform { daemon, reply in
      daemon.ping(reply)
    }
  }

  func getSnapshot() async throws -> DaemonSnapshot {
    try await perform { daemon, reply in
      daemon.getSnapshot(reply)
    }
  }

  func subscribe() async throws -> DaemonSnapshot {
    guard let callbackListener else {
      throw MACDancerError.daemonUnavailable("The authenticated callback channel is not ready.")
    }
    let endpoint = callbackListener.endpoint
    return try await perform { daemon, reply in
      daemon.subscribe(endpoint, reply: reply)
    }
  }

  func setPolicy(_ request: PolicyRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.setPolicy(payload, reply: reply)
    }
  }

  func randomize(_ request: RandomizeRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.randomizeNow(payload, reply: reply)
    }
  }

  func restore(_ request: RestoreRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.restore(payload, reply: reply)
    }
  }

  func cancel(_ request: CancelRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.cancelPendingOperations(payload, reply: reply)
    }
  }

  func updateHistory(_ request: HistoryMutationRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.updateHistory(payload, reply: reply)
    }
  }

  func updateAutomation(_ request: AutomationRequest, operationID: UUID = UUID()) async throws -> DaemonSnapshot {
    let payload = try MDSecurePayload(OperationEnvelope(operationID: operationID, request: request))
    return try await perform { daemon, reply in
      daemon.updateAutomation(payload, reply: reply)
    }
  }

  private func startHeartbeatMonitor() {
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled, self.wantsSubscription {
        do {
          try await Task.sleep(for: .seconds(15))
          guard !Task.isCancelled, self.wantsSubscription else { break }
          _ = try await self.ping()
        } catch is CancellationError {
          break
        } catch {
          // Transport failures are classified by `perform` and immediately
          // update reachability. The retry loop owns reconnection.
        }
      }
      self?.heartbeatTask = nil
    }
  }

  private func subscribeWithRetry() {
    guard wantsSubscription, reconnectTask == nil else { return }
    reconnectTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        let snapshot = try await self.subscribe()
        self.retryDelay = 1
        self.accept(snapshot)
        self.reconnectTask = nil
      } catch {
        self.handleConnectionFailure(error, retry: false)
        self.reconnectTask = nil
        self.scheduleReconnect()
      }
    }
  }

  private func scheduleReconnect() {
    guard wantsSubscription, reconnectTask == nil else { return }
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, 30)
    reconnectTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        self.reconnectTask = nil
        return
      }
      guard self.wantsSubscription else {
        self.reconnectTask = nil
        return
      }
      self.reconnectTask = nil
      self.subscribeWithRetry()
    }
  }

  private func ensureConnection() throws -> NSXPCConnection {
    if let connection { return connection }
    guard let signingRequirement else {
      let error = MACDancerError.daemonUnavailable(
        "MACDancer could not determine its code-signing identity, so it will not connect to a privileged daemon."
      )
      publishStatus(reachability: .unavailable, health: .unhealthy, version: nil, diagnostic: error.localizedDescription)
      throw error
    }

    publishStatus(reachability: .connecting, health: .unknown, version: status.version, diagnostic: nil)
    let connection = NSXPCConnection(
      machServiceName: machServiceName,
      options: .privileged
    )
    connection.remoteObjectInterface = Self.daemonInterface()
    connection.setCodeSigningRequirement(signingRequirement)
    connection.interruptionHandler = { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleInterruption()
      }
    }
    connection.invalidationHandler = { [weak self] in
      Task { @MainActor [weak self] in
        self?.handleInvalidation()
      }
    }
    connection.activate()
    self.connection = connection
    return connection
  }

  private func prepareCallbackTransport(signingRequirement: String) {
    guard callbackListener == nil else { return }
    self.signingRequirement = signingRequirement
    let receiver = DaemonCallbackReceiver(signingRequirement: signingRequirement)
    receiver.onPayload = { [weak self] payload in
      Task { @MainActor [weak self] in
        self?.receiveCallback(payload)
      }
    }
    let listener = NSXPCListener.anonymous()
    listener.delegate = receiver
    listener.setConnectionCodeSigningRequirement(signingRequirement)
    listener.activate()
    callbackReceiver = receiver
    callbackListener = listener
  }

  private func perform(
    _ invoke: @escaping (MACDancerDaemonProtocol, @escaping (MDSecurePayload?, NSError?) -> Void) -> Void
  ) async throws -> DaemonSnapshot {
    let connection = try ensureConnection()
    let snapshot: DaemonSnapshot
    do {
      snapshot = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DaemonSnapshot, Error>) in
        let gate = ReplyGate(continuation: continuation)
        let timeout = DispatchWorkItem {
          gate.fail(DaemonTransportError.timeout(seconds: Int(self.requestTimeout)))
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + requestTimeout,
          execute: timeout
        )

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
          timeout.cancel()
          gate.fail(DaemonTransportError.proxy(error.localizedDescription))
        } as? MACDancerDaemonProtocol
        guard let proxy else {
          timeout.cancel()
          gate.fail(DaemonTransportError.proxy("Unable to create a daemon XPC proxy."))
          return
        }

        invoke(proxy) { payload, error in
          timeout.cancel()
          if let error {
            // The daemon reports command validation failures through this
            // channel too.  Those are not connection failures and must not
            // cause a destructive command to be replayed.
            gate.fail(error)
            return
          }
          guard let payload else {
            gate.fail(DaemonTransportError.emptyReply)
            return
          }
          do {
            let snapshot = try payload.decode(DaemonSnapshot.self)
            guard snapshot.protocolVersion == MACDancerConstants.protocolVersion else {
              gate.fail(MACDancerError.incompatibleProtocol(
                expected: MACDancerConstants.protocolVersion,
                actual: snapshot.protocolVersion
              ))
              return
            }
            gate.succeed(snapshot)
          } catch {
            gate.fail(error)
          }
        }
      }
    } catch let error as DaemonTransportError {
      handleConnectionFailure(error, retry: true)
      throw error
    }

    accept(snapshot)
    return snapshot
  }

  private func receiveCallback(_ payload: MDSecurePayload) {
    do {
      let snapshot = try payload.decode(DaemonSnapshot.self)
      guard snapshot.protocolVersion == MACDancerConstants.protocolVersion else {
        publishStatus(
          reachability: .reachable,
          health: .incompatible,
          version: snapshot.protocolVersion,
          diagnostic: MACDancerError.incompatibleProtocol(
            expected: MACDancerConstants.protocolVersion,
            actual: snapshot.protocolVersion
          ).localizedDescription
        )
        return
      }
      accept(snapshot)
    } catch {
      publishStatus(reachability: .reachable, health: .unhealthy, version: status.version, diagnostic: error.localizedDescription)
    }
  }

  /// Drops only messages that are older than the most recently accepted
  /// revision from the *same* daemon instance.  A daemon restart deliberately
  /// has a new instance ID and is accepted even when its revision starts over.
  private func accept(_ snapshot: DaemonSnapshot) {
    guard snapshotTracker.accepts(snapshot) else { return }

    let heartbeatAge = Date().timeIntervalSince(snapshot.heartbeat)
    let health: DaemonHealth = heartbeatAge > 60 ? .stale : (snapshot.lastError == nil ? .healthy : .unhealthy)
    publishStatus(
      reachability: .reachable,
      health: health,
      version: snapshot.protocolVersion,
      diagnostic: snapshot.lastError
    )
    onSnapshot?(snapshot)
  }

  private func handleInterruption() {
    guard connection != nil else { return }
    publishStatus(
      reachability: .interrupted,
      health: .unhealthy,
      version: status.version,
      diagnostic: "The background service interrupted the connection."
    )
    connection = nil
    scheduleReconnect()
  }

  private func handleInvalidation() {
    connection = nil
    publishStatus(
      reachability: .unavailable,
      health: .unhealthy,
      version: status.version,
      diagnostic: "The background service connection was invalidated."
    )
    scheduleReconnect()
  }

  private func handleConnectionFailure(_ error: Error, retry: Bool) {
    connection?.invalidate()
    connection = nil
    publishStatus(
      reachability: .unavailable,
      health: .unhealthy,
      version: status.version,
      diagnostic: error.localizedDescription
    )
    if retry { scheduleReconnect() }
  }

  private func publishStatus(
    reachability: DaemonReachability,
    health: DaemonHealth,
    version: Int?,
    diagnostic: String?
  ) {
    let next = DaemonClientStatus(
      reachability: reachability,
      health: health,
      version: version,
      diagnostic: diagnostic
    )
    guard next != status else { return }
    status = next
    onStatusChange?(next)
  }

  private static func daemonInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: MACDancerDaemonProtocol.self)
    // NSXPCInterface imports NSSet<Class> as Set<AnyHashable> in Swift.
    // Constructing through NSSet preserves the Objective-C class objects;
    // directly putting a metatype into AnyHashable does not.
    let payloadClasses = NSSet(object: MDSecurePayload.self) as! Set<AnyHashable>
    let endpointClasses = NSSet(object: NSXPCListenerEndpoint.self) as! Set<AnyHashable>

    func configureReply(_ selector: Selector) {
      interface.setClasses(payloadClasses, for: selector, argumentIndex: 0, ofReply: true)
    }

    configureReply(#selector(MACDancerDaemonProtocol.ping(_:)))
    configureReply(#selector(MACDancerDaemonProtocol.getSnapshot(_:)))
    interface.setClasses(endpointClasses, for: #selector(MACDancerDaemonProtocol.subscribe(_:reply:)), argumentIndex: 0, ofReply: false)
    configureReply(#selector(MACDancerDaemonProtocol.subscribe(_:reply:)))

    let mutatingSelectors: [Selector] = [
      #selector(MACDancerDaemonProtocol.setPolicy(_:reply:)),
      #selector(MACDancerDaemonProtocol.randomizeNow(_:reply:)),
      #selector(MACDancerDaemonProtocol.restore(_:reply:)),
      #selector(MACDancerDaemonProtocol.cancelPendingOperations(_:reply:)),
      #selector(MACDancerDaemonProtocol.updateHistory(_:reply:)),
      #selector(MACDancerDaemonProtocol.updateAutomation(_:reply:))
    ]
    for selector in mutatingSelectors {
      interface.setClasses(payloadClasses, for: selector, argumentIndex: 0, ofReply: false)
      configureReply(selector)
    }
    return interface
  }
}

private final class DaemonCallbackReceiver: NSObject, MACDancerClientProtocol, NSXPCListenerDelegate {
  var onPayload: ((MDSecurePayload) -> Void)?
  private let signingRequirement: String?

  init(signingRequirement: String?) {
    self.signingRequirement = signingRequirement
  }

  func daemonDidUpdate(_ payload: MDSecurePayload) {
    onPayload?(payload)
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    // The listener itself has the same requirement.  Retaining this check on
    // the connection protects the callback channel if it is ever refactored
    // away from an anonymous listener.
    guard let signingRequirement else { return false }
    newConnection.exportedInterface = Self.clientInterface()
    newConnection.exportedObject = self
    newConnection.setCodeSigningRequirement(signingRequirement)
    newConnection.activate()
    return true
  }

  private static func clientInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: MACDancerClientProtocol.self)
    interface.setClasses(
      NSSet(object: MDSecurePayload.self) as! Set<AnyHashable>,
      for: #selector(MACDancerClientProtocol.daemonDidUpdate(_:)),
      argumentIndex: 0,
      ofReply: false
    )
    return interface
  }
}

private final class ReplyGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func succeed(_ value: Value) {
    finish(.success(value))
  }

  func fail(_ error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Value, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    guard let continuation else { return }
    switch result {
    case let .success(value): continuation.resume(returning: value)
    case let .failure(error): continuation.resume(throwing: error)
    }
  }
}
