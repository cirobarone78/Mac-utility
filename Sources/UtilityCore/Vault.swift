#if os(macOS)
import Foundation

/// Cassaforte: un'immagine disco cifrata AES-256 di macOS (sparsebundle APFS).
/// Si apre con la password come un disco nel Finder; chiusa, il contenuto è illeggibile.
/// OmniTools non conserva la password: se la perdi, i file non si recuperano.
public struct VaultInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public var mountPoint: String?
    public var bytes: Int64 = 0
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var isOpen: Bool { mountPoint != nil }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    public var id: URL { url }
}

public enum VaultError: LocalizedError {
    case failed(String)
    case wrongPassword
    public var errorDescription: String? {
        switch self {
        case .failed(let s): s.isEmpty ? "Operazione non riuscita." : s
        case .wrongPassword: "Password sbagliata."
        }
    }
}

public enum Vault {
    static let hdiutil = "/usr/bin/hdiutil"

    /// Crea la cassaforte. `sizeGB` è il massimo: il file occupa solo lo spazio dei documenti dentro.
    public static func create(in folder: URL, name: String, sizeGB: Int, password: String) throws -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = folder.appendingPathComponent((clean.isEmpty ? "Cassaforte" : clean) + ".sparsebundle")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw VaultError.failed("Esiste già una cassaforte con questo nome.")
        }
        let r = Shell.run(hdiutil, ["create", "-size", "\(max(1, sizeGB))g", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                    "-encryption", "AES-256", "-stdinpass", "-volname", clean.isEmpty ? "Cassaforte" : clean,
                                    url.path], input: Data(password.utf8))
        guard r.ok else { throw VaultError.failed(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return url
    }

    /// Apre la cassaforte e restituisce dove è montata (es. /Volumes/Cassaforte).
    public static func open(_ url: URL, password: String) throws -> String {
        let r = Shell.run(hdiutil, ["attach", "-stdinpass", "-plist", url.path], input: Data(password.utf8))
        guard r.ok else {
            if r.output.contains("Authentication error") || r.output.contains("authentication") { throw VaultError.wrongPassword }
            throw VaultError.failed(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let mount = mountPoints(inPlist: r.output).first { return mount }
        throw VaultError.failed("Aperta, ma non trovo dove è montata.")
    }

    public static func close(_ mountPoint: String, force: Bool = false) throws {
        let r = Shell.run(hdiutil, ["detach", mountPoint] + (force ? ["-force"] : []))
        guard r.ok else {
            throw VaultError.failed(r.output.contains("Resource busy")
                ? "Qualche app sta usando un file della cassaforte: chiudilo e riprova."
                : r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Per ogni cassaforte: è aperta? dove? quanto occupa?
    public static func status(_ urls: [URL]) -> [VaultInfo] {
        let info = Shell.run(hdiutil, ["info", "-plist"]).output
        var mounted: [String: String] = [:]
        if let plist = plist(info), let images = plist["images"] as? [[String: Any]] {
            for image in images {
                guard let path = image["image-path"] as? String else { continue }
                let mount = (image["system-entities"] as? [[String: Any]])?.compactMap { $0["mount-point"] as? String }.first
                if let mount { mounted[URL(fileURLWithPath: path).standardizedFileURL.path] = mount }
            }
        }
        let scanner = DiskScanner()
        return urls.map { u in
            VaultInfo(url: u, mountPoint: mounted[u.standardizedFileURL.path], bytes: scanner.size(of: u))
        }
    }

    static func plist(_ text: String) -> [String: Any]? {
        guard let start = text.range(of: "<?xml") else { return nil }
        let data = Data(text[start.lowerBound...].utf8)
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func mountPoints(inPlist text: String) -> [String] {
        ((plist(text)?["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["mount-point"] as? String }
    }

    /// Sposta i file nella cassaforte aperta. Gli originali escono dal disco normale:
    /// la copia cifrata è l'unica che resta. «Ripristina» li rimette fuori (a cassaforte aperta).
    public static func moveIn(_ files: [URL], mountPoint: String, logFolder: URL = OperationLog.folder) -> (moved: Int, errors: [String], operationID: String?) {
        let fm = FileManager.default
        var moves: [OperationRecord.Move] = []
        var errors: [String] = []
        for f in files {
            var dest = URL(fileURLWithPath: mountPoint).appendingPathComponent(f.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = f.deletingPathExtension().lastPathComponent + " \(n)"
                dest = URL(fileURLWithPath: mountPoint)
                    .appendingPathComponent(f.pathExtension.isEmpty ? base : base + "." + f.pathExtension)
                n += 1
            }
            do {
                try fm.moveItem(at: f, to: dest)
                moves.append(.init(from: f.path, to: dest.path))
            } catch {
                errors.append("\(f.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var id: String?
        if !moves.isEmpty {
            let record = OperationRecord(kind: "Cassaforte", summary: "\(moves.count) file nella cassaforte", moves: moves)
            OperationLog.save(record, in: logFolder)
            id = record.id
        }
        return (moves.count, errors, id)
    }
}
#endif
