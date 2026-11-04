import AppKit
import SwiftUI

@main
struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Encore", id: "settings") {
            SettingsWindow()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.openSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.manager.stopAll() }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.showPercent) private var showPercent = true

    var body: some View {
        let buds = model.manager.current
        HStack(spacing: 4) {
            Image(systemName: "earbuds")
            if showPercent, let buds, buds.link.isReady, let level = buds.lowestBudLevel {
                Text("\(level)%")
                    .monospacedDigit()
            }
        }
        .onAppear {
            model.openSettingsAction = { openWindow(id: "settings") }
            model.onboardIfNeeded()
        }
    }
}
