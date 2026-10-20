#if os(macOS)
import Foundation
import Security

/// Un elemento del controllo di sicurezza.
public struct SecurityFinding: Identifiable, Hashable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case ok = 0, info = 1, warning = 2, suspicious = 3
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .ok: "a posto"
            case .info: "da sapere"
            case .warning: "attenzione"
            case .suspicious: "sospetto"
            }
        }
    }
    public enum Area: String, Sendable { case system = "Protezioni di sistema", startup = "Avvio automatico",
                                         apps = "App", profiles = "Profili", browser = "Estensioni del browser" }

    public let id = UUID()
    public let area: Area
    public let level: Level
    public let title: String
    public let detail: String
    public let path: String?
}

/// Controlla le "porte d'ingresso" che il malware usa più spesso su macOS.
/// Non è un antivirus: non analizza il contenuto dei file.
public enum SecurityAudit {
    public static func run(home: String = NSHomeDirectory(), progress: (String) -> Void = { _ in },
                           isCancelled: () -> Bool = { false }) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        progress("Protezioni di sistema…")
        out += systemProtections()
        progress("Programmi che partono da soli…")
        out += startupItems(home: home)
        if isCancelled() { return out }
        progress("App installate…")
        out += applications(home: home, isCancelled: isCancelled)
        progress("Profili di configurazione…")
        out += profiles()
        progress("Estensioni di Chrome…")
        out += chromeExtensions(home: home)
        return out.sorted { $0.level != $1.level ? $0.level > $1.level : $0.title < $1.title }
    }

    // MARK: - Sistema

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func systemProtections() -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        let sip = shell("/usr/bin/csrutil", ["status"])
        out.append(sip.contains("enabled")
            ? SecurityFinding(area: .system, level: .ok, title: "Protezione dell'integrità di sistema (SIP) attiva", detail: "Impedisce ai programmi di modificare macOS.", path: nil)
            : SecurityFinding(area: .system, level: .suspicious, title: "Protezione dell'integrità di sistema (SIP) disattivata",
                    detail: "Senza SIP un malware può modificare macOS. Va riattivata dalla modalità di recupero (csrutil enable), a meno che tu non l'abbia spenta di proposito.", path: nil))

        let gk = shell("/usr/sbin/spctl", ["--status"])
        out.append(gk.contains("enabled")
            ? SecurityFinding(area: .system, level: .ok, title: "Gatekeeper attivo", detail: "macOS controlla le app scaricate prima di aprirle.", path: nil)
            : SecurityFinding(area: .system, level: .suspicious, title: "Gatekeeper disattivato",
                    detail: "Le app scaricate non vengono controllate. Riattivalo con «sudo spctl --master-enable».", path: nil))

        let fv = shell("/usr/bin/fdesetup", ["status"])
        out.append(fv.contains("On")
            ? SecurityFinding(area: .system, level: .ok, title: "FileVault attivo", detail: "Il disco è cifrato: se perdi il Mac i dati sono protetti.", path: nil)
            : SecurityFinding(area: .system, level: .warning, title: "FileVault non attivo",
                    detail: "Il disco non è cifrato. Attivalo in Impostazioni di Sistema › Privacy e sicurezza › FileVault.", path: nil))

        let fw = shell("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        out.append(fw.lowercased().contains("enabled")
            ? SecurityFinding(area: .system, level: .ok, title: "Firewall attivo", detail: "Blocca le connessioni in entrata non autorizzate.", path: nil)
            : SecurityFinding(area: .system, level: .info, title: "Firewall non attivo",
                    detail: "Su una rete di casa non è grave, ma su reti pubbliche conviene attivarlo (Impostazioni › Rete › Firewall).", path: nil))

        let xp = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: xp), let v = d["CFBundleShortVersionString"] as? String {
            out.append(SecurityFinding(area: .system, level: .ok, title: "XProtect (antimalware di Apple) presente, versione \(v)",
                             detail: "Si aggiorna da solo se gli aggiornamenti di sicurezza automatici sono attivi.", path: nil))
        }
        return out
    }

    // MARK: - Firma del codice

    struct Signature {
        let valid: Bool
        let signed: Bool
        let teamID: String?
        let isApple: Bool
    }

    static func signature(of path: String) -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return Signature(valid: false, signed: false, teamID: nil, isApple: false)
        }
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let dict = info as? [String: Any] ?? [:]
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String ?? ""
        let signed = dict[kSecCodeInfoCertificates as String] != nil || !identifier.isEmpty
        var requirement: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
        let isApple = requirement.map { SecStaticCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
        return Signature(valid: valid, signed: signed, teamID: team, isApple: isApple)
    }

    static func startupItems(home: String) -> [SecurityFinding] {
        StartupItems.list(home: home).compactMap { item -> SecurityFinding? in
            guard let program = item.program else {
                return SecurityFinding(area: .startup, level: .info, title: item.label,
                             detail: "Elemento all'avvio senza programma indicato.", path: item.plist.path)
            }
            let suspiciousPlace = ["/tmp/", "/private/tmp/", "/Users/Shared/", "/.", "/var/folders/"]
                .contains { program.contains($0) }
            let script = ["sh", "bash", "zsh", "python", "python3", "osascript", "curl", "perl", "ruby"]
                .contains((program as NSString).lastPathComponent)
            guard FileManager.default.fileExists(atPath: program) else {
                return SecurityFinding(area: .startup, level: .warning, title: item.label,
                             detail: "Punta a un programma che non esiste più (\(program)): probabilmente è il residuo di un'app disinstallata. Si può rimuovere.",
                             path: item.plist.path)
            }
            let sig = signature(of: program)
            if suspiciousPlace || (!sig.signed && !script) {
                return SecurityFinding(area: .startup, level: .suspicious, title: item.label,
                             detail: (suspiciousPlace ? "Il programma sta in una cartella insolita (\(program)). " : "")
                                + (sig.signed ? "" : "Il programma non è firmato da nessuno sviluppatore. ")
                                + "Se non lo riconosci, chiedi all'AI cos'è prima di toccarlo.",
                             path: item.plist.path)
            }
            if script {
                return SecurityFinding(area: .startup, level: .warning, title: item.label,
                             detail: "Avvia uno script (\((program as NSString).lastPathComponent)): è normale per alcuni strumenti di sviluppo, ma è anche un trucco usato dai malware. Controlla di riconoscerlo.",
                             path: item.plist.path)
            }
            if !sig.valid {
                return SecurityFinding(area: .startup, level: .warning, title: item.label,
                             detail: "La firma del programma non è valida: potrebbe essere stato modificato dopo l'installazione.", path: item.plist.path)
            }
            return SecurityFinding(area: .startup, level: .ok, title: item.label,
                         detail: sig.isApple ? "Firmato da Apple." : "Firmato dallo sviluppatore \(sig.teamID ?? "—").",
                         path: item.plist.path)
        }
    }

    // MARK: - App

    static func applications(home: String, isCancelled: () -> Bool) -> [SecurityFinding] {
        let dirs = ["/Applications", home + "/Applications"]
        var out: [SecurityFinding] = []
        var notarizedCount = 0
        for dir in dirs {
            let apps = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".app") }
            for name in apps {
                if isCancelled() { return out }
                let path = dir + "/" + name
                let sig = signature(of: path)
                if !sig.signed {
                    out.append(SecurityFinding(area: .apps, level: .warning, title: name,
                                     detail: "App non firmata: non si sa chi l'ha creata. Se non l'hai scaricata tu da una fonte affidabile, valuta di rimuoverla.",
                                     path: path))
                } else if !sig.valid {
                    out.append(SecurityFinding(area: .apps, level: .warning, title: name,
                                     detail: "La firma non è valida: l'app è stata modificata dopo essere stata firmata (succede anche con alcuni aggiornamenti). Reinstallala dalla fonte ufficiale.",
                                     path: path))
                } else {
                    let assess = shell("/usr/sbin/spctl", ["--assess", "--type", "execute", path])
                    if assess.contains("rejected") {
                        out.append(SecurityFinding(area: .apps, level: .info, title: name,
                                         detail: "Firmata ma non autenticata da Apple: Gatekeeper non la aprirebbe se la scaricassi oggi. Comune per app vecchie o installate con strumenti di sviluppo.",
                                         path: path))
                    } else {
                        notarizedCount += 1
                    }
                }
            }
        }
        out.append(SecurityFinding(area: .apps, level: .ok, title: "\(notarizedCount) app firmate e autenticate da Apple",
                         detail: "Superano i controlli di Gatekeeper.", path: nil))
        return out
    }

    // MARK: - Profili e browser

    static func profiles() -> [SecurityFinding] {
        let out = shell("/usr/bin/profiles", ["list"])
        let names = out.split(separator: "\n").filter { $0.contains("profileIdentifier") }
        if names.isEmpty {
            return [SecurityFinding(area: .profiles, level: .ok, title: "Nessun profilo di configurazione",
                          detail: "I profili possono cambiare impostazioni di rete o del browser: qui non ce ne sono.", path: nil)]
        }
        return names.map { line -> SecurityFinding in
            SecurityFinding(area: .profiles, level: .warning, title: "Profilo: " + (line.components(separatedBy: ":").last ?? "").trimmingCharacters(in: .whitespaces),
                  detail: "Se non è dell'azienda o della scuola, potrebbe essere stato installato da un adware (cambia motore di ricerca, proxy…). Controlla in Impostazioni › Generali › Gestione dispositivi.",
                  path: nil)
        }
    }

    static func chromeExtensions(home: String) -> [SecurityFinding] {
        let root = home + "/Library/Application Support/Google/Chrome/Default/Extensions"
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return ids.compactMap { id -> SecurityFinding? in
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + id)) ?? []
            guard let v = versions.sorted().last,
                  let data = FileManager.default.contents(atPath: "\(root)/\(id)/\(v)/manifest.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let name = json["name"] as? String ?? id
            if name.hasPrefix("__MSG_") { return nil }   // componenti interni di Chrome
            let perms = (json["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
                + (json["host_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
            let broad = perms.contains { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0 == "webRequest" }
            return SecurityFinding(area: .browser, level: broad ? .info : .ok, title: "Chrome: \(name)",
                         detail: broad ? "Può leggere e modificare le pagine di tutti i siti. Normale per blocchi pubblicità e gestori di password; se non la riconosci, rimuovila da Chrome › Estensioni."
                                       : "Permessi limitati.",
                         path: "\(root)/\(id)")
        }
    }
}
#endif
