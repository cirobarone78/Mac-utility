import SwiftUI
import UtilityCore

@MainActor
final class BackupModel: ObservableObject {
    @Published var report: BackupReport?
    @Published var loading = false
    @Published var message: String?

    func load() {
        loading = true
        Task {
            report = await Self.check()
            loading = false
        }
    }

    nonisolated static func check() async -> BackupReport { BackupCheck.run() }
    nonisolated static func start() async -> Bool { BackupCheck.startNow() }

    func startNow() {
        Task {
            let ok = await Self.start()
            message = ok ? "Backup avviato: Time Machine lavora in sottofondo." :
                "Non è partito: controlla che il disco di backup sia collegato."
            load()
        }
    }
}

struct BackupView: View {
    @StateObject private var model = BackupModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .backup, subtitle: "Controlla che Time Machine stia davvero salvando i tuoi file.")
            HStack {
                Button("Controlla di nuovo") { model.load() }.disabled(model.loading)
                Button("Esegui un backup adesso") { model.startNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.report?.destinations.isEmpty ?? true || model.report?.running == true)
                Button("Impostazioni di Time Machine") {
                    Finder.open("x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if let m = model.message {
                Text(m).font(.callout).padding(.horizontal, 20).padding(.bottom, 8)
            }

            if model.loading && model.report == nil {
                ProgressView("Controllo…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = model.report {
                List {
                    if r.running {
                        Section { Label("Backup in corso in questo momento.", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Section("Stato") {
                        ForEach(r.findings) { f in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(f.level)).foregroundStyle(color(f.level)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.title).font(.body.bold())
                                    Text(f.detail).font(.callout).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if r.unreadable {
                            Button("Apri Accesso completo al disco") { Finder.open(Finder.fullDiskAccessSettings) }
                        }
                    }
                    if !r.destinations.isEmpty {
                        Section("Dischi di backup") {
                            ForEach(r.destinations) { d in
                                HStack {
                                    Image(systemName: "externaldrive")
                                    VStack(alignment: .leading) {
                                        Text(d.name)
                                        if let last = d.lastBackup {
                                            Text("Ultimo backup: " + last.formatted(date: .long, time: .shortened))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let free = d.bytesAvailable {
                                        Text("Liberi: \(Bytes.format(free))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { if model.report == nil { model.load() } }
    }

    private func icon(_ l: BackupReport.Level) -> String {
        switch l {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    private func color(_ l: BackupReport.Level) -> Color {
        switch l {
        case .ok: Brand.accent
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}
