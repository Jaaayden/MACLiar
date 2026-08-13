import SwiftUI

struct MACDancerSettingsView: View {
  @EnvironmentObject private var model: AppModel
  @AppStorage(MACDancerMenuBarIconPreferenceKey) private var showMenuBarIcon = true
  @AppStorage("showDiagnosticDetails") private var showDiagnosticDetails = false
  let onShowDashboard: () -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        SectionHeader(
          title: L("settings.title", "Settings"),
          subtitle: L("settings.subtitle", "Choose how MACDancer appears and learn which privacy settings macOS controls itself.")
        )

        GroupBox {
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: "globe")
              .font(.title2)
              .foregroundStyle(Color.accentColor)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
              Text(L("settings.language.title", "Language"))
                .font(.headline)
              Text(L("settings.language.detail", "Choose a language for MACDancer without changing the macOS system language."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Picker(L("settings.language.title", "Language"), selection: $model.preferredLanguage) {
              Text(L("settings.language.system", "System Default")).tag(AppLanguage.system)
              Text("English").tag(AppLanguage.english)
              Text("简体中文").tag(AppLanguage.simplifiedChinese)
            }
            .labelsHidden()
            .frame(width: 170)
          }
          .padding(4)
        }

        GroupBox {
          HStack(alignment: .top, spacing: 14) {
            Image(systemName: "menubar.rectangle")
              .font(.title2)
              .foregroundStyle(Color.accentColor)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
              Text(L("settings.menu_bar.title", "Show menu bar icon"))
                .font(.headline)
              Text(L(
                "settings.menu_bar.detail",
                "Keep a small status-menu shortcut available. The main MACDancer window and Dock icon remain available when this is turned off."
              ))
              .font(.subheadline)
              .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Toggle(L("settings.menu_bar.toggle", "Show menu bar icon"), isOn: $showMenuBarIcon)
              .labelsHidden()
              .toggleStyle(.switch)
          }
          .padding(4)
        }

        GroupBox {
          Toggle(isOn: Binding(
            get: { model.automationSettings.vendorCompatibility },
            set: { newValue in
              var settings = model.automationSettings
              settings.vendorCompatibility = newValue
              model.updateAutomation(settings)
            }
          )) {
            HStack(alignment: .top, spacing: 14) {
              Image(systemName: "building.2.crop.circle")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)

              VStack(alignment: .leading, spacing: 5) {
                Text(L("settings.vendor.title", "Vendor-OUI compatibility mode"))
                  .font(.headline)
                Text(L(
                  "settings.vendor.detail",
                  "Use this interface’s verified hardware OUI with a random suffix. This can help strict networks, but reveals the device vendor and reduces privacy."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(L(
                  "settings.vendor.warning",
                  "MACDancer never accepts an arbitrary vendor OUI from the GUI. If the hardware OUI is unavailable, randomization fails safely."
                ))
                .font(.caption)
                .foregroundStyle(.orange)
              }
            }
          }
          .toggleStyle(.switch)
          .padding(4)
        }
        .disabled(model.daemonState != .ready || model.isUpdatingAutomation)

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: "wifi.badge.lock")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

              VStack(alignment: .leading, spacing: 5) {
                Text(L("settings.private_wifi.title", "Private Wi-Fi Address"))
                  .font(.headline)
                Text(L(
                  "settings.private_wifi.detail",
                  "Private Wi-Fi Address is a per-network macOS setting. MACDancer can explain it and take you to System Settings, but it never changes that setting for you."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              }
            }

            Button(L("settings.private_wifi.open", "Open Network Settings")) {
              openNetworkSettings()
            }
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(L("settings.diagnostics.toggle", "Show diagnostic details"), isOn: $showDiagnosticDetails)
              .toggleStyle(.switch)

            if showDiagnosticDetails {
              Divider()
              diagnosticRow(L("settings.diagnostics.registration", "Registration"), daemonRegistrationText(model.daemonRegistration))
              diagnosticRow(L("settings.diagnostics.reachability", "XPC reachability"), daemonReachabilityText(model.daemonReachability))
              diagnosticRow(L("settings.diagnostics.health", "Daemon health"), daemonHealthText(model.daemonHealth))
              diagnosticRow(
                L("settings.diagnostics.protocol", "Protocol"),
                "GUI \(MACDancerConstants.protocolVersion) · daemon \(model.daemonVersion.map(String.init) ?? "—")"
              )
              if let diagnostic = model.daemonDiagnostic, !diagnostic.isEmpty {
                Text(diagnostic)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: "arrow.clockwise.circle")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 28)

              VStack(alignment: .leading, spacing: 5) {
                Text(L("settings.refresh.title", "Read-only refresh"))
                  .font(.headline)
                Text(L(
                  "settings.refresh.detail",
                  "Refresh only asks macOS for the current MAC address of each interface. It does not contact the daemon, scan Wi-Fi, write configuration, or disconnect a network."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              }
            }

            Text(String(format: L("settings.refresh.last_updated", "Last read: %@"), dateTimeText(model.lastRefreshAt)))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(4)
        }

        GroupBox {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
              .font(.title2)
              .foregroundStyle(.green)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
              Text(L("settings.daemon.title", "Background service"))
                .font(.headline)
              Text(L(
                "settings.daemon.detail",
                "Install, approve, repair, or remove the service from the Dashboard. MACDancer reports its state separately from the visible interface values."
              ))
              .font(.subheadline)
              .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Button(L("settings.daemon.show", "Show Dashboard"), action: onShowDashboard)
          }
          .padding(4)
        }
      }
      .padding(24)
      .frame(maxWidth: 1_000, alignment: .leading)
    }
    .navigationTitle(L("settings.title", "Settings"))
  }

  private func diagnosticRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).font(.system(.body, design: .monospaced))
    }
    .font(.subheadline)
  }
}
