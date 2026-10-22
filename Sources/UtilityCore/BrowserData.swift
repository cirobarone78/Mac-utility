#if os(macOS)
import Foundation
import SQLite3

/// Un sito con la cronologia e i cookie che un browser conserva.
public struct BrowserSite: Identifiable, Hashable, Sendable {
    public let site: String
    public var visits: Int
    public var cookies: Int
    public var lastVisit: Date?
    public var id: String { site }
}

/// I dati di un browser (tutti i profili insieme).
public struct BrowserData: Identifiable, Sendable {
    public struct Profile: Sendable {
        public let name: String
        public let history: URL?
        public let cookies: URL?
    }
    public enum Engine: Sendable { case chromium, safari }

    public let name: String
    public let bundleID: String
    public let engine: Engine
    public let profiles: [Profile]
    public var sites: [BrowserSite] = []
    /// Il browser c'è ma i suoi file non sono leggibili (Safari: serve Accesso completo al disco).
    public var unreadable = false
    public var id: String { bundleID }
    /// Safari tiene i cookie in un formato suo: si gestiscono da Safari stesso.
    public var supportsCookies: Bool { engine == .chromium }
}

public enum BrowserCleaner {
    static let chromium: [(name: String, bundleID: String, dir: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
        ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
        ("Chromium", "org.chromium.Chromium", "Chromium"),
    ]

    // MARK: - Lettura

    public static func browsers(home: String = NSHomeDirectory()) -> [BrowserData] {
        let fm = FileManager.default
        var out: [BrowserData] = []
        let safariHistory = URL(fileURLWithPath: home + "/Library/Safari/History.db")
        if fm.fileExists(atPath: home + "/Library/Safari") {
            out.append(BrowserData(name: "Safari", bundleID: "com.apple.Safari", engine: .safari,
                                   profiles: [.init(name: "Safari", history: safariHistory, cookies: nil)]))
        }
        for b in chromium {
            let root = URL(fileURLWithPath: home + "/Library/Application Support/" + b.dir)
            let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            let profiles: [BrowserData.Profile] = dirs.compactMap { dir in
                let history = dir.appendingPathComponent("History")
                let cookies = [dir.appendingPathComponent("Network/Cookies"), dir.appendingPathComponent("Cookies")]
                    .first { fm.fileExists(atPath: $0.path) }
                guard fm.fileExists(atPath: history.path) || cookies != nil else { return nil }
                return .init(name: dir.lastPathComponent,
                             history: fm.fileExists(atPath: history.path) ? history : nil, cookies: cookies)
            }
            if !profiles.isEmpty {
                out.append(BrowserData(name: b.name, bundleID: b.bundleID, engine: .chromium, profiles: profiles))
            }
        }
        return out
    }

    /// Legge i siti di ogni browser (solo lettura, anche col browser aperto).
    public static func scan(home: String = NSHomeDirectory()) -> [BrowserData] {
        browsers(home: home).map { found in
            var b = found
            var sites: [String: BrowserSite] = [:]
            var readAny = false
            for p in b.profiles {
                if let h = p.history, let rows = readHistory(h, engine: b.engine) {
                    readAny = true
                    for (url, visits, last) in rows {
                        guard let s = site(ofURL: url) else { continue }
                        var e = sites[s] ?? BrowserSite(site: s, visits: 0, cookies: 0, lastVisit: nil)
                        e.visits += visits
                        if let last, last > (e.lastVisit ?? .distantPast) { e.lastVisit = last }
                        sites[s] = e
                    }
                }
                if let c = p.cookies, let hosts = readCookieHosts(c) {
                    readAny = true
                    for host in hosts {
                        let s = site(ofHost: host)
                        var e = sites[s] ?? BrowserSite(site: s, visits: 0, cookies: 0, lastVisit: nil)
                        e.cookies += 1
                        sites[s] = e
                    }
                }
            }
            b.unreadable = !readAny
            b.sites = sites.values.sorted { ($0.lastVisit ?? .distantPast) > ($1.lastVisit ?? .distantPast) }
            return b
        }
    }

    static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = "file:" + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)
            + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    static func readHistory(_ url: URL, engine: BrowserData.Engine) -> [(String, Int, Date?)]? {
        guard let db = openReadOnly(url) else { return nil }
        defer { sqlite3_close(db) }
        let sql = engine == .safari
            ? "SELECT i.url, i.visit_count, MAX(v.visit_time) FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id GROUP BY i.id"
            : "SELECT url, visit_count, last_visit_time FROM urls"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [(String, Int, Date?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let u = sqlite3_column_text(stmt, 0) else { continue }
            let t = sqlite3_column_double(stmt, 2)
            let date: Date? = t <= 0 ? nil : engine == .safari
                ? Date(timeIntervalSinceReferenceDate: t)
                : Date(timeIntervalSince1970: t / 1_000_000 - 11_644_473_600)   // microsecondi dal 1601
            out.append((String(cString: u), Int(sqlite3_column_int(stmt, 1)), date))
        }
        return out
    }

    static func readCookieHosts(_ url: URL) -> [String]? {
        guard let db = openReadOnly(url) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT host_key FROM cookies", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let h = sqlite3_column_text(stmt, 0) { out.append(String(cString: h)) }
        }
        return out
    }

    // MARK: - Sito di appartenenza

