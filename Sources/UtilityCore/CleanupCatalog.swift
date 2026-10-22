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
                        detail: "Simboli di debug delle versioni iOS collegate in passato. La versione più recente non viene mai proposta.",
                        folders: ["~/Library/Developer/Xcode/iOS DeviceSupport"], risk: .review,
                        forDevelopers: true),
        CleanupCategory(id: "xcode-archives", name: "Xcode – archivi",
                        detail: "Build caricate sugli store. Servono per leggere i crash: l'archivio più recente di ogni app non viene mai proposto.",
                        folders: ["~/Library/Developer/Xcode/Archives"], risk: .review, forDevelopers: true),
        CleanupCategory(id: "xcode-apps", name: "Xcode – versioni vecchie dell'app",
                        detail: "Copie di Xcode oltre a quella in uso. La versione in uso e la più recente non vengono mai proposte.",
                        folders: ["/Applications"], risk: .review, forDevelopers: true),
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
                let items: [DiskItem]
                switch cat.id {
                case "xcode-apps": items = XcodeVersions.oldXcodeApps(in: root)
                case "xcode-archives": items = XcodeVersions.oldArchives(in: root)
                case "xcode-devicesupport": items = XcodeVersions.dropNewestVersion(scanner.children(of: root, isCancelled: isCancelled))
                default: items = scanner.children(of: root, isCancelled: isCancelled)
                }
                for item in items {
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

/// Protezioni per gli strumenti di Xcode: la versione in uso e la più recente non si propongono mai.
public enum XcodeVersions {
    /// "17.4.1" → [17, 4, 1]; nil se il nome non contiene una versione.
    static func version(in text: String) -> [Int]? {
        guard let r = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return text[r].split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Supporto dispositivi: toglie dall'elenco la versione più recente di iOS (o la più recente per data).
    static func dropNewestVersion(_ items: [DiskItem]) -> [DiskItem] {
        guard items.count > 1 else { return [] }
        let newest = items.max { a, b in
            switch (version(in: a.url.lastPathComponent), version(in: b.url.lastPathComponent)) {
            case let (va?, vb?): return isNewer(vb, than: va)
            default: return (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            }
        }
        return items.filter { $0.url != newest?.url }
    }

    /// Le copie di Xcode in /Applications, esclusa quella in uso (xcode-select) e la più recente.
    static func oldXcodeApps(in root: URL) -> [DiskItem] {
        let fm = FileManager.default
        let apps = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
        guard apps.count > 1 else { return [] }
        let active = (try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path }
            ?? "/Applications/Xcode.app"
        func appVersion(_ url: URL) -> [Int] {
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            return version(in: info?["CFBundleShortVersionString"] as? String ?? "") ?? [0]
        }
        let newest = apps.max { isNewer(appVersion($1), than: appVersion($0)) }
        let scanner = DiskScanner()
        return apps.filter { $0.standardizedFileURL.path != active && $0 != newest }.map {
            let v = (try? $0.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
            return DiskItem(url: $0, bytes: scanner.size(of: $0), isDirectory: true, modified: v)
        }
    }

    /// Archivi di Xcode (.xcarchive): per ogni app si tiene sempre il più recente.
    static func oldArchives(in root: URL) -> [DiskItem] {
        let fm = FileManager.default
        var all: [(item: DiskItem, app: String, date: Date)] = []
        let scanner = DiskScanner()
        for day in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for archive in (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? []
            where archive.pathExtension == "xcarchive" {
                let info = NSDictionary(contentsOf: archive.appendingPathComponent("Info.plist"))
                let app = info?["Name"] as? String ?? archive.deletingPathExtension().lastPathComponent
                let date = info?["CreationDate"] as? Date
                    ?? (try? archive.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                all.append((DiskItem(url: archive, bytes: scanner.size(of: archive), isDirectory: true, modified: date), app, date))
            }
        }
        var out: [DiskItem] = []
        for (_, archives) in Dictionary(grouping: all, by: { $0.app }) {
            out += archives.sorted { $0.date > $1.date }.dropFirst().map { $0.item }
        }
        return out
    }
}
