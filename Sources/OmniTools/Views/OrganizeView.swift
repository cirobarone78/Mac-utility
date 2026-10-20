import SwiftUI
import UtilityCore

@MainActor
final class OrganizeModel: ObservableObject {
    @Published var folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @Published var strategy: FolderOrganizer.Strategy = .topic
    @Published var plan: OrganizePlan?
    /// File da NON spostare (deselezionati dall'utente).
    @Published var excluded: Set<URL> = []
    /// File inutili da mandare nel Cestino.
    @Published var toRemove: Set<URL> = []
    @Published var working = false
    @Published var message: String?
    @Published var canUndo = FolderOrganizer.latestRecordFolder() != nil

    var movingCount: Int {
        plan?.groups.reduce(0) { $0 + $1.files.filter { !excluded.contains($0.url) }.count } ?? 0
    }

    var newFolderCount: Int {
        plan?.groups.filter { g in g.files.contains { !excluded.contains($0.url) } }.count ?? 0
    }

    var removeBytes: Int64 {
        plan?.removals.filter { toRemove.contains($0.id) }.reduce(0) { $0 + $1.item.bytes } ?? 0
    }

    func analyze(policy: SafetyPolicy) {
        working = true
        message = nil
        let target = self.folder, chosen = self.strategy
        Task {
            let plan = await Self.makePlan(chosen, folder: target, policy: policy)
            self.plan = plan
            excluded = []
            toRemove = Set(plan.removals.filter { $0.risk == .safe }.map(\.id))
            working = false
            if plan.groups.isEmpty && plan.removals.isEmpty {
                message = "Nessun file sfuso da riordinare in questa cartella."
            }
        }
    }

    nonisolated static func makePlan(_ strategy: FolderOrganizer.Strategy, folder: URL,
                                     policy: SafetyPolicy) async -> OrganizePlan {
        FolderOrganizer(strategy: strategy).plan(folder: folder, policy: policy)
    }

    func apply(policy: SafetyPolicy) {
        guard var plan else { return }
        plan.groups = plan.groups.map { g in
            var g = g
            g.files = g.files.filter { !excluded.contains($0.url) }
            return g
        }
        let removals = plan.removals.filter { toRemove.contains($0.id) }.map(\.item)
        let r = FolderOrganizer.apply(plan, removals: removals, policy: policy)
        message = "Fatto: \(r.moved) file spostati in \(r.createdFolders) nuove cartelle"
            + (r.trashed > 0 ? ", \(r.trashed) file nel Cestino (\(Bytes.format(r.trashedBytes)))" : "")
            + "." + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
        self.plan = nil
        canUndo = true
    }

    func undo() {
        guard let r = FolderOrganizer.undoLast() else { return }
        message = "Riordino annullato: \(r.moved) file rimessi al loro posto."
            + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
            + " I file finiti nel Cestino si recuperano dal Finder."
        canUndo = FolderOrganizer.latestRecordFolder() != nil
        plan = nil
    }
}

struct OrganizeView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = OrganizeModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .organize,
                         subtitle: "Raccoglie i file sfusi in sottocartelle. Prima vedi tutto, poi decidi.")
            HStack {
                Image(systemName: "folder").foregroundStyle(Brand.accent)
                Text(Finder.short(model.folder)).lineLimit(1).truncationMode(.middle)
                Button("Cambia…") {
                    if let u = Finder.chooseFolder(start: model.folder) {
                        model.folder = u
                        model.plan = nil
                    }
                }
                Spacer()
                Picker("", selection: $model.strategy) {
                    ForEach(FolderOrganizer.Strategy.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(width: 320)
                Button("Analizza") { model.analyze(policy: state.policy) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.working)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if model.working {
                ProgressView("Analisi della cartella…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.plan, !(plan.groups.isEmpty && plan.removals.isEmpty) {
                preview(plan)
                footer
            } else {
                ContentUnavailableView {
                    Label("Scegli una cartella e premi «Analizza»", systemImage: Module.organize.icon)
                } description: {
                    Text(model.message ?? "Per argomento: i file che condividono una parola nel nome finiscono insieme (fatture, screenshot, un progetto…). Gli altri vanno per tipo.")
                } actions: {
                    if model.canUndo {
                        Button("Annulla l'ultimo riordino") { model.undo() }
                    }
                }
            }
        }
        .onChange(of: model.strategy) { if model.plan != nil { model.analyze(policy: state.policy) } }
        .confirmationDialog("Applicare il riordino?", isPresented: $confirming) {
            Button("Applica") { model.apply(policy: state.policy) }
        } message: {
            Text("Creerò fino a \(model.newFolderCount) cartelle e sposterò \(model.movingCount) file."
                 + (model.toRemove.isEmpty ? "" : " \(model.toRemove.count) file andranno nel Cestino (\(Bytes.format(model.removeBytes)))."))
                + Text(" Potrai annullare dal pulsante «Annulla l'ultimo riordino».")
        }
    }

    private func preview(_ plan: OrganizePlan) -> some View {
        List {
            if !plan.removals.isEmpty {
                Section {
                    ForEach(plan.removals) { s in
                        Toggle(isOn: setBinding($model.toRemove, s.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(s.item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Bytes.format(s.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(s.reason).font(.caption)
                                    .foregroundStyle(s.risk == .review ? .orange : .secondary)
                            }
                        }
                        .contextMenu { Button("Mostra nel Finder") { Finder.reveal(s.item.url) } }
                    }
                } header: {
                    Label("Probabilmente inutili → Cestino", systemImage: "trash")
                } footer: {
                    Text("Quelli in arancione non sono selezionati: controllali prima.")
                }
            }

            ForEach(Array(plan.groups.indices), id: \.self) { i in
                Section {
                    ForEach(plan.groups[i].files) { f in
                        Toggle(isOn: excludeBinding(f.url)) {
                            HStack {
                                Image(systemName: icon(for: f.url)).foregroundStyle(.secondary).frame(width: 18)
                                Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Bytes.format(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu { Button("Mostra nel Finder") { Finder.reveal(f.url) } }
                    }
                } header: {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(Brand.accent)
                        TextField("Nome cartella", text: groupName(i))
                            .textFieldStyle(.plain).font(.headline)
                            .frame(maxWidth: 280)
                        Text("\(plan.groups[i].files.count) file · \(plan.groups[i].reason)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.movingCount) file in \(model.newFolderCount) cartelle"
                 + (model.toRemove.isEmpty ? "" : " · \(model.toRemove.count) nel Cestino"))
                .monospacedDigit()
            Spacer()
            Button("Rinuncia") { model.plan = nil }
            Button("Applica…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.movingCount == 0 && model.toRemove.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Collegamenti

    private func groupName(_ i: Int) -> Binding<String> {
        Binding(get: { model.plan?.groups[safe: i]?.name ?? "" },
                set: { new in model.plan?.groups[i].name = new })
    }

    /// Spuntato = il file verrà spostato.
    private func excludeBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { !model.excluded.contains(url) },
                set: { on in if on { model.excluded.remove(url) } else { model.excluded.insert(url) } })
    }

    private func setBinding(_ set: Binding<Set<URL>>, _ url: URL) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(url) },
                set: { on in if on { set.wrappedValue.insert(url) } else { set.wrappedValue.remove(url) } })
    }

    private func icon(for url: URL) -> String {
        switch FileKind.of(url) {
        case .pdf: "doc.richtext"
        case .images: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .documents: "doc.text"
        case .spreadsheets: "tablecells"
        case .presentations: "rectangle.on.rectangle"
        case .ebooks: "book"
        case .archives: "archivebox"
        case .installers: "shippingbox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
