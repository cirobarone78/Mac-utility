import Foundation

public enum Bytes {
    /// "1,2 GB" nel formato del Finder, nella lingua del sistema.
    public static func format(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Una voce su disco (file o cartella) con la sua dimensione.
public struct DiskItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let bytes: Int64
    public let isDirectory: Bool
    public let modified: Date?
    public var id: URL { url }

    public init(url: URL, bytes: Int64, isDirectory: Bool, modified: Date? = nil) {
        self.url = url
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.modified = modified
    }
}
