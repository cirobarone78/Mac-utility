import Foundation

/// Programmi che macOS avvia da solo (LaunchAgents / LaunchDaemons). Solo lettura per ora.
public struct StartupItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        case user = "Utente"
        case allUsersAgent = "Tutti gli utenti"
        case systemDaemon = "Servizio di sistema"
    }
    public let plist: URL
    public let label: String
    public let program: String?
    public let scope: Scope
    public let runAtLoad: Bool
    public let disabled: Bool
    public var id: URL { plist }
}

public enum StartupItems {
    public static func list(home: String = NSHomeDirectory()) -> [StartupItem] {
        let sources: [(String, StartupItem.Scope)] = [
            (home + "/Library/LaunchAgents", .user),
            ("/Library/LaunchAgents", .allUsersAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
        var out: [StartupItem] = []
        for (dir, scope) in sources {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any] else { continue }
                let program = dict["Program"] as? String
                    ?? (dict["ProgramArguments"] as? [String])?.first
                out.append(StartupItem(plist: url,
                                       label: dict["Label"] as? String ?? url.deletingPathExtension().lastPathComponent,
                                       program: program, scope: scope,
                                       runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
                                       disabled: dict["Disabled"] as? Bool ?? false))
            }
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
