import SwiftUI

struct RestoreSheet: View {
  let interface: InterfaceSnapshot
  let handoff: () -> Void
  let restoreHardware: (Bool) -> Void
  let restoreHistory: (String, Bool) -> Void
  let restoreSpecified: (String, Bool, Bool) -> Void
  let dismiss: () -> Void

  @State private var destination: RestoreDestination = .systemManaged
  @State private var selectedHistoryID: String?
  @State private var specifiedAddress = ""
  @State private var confirmsDisruption = false
  @State private var confirmsGlobalAddressRisk = false

  private var destinationAddress: MACAddress? {
    switch destination {
    case .systemManaged:
      nil
    case .hardware:
      interface.hardwareMAC
    case .history:
      selectedHistory?.address
    case .specified:
      parsedSpecifiedAddress
    }
  }

  private var requiresDisruptionConfirmation: Bool {
    guard destination != .systemManaged,
          destinationAddress != nil,
          destinationAddress != interface.currentMAC else { return false }
    return interface.isActive || interface.isDefaultRoute
  }

  private var selectedHistory: HistoryEntry? {
    guard let selectedHistoryID else { return nil }
    return interface.history.entries.first(where: { $0.id == selectedHistoryID })
  }

  private var parsedSpecifiedAddress: MACAddress? {
    MACAddress(specifiedAddress)
  }

  private var specifiedNeedsGlobalAddressWarning: Bool {
    destination == .specified
      && parsedSpecifiedAddress?.isValidAssignable == true
      && parsedSpecifiedAddress?.isLocallyAdministered == false
  }

