import SwiftUI
import AppKit
import UtilityCore

@MainActor
final class PrivacyModel: ObservableObject {
    enum Tab: String, CaseIterable { case permissions = "Permessi delle app", browsers = "Browser" }

    @Published var tab: Tab = .permissions
    // Permessi
    @Published var grants: [PrivacyGrant] = []
    @Published var needsFDA = false
    @Published var showDenied = false
    @Published var loadingGrants = false
    // Browser
    @Published var browsers: [BrowserData] = []
    @Published var browserID: String?
    @Published var chosen: Set<String> = []
    @Published var search = ""
    @Published var history = true
    @Published var cookies = true
    @Published var loadingBrowsers = false
    @Published var message: String?
    @Published var lastOperationID: String?

    func loadGrants() {
        loadingGrants = true
        Task {
            let r = await Self.readGrants()
            grants = r.grants
            needsFDA = r.needsFullDiskAccess
            loadingGrants = false
        }
    }

    nonisolated static func readGrants() async -> PrivacyPermissions.Result { PrivacyPermissions.list() }

    var visibleGrants: [PrivacyGrant] { grants.filter { showDenied || $0.allowed } }

    struct GrantGroup: Identifiable {
        let service: String
        let items: [PrivacyGrant]
        var id: String { service }
    }

    /// Servizi in ordine, con i loro permessi.
    var grantGroups: [GrantGroup] {
        var order: [String] = []
        var map: [String: [PrivacyGrant]] = [:]
        for g in visibleGrants {
            if map[g.service] == nil { order.append(g.service) }
            map[g.service, default: []].append(g)
        }
        return order.map { GrantGroup(service: $0, items: map[$0] ?? []) }
    }

    func revoke(_ g: PrivacyGrant) {
        if PrivacyPermissions.revoke(g) {
            message = "Permesso «\(g.serviceName)» tolto a \(Self.appName(g)). L'app lo chiederà di nuovo se le serve."
            loadGrants()
        } else {
            message = "macOS non permette di toglierlo da qui: si apre la pagina giusta di Impostazioni."
            if let url = PrivacyPermissions.settingsURL(for: g.service) { NSWorkspace.shared.open(url) }
        }
    }

    static func appName(_ g: PrivacyGrant) -> String {
        if g.clientIsPath { return (g.client as NSString).lastPathComponent }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: g.client) else { return g.client }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func appIcon(_ g: PrivacyGrant) -> NSImage? {
        if g.clientIsPath { return NSWorkspace.shared.icon(forFile: g.client) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: g.client) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Browser

    var browser: BrowserData? { browsers.first { $0.id == browserID } }

    var visibleSites: [BrowserSite] {
        guard let b = browser else { return [] }
        return search.isEmpty ? b.sites : b.sites.filter { $0.site.localizedCaseInsensitiveContains(search) }
    }

    func loadBrowsers() {
        loadingBrowsers = true
        Task {
            browsers = await Self.scanBrowsers()
            if browser == nil { browserID = browsers.first?.id }
            chosen = []
            loadingBrowsers = false
        }
    }

    nonisolated static func scanBrowsers() async -> [BrowserData] { BrowserCleaner.scan() }

    func isRunning(_ b: BrowserData) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID).first
    }

    /// Spunta i siti non visitati negli ultimi `months` mesi.
    func selectOlder(months: Int) {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        chosen = Set((browser?.sites ?? []).filter { ($0.lastVisit ?? .distantPast) < cutoff }.map(\.site))
    }

    func clean() {
        guard let b = browser else { return }
        let r = BrowserCleaner.clean(b, sites: chosen, history: history, cookies: cookies)
        lastOperationID = r.operationID
        var text = "\(b.name): cancellate \(r.historyRows) voci di cronologia"
        if b.supportsCookies && cookies { text += " e \(r.cookieRows) cookie" }
        text += "."
        if !r.errors.isEmpty { text += " Problemi: " + r.errors.joined(separator: "; ") }
        if b.engine == .safari { text += " Se la cronologia di Safari si sincronizza con iCloud, alcuni siti possono tornare dagli altri dispositivi." }
        message = text
        loadBrowsers()
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = Restore.run(id)
        lastOperationID = nil
        loadBrowsers()
    }
}

