import SwiftUI
import AppKit
import UtilityCore

/// Nome e colori di OmniNeo (stessi valori di site.css / site-refresh.css).
/// Ogni colore ha la variante scura e quella chiara e segue il tema del Mac.
enum Brand {
    static let name = "OmniTools"

    /// Teal OmniNeo: #2dd4c8 su scuro, #0f766e su chiaro.
    static let accent = Color(dark: 0x2DD4C8, light: 0x0F766E)
    /// Sfondo: blu notte #04070f su scuro, «cool-paper» #eef2f6 su chiaro.
    static let background = Color(dark: 0x04070F, light: 0xEEF2F6)
    /// Riquadri: #0c1628 su scuro, bianco su chiaro.
    static let card = Color(dark: 0x0C1628, light: 0xFFFFFF)
}

extension Color {
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
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
