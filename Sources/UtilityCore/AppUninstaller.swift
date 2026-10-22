#if os(macOS)
import Foundation
import CoreServices
import Security

/// Un'app installata, con quanto serve per disinstallarla e per controllarne gli aggiornamenti.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    /// Indirizzo da cui l'app controlla gli aggiornamenti da sola (Sparkle), se c'è.
    public let feedURL: URL?
    /// Installata dal Mac App Store.
    public let fromAppStore: Bool
    public var bytes: Int64 = 0
    public var lastUsed: Date?
    public var id: URL { url }
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

/// Un file o una cartella che un'app lascia sul disco.
public struct Leftover: Identifiable, Hashable, Sendable {
    public let url: URL
    public let bytes: Int64
    /// Dove si trova, detto in parole ("Preferenze", "Cache"…).
    public let place: String
    /// Perché pensiamo che appartenga all'app.
    public let reason: String
    /// Da controllare: trovato per nome, condiviso con altre app dello stesso sviluppatore…
    public let risky: Bool
    /// Fuori dalla home: il Finder chiederà la password.
    public let needsAdmin: Bool
    public let modified: Date?
    public var id: URL { url }
}

/// Gli avanzi di un'app già cancellata, raggruppati per identificativo.
public struct OrphanGroup: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let items: [Leftover]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var lastModified: Date? { items.compactMap(\.modified).max() }
    public var id: String { bundleID }

    public init(bundleID: String, items: [Leftover]) {
        self.bundleID = bundleID
        self.items = items
    }
}

public enum AppUninstaller {
    public static let selfBundleID = "app.omnitools.mac"

    // MARK: - App installate

