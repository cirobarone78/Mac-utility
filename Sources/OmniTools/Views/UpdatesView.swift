import SwiftUI
import AppKit
import UtilityCore

@MainActor
final class UpdatesModel: ObservableObject {
    @Published var report: UpdateReport?
    @Published var brew: [AppUpdate] = []
    @Published var system: [AppUpdate]?
    @Published var running = false
    @Published var checkingSystem = false
    @Published var status = ""
    @Published var copied: String?

    let hasBrew = UpdateChecker.brewPath != nil

    func run() {
        running = true
        status = "Leggo le app installate…"
        let box = WeakRef(self)
        Task {
            let apps = await Self.apps()
            report = await UpdateChecker.check(apps: apps) { msg in Task { @MainActor in box.value?.status = msg } }
            if hasBrew {
                status = "Controllo Homebrew…"
                brew = await Self.brewUpdates()
            }
            running = false
        }
    }

    nonisolated static func apps() async -> [InstalledApp] { AppUninstaller.installedApps(withSizes: false) }
    nonisolated static func brewUpdates() async -> [AppUpdate] { UpdateChecker.homebrew() }
    nonisolated static func systemUpdates() async -> [AppUpdate] { UpdateChecker.macOS() }

    func checkSystem() {
        checkingSystem = true
        Task {
            system = await Self.systemUpdates()
            checkingSystem = false
        }
    }

    func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = command
    }
}

struct UpdatesView: View {
    @StateObject private var model = UpdatesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .updates,
                         subtitle: "Le app non aggiornate sono la porta d'ingresso più usata dai malware. Qui vedi quali sono indietro.")
            HStack {
                Button(model.report == nil ? "Controlla gli aggiornamenti" : "Controlla di nuovo") { model.run() }
                    .buttonStyle(.borderedProminent).disabled(model.running)
                Button("Aggiornamenti di macOS") { model.checkSystem() }.disabled(model.checkingSystem)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if model.running {
                ProgressView(model.status).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.report == nil && model.system == nil && !model.checkingSystem {
                ContentUnavailableView("Premi «Controlla gli aggiornamenti»", systemImage: Module.updates.icon,
                                       description: Text("Chiede la versione più recente all'App Store e ai siti delle app. Non installa nulla da solo."))
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if model.checkingSystem || model.system != nil {
                Section("macOS") {
                    if model.checkingSystem {
                        HStack { ProgressView().controlSize(.small); Text("Chiedo ad Apple (può volerci un minuto)…") }
                    } else if let sys = model.system, sys.isEmpty {
                        Label("macOS è aggiornato.", systemImage: "checkmark.circle").foregroundStyle(Brand.accent)
                    } else if let sys = model.system {
                        ForEach(sys) { u in
                            HStack {
                                Text(u.name)
                                Spacer()
                                Button("Apri Aggiornamento software") {
                                    Finder.open("x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
                                }
                            }
                        }
                    }
                }
            }
            if let r = model.report {
                Section("App da aggiornare (\(r.updates.count))") {
                    if r.updates.isEmpty {
                        Label("Tutte le app controllate sono aggiornate (\(r.checked) controllate).", systemImage: "checkmark.circle")
                            .foregroundStyle(Brand.accent)
                    }
                    ForEach(r.updates) { u in updateRow(u) }
                }
                if model.hasBrew {
                    Section("Homebrew (\(model.brew.count))") {
                        if model.brew.isEmpty {
                            Text("Nessun pacchetto indietro rispetto all'ultimo «brew update».").foregroundStyle(.secondary)
                        }
                        ForEach(model.brew) { u in updateRow(u) }
                        if let c = model.copied {
                            Text("Copiato: \(c) — incollalo nel Terminale.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !r.unknown.isEmpty {
                    Section {
                        DisclosureGroup("Da controllare a mano (\(r.unknown.count))") {
                            Text("Queste app non dicono da dove si aggiornano. Di solito hanno la voce «Controlla aggiornamenti» nel menu con il loro nome.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(r.unknown) { app in
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 18, height: 18)
                                    Text(app.name)
                                    Text(app.version).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Apri") { NSWorkspace.shared.open(app.url) }
                                }
                            }
                        }
                    }
                }
                if !r.failed.isEmpty {
                    Section("Non verificabili") {
                        Text(r.failed.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func updateRow(_ u: AppUpdate) -> some View {
        HStack(spacing: 10) {
            if let app = u.appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "shippingbox").frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(u.name)
                Text("\(u.installed) → \(u.available) · \(u.source.rawValue)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch u.source {
            case .appStore:
                if let store = u.storeURL { Button("Apri nell'App Store") { NSWorkspace.shared.open(store) } }
            case .sparkle:
                if let app = u.appURL {
                    Button("Apri l'app") { NSWorkspace.shared.open(app) }
                        .help("L'app propone da sola l'aggiornamento, oppure dal menu con il suo nome › «Controlla aggiornamenti».")
                }
            case .homebrew:
                if let c = u.command { Button("Copia il comando") { model.copy(c) } }
            case .macOS:
                EmptyView()
            }
        }
    }
}
