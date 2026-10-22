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
    case dashboard, space, cleanup, duplicates, photos, whatsapp, system, startup, security, organize, assistant, doctor, rename, history, rules
    case uninstall, updates, privacy, backup, virustotal, breaches
    case network, battery, mediaWatch, vault, maintenance
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Panoramica"
        case .space: "Analisi spazio"
        case .cleanup: "Pulizia disco"
        case .duplicates: "Duplicati"
        case .photos: "Foto e cloud"
        case .whatsapp: "WhatsApp"
        case .system: "Stato del sistema"
        case .startup: "Elementi all'avvio"
        case .organize: "Riordina cartelle"
        case .assistant: "Assistente AI"
        case .doctor: "Medico del Mac"
        case .rename: "Rinomina intelligente"
        case .security: "Controllo sicurezza"
        case .history: "Cronologia"
        case .rules: "Regole di sicurezza"
        case .uninstall: "Disinstalla app"
        case .updates: "Aggiornamenti"
        case .privacy: "Privacy"
        case .backup: "Backup"
        case .virustotal: "Seconda opinione"
        case .breaches: "Furti di dati"
        case .network: "Rete e Wi-Fi"
        case .battery: "Batteria"
        case .mediaWatch: "Fotocamera e microfono"
        case .vault: "Cassaforte"
        case .maintenance: "Manutenzione automatica"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .space: "chart.pie"
        case .cleanup: "sparkles"
        case .duplicates: "doc.on.doc"
        case .photos: "photo.on.rectangle.angled"
        case .whatsapp: "bubble.left.and.bubble.right"
        case .system: "cpu"
        case .startup: "power"
        case .organize: "folder.badge.gearshape"
        case .assistant: "brain"
        case .doctor: "stethoscope"
        case .rename: "character.cursor.ibeam"
        case .security: "checkmark.shield"
        case .history: "clock.arrow.circlepath"
        case .rules: "lock.shield"
        case .uninstall: "trash.square"
        case .updates: "arrow.down.app"
        case .privacy: "hand.raised"
        case .backup: "externaldrive.badge.timemachine"
        case .virustotal: "magnifyingglass.circle"
        case .breaches: "person.badge.key"
        case .network: "wifi"
        case .battery: "battery.75percent"
        case .mediaWatch: "web.camera"
        case .vault: "lock.rectangle.stack"
        case .maintenance: "calendar.badge.clock"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var policy: SafetyPolicy = SafetyPolicy.load()
    @Published var selection: Module? = .dashboard

    func savePolicy() { try? policy.save() }
}

/// Ripristina un'operazione dalla Cronologia.
enum Restore {
    /// Messaggio per l'utente, oppure nil se l'operazione non esiste più o è già stata ripristinata.
    static func run(_ id: String) -> String? {
        guard let record = OperationLog.list().first(where: { $0.id == id }), !record.restored else { return nil }
        return OperationLog.restore(record).message
    }
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

    /// Scelta di uno o più file (anche app).
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Controlla"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    static let fullDiskAccessSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Accorcia il percorso sostituendo la home con "~".
    static func short(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + String(url.path.dropFirst(home.count)) : url.path
    }
}
