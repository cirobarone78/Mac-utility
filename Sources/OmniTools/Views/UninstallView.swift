import SwiftUI
import AppKit
import UtilityCore

@MainActor
final class UninstallModel: ObservableObject {
    enum Tab: String, CaseIterable { case apps = "App installate", orphans = "Avanzi di app già cancellate" }
    enum Sort: String, CaseIterable { case size = "Dimensione", name = "Nome", used = "Ultimo uso" }

    @Published var tab: Tab = .apps
    @Published var sort: Sort = .size
    @Published var search = ""
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var selectedID: URL?
    @Published var leftovers: [Leftover] = []
    @Published var chosen: Set<URL> = []
    @Published var loadingLeftovers = false
    @Published var orphans: [OrphanGroup] = []
    @Published var orphanChosen: Set<URL> = []
    @Published var scanningOrphans = false
    @Published var orphansDone = false
    @Published var message: String?
    @Published var lastOperationID: String?

    var selected: InstalledApp? { apps.first { $0.url == selectedID } }

    var visibleApps: [InstalledApp] {
        let list = search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
        switch sort {
        case .size: return list.sorted { $0.bytes > $1.bytes }
        case .name: return list
        case .used: return list.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var chosenBytes: Int64 {
        (selected?.bytes ?? 0) + leftovers.filter { chosen.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    var orphanChosenBytes: Int64 {
        orphans.flatMap(\.items).filter { orphanChosen.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    func load() {
        guard apps.isEmpty, !loading else { return }
        loading = true
        Task {
            apps = await Self.installed()
            loading = false
        }
    }

    nonisolated static func installed() async -> [InstalledApp] {
        AppUninstaller.installedApps(isCancelled: { Task.isCancelled })
    }

    func select(_ id: URL?, policy: SafetyPolicy) {
        selectedID = id
        leftovers = []
        chosen = []
        guard let app = selected else { return }
        loadingLeftovers = true
        Task {
            let found = await Self.leftovers(app, policy: policy)
            guard selectedID == app.url else { return }
            loadingLeftovers = false
            leftovers = found
            // Preselezionati solo quelli sicuramente dell'app: i «da controllare» li spunti tu.
            chosen = Set(found.filter { !$0.risky }.map(\.url))
        }
    }

    nonisolated static func leftovers(_ app: InstalledApp, policy: SafetyPolicy) async -> [Leftover] {
        AppUninstaller.leftovers(of: app, policy: policy)
    }

    /// L'app è aperta in questo momento?
    func running(_ app: InstalledApp) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first
    }

    /// Motivo per cui l'app non si può disinstallare da qui, se c'è.
    func blocked(_ app: InstalledApp) -> String? {
        if app.isApple { return "È un'app di Apple: fa parte di macOS o si toglie dall'App Store." }
        if app.bundleID == AppUninstaller.selfBundleID { return "È OmniTools stessa." }
        return nil
    }

    func uninstall(policy: SafetyPolicy) {
        guard let app = selected else { return }
        var items = [DiskItem(url: app.url, bytes: app.bytes, isDirectory: true)]
        items += leftovers.filter { chosen.contains($0.url) }
            .map { DiskItem(url: $0.url, bytes: $0.bytes, isDirectory: true, modified: $0.modified) }
        let report = SafeRemover(policy: policy).moveToTrash(items, kind: "Disinstallazione")
        lastOperationID = report.operationID
        if report.moved.contains(app.url) {
            message = "\(app.name) è nel Cestino insieme a \(report.moved.count - 1) file che aveva lasciato (\(Bytes.format(report.bytes)))."
                + (report.skipped.isEmpty ? "" : " Saltati \(report.skipped.count) elementi.")
            apps.removeAll { $0.url == app.url }
            selectedID = nil
            leftovers = []
        } else {
            message = "Non è stato possibile spostare \(app.name) nel Cestino: "
                + (report.skipped.first { $0.url == app.url }?.reason ?? "errore sconosciuto")
                + ". Prova a trascinarla nel Cestino dal Finder."
        }
    }

    func scanOrphans(policy: SafetyPolicy) {
        scanningOrphans = true
        let known = apps
        Task {
            let list = known.isEmpty ? await Self.installed() : known
            if apps.isEmpty { apps = list }
            orphans = await Self.findOrphans(list, policy: policy)
            orphanChosen = []
            scanningOrphans = false
            orphansDone = true
        }
    }

    nonisolated static func findOrphans(_ apps: [InstalledApp], policy: SafetyPolicy) async -> [OrphanGroup] {
        AppUninstaller.orphans(apps: apps, policy: policy, isCancelled: { Task.isCancelled })
    }

    func removeOrphans(policy: SafetyPolicy) {
        let items = orphans.flatMap(\.items).filter { orphanChosen.contains($0.url) }
            .map { DiskItem(url: $0.url, bytes: $0.bytes, isDirectory: true, modified: $0.modified) }
        let report = SafeRemover(policy: policy).moveToTrash(items, kind: "Disinstallazione")
        lastOperationID = report.operationID
        message = "Spostati nel Cestino \(report.moved.count) avanzi (\(Bytes.format(report.bytes)))."
            + (report.skipped.isEmpty ? "" : " Saltati \(report.skipped.count).")
        let moved = Set(report.moved)
        orphans = orphans.compactMap { g in
            let rest = g.items.filter { !moved.contains($0.url) }
            return rest.isEmpty ? nil : OrphanGroup(bundleID: g.bundleID, items: rest)
        }
        orphanChosen.subtract(moved)
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = Restore.run(id)
        lastOperationID = nil
        apps = []
        load()
    }
}

struct UninstallView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = UninstallModel()
    @State private var confirm = false
    @State private var confirmOrphans = false
    @State private var askQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .uninstall,
                         subtitle: "Toglie un'app insieme ai file che lascia nella Libreria. Tutto passa dal Cestino.")
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(UninstallModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if let m = model.message {
                HStack {
                    Text(m).font(.callout)
                    Spacer()
                    if model.lastOperationID != nil {
                        Button("Ripristina") { model.restoreLast() }
                    }
                }
                .padding(10).background(Brand.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 8)
            }

            switch model.tab {
            case .apps: appsTab
            case .orphans: orphansTab
            }
        }
        .onAppear { model.load() }
    }

    // MARK: - App installate

    private var appsTab: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    TextField("Cerca", text: $model.search).textFieldStyle(.roundedBorder)
                    Picker("", selection: $model.sort) {
                        ForEach(UninstallModel.Sort.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 120)
                }
                .padding(.horizontal, 10)
                if model.loading {
                    ProgressView("Leggo le app…").frame(maxHeight: .infinity)
                } else {
                    List(model.visibleApps, selection: Binding(get: { model.selectedID },
                                                              set: { model.select($0, policy: state.policy) })) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(usedText(app.lastUsed)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Bytes.format(app.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .tag(app.url)
                    }
                }
            }
            .frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.bold())
                        Text("Versione \(app.version) · \(app.bundleID)").font(.caption).foregroundStyle(.secondary)
                        Text(usedText(app.lastUsed)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let why = model.blocked(app) {
                    Label(why, systemImage: "lock").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Text("File che l'app ha lasciato fuori dal suo pacchetto").font(.headline)
                    if model.loadingLeftovers {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if model.leftovers.isEmpty {
                        Text("Nessuno: si toglie solo l'app.").foregroundStyle(.secondary)
                    }
                    List(model.leftovers) { l in leftoverRow(l, chosen: $model.chosen) }
                        .frame(minHeight: 120)
                    HStack {
                        Text("Totale: \(Bytes.format(model.chosenBytes))").font(.callout.monospacedDigit())
                        Spacer()
                        Button("Mostra l'app nel Finder") { Finder.reveal(app.url) }
                        Button("Disinstalla \(app.name)") {
                            if model.running(app) != nil { askQuit = true } else { confirm = true }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
            .confirmationDialog("Disinstallare \(app.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Sposta nel Cestino", role: .destructive) { model.uninstall(policy: state.policy) }
            } message: {
                Text(confirmText(app))
            }
            .alert("\(app.name) è aperta", isPresented: $askQuit) {
                Button("Chiudi \(app.name)") { model.running(app)?.terminate() }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Chiudila prima di disinstallarla, poi premi di nuovo «Disinstalla».")
            }
        } else {
            ContentUnavailableView("Scegli un'app", systemImage: Module.uninstall.icon,
                                   description: Text("Vedrai l'elenco preciso di cosa verrebbe spostato nel Cestino prima di confermare."))
        }
    }

    private func confirmText(_ app: InstalledApp) -> String {
        let list = model.leftovers.filter { model.chosen.contains($0.url) }
        var lines = ["• \(Finder.short(app.url)) (\(Bytes.format(app.bytes)))"]
        lines += list.prefix(12).map { "• \(Finder.short($0.url)) (\(Bytes.format($0.bytes)))" }
        if list.count > 12 { lines.append("…e altri \(list.count - 12)") }
        var text = lines.joined(separator: "\n")
        if list.contains(where: \.needsAdmin) { text += "\n\nAlcuni file sono condivisi da tutti gli utenti: il Finder ti chiederà la password." }
        if app.fromAppStore { text += "\n\nL'app viene dall'App Store: puoi riscaricarla quando vuoi." }
        return text + "\n\nTutto resta recuperabile con «Ripristina» finché non svuoti il Cestino."
    }

    // MARK: - Avanzi

    private var orphansTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.orphansDone ? "Cerca di nuovo" : "Cerca avanzi") { model.scanOrphans(policy: state.policy) }
                    .buttonStyle(.borderedProminent).disabled(model.scanningOrphans)
                if !model.orphanChosen.isEmpty {
                    Button("Sposta nel Cestino (\(Bytes.format(model.orphanChosenBytes)))") { confirmOrphans = true }
                }
                Spacer()
            }
            Text("File nella Libreria di app che non risultano più installate. Si ignorano quelli di Apple e quelli usati nell'ultimo mese. Nessuno è preselezionato: controlla il nome prima di spuntare (tasto destro › «Chiedi all'AI cos'è»).")
                .font(.caption).foregroundStyle(.secondary)
            if model.scanningOrphans {
                ProgressView("Cerco…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.orphansDone && model.orphans.isEmpty {
                ContentUnavailableView("Nessun avanzo trovato", systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(model.orphans) { g in
                        Section {
                            ForEach(g.items) { l in leftoverRow(l, chosen: $model.orphanChosen) }
                        } header: {
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { g.items.allSatisfy { model.orphanChosen.contains($0.url) } },
                                    set: { on in
                                        let urls = g.items.map(\.url)
                                        if on { model.orphanChosen.formUnion(urls) } else { model.orphanChosen.subtract(urls) }
                                    })) {
                                    Text(g.bundleID).font(.callout.bold())
                                }
                                Spacer()
                                Text(Bytes.format(g.bytes)).font(.caption.monospacedDigit())
                                if let d = g.lastModified { Text("ultimo uso " + d.formatted(date: .abbreviated, time: .omitted)).font(.caption) }
                            }
                            .explainMenu(g.bundleID, context: "Avanzo nella Libreria del Mac di un'app che non risulta più installata (identificativo \(g.bundleID)). Elementi: " + g.items.map(\.place).joined(separator: ", "))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .confirmationDialog("Spostare nel Cestino \(model.orphanChosen.count) avanzi?", isPresented: $confirmOrphans,
                            titleVisibility: .visible) {
            Button("Sposta nel Cestino", role: .destructive) { model.removeOrphans(policy: state.policy) }
        } message: {
            Text("Tutto resta recuperabile con «Ripristina» finché non svuoti il Cestino.")
        }
    }

    // MARK: - Righe

    private func leftoverRow(_ l: Leftover, chosen: Binding<Set<URL>>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(get: { chosen.wrappedValue.contains(l.url) },
                                     set: { if $0 { chosen.wrappedValue.insert(l.url) } else { chosen.wrappedValue.remove(l.url) } }))
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(l.url.lastPathComponent).lineLimit(1)
                    Badge(text: l.place, color: .secondary)
                    if l.risky { Badge(text: "da controllare", color: .orange) }
                    if l.needsAdmin { Badge(text: "password", color: .blue) }
                }
                Text(Finder.short(l.url)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text(l.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Bytes.format(l.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                ExplainCenter.shared.ask(l.url.lastPathComponent,
                                         context: "File lasciato da un'app nella Libreria del Mac (\(l.place)). Percorso: \(Finder.short(l.url)). Motivo: \(l.reason).")
            }
            Button("Mostra nel Finder") { Finder.reveal(l.url) }
        }
    }

    private func usedText(_ d: Date?) -> String {
        guard let d else { return "uso sconosciuto" }
        let days = Int(Date().timeIntervalSince(d) / 86_400)
        switch days {
        case ..<1: return "usata oggi"
        case 1: return "usata ieri"
        case ..<60: return "usata \(days) giorni fa"
        default: return "non usata da \(days / 30) mesi"
        }
    }
}
