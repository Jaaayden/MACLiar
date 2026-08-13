import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppModel

  let onShowInterfaces: () -> Void
  let onRandomize: (InterfaceSnapshot) -> Void
  let onRestore: (InterfaceSnapshot) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        SectionHeader(
          title: L("dashboard.title", "Dashboard"),
          subtitle: L("dashboard.subtitle", "See the MAC address your network interfaces are using right now.")
        )

        DaemonManagementCard()

        overview

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(L("dashboard.interfaces.title", "Interfaces"))
              .font(.title2.weight(.semibold))
            Spacer()
            Button(L("dashboard.interfaces.show_all", "Show all"), action: onShowInterfaces)
          }

          if model.interfaces.isEmpty {
            EmptyState(
              systemImage: "network.slash",
              title: L("dashboard.interfaces.empty.title", "No supported network interfaces"),
              detail: L("dashboard.interfaces.empty.detail", "Connect an Ethernet adapter or enable Wi-Fi, then refresh this view."),
              actionTitle: L("common.refresh", "Refresh"),
              action: { model.refresh() }
            )
            .frame(minHeight: 200)
          } else {
            ForEach(model.interfaces.prefix(3)) { interface in
              InterfaceStatusCard(
                interface: interface,
                compact: true,
                onCopy: {
                  if let address = interface.currentMAC {
                    copyToPasteboard(address.stringValue)
                  }
                },
                onRandomize: { onRandomize(interface) },
                onRestore: { onRestore(interface) }
              )
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: 1_060, alignment: .leading)
    }
    .navigationTitle(L("dashboard.title", "Dashboard"))
  }

  private var overview: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(minimum: 180)), GridItem(.flexible(minimum: 180)), GridItem(.flexible(minimum: 180))],
      spacing: 12
    ) {
      OverviewMetric(
        title: L("dashboard.metric.interfaces", "Supported interfaces"),
        value: "\(model.interfaces.count)",
        detail: L("dashboard.metric.interfaces.detail", "Wi-Fi and Ethernet adapters")
      )

      OverviewMetric(
        title: L("dashboard.metric.active", "Active now"),
        value: "\(model.interfaces.filter(\.isActive).count)",
        detail: L("dashboard.metric.active.detail", "Interfaces currently in use")
      )

      OverviewMetric(
        title: L("dashboard.metric.hardware", "Using hardware MAC"),
        value: "\(hardwareMACCount)",
        detail: L("dashboard.metric.hardware.detail", "Review the interface before changing it")
      )
    }
  }

  private var hardwareMACCount: Int {
    model.interfaces.filter { interface in
      guard let current = interface.currentMAC, let hardware = interface.hardwareMAC else { return false }
      return current == hardware
    }.count
  }
}

private struct OverviewMetric: View {
  let title: String
  let value: String
  let detail: String

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 7) {
        Text(title)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(size: 30, weight: .semibold, design: .rounded))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
  }
}

