import Foundation

/// Una raccomandazione del «Medico del Mac».
public struct DoctorFinding: Codable, Identifiable, Hashable, Sendable {
    public var id: String { title }
    public let title: String
    public let detail: String
    /// "alta" | "media" | "bassa"
    public let priority: String
    /// Schermata di OmniTools che risolve il problema (vedi `DoctorReport.actions`).
    public let action: String
}

public struct DoctorReport: Codable, Sendable {
    public let summary: String
    public let findings: [DoctorFinding]

    public static let actions = ["pulizia", "spazio", "riordino", "duplicati", "foto", "whatsapp",
                                 "sistema", "avvio", "sicurezza", "nessuna"]
}

/// Raccoglie una "fotografia" del Mac (solo numeri e nomi, nessun contenuto di file)
/// e la fa leggere a Claude per avere consigli in ordine di importanza.
public enum MacDoctor {
    /// - Parameter system: righe già pronte sullo stato del sistema (memoria, CPU, batteria…), fornite dall'app.
    public static func snapshot(policy: SafetyPolicy, system: String, home: String = NSHomeDirectory(),
                                progress: (String) -> Void = { _ in }) -> String {
        var lines: [String] = ["# Fotografia del Mac", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)", system]

        if let v = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                                            .volumeAvailableCapacityForImportantUsageKey]) {
            lines.append("Disco: \(Bytes.format(v.volumeAvailableCapacityForImportantUsage ?? 0)) liberi su \(Bytes.format(Int64(v.volumeTotalCapacity ?? 0)))")
        }

        progress("Cache e residui…")
        let findings = CleanupCatalog.scan(policy: policy, home: home)
        lines.append("\n## Pulizia possibile (categoria: totale)")
        for (name, items) in Dictionary(grouping: findings, by: { $0.category.name }).sorted(by: { $0.key < $1.key }) {
            lines.append("- \(name): \(Bytes.format(items.reduce(0) { $0 + $1.item.bytes })) in \(items.count) voci")
        }
        let biggest = findings.sorted { $0.item.bytes > $1.item.bytes }.prefix(8)
        lines.append("Voci più pesanti: " + biggest.map { "\($0.info.title) (\(Bytes.format($0.item.bytes)))" }.joined(separator: "; "))

        let scanner = DiskScanner()
        for (label, sub) in [("Download", "Downloads"), ("Scrivania", "Desktop"), ("Filmati", "Movies")] {
            progress("\(label)…")
            let url = URL(fileURLWithPath: home).appendingPathComponent(sub)
            let kids = scanner.children(of: url)
            guard !kids.isEmpty else { continue }
            let total = kids.reduce(0) { $0 + $1.bytes }
            lines.append("\n## \(label): \(Bytes.format(total)) in \(kids.count) elementi")
            lines.append("Più grandi: " + kids.prefix(6).map { "\($0.url.lastPathComponent) (\(Bytes.format($0.bytes)))" }
                .joined(separator: "; "))
        }

        let trash = URL(fileURLWithPath: home).appendingPathComponent(".Trash")
        let trashSize = scanner.size(of: trash)
        if trashSize > 0 { lines.append("\nCestino: \(Bytes.format(trashSize))") }

        progress("Elementi all'avvio…")
        let startup = StartupItems.list(home: home)
        lines.append("\n## Elementi all'avvio (\(startup.count))")
        lines.append(startup.prefix(40).map { "\($0.label) [\($0.scope.rawValue)\($0.disabled ? ", disattivato" : "")]" }
            .joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    static let doctorSystem = """
    Sei il "Medico del Mac" di OmniTools. Ricevi una fotografia del Mac dell'utente (spazio, cache, \
    cartelle pesanti, elementi all'avvio, memoria e processore). Dai al massimo 8 consigli concreti, in \
    italiano semplice, dal più utile al meno utile. Per ognuno: "title" breve, "detail" (2-3 frasi con \
    numeri presi dalla fotografia: cosa hai visto e cosa conviene fare), "priority" (alta/media/bassa) e \
    "action" = la schermata di OmniTools che lo risolve: pulizia (cache, log, residui), spazio (analisi \
    delle cartelle pesanti), riordino (cartelle disordinate come Download), duplicati, foto (doppioni di \
    foto e cloud), whatsapp, sistema (memoria/processore), avvio (elementi all'avvio), sicurezza, nessuna. \
    "summary": 1-2 frasi sullo stato generale. Non inventare dati che non ci sono; se il Mac è in ordine \
    dillo. Prudenza: non suggerire mai di eliminare documenti personali.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["summary", "findings"],
        "properties": [
            "summary": ["type": "string"],
            "findings": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "required": ["title", "detail", "priority", "action"],
                "properties": [
                    "title": ["type": "string"], "detail": ["type": "string"],
                    "priority": ["type": "string", "enum": ["alta", "media", "bassa"]],
                    "action": ["type": "string", "enum": DoctorReport.actions],
                ],
            ]],
        ],
    ]

    public static func diagnose(snapshot: String, client: ClaudeClient) async throws -> (DoctorReport, ClaudeReply) {
        let reply = try await client.send(system: doctorSystem, messages: [ClaudeMessage(role: "user", text: snapshot)],
                                          schema: schema, maxTokens: 8000, effort: "medium")
        return (try ClaudeClient.decode(DoctorReport.self, from: reply), reply)
    }

    /// Chat libera: la fotografia del Mac fa da contesto (in cache tra un messaggio e l'altro).
    public static func chat(snapshot: String, history: [ClaudeMessage], client: ClaudeClient) async throws -> ClaudeReply {
        let system = """
        Sei l'assistente di OmniTools, un'utility per macOS. Rispondi in italiano semplice e conciso alle \
        domande dell'utente sul suo Mac, usando i dati della fotografia qui sotto quando servono. Se un dato \
        non c'è, dillo e suggerisci quale schermata di OmniTools usare (Pulizia disco, Analisi spazio, \
        Riordina cartelle, Duplicati, Foto e cloud, WhatsApp, Stato del sistema, Elementi all'avvio, \
        Controllo sicurezza). OmniTools non cancella mai nulla senza conferma: non dire di aver fatto azioni.

        \(snapshot)
        """
        return try await client.send(system: system, messages: history, maxTokens: 4000, effort: "low")
    }
}
