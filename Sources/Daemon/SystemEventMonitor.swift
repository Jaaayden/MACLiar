import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration

/// Observes system power and network-configuration changes for the privileged daemon.
///
/// This type never changes network state. Its callbacks only enqueue small semantic
/// events; a coordinator is responsible for reading state and deciding whether work is
/// appropriate.
final class SystemEventMonitor {
    // `kIOMessage*` macros are not imported by Swift. These values are from
    // <IOKit/IOMessage.h> in the macOS SDK: iokit_common_msg(0x270/0x280/0x300).
    private static let ioMessageCanSystemSleep: UInt32 = 0xe000_0270
    private static let ioMessageSystemWillSleep: UInt32 = 0xe000_0280
    private static let ioMessageSystemHasPoweredOn: UInt32 = 0xe000_0300

    enum Event: Equatable {
        /// The system is about to sleep. Persist intent only; do not perform MAC work here.
        case pendingSleepRotation
        /// The coordinator must discard any stale assumptions and read current state again.
        case reconcile(ReconcileReason)
    }

    enum ReconcileReason: Equatable {
        case initial
        case wake
        case networkChange
        /// `configd` restarted, so Dynamic Store deltas are no longer trustworthy.
        case storeRestart
    }

    typealias EventHandler = (Event) -> Void

    enum StartError: Error {
        case powerNotificationRegistrationFailed
        case dynamicStoreCreationFailed
        case dynamicStoreNotificationRegistrationFailed
        case dynamicStoreDispatchQueueRegistrationFailed
    }

    /// Events are delivered serially on a private queue, never on an IOKit or
    /// SystemConfiguration callback queue.
    init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    deinit {
        stop()
    }

    /// Starts observing system events. Calling this repeatedly while already running is a no-op.
    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isMonitorRunning() else { return }

        let callbackContext = CallbackContext(monitor: self)
        let callbackContextPointer = Unmanaged.passRetained(callbackContext).toOpaque()

        var notificationPort: IONotificationPortRef?
        var powerNotifier: io_object_t = 0
        let powerConnection = IORegisterForSystemPower(
            callbackContextPointer,
            &notificationPort,
            Self.powerCallback,
            &powerNotifier
        )

        guard powerConnection != 0, let notificationPort else {
            callbackContext.invalidate()
            if let notificationPort {
                tearDownPowerNotifications(
                    connection: powerConnection,
                    notifier: powerNotifier,
                    notificationPort: notificationPort
                )
            } else if powerConnection != 0 {
                _ = IOServiceClose(powerConnection)
            }
            releaseCallbackContextAfterCallbacks(callbackContextPointer)
            throw StartError.powerNotificationRegistrationFailed
        }

        var dynamicStoreContext = SCDynamicStoreContext(
            version: 0,
            info: callbackContextPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let dynamicStore = SCDynamicStoreCreate(
            nil,
            "MACDancer.SystemEventMonitor" as CFString,
            Self.dynamicStoreCallback,
            &dynamicStoreContext
        ) else {
            callbackContext.invalidate()
            tearDownPowerNotifications(
                connection: powerConnection,
                notifier: powerNotifier,
                notificationPort: notificationPort
            )
            releaseCallbackContextAfterCallbacks(callbackContextPointer)
            throw StartError.dynamicStoreCreationFailed
        }

        let notificationKeys = dynamicStoreNotificationKeys()
        guard SCDynamicStoreSetNotificationKeys(
            dynamicStore,
            notificationKeys.keys,
            notificationKeys.patterns
        ) else {
            callbackContext.invalidate()
            tearDownPowerNotifications(
                connection: powerConnection,
                notifier: powerNotifier,
                notificationPort: notificationPort
            )
            releaseCallbackContextAfterCallbacks(callbackContextPointer)
            throw StartError.dynamicStoreNotificationRegistrationFailed
        }

        guard SCDynamicStoreSetDispatchQueue(dynamicStore, callbackQueue) else {
            callbackContext.invalidate()
            tearDownPowerNotifications(
                connection: powerConnection,
                notifier: powerNotifier,
                notificationPort: notificationPort
            )
            releaseCallbackContextAfterCallbacks(callbackContextPointer)
            throw StartError.dynamicStoreDispatchQueueRegistrationFailed
        }

        self.callbackContext = callbackContext
        self.callbackContextPointer = callbackContextPointer
        self.notificationPort = notificationPort
        self.powerNotifier = powerNotifier
        self.dynamicStore = dynamicStore

        let generation = beginRunning(with: powerConnection)
        IONotificationPortSetDispatchQueue(notificationPort, callbackQueue)
        enqueue(.reconcile(.initial), generation: generation)
    }

