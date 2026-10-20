import SwiftUI
import UtilityCore

@MainActor
final class DoctorModel: ObservableObject {
    @Published var snapshot: String?
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
                let (r, reply) = try await MacDoctor.diagnose(snapshot: snap, client: client)
                report = r
                cost += reply.costUSD
            } catch {
                self.error = error.localizedDescription
            }
            working = false
            status = ""
        }
    }

    nonisolated static func collect(policy: SafetyPolicy, system: String,
                                    progress: @escaping @Sendable (String) -> Void) async -> String {
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
            let snap: String
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
                let reply = try await MacDoctor.chat(snapshot: snap, history: history, client: client)
                chat.append(ClaudeMessage(role: "assistant", text: reply.text))
                cost += reply.costUSD
            } catch {
                chat.append(ClaudeMessage(role: "assistant", text: "Errore: \(error.localizedDescription)"))
            }
            chatBusy = false
        }
    }
}

struct DoctorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var model = DoctorModel()
    @State private var input = ""
    @State private var showSnapshot = false

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
        .sheet(isPresented: $showSnapshot) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Dati inviati a Claude").font(.headline)
                ScrollView { Text(model.snapshot ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
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
        HStack(alignment: .top, spacing: 12) {
            Badge(text: f.priority, color: f.priority == "alta" ? .red : f.priority == "media" ? .orange : Brand.accent)
                .frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(f.title).font(.headline)
                Text(f.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let target = Self.module(for: f.action) {
                Button("Vai a \(target.title)") { state.selection = target }
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
