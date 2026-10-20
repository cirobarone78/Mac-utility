import Foundation

/// Un messaggio della conversazione con Claude.
public struct ClaudeMessage: Codable, Hashable, Sendable {
    public let role: String      // "user" | "assistant"
    public let text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

public struct ClaudeReply: Sendable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
}

/// Client minimo per l'API Messages di Anthropic, condiviso da tutte le funzioni AI di OmniTools.
public struct ClaudeClient: Sendable {
    public let model: AIModel
    public let apiKey: String

    public init(model: AIModel, apiKey: String) {
        self.model = model
        self.apiKey = apiKey
    }

    /// - Parameters:
    ///   - schema: se presente, la risposta è JSON conforme allo schema (structured outputs).
    ///   - effort: "low" per risposte brevi, "medium" per analisi.
    public func send(system: String, messages: [ClaudeMessage], schema: [String: Any]? = nil,
                     maxTokens: Int = 16000, effort: String = "medium") async throws -> ClaudeReply {
        guard !apiKey.isEmpty else { throw AIAdvisorError.missingKey }
        var output: [String: Any] = ["effort": effort]
        if let schema { output["format"] = ["type": "json_schema", "schema": schema] }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            // Il testo di sistema (spesso lungo e uguale tra un messaggio e l'altro) viene messo in cache.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages.map { ["role": $0.role, "content": $0.text] },
            "output_config": output,
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.supportsFallback {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AIAdvisorError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try parse(data)
    }

    func parse(_ data: Data) throws -> ClaudeReply {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIAdvisorError.badResponse("non è JSON")
        }
        switch json["stop_reason"] as? String {
        case "refusal": throw AIAdvisorError.refusal
        case "max_tokens": throw AIAdvisorError.truncated
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AIAdvisorError.badResponse("nessun testo") }
        let usage = json["usage"] as? [String: Any] ?? [:]
        let inTok = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
            + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        let outTok = usage["output_tokens"] as? Int ?? 0
        let cost = Double(inTok) / 1e6 * model.price.input + Double(outTok) / 1e6 * model.price.output
        return ClaudeReply(text: text, inputTokens: inTok, outputTokens: outTok, costUSD: cost)
    }

    /// Decodifica una risposta JSON (structured outputs) nel tipo richiesto.
    public static func decode<T: Decodable>(_ type: T.Type, from reply: ClaudeReply) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(reply.text.utf8)) } catch {
            throw AIAdvisorError.badResponse(error.localizedDescription)
        }
    }
}

// MARK: - «Spiegami questo»

public enum AIExplain {
    static let system = """
    Sei l'assistente di OmniTools, un'utility per macOS. L'utente ti chiede cos'è un elemento del suo Mac \
    (una cartella di cache, un file, un processo, un programma che parte all'avvio, un'app). Rispondi in \
    italiano semplice, in 3-6 frasi: che cos'è, quale app o servizio lo usa, se si può eliminare o \
    disattivare e con quali conseguenze, e se c'è qualcosa di sospetto. Se non lo riconosci con certezza \
    dillo chiaramente e spiega come verificarlo. Non inventare. Niente elenchi lunghi, niente codice.
    """

    public static func explain(_ subject: String, context: String, client: ClaudeClient) async throws -> ClaudeReply {
        try await client.send(system: system,
                              messages: [ClaudeMessage(role: "user", text: "Elemento: \(subject)\nContesto: \(context)")],
                              maxTokens: 2000, effort: "low")
    }
}
