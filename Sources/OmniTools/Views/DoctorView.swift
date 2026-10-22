import SwiftUI
import UtilityCore

@MainActor
final class DoctorModel: ObservableObject {
    @Published var snapshot: DoctorSnapshot?
    /// Elementi spuntati per ogni consiglio (preselezionati quelli proposti dall'AI).
    @Published var chosen: [String: Set<String>] = [:]
    /// Esito di ogni consiglio eseguito: messaggio e operazione da poter ripristinare.
    @Published var done: [String: (message: String, operationID: String?)] = [:]
    @Published var report: DoctorReport?
    @Published var working = false
    @Published var status = ""
    @Published var error: String?
    @Published var cost: Double = 0
    @Published var chat: [ClaudeMessage] = []
    @Published var chatBusy = false

    func diagnose(policy: SafetyPolicy, system: String) {
        guard AIEnv.hasKey else { error = "Inserisci prima la chiave API nella schermata «Assistente AI»."; return }
        working = true
        error = nil
        report = nil
        let client = AIEnv.client()
        let box = WeakRef(self)
        Task {
            let snap = await Self.collect(policy: policy, system: system) { msg in
                Task { @MainActor in box.value?.status = msg }
            }
            snapshot = snap
            status = "Chiedo a Claude…"
            do {
                let (r, reply) = try await MacDoctor.diagnose(snapshot: snap.text, client: client)
                report = r
                done = [:]
                // Solo identificativi davvero presenti nella fotografia.
                chosen = Dictionary(r.findings.map { f in (f.id, Set(f.items.filter { snap.items[$0] != nil })) },
                                    uniquingKeysWith: { a, b in a.union(b) })
                cost += reply.costUSD
            } catch {
                self.error = error.localizedDescription
            }
            working = false
            status = ""
        }
    }

    nonisolated static func collect(policy: SafetyPolicy, system: String,
                                    progress: @escaping @Sendable (String) -> Void) async -> DoctorSnapshot {
        MacDoctor.snapshot(policy: policy, system: system, progress: progress)
    }

    func send(_ text: String, policy: SafetyPolicy, system: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard AIEnv.hasKey else { error = "Inserisci prima la chiave API nella schermata «Assistente AI»."; return }
        chat.append(ClaudeMessage(role: "user", text: question))
        chatBusy = true
        let client = AIEnv.client()
        let history = chat
        let box = WeakRef(self)
        Task {
            let snap: DoctorSnapshot
            if let s = snapshot {
                snap = s
            } else {
                status = "Raccolgo i dati del Mac…"
                snap = await Self.collect(policy: policy, system: system) { msg in
                    Task { @MainActor in box.value?.status = msg }
                }
                snapshot = snap
                status = ""
            }
            do {
                let reply = try await MacDoctor.chat(snapshot: snap.text, history: history, client: client)
                chat.append(ClaudeMessage(role: "assistant", text: reply.text))
                cost += reply.costUSD
            } catch {
                chat.append(ClaudeMessage(role: "assistant", text: "Errore: \(error.localizedDescription)"))
            }
            chatBusy = false
        }
    }
}

extension DoctorModel {
    func items(for f: DoctorFinding) -> [DoctorItem] {
        f.items.compactMap { snapshot?.items[$0] }
    }

    func selectedItems(for f: DoctorFinding) -> [DoctorItem] {
        items(for: f).filter { chosen[f.id]?.contains($0.id) == true }
    }

    func toggle(_ id: String, in f: DoctorFinding) {
        var set = chosen[f.id] ?? []
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        chosen[f.id] = set
    }

    /// Il Medico esegue il consiglio: sposta nel Cestino gli elementi spuntati (annullabile).
    func execute(_ f: DoctorFinding, policy: SafetyPolicy) {
        let items = selectedItems(for: f).map(\.item)
        let r = SafeRemover(policy: policy).moveToTrash(items, kind: "Medico del Mac")
        var msg = "Fatto: \(r.moved.count) elementi nel Cestino (\(Bytes.format(r.bytes)))."
        if !r.skipped.isEmpty { msg += " Non spostati: \(r.skipped.count) (\(r.skipped[0].reason))." }
        done[f.id] = (msg, r.operationID)
    }

    func restore(_ f: DoctorFinding) {
        guard let id = done[f.id]?.operationID else { return }
        done[f.id] = (Restore.run(id) ?? "Già ripristinato.", nil)
    }
}

