import Foundation

/// L'unico punto dell'app che rimuove file. Non cancella mai: sposta nel Cestino,
/// così ogni operazione si può annullare dal Finder ("Rimetti al suo posto").
public struct SafeRemover: Sendable {
    public struct Report: Sendable {
        public var moved: [URL] = []
        public var skipped: [(url: URL, reason: String)] = []
        public var bytes: Int64 = 0
    }

    public let policy: SafetyPolicy
    public init(policy: SafetyPolicy) { self.policy = policy }

    public func moveToTrash(_ items: [DiskItem]) -> Report {
        var r = Report()
        for item in items {
            if policy.isProtected(item.url) {
                r.skipped.append((url: item.url, reason: "protetto dalle regole"))
                continue
            }
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                r.moved.append(item.url)
                r.bytes += item.bytes
            } catch {
                r.skipped.append((url: item.url, reason: error.localizedDescription))
            }
        }
        Journal.append(r)
        return r
    }
}

/// Registro delle operazioni: ~/Library/Application Support/MacUtility/registro.log
public enum Journal {
    public static var fileURL: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("registro.log")
    }

    static func append(_ r: SafeRemover.Report) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = r.moved.map { "\(stamp)\tCESTINO\t\($0.path)" }
        lines += r.skipped.map { "\(stamp)\tSALTATO\t\($0.url.path)\t\($0.reason)" }
        guard !lines.isEmpty, let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
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
