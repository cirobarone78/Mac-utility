import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessario quando si avvia con `swift run` (senza bundle .app).
        NSApp.setActivationPolicy(.regular)
        if let url = Resources.bundle.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            SystemMonitor.shared.start()
            MediaMonitor.shared.start()
            Maintenance.shared.start()
            if MediaMonitor.notifyEnabled || Maintenance.shared.enabled { Notifier.requestPermission() }
        }
    }

    /// L'icona nella barra dei menu resta attiva: chiudere la finestra non chiude l'app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// La struttura dell'app non osserva nulla che cambi spesso (monitor, preferenze):
/// se lo facesse, SwiftUI ricostruirebbe finestra e barra dei menu a ogni aggiornamento.
@main
struct OmniToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(Brand.name, id: "main") {
            ContentView()
                .environmentObject(AppState.shared)
                .environmentObject(SystemMonitor.shared)
                .frame(minWidth: 960, minHeight: 620)
                .tint(Brand.accent)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(AppState.shared)
                .environmentObject(SystemMonitor.shared)
                .tint(Brand.accent)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}