    static let secondLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au",
                                           "co.jp", "co.nz", "com.br", "co.in", "com.cn", "com.tr", "com.mx",
                                           "co.za", "gov.it", "edu.au", "com.ar", "com.sg", "com.hk"]

    /// "mail.google.com" → "google.com"; "www.bbc.co.uk" → "bbc.co.uk".
    public static func site(ofHost host: String) -> String {
        var h = host.lowercased()
        while h.hasPrefix(".") { h.removeFirst() }
        let labels = h.split(separator: ".")
        if labels.count <= 2 || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return h }
        let last2 = labels.suffix(2).joined(separator: ".")
        return secondLevel.contains(last2) ? labels.suffix(3).joined(separator: ".") : last2
    }

    static func site(ofURL s: String) -> String? {
        guard let url = URL(string: s), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return site(ofHost: host)
    }

    // MARK: - Pulizia

    public struct CleanResult: Sendable {
        public var historyRows = 0
        public var cookieRows = 0
        public var operationID: String?
        public var errors: [String] = []
    }

    /// Cancella cronologia e/o cookie dei siti scelti. Il browser deve essere chiuso.
    /// Ogni database viene prima messo nel Cestino così com'era: «Ripristina» lo rimette a posto.
    public static func clean(_ browser: BrowserData, sites: Set<String>, history: Bool, cookies: Bool,
                             logFolder: URL = OperationLog.folder) -> CleanResult {
        var r = CleanResult()
        var moves: [OperationRecord.Move] = []
        for p in browser.profiles {
            if history, let h = p.history {
                let (n, m, err) = rewrite(h) { db in deleteHistory(db, engine: browser.engine, sites: sites) }
                r.historyRows += n
                moves += m
                if let err { r.errors.append("\(browser.name) – cronologia: \(err)") }
            }
            if cookies, browser.supportsCookies, let c = p.cookies {
                let (n, m, err) = rewrite(c) { db in deleteCookies(db, sites: sites) }
                r.cookieRows += n
                moves += m
                if let err { r.errors.append("\(browser.name) – cookie: \(err)") }
            }
        }
        if !moves.isEmpty {
            var parts: [String] = []
            if history { parts.append("cronologia") }
            if cookies && browser.supportsCookies { parts.append("cookie") }
            let record = OperationRecord(kind: "Privacy",
                                         summary: "\(browser.name): \(parts.joined(separator: " e ")) di \(sites.count) siti",
                                         moves: moves)
            OperationLog.save(record, in: logFolder)
            r.operationID = record.id
        }
        Journal.append(lines: ["PRIVACY\t\(browser.name)\t\(sites.count) siti\tcronologia \(r.historyRows)\tcookie \(r.cookieRows)"])
        return r
    }

    static let sidecars = ["-wal", "-shm", "-journal"]

    /// Lavora su una copia del database; se tutto va bene, l'originale va nel Cestino e la copia prende il suo posto.
    static func rewrite(_ url: URL, _ body: (OpaquePointer) -> Int) -> (Int, [OperationRecord.Move], String?) {
        let fm = FileManager.default
        let work = SafetyPolicy.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("tmp", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let originals = [url] + sidecars.map { URL(fileURLWithPath: url.path + $0) }.filter { fm.fileExists(atPath: $0.path) }
            for f in originals { try fm.copyItem(at: f, to: work.appendingPathComponent(f.lastPathComponent)) }
            let copy = work.appendingPathComponent(url.lastPathComponent)

            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                return (0, [], "impossibile aprire il database")
            }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            let n = body(db)
            let committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
            // Riporta tutto nel file principale, così non servono i file di appoggio.
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_close(db)
            guard committed else { return (0, [], "modifica non riuscita") }
            guard n > 0 else { return (0, [], nil) }

            var moves: [OperationRecord.Move] = []
            for f in originals {
                var inTrash: NSURL?
                try fm.trashItem(at: f, resultingItemURL: &inTrash)
                if let dest = inTrash?.path { moves.append(.init(from: f.path, to: dest, replace: true)) }
            }
            try fm.moveItem(at: copy, to: url)
            return (n, moves, nil)
        } catch {
            return (0, [], error.localizedDescription)
        }
    }

    /// Esegue una DELETE per ogni id (con un parametro).
    static func deleteEach(_ db: OpaquePointer, _ sql: String, ids: [Int64]) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var n = 0
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_DONE { n += Int(sqlite3_changes(db)) }
        }
        return n
    }

    static func ids(_ db: OpaquePointer, _ sql: String, keep: (String) -> Bool) -> [Int64] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let t = sqlite3_column_text(stmt, 1), keep(String(cString: t)) {
                out.append(sqlite3_column_int64(stmt, 0))
            }
        }
        return out
    }

    static func deleteHistory(_ db: OpaquePointer, engine: BrowserData.Engine, sites: Set<String>) -> Int {
        let match: (String) -> Bool = { url in
            guard let s = site(ofURL: url) else { return false }
            return sites.contains(s)
        }
        switch engine {
        case .safari:
            let list = ids(db, "SELECT id, url FROM history_items", keep: match)
            _ = deleteEach(db, "DELETE FROM history_visits WHERE history_item = ?", ids: list)
            return deleteEach(db, "DELETE FROM history_items WHERE id = ?", ids: list)
        case .chromium:
            let list = ids(db, "SELECT id, url FROM urls", keep: match)
            _ = deleteEach(db, "DELETE FROM visits WHERE url = ?", ids: list)
            _ = deleteEach(db, "DELETE FROM keyword_search_terms WHERE url_id = ?", ids: list)
            return deleteEach(db, "DELETE FROM urls WHERE id = ?", ids: list)
        }
    }

    static func deleteCookies(_ db: OpaquePointer, sites: Set<String>) -> Int {
        let list = ids(db, "SELECT rowid, host_key FROM cookies") { sites.contains(site(ofHost: $0)) }
        return deleteEach(db, "DELETE FROM cookies WHERE rowid = ?", ids: list)
    }
}
#endif
