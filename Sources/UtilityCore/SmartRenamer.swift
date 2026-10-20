import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Una proposta di nuovo nome.
public struct RenameProposal: Identifiable, Hashable, Sendable {
    public let item: DiskItem
    /// Nome nuovo senza estensione (modificabile dall'utente).
    public var newBase: String
    public let reason: String
    public var id: URL { item.url }
    public var newName: String {
        let ext = item.url.pathExtension
        return ext.isEmpty ? newBase : newBase + "." + ext
    }
}

/// Rinomina i file dal nome generico (IMG_4021, Documento (3), Senza titolo…) con l'aiuto di Claude.
public enum SmartRenamer {
    static let genericPatterns = [
        #"^(img|dsc|dscn|dscf|pxl|mvimg|vid|mov|gopr|dji)[_\- ]?\d+"#,
        #"^(screenshot|schermata|istantanea|screen shot|registrazione schermo|screen recording)"#,
        #"^(whatsapp (image|video|audio)|telegram)"#,
        #"^(senza titolo|untitled|nuovo documento|new document|documento|document|scansione|scan|file|download|image|immagine|foto|photo)( ?\(?\d+\)?)?$"#,
        #"^copia di "#,
        #"^[0-9_\- ]{6,}$"#,                                  // solo numeri/date
        #"^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$"#,   // UUID
        #"^[0-9a-z]{20,}$"#,                                  // codici lunghi
    ]

    /// Un nome "generico" che non dice niente del contenuto.
    public static func isGeneric(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        return genericPatterns.contains { base.range(of: $0, options: .regularExpression) != nil }
    }

    public static func candidates(in folder: URL, policy: SafetyPolicy, onlyGeneric: Bool = true) -> [DiskItem] {
        FolderOrganizer().looseFiles(in: folder, policy: policy).filter { !onlyGeneric || isGeneric($0.url) }
    }

    /// Le prime righe di testo di PDF e file di testo (solo se l'utente lo permette).
    public static func snippet(_ url: URL, limit: Int = 400) -> String? {
        let ext = url.pathExtension.lowercased()
        var text: String?
        if ["txt", "md", "csv", "rtf", "html"].contains(ext) {
            text = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(limit * 2)) }
        }
        #if canImport(PDFKit)
        if ext == "pdf", let doc = PDFDocument(url: url) {
            let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let first = doc.page(at: 0)?.string ?? ""
            text = [title, first].compactMap { $0 }.joined(separator: " — ")
        }
        #endif
        guard let t = text?.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return String(t.prefix(limit))
    }

    static let system = """
    Sei l'assistente di OmniTools. Proponi nomi di file chiari in italiano per file con nomi generici. \
    Formato: "AAAA-MM-GG Descrizione breve" (la data è quella fornita), massimo 60 caratteri, senza \
    estensione, senza caratteri / : \\ * ? " < > |. Per foto e video senza estratto usa la data e, se il nome \
    originale lo suggerisce, il tipo (es. "2024-07-14 Screenshot", "2024-07-14 Foto WhatsApp"). Per i \
    documenti usa l'estratto, se c'è, per capire di cosa si tratta (es. "2024-03-02 Fattura Enel"). Non \
    inventare dettagli che non si deducono. Se non c'è niente di meglio del nome attuale, restituisci \
    "keep": true. "reason": una frase breve in italiano.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["files"],
        "properties": ["files": ["type": "array", "items": [
            "type": "object", "additionalProperties": false,
            "required": ["id", "name", "keep", "reason"],
            "properties": ["id": ["type": "integer"], "name": ["type": "string"],
                           "keep": ["type": "boolean"], "reason": ["type": "string"]],
        ]]],
    ]

    struct Raw: Decodable {
        struct File: Decodable { let id: Int; let name: String; let keep: Bool; let reason: String }
        let files: [File]
    }

    /// - Parameter readContent: se true invia anche le prime righe di PDF e file di testo.
    public static func propose(_ items: [DiskItem], readContent: Bool, client: ClaudeClient) async throws
        -> (proposals: [RenameProposal], cost: Double) {
        var proposals: [RenameProposal] = []
        var cost = 0.0
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for start in stride(from: 0, to: items.count, by: 80) {
            let batch = Array(items[start..<min(start + 80, items.count)])
            let lines = batch.enumerated().map { i, item -> String in
                var fields: [String: Any] = ["id": i, "nome": item.url.lastPathComponent,
                                             "tipo": FileKind.of(item.url).rawValue,
                                             "data": item.modified.map(day.string(from:)) ?? "sconosciuta"]
                if readContent, let s = snippet(item.url) { fields["estratto"] = s }
                let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
                return String(decoding: data, as: UTF8.self)
            }
            let reply = try await client.send(system: system,
                                              messages: [ClaudeMessage(role: "user", text: lines.joined(separator: "\n"))],
                                              schema: schema, maxTokens: 12000, effort: "low")
            cost += reply.costUSD
            let raw = try ClaudeClient.decode(Raw.self, from: reply)
            for f in raw.files where !f.keep && batch.indices.contains(f.id) {
                let clean = sanitize(f.name)
                guard !clean.isEmpty, clean != batch[f.id].url.deletingPathExtension().lastPathComponent else { continue }
                proposals.append(RenameProposal(item: batch[f.id], newBase: clean, reason: f.reason))
            }
        }
        return (proposals, cost)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(cleaned.prefix(80))
    }

    /// Rinomina e registra tutto in Cronologia (si annulla con «Ripristina»).
    public static func apply(_ proposals: [RenameProposal], folder: URL, policy: SafetyPolicy,
                             recordsFolder: URL = OperationLog.folder) -> OrganizeResult {
        var result = OrganizeResult()
        var moves: [OperationRecord.Move] = []
        for p in proposals where !policy.isProtected(p.item.url) {
            let base = sanitize(p.newBase)
            guard !base.isEmpty else { continue }
            let ext = p.item.url.pathExtension
            let dir = p.item.url.deletingLastPathComponent()
            let dest = FolderOrganizer.uniqueDestination(for: ext.isEmpty ? base : base + "." + ext, in: dir)
            do {
                try FileManager.default.moveItem(at: p.item.url, to: dest)
                moves.append(.init(from: p.item.url.path, to: dest.path))
                result.moved += 1
            } catch {
                result.errors.append("\(p.item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let record = OperationRecord(kind: "Rinomina", summary: "\(folder.lastPathComponent): \(result.moved) file rinominati",
                                     moves: moves)
        OperationLog.save(record, in: recordsFolder)
        if !moves.isEmpty { result.operationID = record.id }
        Journal.append(lines: moves.map { "RINOMINATO\t\($0.from)\t→ \(($0.to as NSString).lastPathComponent)" })
        return result
    }
}
