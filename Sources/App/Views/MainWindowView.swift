import SwiftUI

struct MainWindowView: View {
  @EnvironmentObject private var model: AppModel

  @State private var selectedInterfaceID: String?
  @State private var restoreInterfaceID: String?
  @State private var randomizationConfirmationInterfaceID: String?

  var body: some View {
    NavigationSplitView {
      List(selection: sectionSelection) {
        Section {
          navigationRow(.dashboard, title: L("section.dashboard", "Dashboard"), symbol: "rectangle.3.group.fill")
          navigationRow(.interfaces, title: L("section.interfaces", "Interfaces"), symbol: "network")
          navigationRow(.automation, title: L("section.automation", "Automation"), symbol: "clock.arrow.circlepath")
          navigationRow(.settings, title: L("section.settings", "Settings"), symbol: "gearshape")
        }
      }
      .listStyle(.sidebar)
      .navigationTitle(L("app.title", "MACDancer"))
      .safeAreaInset(edge: .bottom) {
        refreshFooter
      }
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 840, minHeight: 560)
    .toolbar {
      ToolbarItem(placement: .principal) {
        toolbarStatus
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          model.refresh()
        } label: {
          if model.isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Label(L("toolbar.refresh", "Refresh"), systemImage: "arrow.clockwise")
          }
        }
        .help(L("toolbar.refresh_help", "Read current MAC addresses only. This never changes your network."))
        .disabled(model.isRefreshing)
      }
    }
    .focusedValue(\.macDancerCopyAction, focusedCopyAction)
    .sheet(isPresented: restoreSheetPresented) {
      if let interface = restoreInterface {
        RestoreSheet(
          interface: interface,
          handoff: {
            model.handoff(interfaceID: interface.id) {
              if interface.kind == .wifi { openNetworkSettings() }
            }
          },
          restoreHardware: { confirmed in
            model.restoreHardware(interfaceID: interface.id, confirmed: confirmed)
          },
          restoreHistory: { address, confirmed in
            model.restoreHistory(interfaceID: interface.id, address: address, confirmed: confirmed)
          },
          restoreSpecified: { address, confirmed, confirmedGlobalAddressRisk in
            model.restoreSpecified(
              interfaceID: interface.id,
              address: address,
              confirmed: confirmed,
              confirmedGlobalAddressRisk: confirmedGlobalAddressRisk
            )
          },
          dismiss: {
            restoreInterfaceID = nil
          }
        )
      }
    }
    .confirmationDialog(
      L("randomize.confirmation.title", "Changing this MAC address may interrupt your connection"),
      isPresented: randomizationConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(L("randomize.confirmation.action", "Randomize now"), role: .destructive) {
        if let interface = randomizationConfirmationInterface {
          model.randomize(interface: interface)
        }
        randomizationConfirmationInterfaceID = nil
      }

      Button(L("common.cancel", "Cancel"), role: .cancel) {
        randomizationConfirmationInterfaceID = nil
      }
      .keyboardShortcut(.cancelAction)
    } message: {
      Text(L(
        "randomize.confirmation.message",
        "This is an active or default-route interface. Its connection can drop while macOS adopts the new MAC address."
      ))
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text(L("common.ok", "OK")))
      )
    }
  }

  private func navigationRow(_ section: AppSection, title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .tag(section)
  }

  private var sectionSelection: Binding<AppSection> {
    Binding(
      get: { model.selection },
      set: { model.selectSection($0) }
    )
  }

  @ViewBuilder
  private var detail: some View {
    switch model.selection {
    case .dashboard:
      DashboardView(
        onShowInterfaces: { model.selectSection(.interfaces) },
        onRandomize: requestRandomization,
        onRestore: presentRestore
      )

    case .interfaces:
      InterfacesPageView(
        selectedInterfaceID: $selectedInterfaceID,
        onRandomize: requestRandomization,
        onRestore: presentRestore
      )

    case .automation:
      AutomationView(onShowInterfaces: { model.selectSection(.interfaces) })

    case .settings:
      MACDancerSettingsView(onShowDashboard: { model.selectSection(.dashboard) })
    }
  }

  @ViewBuilder
  private var toolbarStatus: some View {
    if model.isRefreshing {
      Label(L("refresh.reading", "Reading current MAC addresses…"), systemImage: "arrow.triangle.2.circlepath")
        .foregroundStyle(.secondary)
    } else {
      Text(String(format: L("refresh.last_updated_format", "Last updated %@"), dateTimeText(model.lastRefreshAt)))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var refreshFooter: some View {
    HStack(spacing: 6) {
      Image(systemName: "eye")
      Text(L("refresh.read_only", "Refresh only reads current MAC addresses. It does not change your network."))
        .lineLimit(2)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
  }

  private var restoreSheetPresented: Binding<Bool> {
    Binding(
      get: { restoreInterfaceID != nil },
      set: { isPresented in
        if !isPresented { restoreInterfaceID = nil }
      }
    )
  }

  private var restoreInterface: InterfaceSnapshot? {
    guard let restoreInterfaceID else { return nil }
    return model.interfaces.first(where: { $0.id == restoreInterfaceID })
  }

  private var randomizationConfirmationPresented: Binding<Bool> {
    Binding(
      get: { randomizationConfirmationInterfaceID != nil },
      set: { isPresented in
        if !isPresented { randomizationConfirmationInterfaceID = nil }
      }
    )
  }

  private var randomizationConfirmationInterface: InterfaceSnapshot? {
    guard let randomizationConfirmationInterfaceID else { return nil }
    return model.interfaces.first(where: { $0.id == randomizationConfirmationInterfaceID })
  }

  private var focusedCopyAction: (() -> Void)? {
    let interface = selectedInterfaceID.flatMap { selectedID in
      model.interfaces.first(where: { $0.id == selectedID })
    } ?? model.interfaces.first

    guard let currentMAC = interface?.currentMAC else { return nil }
    return { copyToPasteboard(currentMAC.stringValue) }
  }

  private func presentRestore(_ interface: InterfaceSnapshot) {
    restoreInterfaceID = interface.id
  }

  private func requestRandomization(_ interface: InterfaceSnapshot) {
    guard interface.isActive || interface.isDefaultRoute else {
      model.randomize(interface: interface)
      return
    }
    randomizationConfirmationInterfaceID = interface.id
  }
}
