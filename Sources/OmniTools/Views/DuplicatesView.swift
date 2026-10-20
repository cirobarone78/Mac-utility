import SwiftUI
import UtilityCore

@MainActor
final class DuplicatesModel: ObservableObject {
    @Published var root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @Published var groups: [DuplicateGroup] = []
    @Published var selected: Set<URL> = []
    @Published var scanning = false
    @Published var status = ""
    @Published var lastOperationID: String?
    private var task: Task<Void, Never>?

    var selectedBytes: Int64 {
        groups.flatMap(\.files).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    func scan(policy: SafetyPolicy) {
        task?.cancel()
        scanning = true
        groups = []
        selected = []
        let scanRoot = self.root
        task = Task {
            let box = WeakRef(self)
            let found = await Self.find(under: scanRoot, policy: policy) { msg in
                Task { @MainActor in box.value?.status = msg }
            }
            if Task.isCancelled { return }
            groups = found
            // Proposta: tenere il più vecchio, selezionare le copie.
            selected = Set(found.flatMap { $0.files.dropFirst().map(\.url) })
            scanning = false
            status = found.isEmpty ? "Nessun duplicato trovato." : ""
        }
    }

    nonisolated static func find(under root: URL, policy: SafetyPolicy,
                                 progress: @escaping @Sendable (String) -> Void) async -> [DuplicateGroup] {
        DuplicateFinder().find(under: root, policy: policy, progress: progress,
                               isCancelled: { Task.isCancelled })
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        status = Restore.run(id) ?? "Già ripristinato."
        lastOperationID = nil
        groups = []
    }

    func cancel() {
        task?.cancel()
        scanning = false
    }

    /// Non permette di selezionare tutte le copie di un gruppo: almeno una resta.
    func toggle(_ file: DiskItem, in group: DuplicateGroup) {
        if selected.contains(file.url) {
            selected.remove(file.url)
        } else if group.files.filter({ !selected.contains($0.url) }).count > 1 {
            selected.insert(file.url)
        }
    }

    func trash(policy: SafetyPolicy) {
        let items = groups.flatMap(\.files).filter { selected.contains($0.url) }
        let report = SafeRemover(policy: policy).moveToTrash(items, kind: "Duplicati")
        lastOperationID = report.operationID
        status = "Spostati nel Cestino \(report.moved.count) file (\(Bytes.format(report.bytes)))."
        let moved = Set(report.moved)
        groups = groups.compactMap { g in
            let rest = g.files.filter { !moved.contains($0.url) }
            return rest.count > 1 ? DuplicateGroup(bytesEach: g.bytesEach, files: rest) : nil
        }
        selected.subtract(moved)
    }
}

/// Riferimento debole passabile ai thread in background (per i messaggi di avanzamento).
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

struct DuplicatesView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = DuplicatesModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .duplicates, subtitle: "File identici byte per byte (oltre 1 MB). Una copia resta sempre.")
            HStack {
                Text(Finder.short(model.root)).lineLimit(1).truncationMode(.middle)
                Button("Cambia…") { if let u = Finder.chooseFolder(start: model.root) { model.root = u } }
                Spacer()
                if model.scanning {
                    Button("Interrompi") { model.cancel() }
                } else {
                    Button("Cerca duplicati") { model.scan(policy: state.policy) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if model.scanning {
                ProgressView(model.status.isEmpty ? "Ricerca in corso…" : model.status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.groups.isEmpty {
                ContentUnavailableView {
                    Label("Nessun risultato", systemImage: Module.duplicates.icon)
                } description: {
                    Text(model.status.isEmpty ? "Scegli una cartella e premi «Cerca duplicati»." : model.status)
                } actions: {
                    if model.lastOperationID != nil {
                        Button("Ripristina le copie eliminate") { model.restoreLast() }
                    }
                }
            } else {
                List {
                    ForEach(model.groups) { g in
                        Section("\(g.files.count) copie da \(Bytes.format(g.bytesEach)) – recuperabili \(Bytes.format(g.wasted))") {
                            ForEach(g.files) { f in
                                Toggle(isOn: Binding(get: { model.selected.contains(f.url) },
                                                     set: { _ in model.toggle(f, in: g) })) {
                                    Text(Finder.short(f.url)).lineLimit(1).truncationMode(.middle)
                                }
                                .contextMenu { Button("Mostra nel Finder") { Finder.reveal(f.url) } }
                            }
                        }
                    }
                }
                HStack {
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                    if model.lastOperationID != nil {
                        Button("Ripristina") { model.restoreLast() }
                    }
                    Spacer()
                    Text("Selezionati: \(Bytes.format(model.selectedBytes))").monospacedDigit()
                    Button("Sposta nel Cestino…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selected.isEmpty)
                }
                .padding(16)
            }
        }
        .confirmationDialog("Spostare nel Cestino \(model.selected.count) copie?", isPresented: $confirming) {
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedBytes)))", role: .destructive) {
                model.trash(policy: state.policy)
            }
        }
    }
}
