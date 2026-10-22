#if os(macOS)
import Foundation
import SQLite3

/// Un permesso concesso (o negato) a un'app: fotocamera, microfono, schermo…
public struct PrivacyGrant: Identifiable, Hashable, Sendable {
    public let service: String
    /// Identificativo dell'app (o percorso del programma).
    public let client: String
    public let clientIsPath: Bool
    public let allowed: Bool
    public let modified: Date?
    /// Il permesso sta nel registro di sistema: si revoca solo da Impostazioni.
    public let systemWide: Bool
    public var id: String { service + "|" + client }

    public var serviceName: String { PrivacyPermissions.names[service]?.name ?? service }
    public var shortService: String { service.replacingOccurrences(of: "kTCCService", with: "") }
}

public enum PrivacyPermissions {
    /// Nome in italiano e voce di Impostazioni › Privacy e sicurezza.
    public static let names: [String: (name: String, pane: String, order: Int)] = [
        "kTCCServiceCamera": ("Fotocamera", "Privacy_Camera", 0),
        "kTCCServiceMicrophone": ("Microfono", "Privacy_Microphone", 1),
        "kTCCServiceScreenCapture": ("Registrazione dello schermo", "Privacy_ScreenCapture", 2),
        "kTCCServiceSystemPolicyAllFiles": ("Accesso completo al disco", "Privacy_AllFiles", 3),
        "kTCCServiceAccessibility": ("Accessibilità (controllo del Mac)", "Privacy_Accessibility", 4),
        "kTCCServiceListenEvent": ("Monitoraggio dell'input (tastiera)", "Privacy_ListenEvent", 5),
        "kTCCServicePostEvent": ("Controllo di tastiera e mouse", "Privacy_Accessibility", 6),
        "kTCCServiceAddressBook": ("Contatti", "Privacy_Contacts", 7),
        "kTCCServiceCalendar": ("Calendari", "Privacy_Calendars", 8),
        "kTCCServiceReminders": ("Promemoria", "Privacy_Reminders", 9),
        "kTCCServicePhotos": ("Foto", "Privacy_Photos", 10),
        "kTCCServiceAppleEvents": ("Automazione", "Privacy_Automation", 11),
        "kTCCServiceSystemPolicyDesktopFolder": ("Cartella Scrivania", "Privacy_FilesAndFolders", 12),
        "kTCCServiceSystemPolicyDocumentsFolder": ("Cartella Documenti", "Privacy_FilesAndFolders", 13),
        "kTCCServiceSystemPolicyDownloadsFolder": ("Cartella Download", "Privacy_FilesAndFolders", 14),
        "kTCCServiceSystemPolicyRemovableVolumes": ("Dischi rimovibili", "Privacy_FilesAndFolders", 15),
        "kTCCServiceBluetoothAlways": ("Bluetooth", "Privacy_Bluetooth", 16),
    ]

    /// Permessi che danno accesso a dati molto personali o al controllo del Mac.
    public static let sensitive: Set<String> = [
        "kTCCServiceCamera", "kTCCServiceMicrophone", "kTCCServiceScreenCapture",
        "kTCCServiceSystemPolicyAllFiles", "kTCCServiceAccessibility", "kTCCServiceListenEvent",
    ]

    public struct Result: Sendable {
        public var grants: [PrivacyGrant] = []
        /// Nessun registro leggibile: serve Accesso completo al disco.
        public var needsFullDiskAccess = false
    }

    public static func list(home: String = NSHomeDirectory()) -> Result {
        var r = Result()
        let user = read(home + "/Library/Application Support/com.apple.TCC/TCC.db", systemWide: false)
        let system = read("/Library/Application Support/com.apple.TCC/TCC.db", systemWide: true)
        r.needsFullDiskAccess = user == nil && system == nil
        r.grants = ((user ?? []) + (system ?? []))
            .filter { names[$0.service] != nil }
            .sorted {
                let a = names[$0.service]?.order ?? 99, b = names[$1.service]?.order ?? 99
                return a != b ? a < b : $0.client < $1.client
            }
        return r
    }

    static func read(_ path: String, systemWide: Bool) -> [PrivacyGrant]? {
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT service, client, client_type, auth_value, last_modified FROM access",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [PrivacyGrant] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let s = sqlite3_column_text(stmt, 0), let c = sqlite3_column_text(stmt, 1) else { continue }
            let modified = sqlite3_column_int64(stmt, 4)
            out.append(PrivacyGrant(service: String(cString: s), client: String(cString: c),
                                    clientIsPath: sqlite3_column_int(stmt, 2) == 1,
                                    allowed: sqlite3_column_int(stmt, 3) >= 2,
                                    modified: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                                    systemWide: systemWide))
        }
        return out
    }

    /// Toglie il permesso: l'app lo chiederà di nuovo la prossima volta che le serve.
    /// Funziona per i permessi dell'utente; quelli di sistema si tolgono da Impostazioni.
    public static func revoke(_ g: PrivacyGrant) -> Bool {
        guard !g.clientIsPath else { return false }
        return Shell.run("/usr/bin/tccutil", ["reset", g.shortService, g.client]).ok
    }

    /// Indirizzo della voce di Impostazioni › Privacy e sicurezza.
    public static func settingsURL(for service: String) -> URL? {
        let pane = names[service]?.pane ?? "Privacy"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}
#endif