struct PrivacyView: View {
    @StateObject private var model = PrivacyModel()
    @State private var revoking: PrivacyGrant?
    @State private var confirmClean = false
    @State private var askQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .privacy,
                         subtitle: "Chi può usare fotocamera, microfono e i tuoi file, e cosa ricordano i browser.")
            Picker("", selection: $model.tab) {
                ForEach(PrivacyModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            .padding(.horizontal, 20).padding(.bottom, 8)

            if let m = model.message {
                HStack {
                    Text(m).font(.callout)
                    Spacer()
                    if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() } }
                }
                .padding(10).background(Brand.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 8)
            }

            switch model.tab {
            case .permissions: permissions
            case .browsers: browsers
            }
        }
        .onAppear {
            if model.grants.isEmpty { model.loadGrants() }
            if model.browsers.isEmpty { model.loadBrowsers() }
        }
    }

    // MARK: - Permessi

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Mostra anche i permessi negati", isOn: $model.showDenied)
                Spacer()
                Button("Aggiorna") { model.loadGrants() }
            }
            .padding(.horizontal, 20)
            if model.needsFDA {
                HStack {
                    Text("Per leggere i permessi OmniTools ha bisogno di Accesso completo al disco.")
                    Button("Apri Impostazioni") { Finder.open(Finder.fullDiskAccessSettings) }
                }
                .padding(.horizontal, 20)
            }
            List {
                ForEach(model.grantGroups) { group in
                    Section {
                        ForEach(group.items) { g in grantRow(g) }
                    } header: {
                        HStack {
                            Text(PrivacyPermissions.names[group.service]?.name ?? group.service)
                            if PrivacyPermissions.sensitive.contains(group.service) { Badge(text: "delicato", color: .orange) }
                            Spacer()
                            Button("Impostazioni") {
                                if let url = PrivacyPermissions.settingsURL(for: group.service) { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .confirmationDialog("Togliere il permesso?", isPresented: Binding(get: { revoking != nil },
                                                                         set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { g in
            Button("Togli «\(g.serviceName)» a \(PrivacyModel.appName(g))", role: .destructive) { model.revoke(g) }
        } message: { _ in
            Text("L'app non potrà più usarlo finché non glielo concedi di nuovo (te lo chiederà la prossima volta che le serve).")
        }
    }

    private func grantRow(_ g: PrivacyGrant) -> some View {
        HStack(spacing: 10) {
            if let icon = PrivacyModel.appIcon(g) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app").frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(PrivacyModel.appName(g))
                Text(g.client).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let d = g.modified {
                Text(d.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Badge(text: g.allowed ? "consentito" : "negato", color: g.allowed ? Brand.accent : .secondary)
            if g.allowed {
                Button("Togli") { revoking = g }
                    .help(g.systemWide || g.clientIsPath ? "Si toglie da Impostazioni: si apre la pagina giusta." : "")
            }
        }
        .contextMenu {
            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                ExplainCenter.shared.ask(PrivacyModel.appName(g),
                                         context: "App con il permesso «\(g.serviceName)» su macOS. Identificativo: \(g.client). È normale che ce l'abbia?")
            }
        }
    }

    // MARK: - Browser

    private var browsers: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.loadingBrowsers && model.browsers.isEmpty {
                ProgressView("Leggo i browser…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.browsers.isEmpty {
                ContentUnavailableView("Nessun browser trovato", systemImage: "safari")
            } else {
                HStack {
                    Picker("Browser", selection: $model.browserID) {
                        ForEach(model.browsers) { b in Text(b.name).tag(Optional(b.id)) }
                    }
                    .frame(maxWidth: 260)
                    .onChange(of: model.browserID) { model.chosen = [] }
                    TextField("Cerca un sito", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Spacer()
                    Menu("Seleziona") {
                        Button("Non visitati da 6 mesi") { model.selectOlder(months: 6) }
                        Button("Non visitati da 1 anno") { model.selectOlder(months: 12) }
                        Button("Tutti quelli visibili") { model.chosen.formUnion(model.visibleSites.map(\.site)) }
                        Button("Nessuno") { model.chosen = [] }
                    }
                    .frame(width: 110)
                }
                .padding(.horizontal, 20)

                if let b = model.browser {
                    if b.unreadable {
                        HStack {
                            Text("I dati di \(b.name) non sono leggibili: serve Accesso completo al disco.")
                            Button("Apri Impostazioni") { Finder.open(Finder.fullDiskAccessSettings) }
                        }
                        .padding(.horizontal, 20)
                    }
                    Table(model.visibleSites) {
                        TableColumn("") { s in
                            Toggle("", isOn: Binding(get: { model.chosen.contains(s.site) },
                                                     set: { if $0 { model.chosen.insert(s.site) } else { model.chosen.remove(s.site) } }))
                                .labelsHidden()
                        }
                        .width(24)
                        TableColumn("Sito") { s in Text(s.site) }
                        TableColumn("Visite") { s in Text("\(s.visits)").monospacedDigit() }.width(70)
                        TableColumn("Cookie") { s in Text(b.supportsCookies ? "\(s.cookies)" : "–").monospacedDigit() }.width(70)
                        TableColumn("Ultima visita") { s in
                            Text(s.lastVisit?.formatted(date: .abbreviated, time: .omitted) ?? "–")
                        }
                        .width(120)
                    }
                    HStack {
                        Toggle("Cronologia", isOn: $model.history)
                        Toggle("Cookie e accessi", isOn: $model.cookies).disabled(!b.supportsCookies)
                        Spacer()
                        Button("Cancella i dati di \(model.chosen.count) siti") {
                            if model.isRunning(b) != nil { askQuit = true } else { confirmClean = true }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.chosen.isEmpty || !(model.history || (model.cookies && b.supportsCookies)))
                    }
                    .padding(.horizontal, 20)
                    Text(b.supportsCookies
                         ? "Cancellare i cookie di un sito ti fa uscire dal tuo account su quel sito. Tieni quelli che usi."
                         : "I cookie di Safari si tolgono da Safari › Impostazioni › Privacy › Gestisci dati siti web.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                        .alert("\(b.name) è aperto", isPresented: $askQuit) {
                            Button("Chiudi \(b.name)") { model.isRunning(b)?.terminate() }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("Il browser va chiuso prima di modificare i suoi dati. Chiudilo, poi premi di nuovo il pulsante.")
                        }
                        .confirmationDialog("Cancellare i dati di \(model.chosen.count) siti da \(b.name)?",
                                            isPresented: $confirmClean, titleVisibility: .visible) {
                            Button("Cancella", role: .destructive) { model.clean() }
                        } message: {
                            Text(model.chosen.sorted().prefix(15).joined(separator: ", ")
                                 + (model.chosen.count > 15 ? "…" : "")
                                 + "\n\nPrima di modificarli, i file originali del browser vanno nel Cestino: «Ripristina» rimette tutto com'era.")
                        }
                }
            }
        }
    }
}
