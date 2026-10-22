import Foundation

/// Fa eseguire al Finder le operazioni che macOS nega alle app (es. il Cestino di iCloud Drive).
/// La prima volta macOS chiede: «OmniTools vuole controllare Finder».
public enum FinderBridge {
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(_ source: String) throws -> String? {
        #if os(macOS)
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw CocoaError(.featureUnsupported)
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "errore del Finder"
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw NSError(domain: "FinderBridge", code: code, userInfo: [
                NSLocalizedDescriptionKey: code == -1743
                    ? "OmniTools non ha il permesso di controllare il Finder (Impostazioni di Sistema › Privacy e sicurezza › Automazione)."
                    : message,
            ])
        }
        return result.stringValue
        #else
        throw CocoaError(.featureUnsupported)   // su iPhone non c'è il Finder
        #endif
    }

    /// Sposta nel Cestino tramite il Finder. Restituisce dove è finito il file.
    public static func trash(_ url: URL) throws -> String? {
        try run("""
        tell application "Finder"
            set t to delete (POSIX file \(quoted(url.path)) as alias)
            return POSIX path of (t as alias)
        end tell
        """)
    }

    /// Rimette un file dal Cestino al suo posto, con il nome originale.
    public static func moveBack(from trashPath: String, to originalPath: String) throws {
        let folder = (originalPath as NSString).deletingLastPathComponent
        let name = (originalPath as NSString).lastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        _ = try run("""
        tell application "Finder"
            set moved to move (POSIX file \(quoted(trashPath)) as alias) to (POSIX file \(quoted(folder)) as alias)
            set name of moved to \(quoted(name))
        end tell
        """)
    }

    /// true se l'errore è un permesso negato da macOS (e quindi vale la pena chiedere al Finder).
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           under.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(under.code) { return true }
        return false
    }
}
