import AppKit
import ServiceManagement
import SwiftUI

/// Keeps user-facing copy localization-ready while the project is still using
/// Xcode-generated string catalogs.
@inline(__always)
func L(_ key: String, _ defaultValue: String) -> String {
  let preference = AppLanguage(
    rawValue: UserDefaults.standard.string(forKey: MACDancerLanguagePreferenceKey) ?? ""
  ) ?? .system
  switch preference {
  case .english:
    return defaultValue
  case .simplifiedChinese:
    guard let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
          let bundle = Bundle(path: path) else { return defaultValue }
    return bundle.localizedString(forKey: key, value: defaultValue, table: nil)
  case .system:
    return Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
  }
}

func macText(_ address: MACAddress?) -> String {
  address?.stringValue ?? L("mac.unavailable", "Unavailable")
}

func policyText(_ policy: InterfacePolicy) -> String {
  switch policy {
  case .systemManaged:
    L("policy.system_managed", "Managed by macOS")
  case .random:
    L("policy.random", "Random MAC")
  case let .specified(address):
    String(format: L("policy.specified_format", "Specified: %@"), address.stringValue)
  }
}

func historySourceText(_ source: HistorySource) -> String {
  switch source {
  case .generatedLocal:
    L("history.source.generated_local", "Generated locally")
  case .vendorCompatible:
    L("history.source.vendor_compatible", "Vendor-compatible")
  case .userSpecified:
    L("history.source.user_specified", "Specified by you")
  case .historyRestore:
    L("history.source.history_restore", "Restored from history")
  }
}

func operationText(_ kind: OperationKind) -> String {
  switch kind {
  case .randomize:
    L("operation.randomize", "Randomized")
  case .restoreHardware:
    L("operation.restore_hardware", "Restored hardware MAC")
  case .restoreHistory:
    L("operation.restore_history", "Restored from history")
  case .restoreSpecified:
    L("operation.restore_specified", "Applied specified MAC")
  case .handoff:
    L("operation.handoff", "Handed off to macOS")
  case .reconcile:
    L("operation.reconcile", "Reconciled")
  }
}

func operationStateText(_ state: OperationState) -> String {
  switch state {
  case .pending:
    L("operation_state.pending", "Pending")
  case .running:
    L("operation_state.running", "Working")
  case .succeeded:
    L("operation_state.succeeded", "Up to date")
  case .deferred:
    L("operation_state.deferred", "Deferred for safety")
  case .cancelled:
    L("operation_state.cancelled", "Cancelled")
  case .failed:
    L("operation_state.failed", "Needs attention")
  }
}

func operationStateColor(_ state: OperationState) -> Color {
  switch state {
  case .succeeded:
    .green
  case .pending, .running:
    .blue
  case .deferred:
    .orange
  case .cancelled:
    .secondary
  case .failed:
    .red
  }
}

func daemonRegistrationText(_ state: DaemonRegistrationState) -> String {
  switch state {
  case .unknown: L("daemon.registration.unknown", "Unknown")
  case .notInstalled: L("daemon.registration.not_installed", "Not installed")
  case .enabled: L("daemon.registration.enabled", "Registered")
  case .requiresApproval: L("daemon.registration.requires_approval", "Approval required")
  case .notFound: L("daemon.registration.not_found", "Helper not found")
  }
}

func daemonReachabilityText(_ state: DaemonReachability) -> String {
  switch state {
  case .unknown: L("daemon.reachability.unknown", "Unknown")
  case .connecting: L("daemon.reachability.connecting", "Connecting")
  case .reachable: L("daemon.reachability.reachable", "Reachable")
  case .interrupted: L("daemon.reachability.interrupted", "Interrupted")
  case .unavailable: L("daemon.reachability.unavailable", "Unavailable")
  }
}

func daemonHealthText(_ state: DaemonHealth) -> String {
  switch state {
  case .unknown: L("daemon.health.unknown", "Unknown")
  case .healthy: L("daemon.health.healthy", "Healthy")
  case .stale: L("daemon.health.stale", "Stale")
  case .incompatible: L("daemon.health.incompatible", "Protocol mismatch")
  case .unhealthy: L("daemon.health.unhealthy", "Needs attention")
  }
}

func dateTimeText(_ date: Date?) -> String {
  guard let date else { return L("time.never", "Never") }
  return date.formatted(date: .abbreviated, time: .shortened)
}

func copyToPasteboard(_ value: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(value, forType: .string)
}

@MainActor
@discardableResult
func bringMainWindowForward() -> Bool {
  let application = NSApplication.shared
  application.setActivationPolicy(.regular)
  application.activate()

  let candidate = application.windows.first { window in
    window.canBecomeKey && window.level == .normal
  }
  guard let candidate else { return false }
  candidate.makeKeyAndOrderFront(nil)
  return true
}

@MainActor
func openNetworkSettings() {
  guard let url = URL(string: "x-apple.systempreferences:com.apple.NetworkSettings-Settings.extension") else {
    return
  }
  if !NSWorkspace.shared.open(url) {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }
}

@MainActor
func openBackgroundItemsSettings() {
  SMAppService.openSystemSettingsLoginItems()
}

private struct MACDancerCopyActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var macDancerCopyAction: (() -> Void)? {
    get { self[MACDancerCopyActionKey.self] }
    set { self[MACDancerCopyActionKey.self] = newValue }
  }
}

struct StatusPill: View {
  let title: String
  let systemImage: String
  let tint: Color

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(tint.opacity(0.12), in: Capsule())
  }
}

struct SectionHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.largeTitle.weight(.semibold))
      Text(subtitle)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct EmptyState: View {
  let systemImage: String
  let title: String
  let detail: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(detail)
    } actions: {
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
      }
    }
  }
}
