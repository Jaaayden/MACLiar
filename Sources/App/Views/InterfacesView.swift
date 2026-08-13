import SwiftUI

struct InterfacesPageView: View {
  @EnvironmentObject private var model: AppModel

  @Binding var selectedInterfaceID: String?
  let onRandomize: (InterfaceSnapshot) -> Void
  let onRestore: (InterfaceSnapshot) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        SectionHeader(
          title: L("interfaces.title", "Interfaces"),
          subtitle: L("interfaces.subtitle", "Current values are read directly from macOS. Changing a MAC is always an explicit action.")
        )

        if model.interfaces.isEmpty {
          EmptyState(
            systemImage: "network.slash",
            title: L("interfaces.empty.title", "No supported interfaces found"),
            detail: L("interfaces.empty.detail", "MACDancer lists Wi-Fi and Ethernet adapters that macOS reports as usable."),
            actionTitle: L("common.refresh", "Refresh"),
            action: { model.refresh() }
          )
          .frame(minHeight: 320)
        } else {
          ForEach(model.interfaces) { interface in
            InterfaceStatusCard(
              interface: interface,
              isSelected: selectedInterfaceID == interface.id,
              onCopy: {
                if let address = interface.currentMAC {
                  copyToPasteboard(address.stringValue)
                }
              },
              onRandomize: { onRandomize(interface) },
              onRestore: { onRestore(interface) }
            )
            .contentShape(Rectangle())
            .onTapGesture {
              selectedInterfaceID = interface.id
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 1_060, alignment: .leading)
    }
    .navigationTitle(L("interfaces.title", "Interfaces"))
  }
}

struct InterfaceStatusCard: View {
  @EnvironmentObject private var model: AppModel

  let interface: InterfaceSnapshot
  var compact = false
  var isSelected = false
  let onCopy: () -> Void
  let onRandomize: () -> Void
  let onRestore: () -> Void
  @State private var confirmsClearHistory = false

  private var usesHardwareMAC: Bool {
    guard let current = interface.currentMAC, let hardware = interface.hardwareMAC else { return false }
    return current == hardware
  }

  private var operationInProgress: Bool {
    model.isOperationInProgress(interfaceID: interface.id)
  }

