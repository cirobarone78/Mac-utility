import SwiftUI
import AppKit
import UtilityCore

/// Nome e colori in un solo posto: da personalizzare.
enum Brand {
    static let name = "Mac Utility"
    static let accent = Color(red: 0.08, green: 0.72, blue: 0.65)   // teal
}

enum Module: String, CaseIterable, Identifiable {
    case dashboard, space, cleanup, duplicates, system, startup, organize, assistant, rules
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Panoramica"
        case .space: "Analisi spazio"
        case .cleanup: "Pulizia disco"
        case .duplicates: "Duplicati"
        case .system: "Stato del sistema"
        case .startup: "Elementi all'avvio"
        case .organize: "Riordina cartelle"
        case .assistant: "Assistente AI"
        case .rules: "Regole di sicurezza"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .space: "chart.pie"
        case .cleanup: "sparkles"
        case .duplicates: "doc.on.doc"
        case .system: "cpu"
        case .startup: "power"
        case .organize: "folder.badge.gearshape"
        case .assistant: "brain"
        case .rules: "lock.shield"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var policy: SafetyPolicy = SafetyPolicy.load()
    @Published var selection: Module? = .dashboard

    func savePolicy() { try? policy.save() }
}

enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func chooseFolder(start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = "Scegli"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Accorcia il percorso sostituendo la home con "~".
    static func short(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + String(url.path.dropFirst(home.count)) : url.path
    }
}