    public static func appFolders(home: String = NSHomeDirectory()) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: home + "/Applications")]
    }

    /// Le app in /Applications e ~/Applications (anche dentro una sottocartella, es. «Adobe…»).
    public static func installedApps(home: String = NSHomeDirectory(), withSizes: Bool = true,
                                     isCancelled: () -> Bool = { false }) -> [InstalledApp] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for folder in appFolders(home: home) {
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if url.pathExtension == "app" {
                    bundles.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          url.lastPathComponent != "Utilities" {
                    let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    bundles += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        let scanner = DiskScanner()
        var apps: [InstalledApp] = []
        for url in bundles {
            if isCancelled() { break }
            guard var app = app(at: url) else { continue }
            if withSizes { app.bytes = scanner.size(of: url) }
            app.lastUsed = lastUsed(url)
            apps.append(app)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func app(at url: URL) -> InstalledApp? {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bid = info["CFBundleIdentifier"] as? String, !bid.isEmpty else { return nil }
        let feed = (info["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let mas = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
        // Il nome come appare nel Finder.
        return InstalledApp(url: url, name: url.deletingPathExtension().lastPathComponent,
                            bundleID: bid,
                            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? "",
                            build: (info["CFBundleVersion"] as? String) ?? "",
                            feedURL: feed, fromAppStore: mas)
    }

    /// Ultimo utilizzo secondo Spotlight.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Identificativo dello sviluppatore (Team ID) dalla firma dell'app.
    static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Avanzi di un'app

    /// Cartelle della Libreria dove le app lasciano file, con il nome da mostrare.
    static func places(home: String) -> [(dir: String, label: String, byName: Bool)] {
        let lib = home + "/Library"
        return [
            (lib + "/Application Support", "Dati dell'app", true),
            (lib + "/Caches", "Cache", true),
            (lib + "/Preferences", "Preferenze", false),
            (lib + "/Preferences/ByHost", "Preferenze", false),
            (lib + "/Saved Application State", "Stato delle finestre", false),
            (lib + "/Logs", "Log", true),
            (lib + "/HTTPStorages", "Dati web", false),
            (lib + "/WebKit", "Dati web", false),
            (lib + "/Cookies", "Cookie", false),
            (lib + "/Containers", "Contenitore", false),
            (lib + "/Application Scripts", "Script", false),
            (lib + "/LaunchAgents", "Avvio automatico", false),
            ("/Library/Application Support", "Dati dell'app (tutti gli utenti)", true),
            ("/Library/Caches", "Cache (tutti gli utenti)", false),
            ("/Library/Preferences", "Preferenze (tutti gli utenti)", false),
            ("/Library/LaunchAgents", "Avvio automatico (tutti gli utenti)", false),
            ("/Library/LaunchDaemons", "Servizio di sistema", false),
            ("/Library/PrivilegedHelperTools", "Aiutante con privilegi", false),
        ]
    }

    /// Il nome senza le estensioni tipiche (".plist", ".savedState"…).
    static func stem(_ name: String) -> String {
        for ext in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    /// true se il nome è l'identificativo dell'app o di un suo componente ("com.x.App.helper").
    static func matches(_ name: String, bundleID: String) -> Bool {
        let s = stem(name).lowercased(), b = bundleID.lowercased()
        return s == b || s.hasPrefix(b + ".")
    }

    /// Tutto ciò che l'app ha lasciato fuori dal suo pacchetto.
    public static func leftovers(of app: InstalledApp, home: String = NSHomeDirectory(),
                                 policy: SafetyPolicy = .default) -> [Leftover] {
        let fm = FileManager.default
        let scanner = DiskScanner()
        let appName = app.name.lowercased()
        var out: [Leftover] = []
        var seen = Set<String>()

        func add(_ url: URL, place: String, reason: String, risky: Bool) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), !policy.isProtected(url) else { return }
            seen.insert(path)
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            out.append(Leftover(url: url, bytes: scanner.size(of: url), place: place, reason: reason,
                                risky: risky, needsAdmin: !path.hasPrefix(home + "/"), modified: mod))
        }

        for (dir, label, byName) in places(home: home) {
            for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [] {
                let name = url.lastPathComponent
                if matches(name, bundleID: app.bundleID) {
                    add(url, place: label, reason: "porta l'identificativo dell'app", risky: false)
                } else if byName && appName.count >= 4 && name.lowercased() == appName {
                    add(url, place: label, reason: "ha lo stesso nome dell'app", risky: true)
                } else if url.pathExtension == "plist", dir.hasSuffix("LaunchAgents") || dir.hasSuffix("LaunchDaemons"),
                          launchItem(url, belongsTo: app) {
                    add(url, place: label, reason: "avvia un programma che sta dentro l'app", risky: false)
                }
            }
        }

        // Contenitori di gruppo: condivisi tra le app dello stesso sviluppatore.
        let group = URL(fileURLWithPath: home + "/Library/Group Containers")
        let team = teamID(app.url)
        for url in (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent.lowercased()
            if name.contains(app.bundleID.lowercased()) {
                add(url, place: "Contenitore di gruppo", reason: "porta l'identificativo dell'app", risky: false)
            } else if let team, name.hasPrefix(team.lowercased() + ".") {
                add(url, place: "Contenitore di gruppo",
                    reason: "dello stesso sviluppatore: può servire anche alle sue altre app", risky: true)
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Un elemento di avvio che lancia un programma dentro il pacchetto dell'app.
    static func launchItem(_ plist: URL, belongsTo app: InstalledApp) -> Bool {
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return false }
        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first ?? ""
        return !program.isEmpty && program.hasPrefix(app.url.path + "/")
    }

    // MARK: - Avanzi di app già cancellate

    static let reverseDNSRoots: Set<String> = ["com", "org", "net", "io", "de", "it", "app", "co", "us", "me",
                                               "dev", "uk", "fr", "ch", "nl", "jp", "info", "tv", "ru", "se"]

    /// Ha la forma di un identificativo d'app ("com.sviluppatore.App").
    static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count >= 3 && reverseDNSRoots.contains(parts[0].lowercased())
            && !s.contains(" ") && parts.allSatisfy { !$0.isEmpty }
    }

    /// true se un'app (o un suo componente) con quell'identificativo è ancora installata.
    static func isInstalled(_ id: String, known: Set<String>) -> Bool {
        let low = id.lowercased()
        if known.contains(where: { low == $0 || low.hasPrefix($0 + ".") || $0.hasPrefix(low + ".") }) { return true }
        if let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL],
           !urls.isEmpty { return true }
        return false
    }

    /// Avanzi nella Libreria di app che non sono più installate. Si ignorano gli elementi di Apple
    /// e quelli modificati negli ultimi `quietDays` giorni (qualcosa li sta ancora usando).
    public static func orphans(apps: [InstalledApp], home: String = NSHomeDirectory(),
                               policy: SafetyPolicy = .default, quietDays: Int = 30,
                               isCancelled: () -> Bool = { false }) -> [OrphanGroup] {
        let fm = FileManager.default
        let scanner = DiskScanner()
        let lib = home + "/Library"
        let dirs: [(String, String)] = [
            (lib + "/Application Support", "Dati dell'app"), (lib + "/Caches", "Cache"),
            (lib + "/Preferences", "Preferenze"), (lib + "/Saved Application State", "Stato delle finestre"),
            (lib + "/Logs", "Log"), (lib + "/HTTPStorages", "Dati web"), (lib + "/WebKit", "Dati web"),
            (lib + "/Containers", "Contenitore"), (lib + "/Application Scripts", "Script"),
            (lib + "/LaunchAgents", "Avvio automatico"),
        ]
        // Le app installate ovunque (anche quelle di sistema) contano come «ancora presenti».
        var known = Set(apps.map { $0.bundleID.lowercased() })
        for folder in ["/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"] {
            for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? [] {
                if let a = app(at: url) { known.insert(a.bundleID.lowercased()) }
            }
        }
        let cutoff = Date().addingTimeInterval(-Double(quietDays) * 86_400)
        var groups: [String: [Leftover]] = [:]
        var verdict: [String: Bool] = [:]

        for (dir, label) in dirs {
            if isCancelled() { break }
            for url in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [] {
                var id = stem(url.lastPathComponent)
                if dir.hasSuffix("LaunchAgents"),
                   let plistLabel = (NSDictionary(contentsOf: url) as? [String: Any])?["Label"] as? String {
                    id = plistLabel
                }
                guard looksLikeBundleID(id), !id.lowercased().hasPrefix("com.apple."),
                      id.lowercased() != selfBundleID, !policy.isProtected(url) else { continue }
                if CacheKnowledge.isNeverPropose(id) { continue }
                let installed: Bool
                if let v = verdict[id.lowercased()] { installed = v } else {
                    installed = isInstalled(id, known: known)
                    verdict[id.lowercased()] = installed
                }
                if installed { continue }
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mod, mod > cutoff { continue }
                groups[groupKey(id), default: []].append(
                    Leftover(url: url, bytes: scanner.size(of: url), place: label,
                             reason: "nessuna app installata usa «\(id)»", risky: true,
                             needsAdmin: false, modified: mod))
            }
        }
        return groups.map { OrphanGroup(bundleID: $0.key, items: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Raggruppa i componenti sotto l'app ("com.x.App.helper" → "com.x.App").
    static func groupKey(_ id: String) -> String {
        id.split(separator: ".").prefix(3).joined(separator: ".")
    }
}
#endif
