import Foundation

/// Regole di sicurezza: cosa l'app non deve MAI toccare, nemmeno su richiesta.
/// Salvate in ~/Library/Application Support/OmniTools/regole.json, modificabili dall'utente.
public struct SafetyPolicy: Codable, Equatable, Sendable {
    /// Percorsi intoccabili (anche tutto ciò che contengono). Accetta "~" per la home.
    public var neverTouchPaths: [String]
    /// Nomi di file o cartelle intoccabili ovunque si trovino (es. ".git").
    public var neverTouchNames: [String]

    public init(neverTouchPaths: [String], neverTouchNames: [String]) {
        self.neverTouchPaths = neverTouchPaths
        self.neverTouchNames = neverTouchNames
    }

    public static let `default` = SafetyPolicy(
        neverTouchPaths: [
            "/System", "/bin", "/sbin", "/usr", "/private", "/Library/Apple",
            "~/Library/Keychains", "~/Library/Mobile Documents", "~/Library/Mail",
            "~/Library/Messages", "~/Library/Photos", "~/Pictures/Photos Library.photoslibrary",
            "~/.ssh", "~/.gnupg",
        ],
        neverTouchNames: [".git", ".ssh", ".gnupg", "config.php", "config_local.php"]
    )

    public static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// true se `url` è protetto e quindi non può essere spostato nel Cestino.
    public func isProtected(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let std = url.standardizedFileURL
        let path = std.path
        let homePath = URL(fileURLWithPath: home).standardizedFileURL.path

        // La radice, /Users, /Applications e la home stessa non si toccano mai.
        let roots: Set<String> = ["/", "/Users", "/Applications", "/Library", "/Volumes", homePath]
        if roots.contains(path) { return true }
        // Le cartelle di primo livello della home (Documenti, Scrivania...) nemmeno.
        if std.deletingLastPathComponent().path == homePath && !std.lastPathComponent.hasPrefix(".") {
            return true
        }

        for raw in neverTouchPaths {
            let p = URL(fileURLWithPath: Self.expand(raw, home: homePath)).standardizedFileURL.path
            if path == p || path.hasPrefix(p.hasSuffix("/") ? p : p + "/") { return true }
        }
        let names = Set(neverTouchNames)
        return std.pathComponents.contains { names.contains($0) }
    }

    // MARK: - Salvataggio

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniTools", isDirectory: true)
            .appendingPathComponent("regole.json")
    }

    /// Carica le regole; se il file non c'è lo crea con quelle predefinite.
    public static func load(from url: URL = defaultFileURL) -> SafetyPolicy {
        if let data = try? Data(contentsOf: url),
           let policy = try? JSONDecoder().decode(SafetyPolicy.self, from: data) {
            return policy
        }
        try? SafetyPolicy.default.save(to: url)
        return .default
    }

    public func save(to url: URL = defaultFileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
