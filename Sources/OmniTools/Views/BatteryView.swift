import SwiftUI
import UtilityCore

@MainActor
final class BatteryModel: ObservableObject {
    @Published var health: BatteryHealth?
    @Published var users: [EnergyUser] = []
    @Published var loading = false

    func load() {
        loading = true
        Task {
            let r = await Self.read()
            health = r.0
            users = r.1
            loading = false
        }
    }

    nonisolated static func read() async -> (BatteryHealth, [EnergyUser]) {
        (Battery.read(), Battery.energyUsers())
    }
}

struct BatteryView: View {
    @StateObject private var model = BatteryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .battery, subtitle: "Salute della batteria e app che consumano di più.")
            if let b = model.health, !b.present {
                ContentUnavailableView("Questo Mac non ha una batteria", systemImage: "powerplug",
                                       description: Text("Le app che consumano più energia sono comunque qui sotto."))
                    .frame(maxHeight: 180)
            }
            List {
                if let b = model.health, b.present {
                    Section("Salute") {
                        HStack(spacing: 30) {
                            tile("Capacità massima", b.maxCapacity.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                            tile("Cicli", b.cycles.map { "\($0)" + (b.designCycles.map { " / \($0)" } ?? "") } ?? "–")
                            tile("Condizione", b.condition ?? "–")
                            tile("Carica", b.charge.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                        }
                        .padding(.vertical, 4)
                        ForEach(Battery.advice(b)) { a in
                            Label(a.text, systemImage: a.warning ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                .foregroundStyle(a.warning ? Color.orange : Color.primary)
                        }
                    }
                    Section("Adesso") {
                        row("Stato", b.charging ? "in carica" : b.pluggedIn ? "collegato, non in carica" : "a batteria")
                        if let m = b.minutesRemaining, !b.pluggedIn { row("Autonomia stimata", "\(m / 60) h \(m % 60) min") }
                        if let w = b.watts { row(w >= 0 ? "Potenza in entrata" : "Consumo", String(format: "%.1f W", abs(w)).replacingOccurrences(of: ".", with: ",")) }
                        if let a = b.adapterWatts { row("Alimentatore", "\(a) W") }
                        if let t = b.temperature { row("Temperatura", String(format: "%.1f °C", t).replacingOccurrences(of: ".", with: ",")) }
                        if let v = b.voltage { row("Tensione", String(format: "%.2f V", v).replacingOccurrences(of: ".", with: ",")) }
                        row("Risparmio energetico", b.lowPowerMode ? "attivo" : "spento")
                        if let d = b.manufactureDate { row("Fabbricata il", d) }
                    }
                }
                Section("App che consumano di più adesso") {
                    if model.users.isEmpty && !model.loading {
                        Text("Nessuna app sta consumando molto.").foregroundStyle(.secondary)
                    }
                    ForEach(model.users) { u in
                        HStack {
                            Text(u.name)
                            Spacer()
                            Text(String(format: "%.1f", u.impact).replacingOccurrences(of: ".", with: ",")).monospacedDigit()
                                .foregroundStyle(u.impact > 20 ? Color.orange : Color.secondary)
                        }
                    }
                    Text("È l'«impatto energetico» di Monitoraggio Attività: più è alto, più l'app scarica la batteria e scalda il Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Aggiorna") { model.load() }.disabled(model.loading)
                        Button("Impostazioni Batteria") { Finder.open("x-apple.systempreferences:com.apple.Battery-Settings.extension") }
                        if model.loading { ProgressView().controlSize(.small) }
                    }
                }
            }
        }
        .onAppear { if model.health == nil { model.load() } }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
