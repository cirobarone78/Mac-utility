import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessario quando si avvia con `swift run` (senza bundle .app).
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Con l'icona nella barra dei menu attiva, chiudere la finestra non chiude l'app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "menubar.enabled") as? Bool ?? true)
    }
}

@main
struct OmniToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var monitor = SystemMonitor()
    @AppStorage("menubar.enabled") private var menuBarEnabled = true

    var body: some Scene {
        WindowGroup(Brand.name, id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 960, minHeight: 620)
                .tint(Brand.accent)
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPanel(monitor: monitor)
                .environmentObject(state)
                .tint(Brand.accent)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
