import SwiftUI
import UtilityCore

@MainActor
final class SecurityModel: ObservableObject {
    @Published var findings: [SecurityFinding] = []
    @Published var running = false
    @Published var status = ""
    @Published var showOK = false
    @Published var done = false
    @Published var summary: String?
    @Published var summaryBusy = false

    func run() {
        running = true
        summary = nil
        let box = WeakRef(self)
        Task {
            findings = await Self.audit { msg in Task { @MainActor in box.value?.status = msg } }
            running = false
            done = true
        }
    }

    nonisolated static func audit(progress: @escaping @Sendable (String) -> Void) async -> [SecurityFinding] {
        SecurityAudit.run(progress: progress, isCancelled: { Task.isCancelled })
    }

    /// Riassunto dell'AI: riceve solo titoli e livelli, non i file.
    func summarize() {
        guard AIEnv.hasKey else { summary = "Inserisci la chiave API nella schermata «Assistente AI»."; return }
        summaryBusy = true
        let text = findings.filter { $0.level > .ok }
            .map { "[\($0.level.label)] \($0.area.rawValue): \($0.title) — \($0.detail)" }
            .joined(separator: "\n")
        let client = AIEnv.client()
        Task {
            do {
                let r = try await AIExplain.explain("Risultato del controllo di sicurezza",
                                                    context: "Riassumi in 5-8 frasi cosa è davvero preoccupante e cosa no, in ordine di importanza, e cosa fare. Elementi:\n" + (text.isEmpty ? "nessun elemento da segnalare" : text),
                                                    client: client)
                summary = r.text
            } catch {
                summary = error.localizedDescription
            }
            summaryBusy = false
        }
    }
}

struct SecurityView: View {
    @StateObject private var model = SecurityModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .security,
                         subtitle: "Controlla le porte d'ingresso che usano i malware: avvio automatico, app non firmate, profili, protezioni di sistema.")
            HStack {
                Button(model.done ? "Ripeti il controllo" : "Avvia il controllo") { model.run() }
                    .buttonStyle(.borderedProminent).disabled(model.running)
                if model.done {
                    Button("Riassunto dell'AI") { model.summarize() }.disabled(model.summaryBusy)
                    Toggle("Mostra anche ciò che è a posto", isOn: $model.showOK)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 8)
            Text("Non è un antivirus: non analizza il contenuto dei file. Per una scansione completa usa anche un antimalware dedicato (per esempio Malwarebytes). Tasto destro su un elemento › «Chiedi all'AI cos'è».")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 8)

            if model.running {
                ProgressView(model.status.isEmpty ? "Controllo in corso…" : model.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.done {
                List {
                    if model.summaryBusy || model.summary != nil {
                        Section("Riassunto dell'AI") {
                            if let s = model.summary { Text(s).textSelection(.enabled) } else { ProgressView() }
                        }
                    }
                    let visible = model.findings.filter { model.showOK || $0.level > .ok }
                    if visible.isEmpty {
                        Text("Nessun elemento da segnalare.").foregroundStyle(.secondary)
                    }
                    ForEach(SecurityFinding.Area.allCasesOrdered, id: \.self) { area in
                        let items = visible.filter { $0.area == area }
                        if !items.isEmpty {
                            Section(area.rawValue) {
                                ForEach(items) { f in row(f) }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Premi «Avvia il controllo»", systemImage: Module.security.icon,
                                       description: Text("Richiede circa un minuto. Non modifica nulla."))
            }
        }
    }

    private func row(_ f: SecurityFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Badge(text: f.level.label, color: color(f.level)).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.title).lineLimit(2)
                Text(f.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let p = f.path { Text(p).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
        }
        .contextMenu {
            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                ExplainCenter.shared.ask(f.title, context: "Controllo di sicurezza di un Mac. \(f.area.rawValue). \(f.detail) Percorso: \(f.path ?? "—")")
            }
            if let p = f.path { Button("Mostra nel Finder") { Finder.reveal(URL(fileURLWithPath: p)) } }
        }
    }

    private func color(_ l: SecurityFinding.Level) -> Color {
        switch l {
        case .ok: Brand.accent
        case .info: .blue
        case .warning: .orange
        case .suspicious: .red
        }
    }
}

extension SecurityFinding.Area {
    static let allCasesOrdered: [SecurityFinding.Area] = [.system, .startup, .apps, .profiles, .browser]
}
