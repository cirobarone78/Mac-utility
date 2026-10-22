import SwiftUI
import AppKit
import UtilityCore

@MainActor
final class CleanupModel: ObservableObject {
    @Published var findings: [CleanupFinding] = []
    @Published var selected: Set<URL> = []
    @Published var scanning = false
    @Published var lastReport: String?
    @Published var includeDeveloper = true
    /// App aperte in questo momento (identificativi), per avvisare prima di pulire.
    @Published var runningApps: Set<String> = []
    /// Ultima pulizia, ripristinabile con un clic.
    @Published var lastOperationID: String?

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
        refreshRunningApps()
        let cats = CleanupCatalog.standard.filter { includeDeveloper || !$0.forDevelopers }
        Task {
            // La scansione gira fuori dal thread principale; l'interfaccia si aggiorna qui.
            let found = await Self.scan(cats, policy: policy)
            findings = found
            // Preselezionate solo le voci sicure: quelle «da controllare» le spunti tu.
            selected = Set(found.filter { $0.risk == .safe }.map(\.id))
            scanning = false
        }
    }

    nonisolated static func scan(_ cats: [CleanupCategory], policy: SafetyPolicy) async -> [CleanupFinding] {
        CleanupCatalog.scan(cats, policy: policy, appName: appName(for:), isCancelled: { Task.isCancelled })
    }

    /// Nome dell'app installata con questo identificativo (es. "com.spotify.client" → "Spotify").
    nonisolated static func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func refreshRunningApps() {
        runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Nomi delle app aperte che usano questa voce.
    func openApps(for f: CleanupFinding) -> [String] {
        f.info.bundleIDs.filter { runningApps.contains($0) }.map { Self.appName(for: $0) ?? $0 }
    }

    func clean(policy: SafetyPolicy) {
        let items = findings.filter { selected.contains($0.id) }.map(\.item)
        let report = SafeRemover(policy: policy).moveToTrash(items, kind: "Pulizia disco")
        lastOperationID = report.operationID
        lastReport = "Spostati nel Cestino \(report.moved.count) elementi (\(Bytes.format(report.bytes)))."
            + (report.skipped.isEmpty ? "" : " Saltati \(report.skipped.count) (in uso o protetti).")
            + " Lo spazio si libera svuotando il Cestino."
        findings.removeAll { report.moved.contains($0.id) }
        selected.subtract(report.moved)
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        lastReport = Restore.run(id) ?? "Questa pulizia è già stata ripristinata."
        lastOperationID = nil
        findings = []
    }
}

struct CleanupView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = CleanupModel()
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .cleanup, subtitle: "Cache, log e residui. Clicca una voce per sapere cos'è. Tutto finisce nel Cestino.")
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
                ContentUnavailableView {
                    Label("Premi «Analizza»", systemImage: Module.cleanup.icon)
                } description: {
                    Text(model.lastReport ?? "Vedrai cosa si può eliminare, e perché, prima di toccare qualsiasi cosa.")
                } actions: {
                    if model.lastOperationID != nil {
                        Button("Ripristina: rimetti tutto com'era") { model.restoreLast() }
                    }
                }
            } else {
                List {
                    ForEach(model.groups) { group in
                        let cat = group.category
                        Section {
                            ForEach(group.items) { f in
                                CleanupRow(finding: f, selected: binding(f.id), openApps: model.openApps(for: f))
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRunningApps()
        }
        .confirmationDialog("Spostare nel Cestino \(model.selected.count) elementi?",
                            isPresented: $confirming) {
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedBytes)))", role: .destructive) {
                model.clean(policy: state.policy)
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        let open = Set(model.findings.filter { model.selected.contains($0.id) }.flatMap { model.openApps(for: $0) })
        let warn = open.isEmpty ? "" : "Sono ancora aperte: \(open.sorted().joined(separator: ", ")). Chiudile prima, o alcuni file verranno saltati. "
        return warn + "Potrai recuperare tutto dal Cestino finché non lo svuoti."
    }

    private var footer: some View {
        HStack {
            if let r = model.lastReport { Text(r).font(.callout).foregroundStyle(.secondary) }
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

    private func binding(_ id: URL) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { on in if on { model.selected.insert(id) } else { model.selected.remove(id) } })
    }
}

/// Una voce della pulizia: casella, nome comprensibile, peso; cliccando si apre il dettaglio.
struct CleanupRow: View {
    let finding: CleanupFinding
    @Binding var selected: Bool
    let openApps: [String]
    @State private var expanded = false
    @State private var children: [DiskItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: $selected).labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.info.title).lineLimit(1)
                        if finding.risk == .review {
                            Badge(text: "da controllare", color: .orange)
                        }
                        if !openApps.isEmpty {
                            Badge(text: "\(openApps.joined(separator: ", ")) aperta", color: .yellow)
                        }
                    }
                    Text(finding.item.url.lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Bytes.format(finding.item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }

            if expanded { detail }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                ExplainCenter.shared.ask(finding.item.url.lastPathComponent,
                                         context: "Voce proposta dalla pulizia del disco di un Mac (categoria: \(finding.category.name)). Percorso: \(Finder.short(finding.item.url)). Dimensione: \(Bytes.format(finding.item.bytes)).")
            }
            Button("Mostra nel Finder") { Finder.reveal(finding.item.url) }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("Che cos'è", finding.info.what)
            labeled("Se la elimini", finding.info.effect)
            if !openApps.isEmpty {
                labeled("Attenzione", "\(openApps.joined(separator: ", ")) è aperta: chiudila prima di pulire, o alcuni file verranno saltati.")
            }
            Text("Percorso: \(Finder.short(finding.item.url))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)

            if finding.item.isDirectory {
                Text("Contenuto").font(.caption.bold()).foregroundStyle(.secondary)
                if let children {
                    if children.isEmpty {
                        Text("Nessuna sottocartella leggibile.").font(.caption).foregroundStyle(.secondary)
                    }
                    let top = max(1, children.first?.bytes ?? 1)
                    ForEach(children.prefix(12)) { c in
                        HStack(spacing: 8) {
                            Image(systemName: c.isDirectory ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 14)
                            Text(c.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                .frame(width: 260, alignment: .leading)
                            SizeBar(fraction: Double(c.bytes) / Double(top))
                            Text(Bytes.format(c.bytes)).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        }
                        .contextMenu { Button("Mostra nel Finder") { Finder.reveal(c.url) } }
                    }
                    if children.count > 12 {
                        Text("…e altri \(children.count - 12) elementi").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Misuro le sottocartelle…").font(.caption) }
                        .task { children = await Self.measure(finding.item.url) }
                }
            }

            Button("Mostra nel Finder") { Finder.reveal(finding.item.url) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(12)
        .background(Brand.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 28)
    }

    private func labeled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold()).foregroundStyle(Brand.accent)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    nonisolated static func measure(_ url: URL) async -> [DiskItem] {
        DiskScanner().children(of: url, isCancelled: { Task.isCancelled })
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
