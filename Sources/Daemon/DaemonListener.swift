import Foundation

final class DaemonListener: NSObject, NSXPCListenerDelegate {
  private let listener: NSXPCListener
  private let coordinator: DaemonCoordinator
  private let clientSigningRequirement: String

  init(coordinator: DaemonCoordinator) throws {
    guard let requirement = CodeSigningIdentity.requirement(identifier: MACDancerConstants.appIdentifier) else {
      throw MACDancerError.daemonUnavailable("Unable to construct the GUI code-signing requirement.")
    }
    self.coordinator = coordinator
    clientSigningRequirement = requirement
    listener = NSXPCListener(machServiceName: MACDancerConstants.daemonIdentifier)
    super.init()
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = self
  }

  func run() {
    listener.resume()
    RunLoop.current.run()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let service = DaemonXPCService(
      coordinator: coordinator,
      clientSigningRequirement: clientSigningRequirement
    )
    connection.exportedInterface = Self.daemonInterface()
    connection.exportedObject = service
    connection.invalidationHandler = { service.invalidate() }
    connection.interruptionHandler = { service.invalidate() }
    connection.resume()
    return true
  }

  private static func daemonInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: MACDancerDaemonProtocol.self)
    let payloadClasses = NSSet(object: MDSecurePayload.self) as! Set<AnyHashable>
    let endpointClasses = NSSet(object: NSXPCListenerEndpoint.self) as! Set<AnyHashable>

    func configureReply(_ selector: Selector) {
      interface.setClasses(payloadClasses, for: selector, argumentIndex: 0, ofReply: true)
    }

    configureReply(#selector(MACDancerDaemonProtocol.ping(_:)))
    configureReply(#selector(MACDancerDaemonProtocol.getSnapshot(_:)))
    interface.setClasses(
      endpointClasses,
      for: #selector(MACDancerDaemonProtocol.subscribe(_:reply:)),
      argumentIndex: 0,
      ofReply: false
    )
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

private final class DaemonXPCService: NSObject, MACDancerDaemonProtocol {
  private let coordinator: DaemonCoordinator
  private let clientSigningRequirement: String
  private let lock = NSLock()
  private var callbackConnection: NSXPCConnection?
  private var subscriptionID: UUID?

  init(coordinator: DaemonCoordinator, clientSigningRequirement: String) {
    self.coordinator = coordinator
    self.clientSigningRequirement = clientSigningRequirement
  }

  func invalidate() {
    lock.lock()
    let subscriptionID = self.subscriptionID
    let callbackConnection = self.callbackConnection
    self.subscriptionID = nil
    self.callbackConnection = nil
    lock.unlock()
    callbackConnection?.invalidate()
    if let subscriptionID { coordinator.removeSubscriber(subscriptionID) }
  }

  func ping(_ reply: @escaping (MDSecurePayload?, NSError?) -> Void) { snapshotReply(reply) }
  func getSnapshot(_ reply: @escaping (MDSecurePayload?, NSError?) -> Void) { snapshotReply(reply) }

  func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    invalidate()
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = Self.clientInterface()
    connection.setCodeSigningRequirement(clientSigningRequirement)
    connection.invalidationHandler = { [weak self] in self?.invalidate() }
    connection.interruptionHandler = { [weak self] in self?.invalidate() }
    connection.resume()
    lock.lock()
    callbackConnection = connection
    lock.unlock()
    let subscriptionID = coordinator.addSubscriber { [weak self] snapshot in
      guard let self else { return }
      do {
        let payload = try MDSecurePayload(snapshot)
        let proxy = self.callbackConnection?.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.invalidate() }
          as? MACDancerClientProtocol
        proxy?.daemonDidUpdate(payload)
      } catch { self.invalidate() }
    }
    lock.lock()
    let shouldKeepSubscription = callbackConnection === connection
    if shouldKeepSubscription {
      self.subscriptionID = subscriptionID
    }
    lock.unlock()
    if !shouldKeepSubscription {
      coordinator.removeSubscriber(subscriptionID)
    }
    snapshotReply(reply)
  }

  func setPolicy(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    performOperation(payload, as: OperationEnvelope<PolicyRequest>.self, reply: reply) { envelope, completion in
      self.coordinator.setPolicy(envelope) { result in
        completion(self.validateOperation(result))
      }
    }
  }

  func randomizeNow(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    performOperation(payload, as: OperationEnvelope<RandomizeRequest>.self, reply: reply) { envelope, completion in
      self.coordinator.randomize(envelope) { result in
        completion(self.validateOperation(result))
      }
    }
  }

  func restore(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    performOperation(payload, as: OperationEnvelope<RestoreRequest>.self, reply: reply) { envelope, completion in
      self.coordinator.restore(envelope) { result in
        completion(self.validateOperation(result))
      }
    }
  }

  func cancelPendingOperations(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    do {
      let envelope = try payload.decode(OperationEnvelope<CancelRequest>.self)
      coordinator.cancel(envelope) { result in
        switch result {
        case let .success(snapshot): self.encode(snapshot, reply: reply)
        case let .failure(error): reply(nil, error as NSError)
        }
      }
    } catch { reply(nil, error as NSError) }
  }

  func updateHistory(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    do {
      let envelope = try payload.decode(OperationEnvelope<HistoryMutationRequest>.self)
      coordinator.updateHistory(envelope) { result in
        switch result {
        case let .success(snapshot): self.encode(snapshot, reply: reply)
        case let .failure(error): reply(nil, error as NSError)
        }
      }
    } catch { reply(nil, error as NSError) }
  }

  func updateAutomation(_ payload: MDSecurePayload, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    do {
      let envelope = try payload.decode(OperationEnvelope<AutomationRequest>.self)
      coordinator.updateAutomation(envelope) { result in
        switch result {
        case let .success(snapshot): self.encode(snapshot, reply: reply)
        case let .failure(error): reply(nil, error as NSError)
        }
      }
    } catch { reply(nil, error as NSError) }
  }

  private func snapshotReply(_ reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    coordinator.snapshot { snapshot in self.encode(snapshot, reply: reply) }
  }

  private func validateOperation(_ result: Result<OperationResult, Error>) -> Result<Void, Error> {
    result.flatMap { operation in
      guard operation.state == .succeeded else {
        return .failure(MACDancerError.commandFailed(
          operation.message ?? "The daemon could not verify the requested MAC address."
        ))
      }
      return .success(())
    }
  }

  private func performOperation<Request: Decodable>(
    _ payload: MDSecurePayload,
    as type: Request.Type,
    reply: @escaping (MDSecurePayload?, NSError?) -> Void,
    operation: @escaping (Request, @escaping (Result<Void, Error>) -> Void) -> Void
  ) {
    do {
      let request = try payload.decode(type)
      operation(request) { result in
        switch result {
        case .success:
          self.coordinator.snapshot { snapshot in self.encode(snapshot, reply: reply) }
        case let .failure(error): reply(nil, error as NSError)
        }
      }
    } catch { reply(nil, error as NSError) }
  }

  private func encode<T: Encodable>(_ value: T, reply: @escaping (MDSecurePayload?, NSError?) -> Void) {
    do { reply(try MDSecurePayload(value), nil) }
    catch { reply(nil, error as NSError) }
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
