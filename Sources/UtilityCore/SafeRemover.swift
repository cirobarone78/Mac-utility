import Foundation

/// L'unico punto dell'app che rimuove file. Non cancella mai: sposta nel Cestino,
/// così ogni operazione si può annullare dal Finder ("Rimetti al suo posto").
public struct SafeRemover: Sendable {
    public struct Report: Sendable {
        public var moved: [URL] = []
        /// Per ogni file spostato: dove stava e dove si trova ora nel Cestino.
        public var trashMoves: [OperationRecord.Move] = []
        public var skipped: [(url: URL, reason: String)] = []
        public var bytes: Int64 = 0
        /// Identificativo dell'operazione in Cronologia (per il tasto «Ripristina»).
        public var operationID: String?
    }

    public let policy: SafetyPolicy
    public init(policy: SafetyPolicy) { self.policy = policy }

    /// - Parameters:
    ///   - kind: nome dell'operazione in Cronologia ("Pulizia disco", "Duplicati"…).
    ///   - log: false quando chi chiama registra l'operazione insieme ad altro (es. il riordino).
    public func moveToTrash(_ items: [DiskItem], kind: String = "Cestino", log: Bool = true,
                            logFolder: URL = OperationLog.folder) -> Report {
        var r = Report()
        for item in items {
            if policy.isProtected(item.url) {
                r.skipped.append((url: item.url, reason: "protetto dalle regole"))
                continue
            }
            do {
                var inTrash: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &inTrash)
                r.moved.append(item.url)
                r.bytes += item.bytes
                if let dest = inTrash?.path {
                    r.trashMoves.append(.init(from: item.url.path, to: dest))
                }
            } catch {
                r.skipped.append((url: item.url, reason: error.localizedDescription))
            }
        }
        Journal.append(r)
        if log && !r.trashMoves.isEmpty {
            let record = OperationRecord(kind: kind,
                                         summary: "\(r.moved.count) elementi nel Cestino (\(Bytes.format(r.bytes)))",
                                         moves: r.trashMoves, bytes: r.bytes)
            OperationLog.save(record, in: logFolder)
            r.operationID = record.id
        }
        return r
    }
}

/// Registro delle operazioni: ~/Library/Application Support/OmniTools/registro.log
public enum Journal {
    public static var fileURL: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("registro.log")
    }

    static func append(_ r: SafeRemover.Report) {
        append(lines: r.moved.map { "CESTINO\t\($0.path)" }
               + r.skipped.map { "SALTATO\t\($0.url.path)\t\($0.reason)" })
    }

    static func append(lines: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let stamped = lines.map { "\(stamp)\t\($0)" }
        guard !stamped.isEmpty, let data = (stamped.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
