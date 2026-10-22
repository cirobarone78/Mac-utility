import SwiftUI
import Charts
import UtilityCore

@MainActor
final class NetworkModel: ObservableObject {
    enum Tab: String, CaseIterable { case overview = "Panoramica", speed = "Velocità", nearby = "Reti vicine", activity = "App e dispositivi" }

    @Published var tab: Tab = .overview
    @Published var wifi: WiFiInfo?
    @Published var details = NetworkDetails()
    @Published var publicIP: PublicIPInfo?
    @Published var publicIPError: String?
    @Published var nearby: [NearbyNetwork] = []
    @Published var scanning = false
    @Published var speed: SpeedTestResult?
    @Published var history: [SpeedTestResult] = SpeedHistory.load()
    @Published var pings: [PingResult] = []
    @Published var dns: [DNSTiming] = []
    @Published var testing = false
    @Published var testStatus = ""
    @Published var connections: [AppConnections] = []
    @Published var devices: [LANDevice] = []
    @Published var loadingActivity = false
    @Published var rxRate: Double = 0
    @Published var txRate: Double = 0
    @Published var rssiHistory: [Int] = []

    private var live: Task<Void, Never>?
    private var lastCounters: (rx: Int64, tx: Int64, at: Date)?

    var advice: [NetworkAdvice] {
        NetworkAdvisor.advice(wifi: wifi, details: details, nearby: nearby, speed: speed, pings: pings)
    }

    var primary: String? { details.primaryInterface ?? wifi?.interfaceName }