  private var canPerformRestore: Bool {
    guard !requiresDisruptionConfirmation || confirmsDisruption else { return false }
    guard !specifiedNeedsGlobalAddressWarning || confirmsGlobalAddressRisk else { return false }

    switch destination {
    case .systemManaged:
      return true
    case .hardware:
      return interface.hardwareMAC != nil
    case .history:
      return selectedHistory != nil
    case .specified:
      return parsedSpecifiedAddress?.isValidAssignable == true
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Form {
        Section(L("restore.destination.title", "Choose what to use")) {
          Picker(L("restore.destination.title", "Choose what to use"), selection: $destination) {
            Text(L("restore.destination.system_managed", "Hand off to macOS"))
              .tag(RestoreDestination.systemManaged)
            Text(L("restore.destination.hardware", "Use hardware MAC"))
              .tag(RestoreDestination.hardware)
              .disabled(interface.hardwareMAC == nil)
            Text(L("restore.destination.history", "Use this interface’s history"))
              .tag(RestoreDestination.history)
              .disabled(interface.history.entries.isEmpty)
            Text(L("restore.destination.specified", "Use a specified MAC"))
              .tag(RestoreDestination.specified)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
        }

        destinationDetail

        if requiresDisruptionConfirmation {
          Section {
            Toggle(isOn: $confirmsDisruption) {
              VStack(alignment: .leading, spacing: 4) {
                Label(
                  L("restore.disruption.title", "I understand this can interrupt my connection"),
                  systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Text(L(
                  "restore.disruption.detail",
                  "This interface is active or carries the default route. macOS may disconnect it while applying the requested MAC address."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }


        if specifiedNeedsGlobalAddressWarning {
          Section {
            Toggle(isOn: $confirmsGlobalAddressRisk) {
              VStack(alignment: .leading, spacing: 4) {
                Label(
                  L("restore.specified.global_warning.title", "I understand this is not a locally administered address"),
                  systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
                Text(L(
                  "restore.specified.global_warning.detail",
                  "This address can impersonate a globally assigned device identity. Use it only when you own the address and understand the collision risk."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }

        if interface.kind == .wifi {
          Section {
            VStack(alignment: .leading, spacing: 7) {
              Label(
                L("restore.private_wifi.title", "Private Wi-Fi Address is managed by macOS"),
                systemImage: "wifi.badge.lock"
              )
              .font(.headline)
              Text(L(
                "restore.private_wifi.detail",
                "MACDancer cannot enable or change the per-network Private Wi-Fi Address setting. Use System Settings to inspect that setting."
              ))
              .font(.caption)
              .foregroundStyle(.secondary)
              Button(L("restore.private_wifi.open", "Open Network Settings")) {
                openNetworkSettings()
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Button(L("common.cancel", "Cancel"), action: dismiss)
          .keyboardShortcut(.cancelAction)

        Spacer()

        Button(performTitle, action: performRestore)
          .buttonStyle(.borderedProminent)
          .disabled(!canPerformRestore)
      }
      .padding()
    }
    .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 610)
    .focusedValue(\.macDancerCopyAction, nil)
    .onAppear {
      selectedHistoryID = interface.history.entries.first?.id
      if interface.hardwareMAC == nil {
        destination = interface.history.entries.isEmpty ? .systemManaged : .history
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "arrow.uturn.backward.circle.fill")
        .font(.largeTitle)
        .foregroundStyle(Color.accentColor)

      VStack(alignment: .leading, spacing: 4) {
        Text(L("restore.title", "Restore MAC address"))
          .font(.title2.weight(.semibold))
        Text(interface.displayName + " · " + interface.bsdName)
          .foregroundStyle(.secondary)
        Text(String(format: L("restore.current_format", "Current: %@"), macText(interface.currentMAC)))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
  }

  @ViewBuilder
  private var destinationDetail: some View {
    switch destination {
    case .systemManaged:
      Section(L("restore.system_managed.title", "Hand off to macOS")) {
        Text(L(
          "restore.system_managed.detail",
          "Stop managing this interface through MACDancer and return responsibility to macOS. This does not pretend to configure Private Wi-Fi Address."
        ))
        .foregroundStyle(.secondary)

        if let current = interface.currentMAC,
           let hardware = interface.hardwareMAC,
           current != hardware {
          Label(
            L(
              "restore.system_managed.different_mac",
              "The current MAC differs from the hardware address. Handoff alone does not write it back; choose “Use hardware MAC” above if you want that disruptive restore."
            ),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.orange)
        }

        if interface.kind == .wifi {
          VStack(alignment: .leading, spacing: 8) {
            Label(L("restore.guide.title", "What happens next"), systemImage: "list.number")
              .font(.headline)
            Text(L("restore.guide.step1", "1. MACDancer cancels queued work, waits behind any in-flight request, and permanently stops writing to this interface."))
            Text(L("restore.guide.step2", "2. Network Settings opens after the daemon confirms the handoff. Choose Off, Fixed, or Rotating there yourself."))
            Text(L("restore.guide.step3", "3. If the control remains unavailable, keep MACDancer read-only, restart the Mac, and check MDM or configuration-profile restrictions."))
            Text(L("restore.guide.step4", "4. Forget and rejoin the network only as a last resort; it can affect saved passwords, enterprise authentication, and iCloud Keychain."))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 6)
        }
      }

    case .hardware:
      Section(L("restore.hardware.title", "Hardware MAC")) {
        Text(macText(interface.hardwareMAC))
          .font(.system(.body, design: .monospaced, weight: .medium))
          .textSelection(.enabled)
        Text(L(
          "restore.hardware.detail",
          "Apply the factory MAC address reported by macOS for this interface."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
      }

    case .history:
      Section(L("restore.history.title", "MAC address history for this interface")) {
        if interface.history.entries.isEmpty {
          Text(L("restore.history.empty", "No previous MAC addresses have been recorded for this interface."))
            .foregroundStyle(.secondary)
        } else {
          Picker(L("restore.history.picker", "Previous MAC address"), selection: $selectedHistoryID) {
            ForEach(interface.history.entries) { entry in
              Text(entry.address.stringValue)
                .font(.system(.body, design: .monospaced))
                .tag(Optional(entry.id))
            }
          }

          if let selectedHistory {
            VStack(alignment: .leading, spacing: 3) {
              Text(historySourceText(selectedHistory.source))
              Text(String(format: L("restore.history.last_used", "Last used %@"), dateTimeText(selectedHistory.lastUsedAt)))
              Text(String(format: L("restore.history.first_used", "First used %@"), dateTimeText(selectedHistory.firstUsedAt)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }

    case .specified:
      Section(L("restore.specified.title", "Specified MAC")) {
        TextField(L("restore.specified.placeholder", "aa:bb:cc:dd:ee:ff"), text: $specifiedAddress)
          .font(.system(.body, design: .monospaced))
          .textFieldStyle(.roundedBorder)

        if !specifiedAddress.isEmpty, parsedSpecifiedAddress?.isValidAssignable != true {
          Label(
            L("restore.specified.invalid", "Enter a 48-bit MAC address, for example aa:bb:cc:dd:ee:ff."),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption)
          .foregroundStyle(.red)
        } else {
          Text(L(
            "restore.specified.detail",
            "MACDancer validates the address before sending the request to the background service."
          ))
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var performTitle: String {
    switch destination {
    case .systemManaged:
      L("restore.action.handoff", "Hand off to macOS")
    case .hardware:
      L("restore.action.hardware", "Restore hardware MAC")
    case .history:
      L("restore.action.history", "Restore selected MAC")
    case .specified:
      L("restore.action.specified", "Apply specified MAC")
    }
  }

  private func performRestore() {
    guard canPerformRestore else { return }
    let confirmed = !requiresDisruptionConfirmation || confirmsDisruption

    switch destination {
    case .systemManaged:
      handoff()
    case .hardware:
      restoreHardware(confirmed)
    case .history:
      guard let selectedHistory else { return }
      restoreHistory(selectedHistory.address.stringValue, confirmed)
    case .specified:
      guard let parsedSpecifiedAddress else { return }
      restoreSpecified(
        parsedSpecifiedAddress.stringValue,
        confirmed,
        !specifiedNeedsGlobalAddressWarning || confirmsGlobalAddressRisk
      )
    }

    dismiss()
  }
}

private enum RestoreDestination: Hashable {
  case systemManaged
  case hardware
  case history
  case specified
}