struct DaemonManagementCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsUninstall = false

  private var presentation: DaemonPresentation {
    DaemonPresentation(model.daemonState)
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: presentation.systemImage)
            .font(.title2)
            .foregroundStyle(presentation.tint)
            .frame(width: 28)

          VStack(alignment: .leading, spacing: 4) {
            Text(L("daemon.card.title", "Background service"))
              .font(.headline)
            Text(presentation.message)
              .foregroundStyle(.secondary)
          }
          Spacer()
          StatusPill(title: presentation.title, systemImage: presentation.systemImage, tint: presentation.tint)
        }

        HStack(spacing: 10) {
          switch presentation.kind {
          case .notInstalled:
            Button(L("daemon.action.install", "Install background service")) {
              model.installDaemon()
            }
            .buttonStyle(.borderedProminent)

          case .awaitingApproval:
            Button(L("daemon.action.open_settings", "Open System Settings")) {
              openBackgroundItemsSettings()
            }
            .buttonStyle(.borderedProminent)

          case .unavailable, .unknown:
            Button(L("daemon.action.repair", "Repair connection")) {
              model.repairDaemon()
            }
            .buttonStyle(.borderedProminent)

          case .ready:
            Button(L("daemon.action.repair", "Repair connection")) {
              model.repairDaemon()
            }
          }

          Menu {
            Button(L("daemon.action.install", "Install background service")) {
              model.installDaemon()
            }
            Button(L("daemon.action.repair", "Repair connection")) {
              model.repairDaemon()
            }
            if presentation.kind == .awaitingApproval {
              Button(L("daemon.action.open_settings", "Open System Settings")) {
                openBackgroundItemsSettings()
              }
            }
            Divider()
            Button(L("daemon.action.uninstall", "Uninstall background service"), role: .destructive) {
              confirmsUninstall = true
            }
          } label: {
            Label(L("common.more", "More"), systemImage: "ellipsis.circle")
          }

          Spacer()
        }

        Divider()

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
          serviceFact(
            L("daemon.fact.registration", "Registration"),
            daemonRegistrationText(model.daemonRegistration)
          )
          serviceFact(
            L("daemon.fact.approval", "User approval"),
            model.daemonRegistration == .requiresApproval
              ? L("daemon.fact.required", "Required")
              : L("daemon.fact.not_required", "Not pending")
          )
          serviceFact(
            L("daemon.fact.xpc", "XPC reachability"),
            daemonReachabilityText(model.daemonReachability)
          )
          serviceFact(
            L("daemon.fact.health", "Daemon health"),
            daemonHealthText(model.daemonHealth)
          )
          serviceFact(
            L("daemon.fact.protocol", "Protocol"),
            "GUI \(MACDancerConstants.protocolVersion) · daemon \(model.daemonVersion.map(String.init) ?? "—")"
          )
        }

        if model.legacyLinkLiarDetected {
          Label(
            L(
              "daemon.legacy.warning",
              "LinkLiar’s legacy daemon was detected. MACDancer remains read-only to prevent two services from competing."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.red)
        }
      }
      .padding(4)
    }
    .alert(
      L("daemon.uninstall.title", "Uninstall the background service?"),
      isPresented: $confirmsUninstall
    ) {
      Button(L("daemon.action.uninstall", "Uninstall background service"), role: .destructive) {
        model.uninstallDaemon()
      }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
        .keyboardShortcut(.cancelAction)
    } message: {
      Text(L(
        "daemon.uninstall.message",
        "Automatic MAC protection stops immediately. The current MAC, configuration, and per-interface history are preserved. No address is restored implicitly."
      ))
    }
  }

  private func serviceFact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(.subheadline, design: .monospaced))
    }
  }
}

private struct DaemonPresentation {
  enum Kind {
    case ready
    case notInstalled
    case awaitingApproval
    case unavailable
    case unknown
  }

  let kind: Kind

  init(_ state: DaemonLifecycleState) {
    switch state {
    case .ready: kind = .ready
    case .notInstalled: kind = .notInstalled
    case .awaitingApproval: kind = .awaitingApproval
    case .unavailable: kind = .unavailable
    case .checking: kind = .unknown
    }
  }

  var title: String {
    switch kind {
    case .ready:
      L("daemon.status.ready", "Ready")
    case .notInstalled:
      L("daemon.status.not_installed", "Not installed")
    case .awaitingApproval:
      L("daemon.status.awaiting_approval", "Approval required")
    case .unavailable:
      L("daemon.status.unavailable", "Unavailable")
    case .unknown:
      L("daemon.status.checking", "Checking")
    }
  }

  var message: String {
    switch kind {
    case .ready:
      L("daemon.message.ready", "The service can apply configured MAC changes and report their verified result.")
    case .notInstalled:
      L("daemon.message.not_installed", "Install the privileged background service before changing a MAC address.")
    case .awaitingApproval:
      L("daemon.message.awaiting_approval", "macOS must approve this background service before it can run.")
    case .unavailable:
      L("daemon.message.unavailable", "The service is registered but not responding. Repair the connection before requesting a change.")
    case .unknown:
      L("daemon.message.checking", "MACDancer is checking the service connection.")
    }
  }

  var systemImage: String {
    switch kind {
    case .ready:
      "checkmark.shield.fill"
    case .notInstalled:
      "arrow.down.app"
    case .awaitingApproval:
      "lock.shield"
    case .unavailable:
      "exclamationmark.triangle.fill"
    case .unknown:
      "questionmark.circle"
    }
  }

  var tint: Color {
    switch kind {
    case .ready:
      .green
    case .notInstalled, .awaitingApproval, .unknown:
      .orange
    case .unavailable:
      .red
    }
  }
}
