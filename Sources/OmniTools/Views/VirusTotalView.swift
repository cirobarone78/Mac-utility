import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UtilityCore

@MainActor
final class VirusTotalModel: ObservableObject {
    struct Check: Identifiable {
        let id = UUID()
        let url: URL
        var report: VirusTotalReport?
        var error: String?
        var pending = true
    }

    @Published var hasKey = Keychain.readKey(Keychain.virusTotal)?.isEmpty == false
    @Published var checks: [Check] = []
    @Published var busy = false
    @Published var status = ""
    private var worker: Task<Void, Never>?

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        hasKey = Keychain.saveKey(k, account: Keychain.virusTotal)
    }

    func forgetKey() {
        Keychain.deleteKey(Keychain.virusTotal)
        hasKey = false
    }

    func add(_ urls: [URL]) {
        let fresh = urls.filter { u in !checks.contains { $0.url == u } }
        checks.insert(contentsOf: fresh.map { Check(url: $0) }, at: 0)
        process()
    }

    /// I programmi che partono da soli (esclusi quelli di Apple) e gli installatori scaricati di recente.
    func addSuspects() {
        var urls: [URL] = []
        for item in StartupItems.list() {
            guard let p = item.program, p.hasPrefix("/"), !p.hasPrefix("/System/"), !p.hasPrefix("/usr/"),
                  !p.hasPrefix("/bin/"), !p.hasPrefix("/sbin/"), FileManager.default.fileExists(atPath: p) else { continue }
            urls.append(URL(fileURLWithPath: p))
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let installers: Set<String> = ["dmg", "pkg", "app", "zip"]
        for u in (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard installers.contains(u.pathExtension.lowercased()),
                  let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  d > cutoff else { continue }
            urls.append(u)
        }
        add(urls)
        if urls.isEmpty { status = "Nessun programma da controllare." }
    }

    /// Una richiesta ogni 16 secondi: la chiave gratuita ne permette 4 al minuto.
    func process() {
        guard worker == nil else { return }
        busy = true
        let key = Keychain.readKey(Keychain.virusTotal) ?? ""
        worker = Task {
            var first = true
            while let index = checks.firstIndex(where: { $0.pending }) {
                if !first {
                    status = "Attendo qualche secondo (limite di VirusTotal)…"
                    try? await Task.sleep(for: .seconds(16))
                    if Task.isCancelled { break }
                }
                first = false
                let target = checks[index].url
                status = "Controllo \(target.lastPathComponent)…"
                let result = await Self.lookup(target, key: key)
                guard let i = checks.firstIndex(where: { $0.url == target }) else { continue }
                switch result {
                case .success(let r): checks[i].report = r
                case .failure(let e): checks[i].error = e.localizedDescription
                }
                checks[i].pending = false
                if case .failure(let e) = result, let ve = e as? VirusTotalError, Self.stops(ve) {
                    // Chiave sbagliata o limite raggiunto: inutile continuare.
                    for j in checks.indices where checks[j].pending {
                        checks[j].pending = false
                        checks[j].error = "Non controllato."
                    }
                }
            }
            status = ""
            busy = false
            worker = nil
        }
    }

    nonisolated static func stops(_ e: VirusTotalError) -> Bool {
        switch e {
        case .badKey, .missingKey, .quota: true
        default: false
        }
    }

    /// Per un'app si controlla il programma principale dentro il pacchetto.
    nonisolated static func target(_ url: URL) -> URL {
        guard url.pathExtension == "app",
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String else { return url }
        return url.appendingPathComponent("Contents/MacOS/" + exe)
    }

    nonisolated static func lookup(_ url: URL, key: String) async -> Result<VirusTotalReport, Error> {
        do {
            let hash = try VirusTotalClient.sha256(of: target(url))
            return .success(try await VirusTotalClient(apiKey: key).lookup(sha256: hash))
        } catch {
            return .failure(error)
        }
    }

    func clear() {
        worker?.cancel()
        worker = nil
        busy = false
        checks = []
        status = ""
    }
}

