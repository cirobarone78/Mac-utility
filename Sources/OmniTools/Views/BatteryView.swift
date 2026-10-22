import SwiftUI
import UtilityCore

@MainActor
final class BatteryModel: ObservableObject {
    @Published var health: BatteryHealth?
    @Published var users: [EnergyUser] = []
    @Published var habits = ChargeHabits.summary()
    @Published var loading = false

    func load() {
        loading = true
        Task {
            let r = await Self.read()
            health = r.0
            users = r.1
            ChargeHabits.record(r.0)
            habits = ChargeHabits.summary()
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
                    Section("Limite di carica") {
                        chargeLimit(b)
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

    @ViewBuilder private func chargeLimit(_ b: BatteryHealth) -> some View {
        switch b.limitStatus {
        case .set(let l):
            Label("Limite impostato al \(l)%.", systemImage: "checkmark.circle").foregroundStyle(Brand.accent)
        case .holding(let p):
            Label("Il Mac è collegato ma si ferma al \(p)%: il limite di carica (o la carica ottimizzata) è attivo.",
                  systemImage: "checkmark.circle")
                .foregroundStyle(Brand.accent)
        case .full:
            Label("Il Mac è collegato e la batteria è al 100%: il limite di carica probabilmente non è impostato.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
        case .unknown:
            Text(b.pluggedIn ? "In carica: lo stato del limite si vedrà quando la carica si ferma."
                 : "A batteria: lo stato del limite si vede quando il Mac è collegato.")
                .foregroundStyle(.secondary)
        }
        if model.habits.samples >= 24 {
            Text("Nell'ultima settimana il Mac è stato collegato il \(Int(model.habits.pluggedShare * 100))% del tempo"
                 + (model.habits.pluggedShare > 0 ? ", e al 100% per il \(Int(model.habits.fullWhenPlugged * 100))% di quel tempo." : "."))
                .font(.callout)
        }
        if model.habits.suggestsLimit, b.limitStatus == .full || b.chargeLimit == nil {
            Text("Usi il Mac quasi sempre alla corrente: imposta il limite all'80%. È la cosa che allunga di più la vita della batteria.")
                .font(.callout.bold()).foregroundStyle(Color.orange)
        }
        Text("Una batteria tenuta a lungo al 100% (soprattutto al caldo) perde capacità più in fretta. Con il limite all'80% il Mac usa la corrente e lascia riposare la batteria. Quando ti serve la carica piena (un viaggio), alza il limite la sera prima.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Imposta il limite…") { Finder.open("x-apple.systempreferences:com.apple.Battery-Settings.extension") }
                .buttonStyle(.borderedProminent)
            Text("Impostazioni › Batteria › «i» accanto a «Carica». Puoi anche crearti due Comandi Rapidi («carica piena» e «torna all'80%»).")
                .font(.caption).foregroundStyle(.secondary)
        }
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