  private var interfaceSymbol: String {
    switch interface.kind {
    case .wifi:
      "wifi"
    case .ethernet:
      "cable.connector.horizontal"
    case .other:
      "network"
    }
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: compact ? 10 : 14) {
        header

        if compact {
          compactDetails
        } else {
          detailedMACs
          operationDetails
          historyDetails
        }

        Divider()
        actions
      }
      .padding(5)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        .padding(1)
    }
    .contextMenu {
      Button(L("interface.action.copy", "Copy current MAC"), action: onCopy)
        .disabled(interface.currentMAC == nil)
      Button(L("interface.action.randomize", "Randomize now"), action: onRandomize)
        .disabled(interface.kind == .other || operationInProgress)
      Button(L("interface.action.restore", "Restore…"), action: onRestore)
        .disabled(operationInProgress)
    }
    .alert(
      L("history.clear.confirmation.title", "Clear this interface’s MAC history?"),
      isPresented: $confirmsClearHistory
    ) {
      Button(L("history.clear.action", "Clear History"), role: .destructive) {
        model.clearHistory(interfaceID: interface.id)
      }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L(
        "history.clear.confirmation.message",
        "This removes saved MAC choices for this interface. It does not change the current MAC address or policy."
      ))
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: interfaceSymbol)
        .font(.title2)
        .frame(width: 28)
        .foregroundStyle(interface.kind == .other ? .secondary : Color.accentColor)

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(interface.displayName)
            .font(.headline)
          Text(interface.bsdName)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        Text(policyText(interface.policy))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      HStack(spacing: 6) {
        if interface.isDefaultRoute {
          StatusPill(
            title: L("interface.default_route", "Default route"),
            systemImage: "arrow.triangle.branch",
            tint: .orange
          )
        }
        if interface.isActive {
          StatusPill(
            title: L("interface.active", "Active"),
            systemImage: "bolt.fill",
            tint: .green
          )
        }
      }
    }
  }

  private var compactDetails: some View {
    HStack(alignment: .lastTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(L("interface.current_mac", "Current MAC"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(macText(interface.currentMAC))
          .font(.system(.body, design: .monospaced, weight: .medium))
          .textSelection(.enabled)
      }
      Spacer()
      if usesHardwareMAC {
        StatusPill(
          title: L("interface.using_hardware", "Using hardware MAC"),
          systemImage: "exclamationmark.shield",
          tint: .orange
        )
      }
    }
  }

  private var detailedMACs: some View {
    HStack(alignment: .top, spacing: 28) {
      MACValue(label: L("interface.current_mac", "Current MAC"), value: macText(interface.currentMAC), prominent: true)
      MACValue(label: L("interface.hardware_mac", "Hardware MAC"), value: macText(interface.hardwareMAC))
      Spacer()
      if usesHardwareMAC {
        StatusPill(
          title: L("interface.using_hardware", "Using hardware MAC"),
          systemImage: "exclamationmark.shield",
          tint: .orange
        )
      }
    }
  }

  @ViewBuilder
  private var operationDetails: some View {
    if let operation = interface.lastOperation {
      HStack(alignment: .top, spacing: 8) {
        StatusPill(
          title: operationStateText(operation.state),
          systemImage: operation.state == .succeeded ? "checkmark.circle.fill" : "clock",
          tint: operationStateColor(operation.state)
        )
        VStack(alignment: .leading, spacing: 2) {
          Text(operationText(operation.kind))
            .font(.caption)
          Text(dateTimeText(operation.completedAt ?? operation.startedAt))
            .font(.caption2)
            .foregroundStyle(.secondary)
          if let message = operation.message, !message.isEmpty {
            Text(message)
              .font(.caption)
              .foregroundStyle(operation.state == .failed ? .red : .secondary)
          }
        }
      }
    }

    if let error = interface.errorMessage, !error.isEmpty {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private var historyDetails: some View {
    if !interface.history.entries.isEmpty {
      DisclosureGroup {
        VStack(spacing: 0) {
          ForEach(interface.history.entries) { entry in
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.address.stringValue)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                Text("\(historySourceText(entry.source)) · \(dateTimeText(entry.lastUsedAt))")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                copyToPasteboard(entry.address.stringValue)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help(L("history.copy", "Copy this address"))

              Button(role: .destructive) {
                model.removeHistory(interfaceID: interface.id, address: entry.address)
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
              .help(L("history.delete", "Delete this history entry"))
            }
            .padding(.vertical, 7)

            if entry.id != interface.history.entries.last?.id {
              Divider()
            }
          }

          HStack {
            Spacer()
            Button(L("history.clear.action", "Clear History"), role: .destructive) {
              confirmsClearHistory = true
            }
            .buttonStyle(.borderless)
            .padding(.top, 7)
          }
        }
        .padding(.top, 6)
      } label: {
        Text(String(
          format: L("history.disclosure.count_format", "History (%d of 20)"),
          interface.history.entries.count
        ))
        .font(.subheadline.weight(.medium))
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 10) {
      Button(L("interface.action.copy", "Copy current MAC"), action: onCopy)
        .disabled(interface.currentMAC == nil)

      Button(L("interface.action.randomize", "Randomize now"), action: onRandomize)
        .buttonStyle(.borderedProminent)
        .disabled(interface.kind == .other || operationInProgress)

      Button(L("interface.action.restore", "Restore…"), action: onRestore)
        .disabled(operationInProgress)

      if !compact {
        Menu {
          Button(L("policy.action.random", "Use random policy")) {
            model.setPolicy(interfaceID: interface.id, policy: .random)
          }
          Button(L("policy.action.system_managed", "Hand off to macOS…"), action: onRestore)
        } label: {
          Label(L("policy.action.menu", "Policy"), systemImage: "slider.horizontal.3")
        }
        .disabled(interface.kind == .other || operationInProgress)
      }

      Spacer()

      if interface.isActive || interface.isDefaultRoute {
        Label(L("interface.disruption_notice", "Changes require confirmation"), systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

private struct MACValue: View {
  let label: String
  let value: String
  var prominent = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(prominent ? .title3 : .body, design: .monospaced, weight: prominent ? .semibold : .regular))
        .textSelection(.enabled)
    }
  }
}
