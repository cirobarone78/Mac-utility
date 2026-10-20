import Foundation
import SQLite3

/// Un file multimediale ricevuto o inviato su WhatsApp.
public struct WhatsAppMedia: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case photo = "Foto"
        case video = "Video"
        case audio = "Vocali e audio"
        case document = "Documenti"
        case sticker = "Sticker e GIF"
        case other = "Altro"
    }

    public let url: URL
    public let bytes: Int64
    public let date: Date?
    public let kind: Kind
    /// Identificativo della chat (cartella) e nome leggibile, se trovato.
    public let chatID: String
    public let chatName: String
    public var id: URL { url }
}

public struct WhatsAppScanResult: Sendable {
    public var root: URL?
    public var media: [WhatsAppMedia] = []
    /// File che sono copie identiche di un altro (si propone di tenere il più vecchio).
    public var duplicates: Set<URL> = []
    /// Cartelle che macOS non ha lasciato leggere (permesso negato).
    public var deniedFolders = 0
    /// La cartella dei media esiste ma non è stato possibile elencarla.
    public var mediaFolderUnreadable = false
    public var totalBytes: Int64 { media.reduce(0) { $0 + $1.bytes } }
}

public enum WhatsAppScanner {
    public static let bundleID = "net.whatsapp.WhatsApp"

    /// Dove l'app WhatsApp per Mac tiene i suoi dati (prima quella dell'App Store, poi le versioni precedenti).
    public static func dataFolder(home: String = NSHomeDirectory()) -> URL? {
        [
            home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
            home + "/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Application Support/WhatsApp",
            home + "/Library/Application Support/WhatsApp",
        ]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let extensions: [WhatsAppMedia.Kind: Set<String>] = [
        .photo: ["jpg", "jpeg", "png", "heic", "heif"],
        .video: ["mp4", "mov", "m4v", "3gp"],
        .audio: ["opus", "ogg", "m4a", "mp3", "aac", "amr", "caf", "wav"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "zip", "rar", "pages", "numbers", "key", "csv", "vcf"],
        .sticker: ["webp", "gif", "was"],
    ]

    /// File che non vanno mai toccati: il database delle chat e le impostazioni.
    static let neverTouchExtensions: Set<String> = ["sqlite", "sqlite-wal", "sqlite-shm", "db", "db-wal", "db-shm",
                                                   "plist", "json", "log", "lock"]

    static func kind(of url: URL) -> WhatsAppMedia.Kind? {
        let ext = url.pathExtension.lowercased()
        if neverTouchExtensions.contains(ext) { return nil }
        return extensions.first { $0.value.contains(ext) }?.key
    }

    public static func scan(root: URL, policy: SafetyPolicy, findDuplicates: Bool = true,
                            progress: (Int) -> Void = { _ in },
                            isCancelled: () -> Bool = { false }) -> WhatsAppScanResult {
        var result = WhatsAppScanResult(root: root)
        let names = chatNames(root: root)
        let mediaRoot = root.appendingPathComponent("Message/Media", isDirectory: true)
        let base = FileManager.default.fileExists(atPath: mediaRoot.path) ? mediaRoot : root
        let baseCount = base.standardizedFileURL.pathComponents.count

        // Se macOS nega l'accesso (dati di un'altra app), lo si scopre provando a elencare la cartella.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: base.path)
        } catch {
            result.mediaFolderUnreadable = true
            return result
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var denied = 0
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles], errorHandler: { _, _ in denied += 1; return true })
        while let url = e?.nextObject() as? URL {
            if isCancelled() { break }
            guard let kind = kind(of: url),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  !policy.isProtected(url) else { continue }
            let parts = url.standardizedFileURL.pathComponents
            let chatID = base == mediaRoot && parts.count > baseCount + 1 ? parts[baseCount] : "—"
            result.media.append(WhatsAppMedia(url: url, bytes: Int64(v.fileSize ?? 0), date: v.contentModificationDate,
                                              kind: kind, chatID: chatID, chatName: displayName(chatID, names)))
            if result.media.count % 500 == 0 { progress(result.media.count) }
        }
        result.deniedFolders = denied
        if findDuplicates { result.duplicates = duplicates(result.media, isCancelled: isCancelled) }
        return result
    }

    /// Copie identiche (stesso contenuto, anche in chat diverse): tutte tranne la più vecchia.
    static func duplicates(_ media: [WhatsAppMedia], isCancelled: () -> Bool) -> Set<URL> {
        var out = Set<URL>()
        for sameSize in Dictionary(grouping: media.filter { $0.bytes > 4096 }, by: \.bytes).values where sameSize.count > 1 {
            if isCancelled() { break }
            for same in Dictionary(grouping: sameSize, by: { DuplicateFinder.hash($0.url, limit: nil) })
            where same.key != nil && same.value.count > 1 {
                let sorted = same.value.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                out.formUnion(sorted.dropFirst().map(\.url))
            }
        }
        return out
    }

    static func displayName(_ chatID: String, _ names: [String: String]) -> String {
        if let n = names[chatID], !n.isEmpty { return n }
        if chatID.hasSuffix("@g.us") { return "Gruppo" }
        if let number = chatID.split(separator: "@").first, number.allSatisfy(\.isNumber) { return "+" + number }
        return chatID
    }

    /// Nomi delle chat dal database di WhatsApp, letto in sola lettura senza bloccarlo.
    static func chatNames(root: URL) -> [String: String] {
        let db = root.appendingPathComponent("ChatStorage.sqlite")
        guard FileManager.default.fileExists(atPath: db.path) else { return [:] }
        let uri = "file:" + (db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path) + "?mode=ro&immutable=1"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return [:]
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT ZCONTACTJID, ZPARTNERNAME FROM ZWACHATSESSION", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jid = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) else { continue }
            out[String(cString: jid)] = String(cString: name)
        }
        return out
    }
}
