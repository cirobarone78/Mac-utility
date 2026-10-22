import Foundation

/// Regole di sicurezza: cosa l'app non deve MAI toccare, nemmeno su richiesta.
/// Salvate in ~/Library/Application Support/OmniTools/regole.json, modificabili dall'utente.
public struct SafetyPolicy: Codable, Equatable, Sendable {
    /// Percorsi intoccabili (anche tutto ciò che contengono). Accetta "~" per la home.
    public var neverTouchPaths: [String]
    /// Nomi di file o cartelle intoccabili ovunque si trovino (es. ".git").
    public var neverTouchNames: [String]
    /// Eccezioni dentro un percorso protetto: qui si può lavorare (es. i file di iCloud Drive,
    /// che stanno dentro ~/Library/Mobile Documents). La cartella in sé resta intoccabile.
    public var allowedPaths: [String]

    public static let defaultAllowedPaths = ["~/Library/Mobile Documents/com~apple~CloudDocs"]

    public init(neverTouchPaths: [String], neverTouchNames: [String],
                allowedPaths: [String] = SafetyPolicy.defaultAllowedPaths) {
        self.neverTouchPaths = neverTouchPaths
        self.neverTouchNames = neverTouchNames
        self.allowedPaths = allowedPaths
    }

    enum CodingKeys: String, CodingKey { case neverTouchPaths, neverTouchNames, allowedPaths }

    /// I file di regole salvati prima che esistessero le eccezioni le ricevono predefinite.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        neverTouchPaths = try c.decode([String].self, forKey: .neverTouchPaths)
        neverTouchNames = try c.decode([String].self, forKey: .neverTouchNames)
        allowedPaths = try c.decodeIfPresent([String].self, forKey: .allowedPaths) ?? Self.defaultAllowedPaths
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

        func resolve(_ raw: String) -> String {
            URL(fileURLWithPath: Self.expand(raw, home: homePath)).standardizedFileURL.path
        }
        func isInside(_ p: String, _ root: String) -> Bool {
            p == root || p.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }

        // Cartelle dei servizi cloud: il contenitore (es. «Google Drive», «Il mio Drive») non si tocca,
        // i file dentro sì.
        let cloudStorage = homePath + "/Library/CloudStorage"
        if isInside(path, cloudStorage) && std.pathComponents.count <= cloudStorage.split(separator: "/").count + 3 {
            return true
        }

        let allowed = allowedPaths.map(resolve)
        if allowed.contains(path) { return true }                 // la radice di iCloud Drive
        let allowedRoot = allowed.first { isInside(path, $0) }

        for raw in neverTouchPaths {
            let p = resolve(raw)
            // Una regola più ampia dell'eccezione (es. tutto Mobile Documents) non vale dentro l'eccezione;
            // una regola più specifica (una cartella dentro iCloud Drive) sì.
            if let root = allowedRoot, isInside(root, p) { continue }
            if isInside(path, p) { return true }
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
