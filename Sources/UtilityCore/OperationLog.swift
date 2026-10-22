import Foundation

/// Un'operazione eseguita da OmniTools, con tutto il necessario per tornare indietro.
public struct OperationRecord: Codable, Identifiable, Sendable, Hashable {
    /// Uno spostamento: `from` = dove stava il file, `to` = dove è finito (sottocartella o Cestino).
    public struct Move: Codable, Sendable, Hashable {
        public let from: String
        public let to: String
        /// true quando al ripristino il file attuale va prima spostato nel Cestino
        /// (es. un database del browser ripulito che torna alla versione di prima).
        public var replace: Bool?
        public var toTrash: Bool { to.contains("/.Trash/") }

        public init(from: String, to: String, replace: Bool? = nil) {
            self.from = from
            self.to = to
            self.replace = replace
        }
    }

    public let id: String
    public let date: Date
    /// "Pulizia disco", "Duplicati", "Riordino", "Assistente AI"…
    public let kind: String
    public let summary: String
    public var moves: [Move]
    public var createdFolders: [String]
    public var bytes: Int64
    public var restored = false

    public init(kind: String, summary: String, moves: [Move] = [], createdFolders: [String] = [],
                bytes: Int64 = 0, date: Date = Date()) {
        self.id = String(format: "%.0f", date.timeIntervalSince1970 * 1000) + "-" + UUID().uuidString.prefix(6)
        self.date = date
        self.kind = kind
        self.summary = summary
        self.moves = moves
        self.createdFolders = createdFolders
        self.bytes = bytes
    }
}

public struct RestoreResult: Sendable {
    public var restored = 0
    /// File non più nel Cestino (svuotato o già rimessi a posto a mano).
    public var missing = 0
    /// Al posto originale c'è già un altro file con lo stesso nome.
    public var conflicts = 0
    public var errors: [String] = []

    public var message: String {
        var parts = ["\(restored) elementi rimessi al loro posto."]
        if missing > 0 { parts.append("\(missing) non più disponibili (Cestino svuotato o già ripristinati a mano).") }
        if conflicts > 0 { parts.append("\(conflicts) lasciati dove sono: al loro posto c'è già un file con lo stesso nome.") }
        if !errors.isEmpty { parts.append("Problemi: " + errors.prefix(3).joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}

/// Cronologia delle operazioni: ~/Library/Application Support/OmniTools/operazioni/
public enum OperationLog {
    public static var folder: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("operazioni", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func save(_ record: OperationRecord, in folder: URL = folder) {
        guard !record.moves.isEmpty || !record.createdFolders.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoder.encode(record).write(to: folder.appendingPathComponent(record.id + ".json"), options: .atomic)
    }

    /// Tutte le operazioni, dalla più recente.
    public static func list(in folder: URL = folder) -> [OperationRecord] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(OperationRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// L'ultima operazione non ancora ripristinata, tra quelle dei tipi indicati (tutti se vuoto).
    public static func latest(kinds: Set<String> = [], in folder: URL = folder) -> OperationRecord? {
        list(in: folder).first { !$0.restored && (kinds.isEmpty || kinds.contains($0.kind)) }
    }

    /// Rimette ogni file dov'era (anche dal Cestino) e toglie le cartelle create, se vuote.
    @discardableResult
    public static func restore(_ record: OperationRecord, in folder: URL = folder) -> RestoreResult {
        let fm = FileManager.default
        var result = RestoreResult()
        for move in record.moves.reversed() {
            guard fm.fileExists(atPath: move.to) else { result.missing += 1; continue }
            if fm.fileExists(atPath: move.from) {
                // La versione attuale va nel Cestino (si può sempre recuperare), poi torna quella di prima.
                guard move.replace == true,
                      (try? fm.trashItem(at: URL(fileURLWithPath: move.from), resultingItemURL: nil)) != nil
                else { result.conflicts += 1; continue }
            }
            if move.replace == true {
                // I file di appoggio di un database (-wal, -shm) creati dopo non devono restare
                // accanto alla versione rimessa a posto.
                let recorded = Set(record.moves.map(\.from))
                for suffix in ["-wal", "-shm", "-journal"] {
                    let side = move.from + suffix
                    if !recorded.contains(side), fm.fileExists(atPath: side) {
                        _ = try? fm.trashItem(at: URL(fileURLWithPath: side), resultingItemURL: nil)
                    }
                }
            }
            do {
                try fm.createDirectory(atPath: (move.from as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                try fm.moveItem(atPath: move.to, toPath: move.from)
                result.restored += 1
            } catch let error where FinderBridge.isPermissionError(error) {
                do {
                    try FinderBridge.moveBack(from: move.to, to: move.from)
                    result.restored += 1
                } catch {
                    result.errors.append("\((move.from as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            } catch {
                result.errors.append("\((move.from as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        for dir in record.createdFolders.reversed() {
            if (try? fm.contentsOfDirectory(atPath: dir))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
                try? fm.removeItem(atPath: dir)   // cartella vuota creata da noi
            }
        }
        var updated = record
        updated.restored = true
        try? encoder.encode(updated).write(to: folder.appendingPathComponent(record.id + ".json"), options: .atomic)
        Journal.append(lines: ["RIPRISTINATO\t\(record.kind): \(record.summary) — \(result.message)"])
        return result
    }
}
