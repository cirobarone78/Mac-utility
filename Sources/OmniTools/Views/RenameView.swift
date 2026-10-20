import SwiftUI
import UtilityCore

@MainActor
final class RenameModel: ObservableObject {
    @Published var folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @Published var readContent = false
    @Published var onlyGeneric = true
    @Published var proposals: [RenameProposal] = []
    @Published var selected: Set<URL> = []
    @Published var working = false
    @Published var message: String?
    @Published var cost = 0.0
    @Published var lastOperationID: String?

    func propose(policy: SafetyPolicy) {
        guard AIEnv.hasKey else { message = "Inserisci la chiave API nella schermata «Assistente AI»."; return }
        working = true
        message = nil
        proposals = []
        let target = folder, read = readContent, generic = onlyGeneric
        let client = AIEnv.client()
        Task {
            let items = await Self.candidates(target, policy: policy, onlyGeneric: generic)
            if items.isEmpty {
                message = "Nessun file con un nome generico in questa cartella."
            } else {
                do {
                    let r = try await SmartRenamer.propose(Array(items.prefix(400)), readContent: read, client: client)
                    proposals = r.proposals
                    selected = Set(r.proposals.map(\.id))
                    cost = r.cost
                    message = r.proposals.isEmpty ? "L'AI non ha trovato nomi migliori di quelli attuali." : nil
                } catch {
                    message = error.localizedDescription
                }
            }
            working = false
        }
    }

    nonisolated static func candidates(_ folder: URL, policy: SafetyPolicy, onlyGeneric: Bool) async -> [DiskItem] {
        SmartRenamer.candidates(in: folder, policy: policy, onlyGeneric: onlyGeneric)
    }

    func apply(policy: SafetyPolicy) {
        let chosen = proposals.filter { selected.contains($0.id) }
        let r = SmartRenamer.apply(chosen, folder: folder, policy: policy)
        lastOperationID = r.operationID
        message = "\(r.moved) file rinominati." + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
        proposals = []
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = Restore.run(id) ?? "Già ripristinato."
        lastOperationID = nil
    }
}

struct RenameView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = RenameModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .rename, subtitle: "Nomi chiari per file come IMG_4021.jpg o Documento (3).pdf. Vedi tutto prima, si annulla con «Ripristina».")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(Brand.accent)
                    Text(Finder.short(model.folder)).lineLimit(1).truncationMode(.middle)
                    Button("Cambia…") { if let u = Finder.chooseFolder(start: model.folder) { model.folder = u; model.proposals = [] } }
                    Spacer()
                    Button("Proponi nomi") { model.propose(policy: state.policy) }
                        .buttonStyle(.borderedProminent).disabled(model.working)
                }
                HStack(spacing: 18) {
                    Toggle("Solo i file con nomi generici", isOn: $model.onlyGeneric)
                    Toggle("Leggi l'inizio di PDF e file di testo", isOn: $model.readContent)
                        .help("Invia a Claude le prime righe (circa 400 caratteri) per capire di cosa parla il documento.")
                }
                .font(.callout)
                if model.readContent {
                    Label("Con questa opzione un breve estratto dei documenti viene inviato a Claude. Non usarla su cartelle con documenti riservati.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let m = model.message {
                    HStack {
                        Text(m).font(.callout).foregroundStyle(.secondary)
                        if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() } }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if model.working {
                ProgressView("Claude sta leggendo i nomi…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.proposals.isEmpty {
                List {
                    ForEach($model.proposals) { $p in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { model.selected.contains(p.id) },
                                                     set: { on in if on { model.selected.insert(p.id) } else { model.selected.remove(p.id) } }))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                                    TextField("Nuovo nome", text: $p.newBase).textFieldStyle(.roundedBorder)
                                    Text("." + p.item.url.pathExtension).foregroundStyle(.secondary)
                                }
                                Text(p.reason).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .contextMenu { Button("Mostra nel Finder") { Finder.reveal(p.item.url) } }
                    }
                }
                HStack {
                    if model.cost > 0 { Text(String(format: "Costo: %.4f $", model.cost)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Rinomina \(model.selected.count) file…") { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
                }
                .padding(16)
            } else {
                ContentUnavailableView("Scegli una cartella e premi «Proponi nomi»", systemImage: Module.rename.icon,
                                       description: Text("Puoi correggere ogni nome prima di applicare. Nessun file viene toccato finché non confermi."))
            }
        }
        .confirmationDialog("Rinominare \(model.selected.count) file?", isPresented: $confirming) {
            Button("Rinomina") { model.apply(policy: state.policy) }
        } message: {
            Text("Si annulla con «Ripristina» o da Cronologia.")
        }
    }
}
