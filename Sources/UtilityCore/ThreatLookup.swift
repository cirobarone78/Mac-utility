import Foundation
import CryptoKit

/// «Seconda opinione» di VirusTotal su un file: si invia solo l'impronta (SHA-256), mai il file.
public struct VirusTotalReport: Sendable, Hashable {
    public let sha256: String
    /// false: VirusTotal non ha mai visto questo file.
    public let known: Bool
    public var malicious = 0
    public var suspicious = 0
    public var harmless = 0
    public var undetected = 0
    public var name: String?
    public var threatLabel: String?
    public var lastAnalysis: Date?

    public var engines: Int { malicious + suspicious + harmless + undetected }
    public var link: URL { URL(string: "https://www.virustotal.com/gui/file/\(sha256)")! }

    public enum Verdict: Sendable { case clean, suspicious, malicious, unknown }
    public var verdict: Verdict {
        guard known else { return .unknown }
        if malicious >= 3 { return .malicious }
        if malicious > 0 || suspicious > 0 { return .suspicious }
        return .clean
    }
}

public enum VirusTotalError: LocalizedError {
    case missingKey, badKey, quota, http(Int), unreadable

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Manca la chiave di VirusTotal."
        case .badKey: "VirusTotal non accetta la chiave: controlla di averla copiata per intero."
        case .quota: "Limite di VirusTotal raggiunto (4 controlli al minuto, 500 al giorno con la chiave gratuita). Riprova tra poco."
        case .http(let c): "VirusTotal ha risposto con l'errore \(c)."
        case .unreadable: "Il file non si può leggere."
        }
    }
}

public struct VirusTotalClient: Sendable {
    public let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    /// Impronta SHA-256 del file intero, letta a blocchi (anche file di gigabyte).
    public static func sha256(of url: URL) throws -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw VirusTotalError.unreadable }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func lookup(sha256: String) async throws -> VirusTotalReport {
        guard !apiKey.isEmpty else { throw VirusTotalError.missingKey }
        var request = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/files/\(sha256)")!,
                                 timeoutInterval: 30)
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 404: return VirusTotalReport(sha256: sha256, known: false)
        case 401, 403: throw VirusTotalError.badKey
        case 429: throw VirusTotalError.quota
        default: throw VirusTotalError.http(code)
        }
        return Self.parse(data, sha256: sha256)
    }

    static func parse(_ data: Data, sha256: String) -> VirusTotalReport {
        var r = VirusTotalReport(sha256: sha256, known: true)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attrs = (json["data"] as? [String: Any])?["attributes"] as? [String: Any] else { return r }
        let stats = attrs["last_analysis_stats"] as? [String: Any] ?? [:]
        r.malicious = stats["malicious"] as? Int ?? 0
        r.suspicious = stats["suspicious"] as? Int ?? 0
        r.harmless = stats["harmless"] as? Int ?? 0
        r.undetected = stats["undetected"] as? Int ?? 0
        r.name = attrs["meaningful_name"] as? String
        r.threatLabel = (attrs["popular_threat_classification"] as? [String: Any])?["suggested_threat_label"] as? String
        if let t = attrs["last_analysis_date"] as? Double { r.lastAnalysis = Date(timeIntervalSince1970: t) }
        else if let t = attrs["last_analysis_date"] as? Int { r.lastAnalysis = Date(timeIntervalSince1970: TimeInterval(t)) }
        return r
    }
}

// MARK: - Have I Been Pwned

/// Un furto di dati in cui compare l'indirizzo email.
public struct Breach: Identifiable, Hashable, Sendable {
    public let name: String
    public let title: String
    public let domain: String
    public let date: String
    public let accounts: Int
    /// Che cosa è stato rubato ("Email addresses", "Passwords"…), tradotto quando possibile.
    public let data: [String]
    public let description: String
    public var id: String { name }
    public var includesPasswords: Bool { data.contains { $0.localizedCaseInsensitiveContains("password") } }
}

public enum BreachError: LocalizedError {
    case missingKey, badKey, quota, http(Int)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Per cercare un indirizzo email serve una chiave di Have I Been Pwned (circa 4 $ al mese)."
        case .badKey: "Have I Been Pwned non accetta la chiave."
        case .quota: "Troppe richieste ravvicinate: riprova tra qualche secondo."
        case .http(let c): "Have I Been Pwned ha risposto con l'errore \(c)."
        }
    }
}

public enum BreachCheck {
    static let userAgent = "OmniTools-Mac"

    /// Quante volte la password compare nei furti di dati noti. Gratuito e anonimo: si inviano
    /// solo i primi 5 caratteri dell'impronta SHA-1, la password non lascia mai il Mac.
    public static func passwordCount(_ password: String) async throws -> Int {
        let hash = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        let prefix = String(hash.prefix(5)), suffix = String(hash.dropFirst(5))
        var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BreachError.http(code) }
        return count(in: String(decoding: data, as: UTF8.self), suffix: suffix)
    }

    static func count(in body: String, suffix: String) -> Int {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].uppercased() == suffix { return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return 0
    }

    /// I furti di dati in cui compare l'indirizzo (serve la chiave a pagamento di haveibeenpwned.com).
    public static func breaches(email: String, apiKey: String) async throws -> [Breach] {
        guard !apiKey.isEmpty else { throw BreachError.missingKey }
        let account = email.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email
        var request = URLRequest(url: URL(string: "https://haveibeenpwned.com/api/v3/breachedaccount/\(account)?truncateResponse=false")!)
        request.setValue(apiKey, forHTTPHeaderField: "hibp-api-key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 404: return []
        case 401: throw BreachError.badKey
        case 429: throw BreachError.quota
        default: throw BreachError.http(code)
        }
        let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return list.map { b in
            Breach(name: b["Name"] as? String ?? "?",
                   title: b["Title"] as? String ?? b["Name"] as? String ?? "?",
                   domain: b["Domain"] as? String ?? "",
                   date: b["BreachDate"] as? String ?? "",
                   accounts: b["PwnCount"] as? Int ?? 0,
                   data: ((b["DataClasses"] as? [String]) ?? []).map(translate),
                   description: stripHTML(b["Description"] as? String ?? ""))
        }.sorted { $0.date > $1.date }
    }

    static let translations: [String: String] = [
        "Email addresses": "Indirizzi email", "Passwords": "Password", "Usernames": "Nomi utente",
        "Names": "Nomi", "Phone numbers": "Numeri di telefono", "Physical addresses": "Indirizzi di casa",
        "Dates of birth": "Date di nascita", "IP addresses": "Indirizzi IP", "Genders": "Sesso",
        "Geographic locations": "Posizioni", "Credit cards": "Carte di credito",
        "Security questions and answers": "Domande e risposte di sicurezza", "Partial credit card data": "Dati parziali di carte",
        "Job titles": "Professioni", "Employers": "Datori di lavoro", "Social media profiles": "Profili social",
        "Password hints": "Suggerimenti password", "Bank account numbers": "Conti bancari",
    ]

    static func translate(_ s: String) -> String { translations[s] ?? s }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
