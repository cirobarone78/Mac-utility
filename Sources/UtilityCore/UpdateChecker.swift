#if os(macOS)
import Foundation

/// Un aggiornamento disponibile (o da verificare) per un'app o un pacchetto.
public struct AppUpdate: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case appStore = "App Store"
        case sparkle = "Aggiornamento dell'app"
        case homebrew = "Homebrew"
        case macOS = "macOS"
    }
    public let name: String
    public let installed: String
    public let available: String
    public let source: Source
    /// App sul disco (per aprirla), se c'è.
    public let appURL: URL?
    /// Pagina dell'App Store, se c'è.
    public let storeURL: URL?
    /// Comando da incollare nel Terminale (Homebrew).
    public let command: String?
    public var id: String { source.rawValue + "|" + name }
}

public struct UpdateReport: Sendable {
    public var updates: [AppUpdate] = []
    /// App che non dicono da dove si aggiornano: vanno controllate a mano.
    public var unknown: [InstalledApp] = []
    /// App il cui controllo non è riuscito (rete, indirizzo non sicuro…).
    public var failed: [String] = []
    public var checked = 0

    public init() {}
}

public enum UpdateChecker {
    // MARK: - App

    /// Controlla App Store e aggiornamenti delle app (Sparkle). Le app di Apple si aggiornano con macOS.
    public static func check(apps: [InstalledApp], country: String = "it",
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async -> UpdateReport {
        var report = UpdateReport()
        let candidates = apps.filter { !$0.isApple && $0.bundleID != AppUninstaller.selfBundleID }
        // A gruppi di 8 richieste per volta.
        var index = 0
        while index < candidates.count {
            let batch = Array(candidates[index..<min(index + 8, candidates.count)])
            index += batch.count
            let results = await withTaskGroup(of: (InstalledApp, Outcome).self) { group in
                for app in batch {
                    group.addTask { (app, await Self.outcome(for: app, country: country)) }
                }
                var all: [(InstalledApp, Outcome)] = []
                for await r in group { all.append(r) }
                return all
            }
            for (app, result) in results {
                switch result {
                case .unknown: report.unknown.append(app)
                case .update(let u): report.updates.append(u)
                case .upToDate: break
                case .failed: report.failed.append(app.name)
                }
            }
            report.checked = index
            progress("Controllate \(index) app su \(candidates.count)…")
        }
        report.updates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        report.unknown.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        report.failed.sort()
        return report
    }

    enum Outcome: Sendable {
        case update(AppUpdate), upToDate, unknown, failed
    }

    static func outcome(for app: InstalledApp, country: String) async -> Outcome {
        do {
            if app.fromAppStore {
                return try await appStore(app, country: country).map(Outcome.update) ?? .upToDate
            }
            if let feed = app.feedURL {
                return try await sparkle(app, feed: feed).map(Outcome.update) ?? .upToDate
            }
            return .unknown
        } catch {
            return .failed
        }
    }

    static func appStore(_ app: InstalledApp, country: String) async throws -> AppUpdate? {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [.init(name: "bundleId", value: app.bundleID), .init(name: "country", value: country),
                        .init(name: "entity", value: "macSoftware")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String else { return nil }
        guard Versions.isNewer(version, than: app.version) else { return nil }
        let store = (first["trackViewUrl"] as? String)
            .flatMap { URL(string: $0.replacingOccurrences(of: "https://", with: "macappstore://")) }
        return AppUpdate(name: app.name, installed: app.version, available: version, source: .appStore,
                         appURL: app.url, storeURL: store, command: nil)
    }

    static func sparkle(_ app: InstalledApp, feed: URL) async throws -> AppUpdate? {
        var url = feed
        // Le connessioni non cifrate sono bloccate: si prova la versione https dello stesso indirizzo.
        if url.scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            url = c.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("OmniTools", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let items = AppcastParser.parse(data)
        guard let newest = items.max(by: { isNewer($1, than: $0) }) else { return nil }
        // Si confronta la versione «per le persone» se c'è, altrimenti il numero di build.
        let newer: Bool
        if let short = newest.shortVersion, !app.version.isEmpty {
            newer = Versions.isNewer(short, than: app.version)
                || (short == app.version && Versions.isNewer(newest.version, than: app.build))
        } else {
            newer = Versions.isNewer(newest.version, than: app.build)
        }
        guard newer else { return nil }
        return AppUpdate(name: app.name, installed: app.version,
                         available: newest.shortVersion ?? newest.version, source: .sparkle,
                         appURL: app.url, storeURL: nil, command: nil)
    }

    static func isNewer(_ a: AppcastParser.Item, than b: AppcastParser.Item) -> Bool {
        if let x = a.shortVersion, let y = b.shortVersion, x != y { return Versions.isNewer(x, than: y) }
        return Versions.isNewer(a.version, than: b.version)
    }

    // MARK: - Homebrew

    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pacchetti di Homebrew più vecchi dell'ultima versione nota (vale l'elenco scaricato con l'ultimo «brew update»).
    public static func homebrew() -> [AppUpdate] {
        guard let brew = brewPath else { return [] }
        let r = Shell.run(brew, ["outdated", "--json=v2", "--greedy"], environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        guard let start = r.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [String: Any]
        else { return [] }
        var out: [AppUpdate] = []
        for (key, cask) in [("formulae", false), ("casks", true)] {
            for item in (json[key] as? [[String: Any]]) ?? [] {
                guard let name = item["name"] as? String else { continue }
                let installed = (item["installed_versions"] as? [String])?.last ?? "?"
                let current = item["current_version"] as? String ?? "?"
                out.append(AppUpdate(name: name, installed: installed, available: current, source: .homebrew,
                                     appURL: nil, storeURL: nil,
                                     command: "brew upgrade " + (cask ? "--cask " : "") + name))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - macOS

    /// Aggiornamenti di sistema (può richiedere un minuto).
    public static func macOS() -> [AppUpdate] {
        let r = Shell.run("/usr/sbin/softwareupdate", ["--list"])
        return parseSoftwareUpdate(r.output)
    }

    static func parseSoftwareUpdate(_ text: String) -> [AppUpdate] {
        text.split(separator: "\n").compactMap { line -> AppUpdate? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Title:") else { return nil }
            var fields: [String: String] = [:]
            for part in t.split(separator: ",") {
                let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            guard let title = fields["Title"] else { return nil }
            return AppUpdate(name: title, installed: "", available: fields["Version"] ?? "", source: .macOS,
                             appURL: nil, storeURL: nil, command: nil)
        }
    }
}

/// Legge il «appcast» con cui le app Sparkle annunciano le nuove versioni.
public enum AppcastParser {
    public struct Item: Sendable, Equatable {
        public var version: String
        public var shortVersion: String?
    }

    public static func parse(_ data: Data) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.items.filter { !$0.version.isEmpty || $0.shortVersion != nil }
            .map { Item(version: $0.version.isEmpty ? ($0.shortVersion ?? "") : $0.version, shortVersion: $0.shortVersion) }
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var beta = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item":
                current = Item(version: "", shortVersion: nil)
                beta = false
            case "enclosure":
                if let v = attributes["sparkle:version"], current?.version.isEmpty == true { current?.version = v }
                if let s = attributes["sparkle:shortVersionString"], current?.shortVersion == nil { current?.shortVersion = s }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version": if !value.isEmpty { current?.version = value }
            case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersion = value }
            case "sparkle:channel": if !value.isEmpty { beta = true }   // canali beta/anteprima: si ignorano
            case "item":
                if let c = current, !beta { items.append(c) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
#endif