    /// Stops observing and releases all IOKit/SystemConfiguration registrations.
    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isMonitorRunning() || callbackContextPointer != nil else { return }

        let context = callbackContext
        let contextPointer = callbackContextPointer
        let connection = powerConnection
        let notifier = powerNotifier
        context?.invalidate()
        endRunning()

        if let dynamicStore {
            _ = SCDynamicStoreSetDispatchQueue(dynamicStore, nil)
            self.dynamicStore = nil
        }

        if let notificationPort {
            tearDownPowerNotifications(
                connection: connection,
                notifier: notifier,
                notificationPort: notificationPort
            )
            self.notificationPort = nil
        }

        stateLock.lock()
        powerConnection = 0
        stateLock.unlock()
        powerNotifier = 0
        callbackContext = nil
        callbackContextPointer = nil

        if let contextPointer {
            // Sources are disabled before this barrier. Keeping the context alive until this
            // point lets already-queued C callbacks safely observe its invalidated state.
            releaseCallbackContextAfterCallbacks(contextPointer)
        }
    }

    // MARK: - IOKit callbacks

    private static let powerCallback: IOServiceInterestCallback = {
        referenceCon, _, messageType, messageArgument in
        guard let referenceCon else { return }

        let context = Unmanaged<CallbackContext>
            .fromOpaque(referenceCon)
            .takeUnretainedValue()
        context.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
    }

    fileprivate func handlePowerMessage(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        if messageType == Self.ioMessageSystemWillSleep {
            handleWillSleep(messageArgument: messageArgument)
        } else if messageType == Self.ioMessageCanSystemSleep {
            // We do not veto idle sleep. Acknowledge it promptly without creating work.
            acknowledgeSleepChange(messageArgument: messageArgument)
        } else if messageType == Self.ioMessageSystemHasPoweredOn,
                  let generation = activeGeneration() {
            enqueue(.reconcile(.wake), generation: generation)
        }
    }

    private func handleWillSleep(messageArgument: UnsafeMutableRawPointer?) {
        stateLock.lock()
        let isRunning = self.isRunning
        let generation = self.generation
        let connection = powerConnection
        stateLock.unlock()

        if isRunning {
            enqueue(.pendingSleepRotation, generation: generation)
        }

        // `kIOMessageSystemWillSleep` is non-abortable. Do not do MAC work in this
        // callback: acknowledge immediately so the system may continue sleeping.
        if connection != 0, let messageArgument {
            _ = IOAllowPowerChange(connection, Int(bitPattern: messageArgument))
        }
    }

    private func acknowledgeSleepChange(messageArgument: UnsafeMutableRawPointer?) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard powerConnection != 0, let messageArgument else { return }
        _ = IOAllowPowerChange(powerConnection, Int(bitPattern: messageArgument))
    }

    // MARK: - SystemConfiguration callbacks

    private static let dynamicStoreCallback: SCDynamicStoreCallBack = { _, changedKeys, info in
        guard let info else { return }

        let context = Unmanaged<CallbackContext>
            .fromOpaque(info)
            .takeUnretainedValue()
        context.handleDynamicStoreChange(changedKeys)
    }

    fileprivate func handleDynamicStoreChange(_ changedKeys: CFArray) {
        guard let generation = activeGeneration() else { return }

        // An empty key list is the documented signal that the Dynamic Store server
        // restarted. Do not attempt an incremental interpretation of stale state.
        let reason: ReconcileReason = CFArrayGetCount(changedKeys) == 0
            ? .storeRestart
            : .networkChange
        enqueue(.reconcile(reason), generation: generation)
    }

    // MARK: - State and setup

    private func dynamicStoreNotificationKeys() -> (keys: CFArray, patterns: CFArray) {
        let globalIPv4 = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCEntNetIPv4
        )
        let globalIPv6 = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCEntNetIPv6
        )
        let interfaceLink = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCCompAnyRegex,
            kSCEntNetLink
        )
        let serviceIPv4 = SCDynamicStoreKeyCreateNetworkServiceEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCCompAnyRegex,
            kSCEntNetIPv4
        )
        let serviceIPv6 = SCDynamicStoreKeyCreateNetworkServiceEntity(
            nil,
            kSCDynamicStoreDomainState,
            kSCCompAnyRegex,
            kSCEntNetIPv6
        )

        return (
            [globalIPv4, globalIPv6] as CFArray,
            [interfaceLink, serviceIPv4, serviceIPv6] as CFArray
        )
    }

    private func beginRunning(with connection: io_connect_t) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }

        generation &+= 1
        powerConnection = connection
        isRunning = true
        return generation
    }

    private func endRunning() {
        stateLock.lock()
        isRunning = false
        generation &+= 1
        stateLock.unlock()
    }

    private func isMonitorRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    private func activeGeneration() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning ? generation : nil
    }

    private func isCurrentGeneration(_ expectedGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning && generation == expectedGeneration
    }

    private func enqueue(_ event: Event, generation: UInt64) {
        eventQueue.async { [weak self] in
            guard let self, self.isCurrentGeneration(generation) else { return }
            self.eventHandler(event)
        }
    }

    private func tearDownPowerNotifications(
        connection: io_connect_t,
        notifier: io_object_t,
        notificationPort: IONotificationPortRef
    ) {
        var notifier = notifier
        if notifier != 0 {
            _ = IODeregisterForSystemPower(&notifier)
        }
        IONotificationPortDestroy(notificationPort)
        if connection != 0 {
            _ = IOServiceClose(connection)
        }
    }

    private func releaseCallbackContextAfterCallbacks(_ pointer: UnsafeMutableRawPointer) {
        callbackQueue.async {
            Unmanaged<CallbackContext>.fromOpaque(pointer).release()
        }
    }

    // MARK: - Stored state

    private let eventHandler: EventHandler
    private let callbackQueue = DispatchQueue(label: "com.macdancer.daemon.system-events.callbacks")
    private let eventQueue = DispatchQueue(label: "com.macdancer.daemon.system-events.events")
    private let lifecycleLock = NSLock()
    private let stateLock = NSLock()

    // Access only while `lifecycleLock` is held.
    private var notificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var dynamicStore: SCDynamicStore?
    private var callbackContext: CallbackContext?
    private var callbackContextPointer: UnsafeMutableRawPointer?

    // Access only while `stateLock` is held.
    private var powerConnection: io_connect_t = 0
    private var isRunning = false
    private var generation: UInt64 = 0
}

private final class CallbackContext {
    init(monitor: SystemEventMonitor) {
        self.monitor = monitor
    }

    func invalidate() {
        lock.lock()
        monitor = nil
        lock.unlock()
    }

    func handlePowerMessage(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        withMonitor { monitor in
            monitor.handlePowerMessage(messageType: messageType, messageArgument: messageArgument)
        }
    }

    func handleDynamicStoreChange(_ changedKeys: CFArray) {
        withMonitor { monitor in
            monitor.handleDynamicStoreChange(changedKeys)
        }
    }

    private func withMonitor(_ body: (SystemEventMonitor) -> Void) {
        lock.lock()
        let monitor = monitor
        lock.unlock()

        if let monitor {
            body(monitor)
        }
    }

    private let lock = NSLock()
    private weak var monitor: SystemEventMonitor?
}
