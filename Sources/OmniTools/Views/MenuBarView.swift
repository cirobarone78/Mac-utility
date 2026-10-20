import SwiftUI
import AppKit
import UtilityCore

/// Icona della barra dei menu: monocromatica ("template"), macOS la colora secondo il tema.
struct MenuBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @AppStorage("menubar.showFree") private var showFree = false

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon)
            if showFree && monitor.snapshot.diskTotal > 0 {
                Text(Bytes.format(monitor.snapshot.diskFree)).monospacedDigit()
            }
        }
        .onAppear { monitor.start() }
    }

    static let icon: NSImage = {
        let image = Resources.bundle.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

@MainActor
final class QuickCleanModel: ObservableObject {
    @Published var findings: [CleanupFinding] = []
    @Published var scanning = false
    @Published var result: String?

    var bytes: Int64 { findings.reduce(0) { $0 + $1.item.bytes } }

    /// Solo le categorie "sicure" (si ricreano da sole): cache, log, DerivedData, Gradle, npm…
    func scan(policy: SafetyPolicy) {
        scanning = true
        result = nil
        Task {
            findings = await CleanupModel.scan(CleanupCatalog.standard.filter { $0.risk == .safe }, policy: policy)
            scanning = false
        }
    }

    func clean(policy: SafetyPolicy) {
        let r = SafeRemover(policy: policy).moveToTrash(findings.map(\.item))
        result = "\(Bytes.format(r.bytes)) nel Cestino. Svuotalo per liberare lo spazio."
        findings = []
    }
}

/// Il pannello che si apre cliccando l'icona.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var monitor: SystemMonitor
    @StateObject private var quick = QuickCleanModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menubar.showFree") private var showFree = false
    @State private var confirming = false

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text(Brand.name).font(.headline)
                Spacer()
                Text(Self.uptime(s.uptime)).font(.caption).foregroundStyle(.secondary)
            }

            meter("Disco", value: s.diskTotal > 0 ? Double(s.diskTotal - s.diskFree) / Double(s.diskTotal) : 0,
                  detail: s.diskTotal > 0 ? "\(Bytes.format(s.diskFree)) liberi" : "–")
            meter("Memoria", value: Double(s.memoryUsed) / Double(max(1, s.memoryTotal)),
                  detail: s.memoryUsed > 0 ? Bytes.format(Int64(s.memoryUsed)) : "–")
            meter("Processore", value: s.cpuUsage, detail: "\(Int(s.cpuUsage * 100))%")
            if let b = s.battery {
                meter("Batteria", value: b, detail: s.charging ? "in carica" : "\(Int(b * 100))%", invert: true)
            }

            Divider()
            quickClean
            Divider()

            HStack {
                Button("Apri OmniTools") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Menu {
                    Toggle("Mostra lo spazio libero accanto all'icona", isOn: $showFree)
                    Divider()
                    Button("Esci da OmniTools") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { monitor.start() }
    }

    @ViewBuilder
    private var quickClean: some View {
        if quick.scanning {
            HStack { ProgressView().controlSize(.small); Text("Cerco cache e log…").font(.callout) }
        } else if !quick.findings.isEmpty && confirming {
            // Conferma dentro il pannello: un dialogo separato lo farebbe chiudere.
            VStack(alignment: .leading, spacing: 8) {
                Text("Spostare nel Cestino \(Bytes.format(quick.bytes)) di cache e log? Le app li ricreano da sole.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Annulla") { confirming = false }
                    Spacer()
                    Button("Sposta nel Cestino", role: .destructive) {
                        quick.clean(policy: state.policy)
                        confirming = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if !quick.findings.isEmpty {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(Bytes.format(quick.bytes)) da liberare").font(.callout.bold())
                    Text("cache, log, residui di sviluppo").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pulisci…") { confirming = true }.buttonStyle(.borderedProminent)
            }
        } else {
            HStack {
                Text(quick.result ?? "Pulizia rapida").font(.callout)
                    .foregroundStyle(quick.result == nil ? .primary : .secondary)
                Spacer()
                Button("Analizza") { quick.scan(policy: state.policy) }
            }
        }
    }

    private func meter(_ title: String, value: Double, detail: String, invert: Bool = false) -> some View {
        let level = invert ? 1 - value : value
        let color: Color = level > 0.9 ? .red : level > 0.75 ? .orange : Brand.accent
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 6)
        }
    }

    static func uptime(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return "acceso da " + (f.string(from: t) ?? "–")
    }
}
