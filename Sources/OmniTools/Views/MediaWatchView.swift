import SwiftUI
import UtilityCore

struct MediaWatchView: View {
    @ObservedObject private var monitor = MediaMonitor.shared
    @AppStorage("media.notify") private var notify = true
    @State private var log: [MediaEvent] = MediaLog.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .mediaWatch,
                         subtitle: "Ti avvisa quando un'app accende la fotocamera o il microfono e tiene il registro.")
            HStack(spacing: 30) {
                status("Fotocamera", on: monitor.state.cameraOn, apps: monitor.cameraApps, icon: "video.fill")
                status("Microfono", on: monitor.state.micOn, apps: monitor.micApps, icon: "mic.fill")
                Spacer()
            }
            .padding(.horizontal, 20).padding(.bottom, 10)
            HStack {
                Toggle("Notifica quando si accendono", isOn: $notify)
                    .onChange(of: notify) { if notify { Notifier.requestPermission() } }
                Spacer()
                Button("Aggiorna il registro") { log = MediaLog.load() }
                Button("Svuota il registro") { MediaLog.clear(); log = [] }.disabled(log.isEmpty)
            }
            .padding(.horizontal, 20).padding(.bottom, 6)
            Text("Per il microfono macOS indica l'app esatta. Per la fotocamera no: OmniTools indica le app aperte che hanno il permesso di usarla. Il pallino verde (fotocamera) o arancione (microfono) di macOS in alto resta il segnale più affidabile.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 8)
            if log.isEmpty {
                ContentUnavailableView("Nessun evento registrato", systemImage: "video.slash",
                                       description: Text("Il controllo è attivo finché OmniTools è aperto (anche solo nella barra dei menu)."))
            } else {
                Table(log) {
                    TableColumn("Quando") { e in Text(e.date.formatted(date: .abbreviated, time: .standard)) }.width(170)
                    TableColumn("Dispositivo") { e in Text(e.device.rawValue) }.width(100)
                    TableColumn("") { e in Text(e.on ? "acceso" : "spento").foregroundStyle(e.on ? Color.orange : Color.secondary) }.width(70)
                    TableColumn("App") { e in Text(e.apps.isEmpty ? "–" : e.apps.joined(separator: ", ")) }
                }
            }
        }
        .onChange(of: monitor.state) { log = MediaLog.load() }
    }

    private func status(_ title: String, on: Bool, apps: [String], icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(on ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(on ? (apps.isEmpty ? "in uso" : "in uso: " + apps.joined(separator: ", ")) : "spento")
                    .font(.callout).foregroundStyle(on ? Color.orange : Color.secondary)
            }
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
    }
}
