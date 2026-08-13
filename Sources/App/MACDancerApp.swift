import AppKit
import SwiftUI

private enum MACDancerSceneID {
  static let mainWindow = "main-window"
}

@main
struct MACDancerApp: App {
  @NSApplicationDelegateAdaptor(MACDancerApplicationDelegate.self) private var applicationDelegate
  @StateObject private var model = AppModel()
  @AppStorage(MACDancerMenuBarIconPreferenceKey) private var showMenuBarIcon = true

  var body: some Scene {
    WindowGroup(id: MACDancerSceneID.mainWindow) {
      MainWindowView()
        .environmentObject(model)
        .onAppear {
          // Run on the next main-loop turn, after SwiftUI has finished the
          // current view update transaction. AppModel.start() is idempotent.
          DispatchQueue.main.async {
            model.start()
          }
        }
    }
    .defaultSize(width: 1_060, height: 720)
    .commands {
      MACDancerCommands(model: model)
    }

    // A system symbol is intentional: it remains available in self-built apps
    // even when a custom asset catalog was not bundled correctly.
    MenuBarExtra(
      L("menu_bar.title", "MACDancer"),
      systemImage: "shuffle.circle.fill",
      isInserted: $showMenuBarIcon
    ) {
      MACDancerMenuBarView()
        .environmentObject(model)
    }
    .menuBarExtraStyle(.menu)
  }
}

final class MACDancerApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async {
      bringMainWindowForward()
    }
  }
}

private struct MACDancerMenuBarView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(L("menu_bar.open", "Open MACDancer")) {
      showMainWindow()
    }

    Button(L("menu_bar.refresh", "Refresh MAC addresses")) {
      model.refresh()
    }
    .disabled(model.isRefreshing)

    Divider()

    Button(L("menu_bar.settings", "Settings")) {
      model.selectSection(.settings)
      showMainWindow()
    }

    Divider()

    Button(L("menu_bar.quit", "Quit MACDancer")) {
      NSApplication.shared.terminate(nil)
    }
  }

  private func showMainWindow() {
    guard !bringMainWindowForward() else { return }
    openWindow(id: MACDancerSceneID.mainWindow)
    DispatchQueue.main.async {
      bringMainWindowForward()
    }
  }
}

private struct MACDancerCommands: Commands {
  @ObservedObject var model: AppModel
  @FocusedValue(\.macDancerCopyAction) private var copyMAC
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(L("command.open_settings", "Settings")) {
        model.selectSection(.settings)
        showMainWindow()
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandMenu(L("command.navigate", "Navigate")) {
      Button(L("section.dashboard", "Dashboard")) {
        model.selectSection(.dashboard)
        showMainWindow()
      }
      .keyboardShortcut("1", modifiers: .command)

      Button(L("section.interfaces", "Interfaces")) {
        model.selectSection(.interfaces)
        showMainWindow()
      }
      .keyboardShortcut("2", modifiers: .command)

      Button(L("section.automation", "Automation")) {
        model.selectSection(.automation)
        showMainWindow()
      }
      .keyboardShortcut("3", modifiers: .command)

      Button(L("section.settings", "Settings")) {
        model.selectSection(.settings)
        showMainWindow()
      }
      .keyboardShortcut("4", modifiers: .command)
    }

    CommandGroup(after: .toolbar) {
      Button(L("command.refresh", "Refresh MAC addresses")) {
        model.refresh()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(model.isRefreshing)
    }

    CommandGroup(after: .pasteboard) {
      Button(L("command.copy_mac", "Copy current MAC address")) {
        copyMAC?()
      }
      .keyboardShortcut("c", modifiers: .command)
      .disabled(copyMAC == nil)
    }
  }

  private func showMainWindow() {
    guard !bringMainWindowForward() else { return }
    openWindow(id: MACDancerSceneID.mainWindow)
    DispatchQueue.main.async {
      bringMainWindowForward()
    }
  }
}
