import Foundation

/// Quello che l'AI vede di un file: solo metadati, mai il contenuto.
public struct FileFacts: Codable, Sendable {
    public let id: Int
    public let name: String
    public let kind: String
    public let sizeBytes: Int64
    public let created: String?
    public let lastOpened: String?
    /// Indizi già trovati dall'analisi locale (es. "copia identica di X", "file vuoto").
    public let hint: String?
}

/// Una proposta dell'AI, già verificata contro le regole.
public struct AIProposal: Identifiable, Hashable, Sendable {
    public enum Action: String, Sendable { case trash, move, keep }
    public let item: DiskItem
    public let action: Action
    public let folder: String
    public let reason: String
    /// "alta" | "media" | "bassa"
    public let confidence: String
    public var id: URL { item.url }
}

public struct AIAdvice: Sendable {
    public let folder: URL
    public var proposals: [AIProposal]
    public var summary: String
    public var skippedFiles: Int
    public var inputTokens = 0
    public var outputTokens = 0
    public var costUSD: Double = 0
}

public enum AIModel: String, CaseIterable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var label: String {
        switch self {
        case .opus: "Claude Opus 5.5 (più accurato)"
        case .sonnet: "Claude Sonnet 5.5 (equilibrato)"
        case .haiku: "Claude Haiku 5.5 (economico)"
        }
    }

    /// Prezzo in dollari per milione di token (ingresso, uscita).
    var price: (input: Double, output: Double) {
        switch self {
        case .opus: (4, 20)
        case .sonnet: (2, 10)
        case .haiku: (0.10, 0.50)
        }
    }

    /// Il ripiego automatico lato server in caso di rifiuto esiste per Opus e Sonnet.
    var supportsFallback: Bool { self != .haiku }
}

public enum AIAdvisorError: LocalizedError {
    case missingKey
    case http(Int, String)
    case refusal
    case truncated
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Manca la chiave API di Anthropic: inseriscila nelle impostazioni dell'assistente."
        case .http(401, _): "Chiave API non valida."
        case .http(429, _): "Troppe richieste ravvicinate: riprova tra un minuto."
        case .http(529, _): "Il servizio è sovraccarico in questo momento: riprova tra poco."
        case .http(let code, let body): "Errore \(code) dal servizio: \(body.prefix(200))"
        case .refusal: "Il modello ha rifiutato la richiesta."
        case .truncated: "La risposta è stata troncata: riprova con meno file."
        case .badResponse(let s): "Risposta non leggibile: \(s)"
        }
    }
}

/// Chiede a Claude cosa fare dei file sfusi di una cartella. Non esegue niente:
/// restituisce proposte che l'utente approva una per una.
public struct AIAdvisor: Sendable {
    public var model: AIModel
    public var apiKey: String
    /// Indicazioni personali, es. "non toccare nulla che riguardi OmniNeo".
    public var instructions: String
    public var maxFiles = 400
    public var batchSize = 120

    public init(model: AIModel = .opus, apiKey: String, instructions: String = "") {
        self.model = model
        self.apiKey = apiKey
        self.instructions = instructions
    }

    // MARK: - Dati inviati

