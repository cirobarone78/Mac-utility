import SwiftUI
import UtilityCore

struct MaintenanceView: View {
    @ObservedObject private var m = Maintenance.shared
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .maintenance,
                         subtitle: "OmniTools controlla il Mac da solo e ti avvisa. Non cancella né installa mai nulla senza di te.")
            Form {
                Section("Impostazioni") {
                    Toggle("Controllo automatico", isOn: $m.enabled)
                        .onChange(of: m.enabled) { if m.enabled { Notifier.requestPermission() } }
                    Picker("Frequenza", selection: $m.frequencyDays) {
                        ForEach(Maintenance.Frequency.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .disabled(!m.enabled)
                    Toggle("Controlla anche gli aggiornamenti delle app (usa internet)", isOn: $m.checkUpdates)
                    Toggle("Apri OmniTools all'accesso (solo nella barra dei menu)",
                           isOn: Binding(get: { m.launchAtLogin }, set: { m.launchAtLogin = $0 }))
                    if let next = m.nextRun {
                        Text("Prossimo controllo: " + next.formatted(date: .abbreviated, time: .shortened)
                             + ". Funziona finché OmniTools è aperto, anche solo come icona nella barra dei menu.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(m.running ? "Controllo in corso…" : "Esegui adesso") {
                        Task { await m.run(notify: false) }
                    }
                    .disabled(m.running)
                }
                if let r = m.last {
                    Section("Ultimo controllo: " + r.date.formatted(date: .abbreviated, time: .shortened)) {
                        line("Spazio da liberare (cache e log)", Bytes.format(r.cleanableBytes), .cleanup,
                             warn: r.cleanableBytes > 1_000_000_000)
                        line("App da aggiornare", r.updates.isEmpty ? "nessuna" : "\(r.updates.count): " + r.updates.prefix(5).joined(separator: ", "),
                             .updates, warn: !r.updates.isEmpty)
                        line("Backup", !r.backupConfigured ? "Time Machine non configurato"
                             : r.backupDays.map { $0 == 0 ? "fatto oggi" : "ultimo \($0) giorni fa" } ?? "data sconosciuta",
                             .backup, warn: !r.backupConfigured || (r.backupDays ?? 0) > 7)
                        if let free = r.diskFree {
                            line("Spazio libero sul disco", Bytes.format(free), .space, warn: free < 20_000_000_000)
                        }
                        if let c = r.batteryCapacity {
                            line("Batteria", "capacità al \(Int((c * 100).rounded()))%", .battery, warn: c < 0.8)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func line(_ title: String, _ value: String, _ module: Module, warn: Bool) -> some View {
        HStack {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(warn ? Color.orange : Brand.accent)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Button("Apri") { state.selection = module }.buttonStyle(.link)
        }
    }
}
