import SwiftUI

struct AutomationView: View {
  @EnvironmentObject private var model: AppModel
  let onShowInterfaces: () -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        SectionHeader(
          title: L("automation.title", "Automation"),
          subtitle: L("automation.subtitle", "MACDancer keeps configured policies in sync without silently changing an active connection.")
        )

        GroupBox {
          VStack(alignment: .leading, spacing: 14) {
            HStack {
              VStack(alignment: .leading, spacing: 3) {
                Text(L("automation.configured.title", "Configured random-MAC interfaces"))
                  .font(.headline)
                Text(L("automation.configured.detail", "These policies are applied by the background service only when their safety conditions allow it."))
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text("\(randomPolicyCount)")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            }

            Button(L("automation.configure", "Review interface policies"), action: onShowInterfaces)
          }
          .padding(4)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 0) {
            automationToggle(
              title: L("automation.setting.wake.title", "Queue a rotation after wake"),
              detail: L(
                "automation.setting.wake.detail",
                "Reconcile after wake and rotate only after the interface is no longer active, associated Wi-Fi, or the default route."
              ),
              keyPath: \.rotateAfterWake
            )

            Divider().padding(.vertical, 10)

            automationToggle(
              title: L("automation.setting.inactive.title", "Rotate when an interface becomes inactive"),
              detail: L(
                "automation.setting.inactive.detail",
                "Queue one coalesced rotation when a configured interface transitions from active to safely inactive."
              ),
              keyPath: \.rotateWhenInterfaceBecomesInactive
            )

            Divider().padding(.vertical, 10)

            automationToggle(
              title: L("automation.setting.sleep.title", "Prepare a rotation before sleep"),
              detail: L(
                "automation.setting.sleep.detail",
                "Record pending work and let macOS sleep immediately. No MAC is written from the sleep callback."
              ),
              keyPath: \.prepareRotationBeforeSleep
            )
          }
          .padding(4)
        }
        .disabled(model.daemonState != .ready || model.isUpdatingAutomation)

        VStack(alignment: .leading, spacing: 10) {
          Text(L("automation.events.title", "Safety-first automatic events"))
            .font(.title2.weight(.semibold))

          AutomationEventRow(
            icon: "arrow.triangle.2.circlepath",
            title: L("automation.event.network.title", "Network conditions change"),
            detail: L("automation.event.network.detail", "The service rechecks configured policies after macOS reports an interface change."),
            tint: .blue
          )

          AutomationEventRow(
            icon: "bed.double.fill",
            title: L("automation.event.sleep.title", "Before sleep"),
            detail: L("automation.event.sleep.detail", "MACDancer only records pending work and immediately allows sleep; it never writes a MAC from the power callback."),
            tint: .purple
          )

          AutomationEventRow(
            icon: "wifi.slash",
            title: L("automation.event.active_wifi.title", "Active Wi-Fi is protected"),
            detail: L("automation.event.active_wifi.detail", "MACDancer never changes an active Wi-Fi connection automatically. Manual changes require your confirmation."),
            tint: .orange
          )

          AutomationEventRow(
            icon: "arrow.triangle.branch",
            title: L("automation.event.default_route.title", "Default route is protected"),
            detail: L("automation.event.default_route.detail", "Automatic changes are deferred while an interface carries your default route."),
            tint: .orange
          )
        }

        GroupBox {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
              .foregroundStyle(.secondary)
            Text(L(
              "automation.scope_notice",
              "This page explains the daemon’s existing behavior. It does not add a timer, scan networks, or make a network change by itself."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }
          .padding(4)
        }
      }
      .padding(24)
      .frame(maxWidth: 1_060, alignment: .leading)
    }
    .navigationTitle(L("automation.title", "Automation"))
  }

  private var randomPolicyCount: Int {
    model.interfaces.reduce(into: 0) { count, interface in
      if case .random = interface.policy {
        count += 1
      }
    }
  }

  private func automationToggle(
    title: String,
    detail: String,
    keyPath: WritableKeyPath<AutomationSettings, Bool>
  ) -> some View {
    Toggle(isOn: Binding(
      get: { model.automationSettings[keyPath: keyPath] },
      set: { newValue in
        var updated = model.automationSettings
        updated[keyPath: keyPath] = newValue
        model.updateAutomation(updated)
      }
    )) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
  }
}

private struct AutomationEventRow: View {
  let icon: String
  let title: String
  let detail: String
  let tint: Color

  var body: some View {
    GroupBox {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(tint)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(4)
    }
  }
}
