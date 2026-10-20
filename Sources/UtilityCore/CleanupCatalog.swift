import Foundation

/// Una categoria di file che di solito si può eliminare (cache, log, residui di sviluppo).
public struct CleanupCategory: Identifiable, Hashable, Sendable {
    public enum Risk: String, Sendable {
        /// Si ricrea da solo: selezionato in automatico.
        case safe
        /// Da guardare prima: mai selezionato in automatico.
        case review
    }

    public let id: String
    public let name: String
    public let detail: String
    /// Cartelle di cui si propone il CONTENUTO (mai la cartella stessa).
    public let folders: [String]
    public let risk: Risk
    public let forDevelopers: Bool
    /// Se impostato, propone solo le voci non modificate da almeno N giorni.
    public let olderThanDays: Int?

    public init(id: String, name: String, detail: String, folders: [String], risk: Risk,
                forDevelopers: Bool = false, olderThanDays: Int? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.folders = folders
        self.risk = risk; self.forDevelopers = forDevelopers; self.olderThanDays = olderThanDays
    }
}

public struct CleanupFinding: Identifiable, Hashable, Sendable {
    public let category: CleanupCategory
    public let item: DiskItem
    /// Spiegazione della voce e rischio specifico.
    public let info: CacheInfo
    public var id: URL { item.url }

    /// Il rischio più prudente tra quello della categoria e quello della voce.
    public var risk: CleanupCategory.Risk {
        category.risk == .review || info.risk == .review ? .review : .safe
    }
}

public enum CleanupCatalog {
    public static let standard: [CleanupCategory] = [
        CleanupCategory(id: "user-caches", name: "Cache delle app",
                        detail: "File temporanei che le app ricreano quando servono.",
                        folders: ["~/Library/Caches"], risk: .safe),
        CleanupCategory(id: "user-logs", name: "Log",
                        detail: "Registri di funzionamento delle app.",
                        folders: ["~/Library/Logs"], risk: .safe),
        CleanupCategory(id: "old-downloads", name: "Download vecchi",
                        detail: "Elementi in Download non toccati da oltre 90 giorni. Controllali uno per uno.",
                        folders: ["~/Downloads"], risk: .review, olderThanDays: 90),
        CleanupCategory(id: "xcode-derived", name: "Xcode – DerivedData",
                        detail: "Compilazioni intermedie: Xcode le rifà alla prossima build.",
                        folders: ["~/Library/Developer/Xcode/DerivedData"], risk: .safe, forDevelopers: true),
        CleanupCategory(id: "xcode-devicesupport", name: "Xcode – supporto dispositivi",
                        detail: "Simboli di debug delle versioni iOS collegate in passato.",
                        folders: ["~/Library/Developer/Xcode/iOS DeviceSupport"], risk: .review,
                        forDevelopers: true),
        CleanupCategory(id: "xcode-archives", name: "Xcode – archivi",
                        detail: "Build caricate sugli store. Servono per leggere i crash: tieni le ultime.",
                        folders: ["~/Library/Developer/Xcode/Archives"], risk: .review, forDevelopers: true),
        CleanupCategory(id: "simulator-caches", name: "Simulatori – cache",
                        detail: "Cache dei simulatori iOS.",
                        folders: ["~/Library/Developer/CoreSimulator/Caches"], risk: .safe, forDevelopers: true),
        CleanupCategory(id: "gradle", name: "Gradle (Android)",
                        detail: "Dipendenze scaricate: si riscaricano alla prossima build Android.",
                        folders: ["~/.gradle/caches"], risk: .safe, forDevelopers: true),
        CleanupCategory(id: "npm", name: "Cache di npm",
                        detail: "Pacchetti JavaScript già scaricati.",
                        folders: ["~/.npm/_cacache"], risk: .safe, forDevelopers: true),
    ]

    /// Elenca cosa si potrebbe eliminare, rispettando le regole di sicurezza.
    public static func scan(_ categories: [CleanupCategory] = standard,
                            policy: SafetyPolicy,
                            home: String = NSHomeDirectory(),
                            now: Date = Date(),
                            appName: (String) -> String? = { _ in nil },
                            isCancelled: () -> Bool = { false }) -> [CleanupFinding] {
        let scanner = DiskScanner()
        var out: [CleanupFinding] = []
        for cat in categories {
            for folder in cat.folders {
                let root = URL(fileURLWithPath: SafetyPolicy.expand(folder, home: home), isDirectory: true)
                for item in scanner.children(of: root, isCancelled: isCancelled) {
                    if isCancelled() { return out }
                    if item.bytes == 0 || policy.isProtected(item.url, home: home) { continue }
                    if let days = cat.olderThanDays {
                        guard let m = item.modified,
                              now.timeIntervalSince(m) > Double(days) * 86_400 else { continue }
                    }
                    let info = CacheKnowledge.info(for: item, category: cat, appName: appName)
                    if info.neverPropose { continue }
                    out.append(CleanupFinding(category: cat, item: item, info: info))
                }
            }
        }
        return out
    }
}