    func start() {
        refresh()
        guard live == nil else { return }
        live = Task {
            while !Task.isCancelled {
                let iface = primary
                let (w, counters) = await Self.sample()
                wifi = w
                if let r = w?.rssi, w?.connected == true {
                    rssiHistory.append(r)
                    if rssiHistory.count > 60 { rssiHistory.removeFirst() }
                }
                if let iface, let c = counters[iface] {
                    let now = Date()
                    if let last = lastCounters {
                        let dt = now.timeIntervalSince(last.at)
                        if dt > 0, c.rx >= last.rx, c.tx >= last.tx {
                            rxRate = Double(c.rx - last.rx) * 8 / dt
                            txRate = Double(c.tx - last.tx) * 8 / dt
                        }
                    }
                    lastCounters = (c.rx, c.tx, now)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        live?.cancel()
        live = nil
        lastCounters = nil
    }

    nonisolated static func sample() async -> (WiFiInfo?, [String: (rx: Int64, tx: Int64)]) {
        (WiFi.current(), NetworkActivity.counters())
    }

    func refresh() {
        Task {
            details = await Self.readDetails()
            wifi = await Self.readWiFi()
        }
    }

    nonisolated static func readDetails() async -> NetworkDetails { NetworkInspector.details() }
    nonisolated static func readWiFi() async -> WiFiInfo? { WiFi.current() }

    func loadPublicIP() {
        publicIPError = nil
        Task {
            do { publicIP = try await NetworkInspector.publicIP() }
            catch { publicIPError = error.localizedDescription }
        }
    }

    func scanNearby() {
        scanning = true
        Task {
            nearby = await Self.scan()
            scanning = false
        }
    }

    nonisolated static func scan() async -> [NearbyNetwork] { WiFi.scan() }

    func runTests() {
        testing = true
        let gateway = details.gateway
        Task {
            testStatus = "Misuro la latenza…"
            pings = await Self.pings(gateway: gateway)
            testStatus = "Misuro il DNS…"
            dns = await Self.dnsTimings()
            testStatus = "Test di velocità con i server di Apple (circa 20 secondi)…"
            if var r = await Self.speedTest() {
                r.network = wifi?.ssid ?? (wifi?.connected == true ? "Wi-Fi" : primary)
                speed = r
                SpeedHistory.append(r)
                history = SpeedHistory.load()
            } else {
                testStatus = "Test di velocità non riuscito: controlla la connessione."
                testing = false
                return
            }
            testStatus = ""
            testing = false
        }
    }

    nonisolated static func pings(gateway: String?) async -> [PingResult] {
        var out: [PingResult] = []
        if let g = gateway { out.append(NetworkTests.ping(g, label: "router")) }
        out.append(NetworkTests.ping("1.1.1.1", label: "internet (Cloudflare)"))
        out.append(NetworkTests.ping("8.8.8.8", label: "internet (Google)"))
        return out
    }

    nonisolated static func dnsTimings() async -> [DNSTiming] {
        ["apple.com", "google.com", "wikipedia.org"].map(NetworkTests.dnsTiming)
    }

    nonisolated static func speedTest() async -> SpeedTestResult? { NetworkTests.speedTest() }

    func loadActivity() {
        loadingActivity = true
        let gateway = details.gateway
        Task {
            (connections, devices) = await Self.activity(gateway: gateway)
            loadingActivity = false
        }
    }

    nonisolated static func activity(gateway: String?) async -> ([AppConnections], [LANDevice]) {
        (NetworkActivity.connections(), NetworkActivity.lanDevices(gateway: gateway))
    }

    static func rate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return SpeedTestResult.mbps(bps) }
        return String(format: "%.0f kbit/s", bps / 1000)
    }
}

struct NetworkView: View {
    @StateObject private var model = NetworkModel()
    @ObservedObject private var location = LocationPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .network, subtitle: "Wi-Fi, velocità, chi usa la rete e cosa migliorare.")
            Picker("", selection: $model.tab) {
                ForEach(NetworkModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            .padding(.horizontal, 20).padding(.bottom, 8)

            switch model.tab {
            case .overview: overview
            case .speed: speedTab
            case .nearby: nearbyTab
            case .activity: activityTab
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Panoramica

    private var overview: some View {
        List {
            Section {
                HStack(spacing: 24) {
                    liveTile("Download ora", NetworkModel.rate(model.rxRate), "arrow.down.circle")
                    liveTile("Upload ora", NetworkModel.rate(model.txRate), "arrow.up.circle")
                    if let w = model.wifi, w.connected {
                        liveTile("Segnale", "\(w.rssi) dBm · \(w.signalLabel)", "wifi")
                        liveTile("Collegamento al router", "\(Int(w.linkRate)) Mbit/s", "point.3.connected.trianglepath.dotted")
                    }
                }
                .padding(.vertical, 4)
            }

            if let w = model.wifi {
                Section("Wi-Fi") {
                    if !w.powerOn {
                        Text("Il Wi-Fi è spento.").foregroundStyle(.secondary)
                    } else if !w.connected {
                        Text("Non collegato a nessuna rete Wi-Fi.").foregroundStyle(.secondary)
                    } else {
                        if w.ssid == nil {
                            HStack {
                                Text("macOS mostra il nome della rete solo alle app con il permesso Localizzazione.")
                                    .font(.callout)
                                Button(location.status.rawValue == 0 ? "Concedi" : "Apri Impostazioni") { location.request() }
                            }
                        }
                        info("Rete", w.ssid ?? "nome non disponibile")
                        info("Segnale", "\(w.rssi) dBm (\(w.signalLabel)) · rumore \(w.noise) dBm · segnale/rumore \(w.snr) dB")
                        if model.rssiHistory.count > 3 {
                            Chart(model.rssiHistory.enumerated().map { ChartPoint(id: $0.offset, value: $0.element) }) { item in
                                LineMark(x: .value("t", item.id), y: .value("dBm", item.value))
                                    .foregroundStyle(Brand.accent)
                            }
                            .chartYScale(domain: -95 ... -30)
                            .chartXAxis(.hidden)
                            .frame(height: 70)
                        }
                        info("Protezione", w.security)
                        info("Standard", w.standard)
                        info("Banda e canale", "\(w.band) · canale \(w.channel.map(String.init) ?? "–") · larghezza \(w.width)")
                        info("Velocità del collegamento", "\(Int(w.linkRate)) Mbit/s (tra Mac e router, non è la velocità di internet)")
                        if let b = w.bssid { info("Punto di accesso (BSSID)", b) }
                        if let c = w.country { info("Paese", c) }
                        if let m = w.macAddress { info("Indirizzo MAC del Mac", m) }
                    }
                }
            }

            Section("Connessione") {
                if let p = model.primary { info("In uso", p == model.wifi?.interfaceName ? "Wi-Fi (\(p))" : p) }
                ForEach(model.details.interfaces) { i in
                    info("\(i.kind) (\(i.name))", (i.ipv4 + i.ipv6.prefix(1)).joined(separator: "  ·  "))
                }
                info("Router", model.details.gateway ?? "–")
                info("DNS", model.details.dns.isEmpty ? "–" : model.details.dns.joined(separator: ", "))
                info("VPN", model.details.vpnActive ? "attiva" + (model.details.vpnNames.isEmpty ? "" : " (\(model.details.vpnNames.joined(separator: ", ")))") : "no")
                if let p = model.details.proxy { info("Proxy", p) }
                if let ip = model.publicIP {
                    info("IP pubblico", ip.ip)
                    info("Fornitore", ip.org ?? "–")
                    info("Posizione stimata", [ip.city, ip.region, ip.country].compactMap { $0 }.joined(separator: ", "))
                } else {
                    HStack {
                        Button("Mostra IP pubblico e fornitore") { model.loadPublicIP() }
                        Text("Chiede a ipinfo.io: è l'unico dato che esce dal Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let e = model.publicIPError { Text(e).font(.caption).foregroundStyle(.orange) }
                }
                Button("Aggiorna") { model.refresh() }
            }

            Section("Consigli") {
                let list = model.advice
                if list.isEmpty {
                    Text("Fai il test di velocità e cerca le reti vicine per consigli più precisi.").foregroundStyle(.secondary)
                }
                ForEach(list) { a in adviceRow(a) }
            }
        }
    }

    private func liveTile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 200, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }

    private func adviceRow(_ a: NetworkAdvice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.level == .ok ? "checkmark.circle.fill" : a.level == .info ? "info.circle"
                  : a.level == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(a.level == .ok ? Brand.accent : a.level == .info ? Color.blue : a.level == .warning ? Color.orange : Color.red)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).bold()
                Text(a.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Velocità

    private var speedTab: some View {
        List {
            Section {
                HStack {
                    Button(model.testing ? "Test in corso…" : "Avvia il test") { model.runTests() }
                        .buttonStyle(.borderedProminent).disabled(model.testing)
                    if model.testing { ProgressView().controlSize(.small); Text(model.testStatus).font(.callout) }
                    else if !model.testStatus.isEmpty { Text(model.testStatus).foregroundStyle(.orange) }
                    Spacer()
                }
                Text("Usa lo strumento di Apple incluso in macOS (networkQuality) e i server di Apple. Consuma qualche centinaio di MB: evitalo con il telefono in condivisione.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = model.speed {
                Section("Risultato") {
                    HStack(spacing: 30) {
                        bigNumber("Download", SpeedTestResult.mbps(s.download), "arrow.down")
                        bigNumber("Upload", SpeedTestResult.mbps(s.upload), "arrow.up")
                        if let l = s.idleLatency { bigNumber("Latenza", "\(Int(l)) ms", "timer") }
                        if let r = s.responsiveness { bigNumber("Reattività", "\(s.responsivenessLabel) (\(Int(r)) RPM)", "waveform.path.ecg") }
                    }
                    .padding(.vertical, 6)
                    Text(usage(s)).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !model.pings.isEmpty {
                Section("Latenza e stabilità") {
                    ForEach(model.pings) { p in
                        info("Verso \(p.label)",
                             [p.average.map { "media \(String(format: "%.1f", $0)) ms" },
                              p.jitter.map { "variazione \(String(format: "%.1f", $0)) ms" },
                              p.loss.map { "persi \(String(format: "%.0f", $0))%" }]
                                .compactMap { $0 }.joined(separator: " · ").replacingOccurrences(of: ".", with: ","))
                    }
                }
            }
            if !model.dns.isEmpty {
                Section("Tempo di risposta del DNS") {
                    ForEach(model.dns) { d in info(d.domain, d.milliseconds.map { "\($0) ms" } ?? "nessuna risposta") }
                    Text("Sotto i 50 ms è buono. Se è spesso lento, un DNS come 1.1.1.1 o 8.8.8.8 (Impostazioni › Rete › Dettagli › DNS) può rendere più veloce l'apertura dei siti.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.history.count > 1 {
                Section("Cronologia") {
                    Chart(Array(model.history.reversed())) { r in
                        LineMark(x: .value("Data", r.date), y: .value("Mbit/s", r.download / 1_000_000))
                            .foregroundStyle(by: .value("Tipo", "Download"))
                        LineMark(x: .value("Data", r.date), y: .value("Mbit/s", r.upload / 1_000_000))
                            .foregroundStyle(by: .value("Tipo", "Upload"))
                    }
                    .frame(height: 160)
                    ForEach(model.history.prefix(10)) { r in
                        info(r.date.formatted(date: .abbreviated, time: .shortened),
                             "↓ \(SpeedTestResult.mbps(r.download))  ↑ \(SpeedTestResult.mbps(r.upload))" + (r.network.map { "  · \($0)" } ?? ""))
                    }
                }
            }
        }
    }

    private func bigNumber(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
    }

    /// Cosa ci si può fare con questa velocità.
    private func usage(_ s: SpeedTestResult) -> String {
        let down = s.download / 1_000_000, up = s.upload / 1_000_000
        var parts: [String] = []
        parts.append(down >= 25 ? "Film in 4K: sì." : down >= 5 ? "Film in HD: sì; 4K: al limite." : "Video: solo a bassa qualità.")
        parts.append(up >= 3 ? "Videochiamate in HD: sì." : up >= 1 ? "Videochiamate: sì, a qualità ridotta." : "Videochiamate: difficili (upload basso).")
        parts.append("Scaricare 1 GB: circa \(max(1, Int(8_000 / max(down, 0.1)))) secondi.")
        return parts.joined(separator: " ")
    }

    // MARK: - Reti vicine

    private var nearbyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.nearby.isEmpty ? "Cerca le reti vicine" : "Cerca di nuovo") { model.scanNearby() }
                    .buttonStyle(.borderedProminent).disabled(model.scanning)
                if model.scanning { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 20)
            if !model.nearby.isEmpty {
                let crowd = WiFi.crowding(model.nearby).map { ChartPoint(id: $0.key, value: $0.value) }.sorted { $0.id < $1.id }
                Chart(crowd) { item in
                    BarMark(x: .value("Canale", String(item.id)), y: .value("Reti", item.value))
                        .foregroundStyle(item.id == model.wifi?.channel ? Brand.accent : Color.gray.opacity(0.6))
                }
                .frame(height: 140)
                .padding(.horizontal, 20)
                Text("Reti per canale. In evidenza il tuo: se è tra i più alti, nel router scegli un canale meno affollato.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                Table(model.nearby) {
                    TableColumn("Rete") { n in Text(n.ssid).bold(n.ssid == model.wifi?.ssid) }
                    TableColumn("Segnale") { n in Text("\(n.rssi) dBm").monospacedDigit() }.width(80)
                    TableColumn("Canale") { n in Text(n.channel.map(String.init) ?? "–") }.width(60)
                    TableColumn("Banda") { n in Text(n.band) }.width(70)
                    TableColumn("Protetta") { n in Text(n.secure ? "sì" : "aperta").foregroundStyle(n.secure ? Color.primary : Color.orange) }.width(70)
                }
            } else if !model.scanning {
                ContentUnavailableView("Premi «Cerca le reti vicine»", systemImage: "wifi",
                                       description: Text(location.granted ? "Richiede qualche secondo."
                                                         : "Senza il permesso Localizzazione macOS nasconde i nomi delle reti."))
            }
        }
    }

    // MARK: - App e dispositivi

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.connections.isEmpty ? "Mostra chi usa la rete" : "Aggiorna") { model.loadActivity() }
                    .buttonStyle(.borderedProminent).disabled(model.loadingActivity)
                if model.loadingActivity { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal, 20)
            List {
                if !model.connections.isEmpty {
                    Section("App collegate a internet (\(model.connections.count))") {
                        ForEach(model.connections) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a.name).bold()
                                    Spacer()
                                    if let i = a.bytesIn, let o = a.bytesOut {
                                        Text("↓ \(Bytes.format(i))  ↑ \(Bytes.format(o))").font(.caption.monospacedDigit())
                                    }
                                }
                                if !a.established.isEmpty {
                                    Text("\(a.established.count) connessioni: " + a.established.prefix(4).joined(separator: ", ")
                                         + (a.established.count > 4 ? "…" : ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                if !a.listening.isEmpty {
                                    Text("Accetta connessioni in ingresso sulle porte " + a.listening.joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .contextMenu {
                                Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                                    ExplainCenter.shared.ask(a.name, context: "Programma su macOS collegato a internet. Connessioni: \(a.established.prefix(6).joined(separator: ", ")). Porte in ascolto: \(a.listening.joined(separator: ", ")). È normale?")
                                }
                            }
                        }
                        Text("I dati ↓↑ sono quelli scambiati da quando il programma è partito. Le porte in ascolto non sono un problema se sai a cosa servono (es. condivisione schermo, AirPlay, programmi per sviluppatori).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.devices.isEmpty {
                    Section("Dispositivi visti sulla rete (\(model.devices.count))") {
                        ForEach(model.devices) { d in
                            HStack {
                                Image(systemName: d.isRouter ? "wifi.router" : "desktopcomputer")
                                Text(d.ip).monospacedDigit().frame(width: 130, alignment: .leading)
                                Text(d.mac).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if d.isRouter { Badge(text: "router", color: Brand.accent) }
                                Spacer()
                            }
                        }
                        Text("Sono i dispositivi con cui il Mac ha parlato di recente. Se ne vedi di sconosciuti sulla rete di casa, cambia la password del Wi-Fi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Un punto per i grafici (chiave numerica e valore).
struct ChartPoint: Identifiable {
    let id: Int
    let value: Int
}
