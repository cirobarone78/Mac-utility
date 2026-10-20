import SwiftUI
import UtilityCore

@MainActor
final class AssistantModel: ObservableObject {
    @Published var folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @Published var advice: AIAdvice?
    @Published var approved: Set<URL> = []
    @Published var working = false
    @Published var status = ""
    @Published var message: String?
    @Published var hasKey = Keychain.readKey()?.isEmpty == false
    @Published var preview: String?

    func advisor(model: AIModel, instructions: String) -> AIAdvisor {
        AIAdvisor(model: model, apiKey: Keychain.readKey() ?? "", instructions: instructions)
    }

    func ask(model: AIModel, instructions: String, policy: SafetyPolicy) {
        working = true
        message = nil
        advice = nil
        let client = self.advisor(model: model, instructions: instructions)
        let target = folder
        Task {
            do {
                let result = try await client.advise(folder: target, policy: policy) { text in
                    Task { @MainActor in self.status = text }
                }
                advice = result
                // Si preselezionano solo gli spostamenti; le eliminazioni le spunti tu.
                approved = Set(result.proposals.filter { $0.action == .move }.map(\.id))
                if result.proposals.isEmpty { message = "Nessun file sfuso da esaminare in questa cartella." }
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }

    func apply(policy: SafetyPolicy) {
        guard let advice else { return }
        let (plan, removals) = advice.plan(approved: approved)
        let r = FolderOrganizer.apply(plan, removals: removals, policy: policy, kind: "Assistente AI")
        message = "Fatto: \(r.moved) file spostati, \(r.createdFolders) cartelle nuove"
            + (r.trashed > 0 ? ", \(r.trashed) file nel Cestino (\(Bytes.format(r.trashedBytes)))" : "")
            + "." + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
            + " Per tornare indietro: Cronologia › Ripristina."
        self.advice = nil
    }
}

private struct FolderGroup: Identifiable {
    let name: String
    let items: [AIProposal]
    var id: String { name }
}

struct AssistantView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = AssistantModel()
    @AppStorage("ai.model") private var modelRaw = AIModel.opus.rawValue
    @AppStorage("ai.instructions") private var instructions = ""
    @State private var keyField = ""
    @State private var confirming = false

    private var aiModel: AIModel { AIModel(rawValue: modelRaw) ?? .opus }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .assistant,
                         subtitle: "Claude legge nomi, tipi, dimensioni e date dei file e propone cosa fare. Decidi tu.")
            if !model.hasKey {
                keySetup
            } else {
                controls
                content
            }
        }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.preview = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ecco esattamente cosa viene inviato").font(.headline)
                Text("Oltre a queste righe viaggiano solo le istruzioni fisse dell'assistente. Il contenuto dei file non viene mai letto.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView { Text(model.preview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                HStack { Spacer(); Button("Chiudi") { model.preview = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(width: 720, height: 520)
        }
        .confirmationDialog("Applicare le proposte approvate?", isPresented: $confirming) {
            Button("Applica") { model.apply(policy: state.policy) }
        } message: {
            Text(confirmText)
        }
    }

    // MARK: - Chiave

    private var keySetup: some View {
        Form {
            Section {
                SecureField("sk-ant-…", text: $keyField)
                HStack {
                    Button("Salva nel Portachiavi") {
                        if Keychain.saveKey(keyField.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            keyField = ""
                            model.hasKey = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Crea una chiave su console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            } header: {
                Text("Chiave API di Anthropic")
            } footer: {
                Text("Resta nel Portachiavi di questo Mac. Ogni analisi ha un piccolo costo sul tuo account Anthropic, mostrato a fine analisi.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Comandi

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder").foregroundStyle(Brand.accent)
                Text(Finder.short(model.folder)).lineLimit(1).truncationMode(.middle)
                Button("Cambia…") {
                    if let u = Finder.chooseFolder(start: model.folder) { model.folder = u; model.advice = nil }
                }
                Spacer()
                Picker("Modello", selection: $modelRaw) {
                    ForEach(AIModel.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .frame(width: 300)
            }
            HStack {
                TextField("Indicazioni personali (facoltative), es. «non eliminare nulla che riguardi OmniNeo»",
                          text: $instructions)
                Button("Vedi cosa invio") {
                    model.preview = model.advisor(model: aiModel, instructions: instructions)
                        .preview(for: model.folder, policy: state.policy)
                }
                Button("Chiedi all'assistente") {
                    model.ask(model: aiModel, instructions: instructions, policy: state.policy)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.working)
                Menu {
                    Button("Cambia chiave API", role: .destructive) { Keychain.deleteKey(); model.hasKey = false }
                } label: { Image(systemName: "key") }
                .menuStyle(.borderlessButton).frame(width: 30)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.working {
            ProgressView(model.status.isEmpty ? "L'assistente sta guardando la cartella…" : model.status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let advice = model.advice, !advice.proposals.isEmpty {
            results(advice)
        } else {
            ContentUnavailableView {
                Label("Scegli una cartella e chiedi all'assistente", systemImage: Module.assistant.icon)
            } description: {
                Text(model.message ?? "Riceverai proposte di spostamento e di eliminazione, ognuna con il suo motivo. Non succede nulla finché non premi «Applica».")
            }
        }
    }

    private func results(_ advice: AIAdvice) -> some View {
        let trash = advice.proposals.filter { $0.action == .trash }
        let moves = Dictionary(grouping: advice.proposals.filter { $0.action == .move }, by: \.folder)
            .map { FolderGroup(name: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
        let keep = advice.proposals.filter { $0.action == .keep }

        return VStack(spacing: 0) {
            List {
                Section {
                    Text(advice.summary).font(.callout)
                    if advice.skippedFiles > 0 {
                        Text("\(advice.skippedFiles) file non esaminati (limite per analisi).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !trash.isEmpty {
                    Section {
                        ForEach(trash) { row($0) }
                    } header: {
                        HStack {
                            Label("Da mandare nel Cestino", systemImage: "trash")
                            Spacer()
                            Button("Spunta quelle a fiducia alta") {
                                model.approved.formUnion(trash.filter { $0.confidence == "alta" }.map(\.id))
                            }
                            .buttonStyle(.link)
                        }
                    } footer: {
                        Text("Nessuna eliminazione è spuntata in partenza: scegli tu.")
                    }
                }

                ForEach(moves) { group in
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        Label("\(group.name) · \(group.items.count) file", systemImage: "folder.fill")
                            .foregroundStyle(Brand.accent)
                    }
                }

                if !keep.isEmpty {
                    Section {
                        DisclosureGroup("\(keep.count) file da lasciare dove sono") {
                            ForEach(keep) { p in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.item.url.lastPathComponent).lineLimit(1)
                                    Text(p.reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Text(String(format: "Costo stimato di questa analisi: %.3f $", advice.costUSD))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rinuncia") { model.advice = nil }
                Button("Applica…") { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.approved.isEmpty)
            }
            .padding(16)
        }
    }

    private func row(_ p: AIProposal) -> some View {
        Toggle(isOn: Binding(get: { model.approved.contains(p.id) },
                             set: { on in if on { model.approved.insert(p.id) } else { model.approved.remove(p.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(p.item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Bytes.format(p.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(p.reason).font(.caption).foregroundStyle(.secondary)
                    Text("fiducia \(p.confidence)").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(p.confidence == "alta" ? Brand.accent.opacity(0.2) : Color.orange.opacity(0.2),
                                    in: Capsule())
                }
            }
        }
        .contextMenu { Button("Mostra nel Finder") { Finder.reveal(p.item.url) } }
    }

    private var confirmText: String {
        guard let advice = model.advice else { return "" }
        let chosen = advice.proposals.filter { model.approved.contains($0.id) }
        let moves = chosen.filter { $0.action == .move }.count
        let trash = chosen.filter { $0.action == .trash }
        let bytes = trash.reduce(Int64(0)) { $0 + $1.item.bytes }
        return "Sposterò \(moves) file" + (trash.isEmpty ? "." : " e metterò \(trash.count) file nel Cestino (\(Bytes.format(bytes))).")
            + " Potrai tornare indietro da Cronologia › Ripristina."
    }
}