struct VirusTotalView: View {
    @StateObject private var model = VirusTotalModel()
    @State private var keyField = ""
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .virustotal,
                         subtitle: "Un file ti sembra strano? VirusTotal lo confronta con circa 70 antivirus.")
            if !model.hasKey {
                keySetup
            } else {
                HStack {
                    Button("Scegli file o app…") { model.add(Finder.chooseFiles()) }.buttonStyle(.borderedProminent)
                    Button("Controlla i programmi all'avvio e gli installatori scaricati") { model.addSuspects() }
                    Spacer()
                    if !model.checks.isEmpty { Button("Svuota l'elenco") { model.clear() } }
                    Menu("Chiave") {
                        Button("Dimentica la chiave", role: .destructive) { model.forgetKey() }
                    }
                    .frame(width: 80)
                }
                .padding(.horizontal, 20).padding(.bottom, 6)
                Text("Si invia solo l'impronta del file (SHA-256), mai il file: niente lascia il Mac. Puoi anche trascinare qui i file.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 6)
                if !model.status.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text(model.status).font(.callout) }
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }
                if model.checks.isEmpty {
                    ContentUnavailableView("Trascina qui un file o un'app", systemImage: "arrow.down.doc",
                                           description: Text("Oppure usa i pulsanti qui sopra."))
                } else {
                    List(model.checks) { c in row(c) }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add([url]) } }
                }
            }
            return true
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Serve una chiave gratuita di VirusTotal").font(.headline)
            Text("1. Crea un account su virustotal.com (gratis).\n2. Apri il tuo profilo › «API key» e copia la chiave.\n3. Incollala qui: resta nel Portachiavi del Mac.\n\nCon la chiave gratuita puoi fare 4 controlli al minuto e 500 al giorno, solo per uso personale.")
                .font(.callout)
            HStack {
                Button("Apri virustotal.com") { Finder.open("https://www.virustotal.com/gui/join-us") }
                SecureField("Chiave API di VirusTotal", text: $keyField).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Button("Salva") { model.saveKey(keyField); keyField = "" }.disabled(keyField.isEmpty)
            }
        }
        .padding(20)
    }

    private func row(_ c: VirusTotalModel.Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: c.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.url.lastPathComponent).lineLimit(1)
                Text(Finder.short(c.url)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let r = c.report { Text(explanation(r)).font(.caption).foregroundStyle(.secondary) }
                if let e = c.error { Text(e).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if c.pending {
                Text("in coda").font(.caption).foregroundStyle(.secondary)
            } else if let r = c.report {
                verdictBadge(r)
                if r.known { Button("Dettagli") { NSWorkspace.shared.open(r.link) }.buttonStyle(.link) }
            }
        }
        .contextMenu {
            Button("Mostra nel Finder") { Finder.reveal(c.url) }
        }
    }

    @ViewBuilder private func verdictBadge(_ r: VirusTotalReport) -> some View {
        switch r.verdict {
        case .clean: Badge(text: "pulito · 0/\(r.engines)", color: Brand.accent)
        case .suspicious: Badge(text: "da valutare · \(r.malicious + r.suspicious)/\(r.engines)", color: .orange)
        case .malicious: Badge(text: "pericoloso · \(r.malicious)/\(r.engines)", color: .red)
        case .unknown: Badge(text: "mai visto", color: .secondary)
        }
    }

    private func explanation(_ r: VirusTotalReport) -> String {
        switch r.verdict {
        case .clean:
            return "Nessun antivirus lo segnala."
        case .suspicious:
            return "Pochi antivirus lo segnalano: spesso sono falsi allarmi (programmi poco diffusi, strumenti per sviluppatori). Guarda i dettagli prima di decidere."
                + (r.threatLabel.map { " Etichetta: \($0)." } ?? "")
        case .malicious:
            return "Molti antivirus lo considerano pericoloso" + (r.threatLabel.map { " (\($0))" } ?? "")
                + ". Non aprirlo; se è un programma installato, disinstallalo e cambia le password usate su questo Mac."
        case .unknown:
            return "VirusTotal non l'ha mai visto. Non vuol dire che sia pericoloso: capita con file personali o programmi rari. Se hai dubbi, puoi caricarlo tu da virustotal.com."
        }
    }
}
