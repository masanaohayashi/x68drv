import SwiftUI
import AppKit
import X68Core

@main
struct X68drvApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("x68drv", id: "settings") {
            SettingsView()
                .environmentObject(AppModel.shared)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 380, height: 280)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(AppModel.shared)
        } label: {
            // Tight-cropped template art; explicit size so it fills the menu bar slot.
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                // Menu bar slot is ~22pt; fill it after tight-cropping source art.
                .frame(width: 22, height: 22)
                .accessibilityLabel("x68drv")
        }
    }
}

// MARK: - Window presentation bridge

/// Opens the settings window when `wantsSettingsWindow` becomes true.
struct SettingsWindowPresenter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onChange(of: model.wantsSettingsWindow) { wants in
                if wants {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .onAppear {
                // Catch Mode A decision that may already be set.
                if model.wantsSettingsWindow {
                    openWindow(id: "settings")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)) { _ in
                // Second chance after routing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if model.wantsSettingsWindow {
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
    }
}
