import Foundation
import CryptoKit

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let bytesEach: Int64
    /// Ordinati dal più vecchio: il primo è quello proposto da tenere.
    public let files: [DiskItem]
    public var wasted: Int64 { bytesEach * Int64(files.count - 1) }

    public init(bytesEach: Int64, files: [DiskItem]) {
        self.bytesEach = bytesEach
        self.files = files
    }
}

/// Trova file identici: prima per dimensione, poi per impronta dei primi 64 KB, infine per impronta completa.
public struct DuplicateFinder: Sendable {
    public var minBytes: Int64

    public init(minBytes: Int64 = 1_000_000) { self.minBytes = minBytes }

    public func find(under root: URL, policy: SafetyPolicy,
                     progress: (String) -> Void = { _ in },
                     isCancelled: () -> Bool = { false }) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .creationDateKey, .contentModificationDateKey]
        var bySize: [Int64: [DiskItem]] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                               options: [.skipsPackageDescendants],
                                               errorHandler: { _, _ in true })
        var seen = 0
        while let url = e?.nextObject() as? URL {
            if isCancelled() { return [] }
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, v.isSymbolicLink != true,
                  let size = v.fileSize, Int64(size) >= minBytes,
                  !policy.isProtected(url) else { continue }
            bySize[Int64(size), default: []].append(
                DiskItem(url: url, bytes: Int64(size), isDirectory: false,
                         modified: v.creationDate ?? v.contentModificationDate))
            seen += 1
            if seen % 500 == 0 { progress("\(seen) file esaminati") }
        }

        var groups: [DuplicateGroup] = []
        for (size, items) in bySize where items.count > 1 {
            if isCancelled() { return [] }
            for partial in Dictionary(grouping: items, by: { Self.hash($0.url, limit: 65_536) }).values
            where partial.count > 1 {
                for full in Dictionary(grouping: partial, by: { Self.hash($0.url, limit: nil) })
                where full.key != nil && full.value.count > 1 {
                    let sorted = full.value.sorted { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
                    groups.append(DuplicateGroup(bytesEach: size, files: sorted))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// SHA-256 del file (o dei suoi primi `limit` byte). nil se non leggibile.
    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = try? h.read(upToCount: min(1 << 20, remaining))
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
