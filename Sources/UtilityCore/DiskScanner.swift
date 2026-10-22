import Foundation

/// Misura lo spazio occupato. Non segue i collegamenti simbolici.
/// Nota: con APFS i cloni e i link fisici possono far sembrare le cartelle più grandi del reale.
public struct DiskScanner: Sendable {
    public init() {}

    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey,
    ]

    static func allocatedSize(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    /// Dimensione totale di un file o di una cartella (ricorsiva).
    public func size(of url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        guard v.isDirectory == true else { return Self.allocatedSize(v) }

        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Self.keys,
                                               options: [], errorHandler: { _, _ in true })
        while let child = e?.nextObject() as? URL {
            if isCancelled() { break }
            guard let cv = try? child.resourceValues(forKeys: Set(Self.keys)),
                  cv.isSymbolicLink != true, cv.isDirectory != true else { continue }
            total += Self.allocatedSize(cv)
        }
        return total
    }

    /// Le voci direttamente dentro `root`, dalla più pesante.
    public func children(of root: URL, isCancelled: () -> Bool = { false }) -> [DiskItem] {
        let fm = FileManager.default
        guard let list = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Self.keys,
                                                     options: []) else { return [] }
        var out: [DiskItem] = []
        for url in list {
            if isCancelled() { break }
            let v = try? url.resourceValues(forKeys: Set(Self.keys))
            if v?.isSymbolicLink == true { continue }
            out.append(DiskItem(url: url, bytes: size(of: url, isCancelled: isCancelled),
                                isDirectory: v?.isDirectory == true,
                                modified: v?.contentModificationDate))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// I file più grandi sotto `root`.
    public func largeFiles(under root: URL, minBytes: Int64 = 200_000_000, limit: Int = 100,
                           isCancelled: () -> Bool = { false }) -> [DiskItem] {
        var found: [DiskItem] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Self.keys,
                                               options: [], errorHandler: { _, _ in true })
        while let url = e?.nextObject() as? URL {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(Self.keys)),
                  v.isSymbolicLink != true, v.isDirectory != true else { continue }
            let s = Self.allocatedSize(v)
            if s >= minBytes {
                found.append(DiskItem(url: url, bytes: s, isDirectory: false,
                                      modified: v.contentModificationDate))
            }
        }
        return Array(found.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