struct DoctorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var model = DoctorModel()
    @State private var input = ""
    @State private var showSnapshot = false
    @State private var confirming: DoctorFinding?

    private var systemLines: String {
        let s = monitor.snapshot
        var lines = ["Memoria usata: \(Bytes.format(Int64(s.memoryUsed))) di \(Bytes.format(Int64(s.memoryTotal)))",
                     "Processore: \(Int(s.cpuUsage * 100))%",
                     "Acceso da: \(Int(s.uptime / 3600)) ore"]
        if let b = s.battery { lines.append("Batteria: \(Int(b * 100))%") }
        lines.append("Processi più pesanti: " + s.topProcesses.prefix(6)
            .map { "\($0.name) \(String(format: "%.0f", $0.cpu))% CPU \(Bytes.format(Int64($0.memoryBytes)))" }
            .joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .doctor, subtitle: "L'AI guarda lo stato del Mac e ti dice cosa conviene fare per primo. Poi puoi farle domande.")
            HStack {
                Button(model.report == nil ? "Fai il punto" : "Rifai il punto") {
                    model.diagnose(policy: state.policy, system: systemLines)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.working)
                if model.snapshot != nil { Button("Vedi i dati inviati") { showSnapshot = true } }
                Spacer()
                if model.cost > 0 {
                    Text(String(format: "Costo finora: %.3f $", model.cost)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.working {
                        HStack { ProgressView().controlSize(.small); Text(model.status) }.padding(.vertical, 20)
                    }
                    if let e = model.error { Text(e).foregroundStyle(.orange) }
                    if let r = model.report {
                        Text(r.summary).font(.title3)
                        ForEach(r.findings) { f in finding(f) }
                    } else if !model.working && model.chat.isEmpty {
                        Text("Premi «Fai il punto»: OmniTools raccoglie solo numeri e nomi (spazio, cache, cartelle pesanti, avvio, memoria), mai il contenuto dei file, e Claude ti restituisce i consigli in ordine di importanza. Con migliaia di file la raccolta richiede un minuto.")
                            .foregroundStyle(.secondary)
                    }
                    if !model.chat.isEmpty {
                        Divider().padding(.vertical, 6)
                        ForEach(Array(model.chat.enumerated()), id: \.offset) { _, m in bubble(m) }
                        if model.chatBusy {
                            HStack { ProgressView().controlSize(.small); Text(model.status.isEmpty ? "Claude sta rispondendo…" : model.status) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                TextField("Chiedi qualcosa sul tuo Mac, es. «perché il disco è pieno?»", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Invia", action: send).disabled(model.chatBusy || input.isEmpty)
            }
            .padding(16)
        }
        .confirmationDialog("Spostare nel Cestino gli elementi spuntati?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { f in
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedItems(for: f).reduce(0) { $0 + $1.item.bytes })))",
                   role: .destructive) { model.execute(f, policy: state.policy) }
        } message: { f in
            Text(model.selectedItems(for: f).prefix(8).map { "• " + $0.title }.joined(separator: "\n")
                 + (model.selectedItems(for: f).count > 8 ? "\n…e altri \(model.selectedItems(for: f).count - 8)" : "")
                 + "\n\nTutto resta recuperabile con «Ripristina» finché non svuoti il Cestino.")
        }
        .sheet(isPresented: $showSnapshot) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dati inviati a Claude").font(.headline)
                ScrollView { Text(model.snapshot?.text ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                HStack { Spacer(); Button("Chiudi") { showSnapshot = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(20).frame(width: 700, height: 500)
        }
    }

    private func send() {
        let text = input
        input = ""
        model.send(text, policy: state.policy, system: systemLines)
    }

    private func finding(_ f: DoctorFinding) -> some View {
        let items = model.items(for: f)
        let selected = model.selectedItems(for: f)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Badge(text: f.priority, color: f.priority == "alta" ? .red : f.priority == "media" ? .orange : Brand.accent)
                    .frame(width: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.title).font(.headline)
                    Text(f.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let target = Self.module(for: f.action) {
                    Button("Apri \(target.title)") { state.selection = target }.buttonStyle(.link)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cosa verrebbe spostato nel Cestino:").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(items) { d in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(get: { model.chosen[f.id]?.contains(d.id) == true },
                                                     set: { _ in model.toggle(d.id, in: f) }))
                                .labelsHidden()
                                .disabled(model.done[f.id] != nil)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(d.title).lineLimit(2)
                                    if d.risky { Badge(text: "da controllare", color: .orange) }
                                }
                                Text([Bytes.format(d.item.bytes),
                                      d.item.modified.map { "ultima modifica " + $0.formatted(date: .abbreviated, time: .omitted) },
                                      Finder.short(d.item.url)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .contextMenu {
                            Button("Mostra nel Finder") { Finder.reveal(d.item.url) }
                            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                                ExplainCenter.shared.ask(d.item.url.lastPathComponent, context: d.title + ". " + d.detail)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Brand.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    if let result = model.done[f.id] {
                        Label(result.message, systemImage: "checkmark.circle").foregroundStyle(Brand.accent)
                        if result.operationID != nil { Button("Ripristina") { model.restore(f) } }
                    } else {
                        Button("Fallo tu: sposta nel Cestino \(selected.count) elementi (\(Bytes.format(selected.reduce(0) { $0 + $1.item.bytes })))") {
                            confirming = f
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
    }

    private func bubble(_ m: ClaudeMessage) -> some View {
        HStack {
            if m.role == "user" { Spacer(minLength: 80) }
            Text(m.text)
                .textSelection(.enabled)
                .padding(10)
                .background(m.role == "user" ? Brand.accent.opacity(0.18) : Brand.card, in: RoundedRectangle(cornerRadius: 10))
            if m.role != "user" { Spacer(minLength: 80) }
        }
    }

    static func module(for action: String) -> Module? {
        switch action {
        case "pulizia": .cleanup
        case "spazio": .space
        case "riordino": .organize
        case "duplicati": .duplicates
        case "foto": .photos
        case "whatsapp": .whatsapp
        case "sistema": .system
        case "avvio": .startup
        case "sicurezza": .security
        default: nil
        }
    }
}
