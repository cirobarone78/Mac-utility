#if os(macOS)
import Foundation

/// Stato dei backup di Time Machine, detto in parole.
public struct BackupReport: Sendable {
    public struct Destination: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let lastBackup: Date?
        public let bytesAvailable: Int64?
        public let bytesUsed: Int64?
    }

    public enum Level: Int, Comparable, Sendable {
        case ok, info, warning, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Finding: Identifiable, Sendable {
        public let id = UUID()
        public let level: Level
        public let title: String
        public let detail: String
    }

    public var autoBackup: Bool?
    public var destinations: [Destination] = []
    public var lastBackup: Date?
    public var running = false
    public var excluded: [String] = []
    public var findings: [Finding] = []
    /// Le preferenze di Time Machine non sono leggibili (serve Accesso completo al disco).
    public var unreadable = false

    public init() {}
}

public enum BackupCheck {
    static let plistPath = "/Library/Preferences/com.apple.TimeMachine.plist"

    public static func run(home: String = NSHomeDirectory(), now: Date = Date()) -> BackupReport {
        var r = BackupReport()
        let prefs = NSDictionary(contentsOfFile: plistPath) as? [String: Any]
        r.unreadable = prefs == nil
        r.autoBackup = prefs?["AutoBackup"] as? Bool

        for d in (prefs?["Destinations"] as? [[String: Any]]) ?? [] {
            let dates = (d["SnapshotDates"] as? [Date]) ?? []
            let last = dates.max() ?? (d["ReferenceLocalSnapshotDate"] as? Date)
            r.destinations.append(.init(id: d["DestinationID"] as? String ?? UUID().uuidString,
                                        name: d["LastKnownVolumeName"] as? String ?? "Disco di backup",
                                        lastBackup: last,
                                        bytesAvailable: (d["BytesAvailable"] as? NSNumber)?.int64Value,
                                        bytesUsed: (d["BytesUsed"] as? NSNumber)?.int64Value))
        }
        // Se le preferenze non dicono la data, la chiede a tmutil (funziona se il disco è collegato).
        r.lastBackup = r.destinations.compactMap(\.lastBackup).max() ?? latestFromTmutil()
        if r.destinations.isEmpty {
            let info = Shell.run("/usr/bin/tmutil", ["destinationinfo"]).output
            for block in info.components(separatedBy: "====") where block.contains("Name") {
                let name = block.split(separator: "\n").first { $0.hasPrefix("Name") }?
                    .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                r.destinations.append(.init(id: UUID().uuidString, name: name ?? "Disco di backup",
                                            lastBackup: nil, bytesAvailable: nil, bytesUsed: nil))
            }
        }
        r.running = Shell.run("/usr/bin/tmutil", ["status"]).output.contains("Running = 1")

        // Le cartelle importanti sono incluse nel backup?
        for folder in ["Documents", "Desktop", "Pictures", "Movies", "Music"] {
            let path = home + "/" + folder
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if Shell.run("/usr/bin/tmutil", ["isexcluded", path]).output.contains("[Excluded]") {
                r.excluded.append(path)
            }
        }
        r.findings = findings(for: r, now: now)
        return r
    }

    static func latestFromTmutil() -> Date? {
        let out = Shell.run("/usr/bin/tmutil", ["latestbackup"]).output
        // Il nome della cartella è la data: …/2026-10-21-093012.backup
        guard let r = out.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: String(out[r]))
    }

    static func findings(for r: BackupReport, now: Date) -> [BackupReport.Finding] {
        var out: [BackupReport.Finding] = []
        if r.destinations.isEmpty {
            out.append(.init(level: .critical, title: "Time Machine non è configurato",
                             detail: "Nessun disco di backup. Se il Mac si rompe o viene rubato, i file che non sono su iCloud si perdono. Collega un disco esterno e sceglilo in Impostazioni › Generali › Time Machine."))
            return out
        }
        if r.autoBackup == false {
            out.append(.init(level: .warning, title: "I backup automatici sono spenti",
                             detail: "Time Machine fa il backup solo quando lo avvii tu. Riaccendili nelle impostazioni di Time Machine."))
        }
        if let last = r.lastBackup {
            let days = Int(now.timeIntervalSince(last) / 86_400)
            let when = days == 0 ? "oggi" : days == 1 ? "ieri" : "\(days) giorni fa"
            let level: BackupReport.Level = days > 30 ? .critical : days > 7 ? .warning : .ok
            out.append(.init(level: level, title: "Ultimo backup: \(when)",
                             detail: level == .ok ? "Tutto regolare."
                                : "Collega il disco di backup al Mac e lascialo collegato finché Time Machine ha finito."))
        } else {
            out.append(.init(level: .warning, title: "Data dell'ultimo backup sconosciuta",
                             detail: r.unreadable
                                ? "Per leggerla, OmniTools ha bisogno di Accesso completo al disco (Impostazioni › Privacy e sicurezza)."
                                : "Collega il disco di backup: Time Machine non ha ancora completato un backup."))
        }
        for d in r.destinations {
            if let free = d.bytesAvailable, let used = d.bytesUsed, used + free > 0 {
                let fraction = Double(free) / Double(used + free)
                if fraction < 0.1 {
                    out.append(.init(level: .info, title: "«\(d.name)» è quasi pieno",
                                     detail: "Restano \(Bytes.format(free)). Time Machine cancellerà da solo i backup più vecchi per fare spazio: è normale, ma la cronologia sarà più corta."))
                }
            }
        }
        for path in r.excluded {
            out.append(.init(level: .warning, title: "«\((path as NSString).lastPathComponent)» è escluso dal backup",
                             detail: "Questa cartella non viene salvata. Toglila dalle esclusioni nelle opzioni di Time Machine, a meno che sia una tua scelta."))
        }
        out.append(.init(level: .info, title: "iCloud non è un backup",
                         detail: "iCloud Drive e Foto su iCloud sincronizzano: se cancelli un file, sparisce anche dagli altri dispositivi. Time Machine invece conserva le versioni passate."))
        return out.sorted { $0.level > $1.level }
    }

    /// Avvia subito un backup.
    @discardableResult
    public static func startNow() -> Bool {
        Shell.run("/usr/bin/tmutil", ["startbackup", "--auto"]).ok
    }
}
#endif
