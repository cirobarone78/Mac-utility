import SwiftUI
import UtilityCore

@MainActor
final class CleanupModel: ObservableObject {
    @Published var findings: [CleanupFinding] = []
    @Published var selected: Set<URL> = []
    @Published var scanning = false
    @Published var lastReport: String?
    @Published var includeDeveloper = true

    var selectedBytes: Int64 {
        findings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.item.bytes }
    }

    struct Group: Identifiable {
        let category: CleanupCategory
        let items: [CleanupFinding]
        var id: String { category.id }
        var bytes: Int64 { items.reduce(0) { $0 + $1.item.bytes } }
    }

    var groups: [Group] {
        let byCat = Dictionary(grouping: findings, by: { $0.category.id })
        return CleanupCatalog.standard.compactMap { cat in
            byCat[cat.id].map { Group(category: cat, items: $0) }
        }
    }

    func scan(policy: SafetyPolicy) {
        scanning = true
        lastReport = nil
        let cats = CleanupCatalog.standard.filter { includeDeveloper || !$0.forDevelopers }
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = CleanupCatalog.scan(cats, policy: policy)
            await MainActor.run {
                guard let self else { return }
                self.findings = found
                // Solo le categorie sicure vengono preselezionate.
                self.selected = Set(found.filter { $0.category.risk == .safe }.map(\.id))
                self.scanning = false
            }
        }
    }

    func clean(policy: SafetyPolicy) {
        let items = findings.filter { selected.contains($0.id) }.map(\.item)
        let report = SafeRemover(policy: policy).moveToTrash(items)
        lastReport = "Spostati nel Cestino \(report.moved.count) elementi (\(Bytes.format(report.bytes)))."
            + (report.skipped.isEmpty ? "" : " Saltati \(report.skipped.count) (in uso o protetti).")
            + " Lo spazio si libera svuotando il Cestino."
        findings.removeAll { report.moved.contains($0.id) }
        selected.subtract(report.moved)
    }
}

struct CleanupView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = CleanupModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .cleanup, subtitle: "Cache, log e residui. Tutto finisce nel Cestino: nulla è cancellato per sempre.")
            HStack {
                Toggle("Includi strumenti di sviluppo (Xcode, Gradle, npm)", isOn: $model.includeDeveloper)
                Spacer()
                Button(model.findings.isEmpty ? "Analizza" : "Analizza di nuovo") { model.scan(policy: state.policy) }
                    .disabled(model.scanning)
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if model.scanning {
                ProgressView("Analisi in corso…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.findings.isEmpty {
                ContentUnavailableView("Premi «Analizza»", systemImage: Module.cleanup.icon,
                                       description: Text(model.lastReport ?? "Vedrai cosa si può eliminare prima di toccare qualsiasi cosa."))
            } else {
                List {
                    ForEach(model.groups) { group in
                        let cat = group.category
                        Section {
                            ForEach(group.items) { f in
                                Toggle(isOn: binding(f.id)) {
                                    HStack {
                                        Text(f.item.url.lastPathComponent).lineLimit(1)
                                        Spacer()
                                        Text(Bytes.format(f.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                                .contextMenu { Button("Mostra nel Finder") { Finder.reveal(f.item.url) } }
                            }
                        } header: {
                            HStack {
                                Text(cat.name)
                                if cat.risk == .review {
                                    Text("da controllare").font(.caption).foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(Bytes.format(group.bytes))
                            }
                        } footer: {
                            Text(cat.detail)
                        }
                    }
                }
                footer
            }
        }
        .confirmationDialog("Spostare nel Cestino \(model.selected.count) elementi?",
                            isPresented: $confirming) {
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedBytes)))", role: .destructive) {
                model.clean(policy: state.policy)
            }
        } message: {
            Text("Potrai recuperarli dal Cestino finché non lo svuoti.")
        }
    }

    private var footer: some View {
        HStack {
            if let r = model.lastReport { Text(r).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            Text("Selezionati: \(Bytes.format(model.selectedBytes))").monospacedDigit()
            Button("Sposta nel Cestino…") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty)
        }
        .padding(16)
    }

    private func binding(_ id: URL) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { on in if on { model.selected.insert(id) } else { model.selected.remove(id) } })
    }
}