    /// I file che verrebbero descritti all'AI (già filtrati dalle regole di sicurezza).
    public func facts(for folder: URL, policy: SafetyPolicy) -> (items: [DiskItem], facts: [FileFacts]) {
        let organizer = FolderOrganizer()
        let items = Array(organizer.looseFiles(in: folder, policy: policy).prefix(maxFiles))
        let hints = Dictionary(organizer.uselessFiles(items, folder: folder, now: Date())
            .map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let facts = items.enumerated().map { (i, item) -> FileFacts in
            let opened = try? item.url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
            return FileFacts(id: i, name: item.url.lastPathComponent, kind: FileKind.of(item.url).rawValue,
                             sizeBytes: item.bytes, created: item.modified.map(day.string(from:)),
                             lastOpened: opened.map(day.string(from:)), hint: hints[item.url])
        }
        return (items, facts)
    }

    /// Il testo esatto che verrà inviato, per mostrarlo all'utente.
    public func preview(for folder: URL, policy: SafetyPolicy) -> String {
        let (_, facts) = facts(for: folder, policy: policy)
        return Self.userMessage(folderName: folder.lastPathComponent, facts: facts, instructions: instructions)
    }

    // MARK: - Richiesta

    public func advise(folder: URL, policy: SafetyPolicy,
                       progress: @Sendable (String) -> Void = { _ in }) async throws -> AIAdvice {
        guard !apiKey.isEmpty else { throw AIAdvisorError.missingKey }
        let (items, allFacts) = facts(for: folder, policy: policy)
        let total = FolderOrganizer().looseFiles(in: folder, policy: policy).count
        var advice = AIAdvice(folder: folder, proposals: [], summary: "", skippedFiles: max(0, total - items.count))

        var summaries: [String] = []
        let batches = stride(from: 0, to: allFacts.count, by: batchSize).map {
            Array(allFacts[$0..<min($0 + batchSize, allFacts.count)])
        }
        for (n, batch) in batches.enumerated() {
            progress("Analisi \(n + 1) di \(batches.count)…")
            let reply = try await send(folderName: folder.lastPathComponent, facts: batch)
            advice.inputTokens += reply.inputTokens
            advice.outputTokens += reply.outputTokens
            summaries.append(reply.summary)

            var seen = Set<Int>()
            for p in reply.proposals {
                // Solo id realmente inviati, una volta sola, e mai file protetti.
                guard batch.contains(where: { $0.id == p.id }), seen.insert(p.id).inserted,
                      items.indices.contains(p.id), !policy.isProtected(items[p.id].url),
                      let action = AIProposal.Action(rawValue: p.action) else { continue }
                let folderName = FolderOrganizer.sanitize(p.folder)
                if action == .move && p.folder.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                advice.proposals.append(AIProposal(item: items[p.id], action: action,
                                                   folder: action == .move ? folderName : "",
                                                   reason: p.reason, confidence: p.confidence))
            }
        }
        advice.summary = summaries.filter { !$0.isEmpty }.joined(separator: "\n")
        advice.costUSD = Double(advice.inputTokens) / 1e6 * model.price.input
            + Double(advice.outputTokens) / 1e6 * model.price.output
        return advice
    }

    struct RawProposal: Decodable {
        let id: Int
        let action: String
        let folder: String
        let reason: String
        let confidence: String
    }

    struct Reply {
        let summary: String
        let proposals: [RawProposal]
        let inputTokens: Int
        let outputTokens: Int
    }

    static let systemPrompt = """
    Sei l'assistente di OmniTools, un'utility per macOS. Ti viene data la descrizione dei file \
    sfusi di UNA cartella (solo metadati: nome, tipo, dimensione, date; mai il contenuto). \
    Proponi per ogni file una di tre azioni:
    - "move": spostarlo in una sottocartella. Raggruppa per affinità di argomento prima che per tipo \
    (es. "preventivo idraulico" e "offerta caldaia" vanno insieme in "Casa"). Nomi di cartella brevi, \
    in italiano, con l'iniziale maiuscola; riusa gli stessi nomi per file affini. Evita cartelle \
    con un solo file, salvo che il file sia chiaramente a sé.
    - "trash": mandarlo nel Cestino. Solo per file chiaramente inutili: copie identiche, file vuoti, \
    download incompleti, installer già usati, archivi già estratti, file temporanei. Nel dubbio \
    scegli "keep" o "move", mai "trash". Non proporre mai "trash" per documenti personali, \
    di identità, sanitari, legali, fiscali o di lavoro, né per foto e video personali.
    - "keep": lasciarlo dov'è.
    L'utente approverà ogni proposta una per una: spiega ogni scelta in una frase breve in italiano \
    ("reason"). "confidence" è "alta", "media" o "bassa". "folder" è vuoto se l'azione non è "move". \
    "summary" riassume in una o due frasi cosa c'è nella cartella e cosa proponi. \
    Rispetta le indicazioni personali dell'utente, se presenti.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "proposals"],
        "properties": [
            "summary": ["type": "string"],
            "proposals": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "action", "folder", "reason", "confidence"],
                    "properties": [
                        "id": ["type": "integer"],
                        "action": ["type": "string", "enum": ["move", "trash", "keep"]],
                        "folder": ["type": "string"],
                        "reason": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["alta", "media", "bassa"]],
                    ],
                ],
            ],
        ],
    ]

    static func userMessage(folderName: String, facts: [FileFacts], instructions: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let lines = facts.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
        let personal = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Cartella: "\(folderName)"
        Data di oggi: \(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate]))
        \(personal.isEmpty ? "" : "Indicazioni personali dell'utente: \(personal)\n")
        File (uno per riga, JSON):
        \(lines.joined(separator: "\n"))
        """
    }

    func send(folderName: String, facts: [FileFacts]) async throws -> Reply {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 32000,
            "system": Self.systemPrompt,
            "messages": [["role": "user",
                          "content": Self.userMessage(folderName: folderName, facts: facts,
                                                      instructions: instructions)]],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": Self.schema],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.supportsFallback {
            // In caso di rifiuto il server riprova da solo su un modello alternativo.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AIAdvisorError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Reply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAdvisorError.badResponse("non è JSON")
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw AIAdvisorError.refusal
        case "max_tokens": throw AIAdvisorError.truncated
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        // La risposta strutturata è nell'ultimo blocco di testo (i blocchi "thinking" si ignorano).
        guard let text = blocks.last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let payload = text.data(using: .utf8) else {
            throw AIAdvisorError.badResponse("nessun testo")
        }
        struct Payload: Decodable { let summary: String; let proposals: [RawProposal] }
        let decoded: Payload
        do { decoded = try JSONDecoder().decode(Payload.self, from: payload) } catch {
            throw AIAdvisorError.badResponse(error.localizedDescription)
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return Reply(summary: decoded.summary, proposals: decoded.proposals,
                     inputTokens: usage["input_tokens"] as? Int ?? 0,
                     outputTokens: usage["output_tokens"] as? Int ?? 0)
    }
}

extension AIAdvice {
    /// Trasforma le proposte approvate in un piano di riordino (così vale anche «Annulla»).
    public func plan(approved: Set<URL>) -> (plan: OrganizePlan, removals: [DiskItem]) {
        let chosen = proposals.filter { approved.contains($0.id) }
        let groups = Dictionary(grouping: chosen.filter { $0.action == .move }, by: \.folder)
            .map { OrganizeGroup(name: $0.key, files: $0.value.map(\.item), reason: "proposta dell'assistente") }
        return (OrganizePlan(folder: folder, groups: groups, removals: []),
                chosen.filter { $0.action == .trash }.map(\.item))
    }
}
