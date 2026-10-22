#if os(macOS)
import Foundation
import CoreWLAN
import Darwin

// MARK: - Wi-Fi

/// La rete Wi-Fi a cui il Mac è collegato.
public struct WiFiInfo: Sendable {
    public enum SecurityLevel: Int, Sendable { case open, weak, good, strong, unknown }

    public var interfaceName: String
    public var powerOn: Bool
    public var connected: Bool
    /// nil se macOS non lo rivela: dal 2023 serve il permesso Localizzazione.
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int
    public var noise: Int
    /// Velocità del collegamento tra Mac e router, in Mbit/s (non è la velocità di internet).
    public var linkRate: Double
    public var channel: Int?
    public var band: String
    public var width: String
    public var security: String
    public var securityLevel: SecurityLevel
    public var standard: String
    public var country: String?
    public var macAddress: String?

    /// Rapporto segnale/rumore in dB: più è alto, più il collegamento è stabile.
    public var snr: Int { rssi - noise }

    public var signalLabel: String {
        switch rssi {
        case -50...0: "eccellente"
        case -60 ..< -50: "buono"
        case -70 ..< -60: "discreto"
        case -80 ..< -70: "debole"
        default: "molto debole"
        }
    }

    /// Da 0 a 4 tacche.
    public var bars: Int {
        switch rssi {
        case -55...0: 4
        case -65 ..< -55: 3
        case -75 ..< -65: 2
        case -85 ..< -75: 1
        default: 0
        }
    }
}

/// Una rete Wi-Fi nei dintorni.
public struct NearbyNetwork: Identifiable, Hashable, Sendable {
    public let ssid: String
    public let bssid: String?
    public let rssi: Int
    public let channel: Int?
    public let band: String
    public let secure: Bool
    public var id: String { (bssid ?? UUID().uuidString) + ssid }
}

public enum WiFi {
    public static func current() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        let channel = iface.wlanChannel()
        let sec = iface.security().rawValue
        let rssi = iface.rssiValue()
        return WiFiInfo(interfaceName: iface.interfaceName ?? "en0",
                        powerOn: iface.powerOn(),
                        connected: rssi != 0,
                        ssid: iface.ssid(), bssid: iface.bssid(),
                        rssi: rssi, noise: iface.noiseMeasurement(),
                        linkRate: iface.transmitRate(),
                        channel: channel.map { $0.channelNumber },
                        band: band(channel), width: width(channel),
                        security: securityName(sec), securityLevel: securityLevel(sec),
                        standard: standard(iface.activePHYMode().rawValue),
                        country: iface.countryCode(), macAddress: iface.hardwareAddress())
    }

    /// Cerca le reti vicine (qualche secondo). Senza Localizzazione i nomi possono mancare.
    public static func scan() -> [NearbyNetwork] {
        guard let iface = CWWiFiClient.shared().interface(),
              let found = try? iface.scanForNetworks(withName: nil) else { return [] }
        let open = CWSecurity(rawValue: 0)
        return found.map { n in
            let secure = open.map { !n.supportsSecurity($0) } ?? true
            return NearbyNetwork(ssid: n.ssid ?? "(nome nascosto)", bssid: n.bssid, rssi: n.rssiValue,
                                 channel: n.wlanChannel.map { $0.channelNumber }, band: band(n.wlanChannel),
                                 secure: secure)
        }
        .sorted { $0.rssi > $1.rssi }
    }

    static func band(_ c: CWChannel?) -> String {
        guard let c else { return "–" }
        switch c.channelBand.rawValue {
        case 1: return "2,4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        default: return c.channelNumber > 14 ? "5 GHz" : "2,4 GHz"
        }
    }

    static func width(_ c: CWChannel?) -> String {
        switch c?.channelWidth.rawValue ?? 0 {
        case 1: "20 MHz"
        case 2: "40 MHz"
        case 3: "80 MHz"
        case 4: "160 MHz"
        default: "–"
        }
    }

    // Valori di CWSecurity (CoreWLAN).
    static func securityName(_ raw: Int) -> String {
        switch raw {
        case 0: "Nessuna (rete aperta)"
        case 1: "WEP"
        case 2, 3: "WPA Personal"
        case 4: "WPA2 Personal"
        case 5: "WPA2/WPA3 Personal"
        case 6: "WEP dinamico"
        case 7, 8: "WPA Enterprise"
        case 9: "WPA2 Enterprise"
        case 10: "WPA2/WPA3 Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 (transizione)"
        case 14, 15: "OWE (aperta ma cifrata)"
        default: "Sconosciuta"
        }
    }

    static func securityLevel(_ raw: Int) -> WiFiInfo.SecurityLevel {
        switch raw {
        case 0: .open
        case 1, 2, 3, 6, 7, 8: .weak
        case 4, 5, 9, 10, 13, 14, 15: .good
        case 11, 12: .strong
        default: .unknown
        }
    }

    // Valori di CWPHYMode.
    static func standard(_ raw: Int) -> String {
        switch raw {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4 (802.11n)"
        case 5: "Wi-Fi 5 (802.11ac)"
        case 6: "Wi-Fi 6 (802.11ax)"
        case 7: "Wi-Fi 7 (802.11be)"
        default: "–"
        }
    }

    /// Quante reti vicine usano ogni canale (per capire se il canale è affollato).
    public static func crowding(_ nearby: [NearbyNetwork]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for n in nearby { if let c = n.channel { out[c, default: 0] += 1 } }
        return out
    }
}

// MARK: - Collegamenti, indirizzi, DNS

public struct InterfaceInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let kind: String
    public let ipv4: [String]
    public let ipv6: [String]
    public var id: String { name }
}

public struct NetworkDetails: Sendable {
    public var interfaces: [InterfaceInfo] = []
    public var primaryInterface: String?
    public var gateway: String?
    public var dns: [String] = []
    public var vpnActive = false
    public var vpnNames: [String] = []
    public var proxy: String?
}

public struct PublicIPInfo: Codable, Sendable {
    public let ip: String
    public let city: String?
    public let region: String?
    public let country: String?
    /// Il fornitore di internet ("AS3269 Telecom Italia").
    public let org: String?
}

public enum NetworkInspector {
    public static func details(wifiInterface: String? = WiFi.current()?.interfaceName) -> NetworkDetails {
        var d = NetworkDetails()
        d.interfaces = interfaces(wifi: wifiInterface)
        let route = Shell.run("/sbin/route", ["-n", "get", "default"]).output
        d.gateway = field(route, "gateway")
        d.primaryInterface = field(route, "interface")
        d.dns = dnsServers()
        let nc = Shell.run("/usr/sbin/scutil", ["--nc", "list"]).output
        d.vpnNames = nc.split(separator: "\n").filter { $0.contains("(Connected)") }.compactMap { line in
            line.split(separator: "\"").dropFirst().first.map(String.init)
        }
        d.vpnActive = !d.vpnNames.isEmpty || d.interfaces.contains { $0.name.hasPrefix("utun") && !$0.ipv4.isEmpty }
        let proxies = Shell.run("/usr/sbin/scutil", ["--proxy"]).output
        if proxies.contains("HTTPSEnable : 1") || proxies.contains("HTTPEnable : 1") {
            d.proxy = field(proxies, "HTTPSProxy", separator: ":") ?? field(proxies, "HTTPProxy", separator: ":")
        }
        return d
    }

    static func field(_ text: String, _ key: String, separator: Character = ":") -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: separator, maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }

    static func dnsServers() -> [String] {
        let text = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8))
            ?? Shell.run("/usr/sbin/scutil", ["--dns"]).output
        var out: [String] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("nameserver") {
                let value = t.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "\t" }).last.map(String.init) ?? ""
                if !value.isEmpty, !out.contains(value) { out.append(value) }
            }
        }
        return out
    }

    /// Le interfacce accese con un indirizzo (escluso il collegamento interno lo0).
    static func interfaces(wifi: String?) -> [InterfaceInfo] {
        var v4: [String: [String]] = [:], v6: [String: [String]] = [:]
        var order: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let addr = p.pointee.ifa_addr else { continue }
            let name = String(cString: p.pointee.ifa_name)
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let hostLength = socklen_t(host.count)
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, hostLength,
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !order.contains(name) { order.append(name) }
            if family == AF_INET { v4[name, default: []].append(ip) }
            else if !ip.hasPrefix("fe80") { v6[name, default: []].append(ip) }
        }
        return order.compactMap { name in
            let a = v4[name] ?? [], b = v6[name] ?? []
            guard !a.isEmpty || !b.isEmpty else { return nil }
            let kind: String
            if name == wifi { kind = "Wi-Fi" }
            else if name.hasPrefix("en") { kind = "Ethernet / Thunderbolt" }
            else if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { kind = "VPN o tunnel" }
            else if name.hasPrefix("bridge") { kind = "Condivisione" }
            else if name.hasPrefix("awdl") || name.hasPrefix("llw") { kind = "AirDrop / Continuity" }
            else { kind = "Altro" }
            return InterfaceInfo(name: name, kind: kind, ipv4: a, ipv6: b)
        }
        .filter { !$0.ipv4.isEmpty || $0.kind == "Wi-Fi" || $0.kind.hasPrefix("Ethernet") }
    }

    /// Indirizzo pubblico e fornitore (da ipinfo.io: è l'unica richiesta che esce dal Mac).
    public static func publicIP() async throws -> PublicIPInfo {
        var request = URLRequest(url: URL(string: "https://ipinfo.io/json")!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(PublicIPInfo.self, from: data)
    }
}

// MARK: - Velocità e qualità

public struct SpeedTestResult: Codable, Identifiable, Hashable, Sendable {
    public var id: Date { date }
    public let date: Date
    /// bit al secondo
    public let download: Double
    public let upload: Double
    /// Reattività sotto carico, in «giri al minuto» (RPM): più è alta, meglio vanno videochiamate e giochi.
    public let responsiveness: Double?
    /// Latenza a vuoto, in millisecondi.
    public let idleLatency: Double?
    public let interface: String?
    public var network: String?

    public static func mbps(_ bps: Double) -> String {
        String(format: "%.1f Mbit/s", bps / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    public var responsivenessLabel: String {
        guard let r = responsiveness else { return "–" }
        switch r {
        case 800...: return "alta"
        case 200..<800: return "media"
        default: return "bassa"
        }
    }
}

public struct PingResult: Identifiable, Sendable {
    public let host: String
    public let label: String
    public let average: Double?
    public let jitter: Double?
    public let loss: Double?
    public var id: String { host }
}

public struct DNSTiming: Identifiable, Sendable {
    public let domain: String
    public let milliseconds: Int?
    public var id: String { domain }
}

public enum NetworkTests {
    /// Test di velocità con lo strumento di Apple incluso in macOS (server di Apple, circa 20 secondi).
    public static func speedTest() -> SpeedTestResult? {
        let r = Shell.run("/usr/bin/networkQuality", ["-c"])
        guard let start = r.output.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(r.output[start...].utf8)) as? [String: Any]
        else { return nil }
        return parseSpeed(json)
    }

    static func parseSpeed(_ json: [String: Any], date: Date = Date()) -> SpeedTestResult? {
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        guard let dl = num("dl_throughput") else { return nil }
        return SpeedTestResult(date: date, download: dl, upload: num("ul_throughput") ?? 0,
                               responsiveness: num("dl_responsiveness") ?? num("responsiveness"),
                               idleLatency: num("base_rtt"), interface: json["interface_name"] as? String,
                               network: nil)
    }

    public static func ping(_ host: String, label: String, count: Int = 10) -> PingResult {
        let out = Shell.run("/sbin/ping", ["-c", "\(count)", "-i", "0.2", "-t", "8", host]).output
        let (avg, jitter) = parseRoundTrip(out)
        return PingResult(host: host, label: label, average: avg, jitter: jitter, loss: parseLoss(out))
    }

    /// "round-trip min/avg/max/stddev = 3.1/4.2/6.0/0.8 ms" → (4,2; 0,8)
    static func parseRoundTrip(_ text: String) -> (Double?, Double?) {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
              let values = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first?.split(separator: "/").compactMap({ Double($0) }),
              values.count >= 4 else { return (nil, nil) }
        return (values[1], values[3])
    }

    static func parseLoss(_ text: String) -> Double? {
        guard let r = text.range(of: #"([\d.]+)% packet loss"#, options: .regularExpression) else { return nil }
        return Double(text[r].split(separator: "%").first ?? "")
    }

    /// Tempo per risolvere un nome con il DNS in uso.
    public static func dnsTiming(_ domain: String) -> DNSTiming {
        let out = Shell.run("/usr/bin/dig", ["+noall", "+stats", "+tries=1", "+time=3", domain]).output
        guard let r = out.range(of: #"Query time: \d+"#, options: .regularExpression),
              let ms = Int(out[r].split(separator: " ").last ?? "") else { return DNSTiming(domain: domain, milliseconds: nil) }
        return DNSTiming(domain: domain, milliseconds: ms)
    }
}

/// Cronologia dei test di velocità: ~/Library/Application Support/OmniTools/velocita.json
public enum SpeedHistory {
    static var url: URL { SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("velocita.json") }

    public static func load() -> [SpeedTestResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([SpeedTestResult].self, from: data)) ?? []
    }

    public static func append(_ r: SpeedTestResult) {
        var list = load()
        list.insert(r, at: 0)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(Array(list.prefix(100))).write(to: url, options: .atomic)
    }
}

// MARK: - Chi usa la rete

/// Le connessioni di un'app (solo i programmi dell'utente: quelli di sistema richiederebbero la password).
public struct AppConnections: Identifiable, Hashable, Sendable {
    public let name: String
    public let pid: Int32
    public var established: [String] = []
    public var listening: [String] = []
    public var bytesIn: Int64?
    public var bytesOut: Int64?
    public var id: Int32 { pid }
}

public struct LANDevice: Identifiable, Hashable, Sendable {
    public let ip: String
    public let mac: String
    public let interface: String
    public var isRouter = false
    public var id: String { ip }
}

public enum NetworkActivity {
    public static func connections() -> [AppConnections] {
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "+c", "0", "-i", "-F", "pcnT"]).output
        var apps: [Int32: AppConnections] = [:]
        var pid: Int32 = 0, command = ""
        var name: String?
        func flush() {
            guard let n = name, pid != 0 else { return }
            var a = apps[pid] ?? AppConnections(name: command, pid: pid)
            if n.contains("->") {
                let remote = String(n.split(separator: ">").last ?? "")
                if !a.established.contains(remote) { a.established.append(remote) }
            }
            apps[pid] = a
            name = nil
        }
        for raw in out.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p": flush(); pid = Int32(value) ?? 0
            case "c": command = value
            case "f": flush()
            case "n": name = value
            case "T":
                if value == "ST=LISTEN", let n = name {
                    var a = apps[pid] ?? AppConnections(name: command, pid: pid)
                    let port = String(n.split(separator: ":").last ?? "")
                    if !a.listening.contains(port) { a.listening.append(port) }
                    apps[pid] = a
                    name = nil
                }
            default: break
            }
        }
        flush()
        let traffic = trafficByProcess()
        let list: [AppConnections] = apps.values.map { item in
            var a = item
            if let t = traffic[a.pid] { a.bytesIn = t.0; a.bytesOut = t.1 }
            return a
        }
        func total(_ a: AppConnections) -> Int64 { (a.bytesIn ?? 0) + (a.bytesOut ?? 0) }
        return list.filter { !$0.established.isEmpty || !$0.listening.isEmpty }
            .sorted { total($0) != total($1) ? total($0) > total($1) : $0.established.count > $1.established.count }
    }

    /// Dati scambiati da ogni processo da quando è partito (da nettop).
    static func trafficByProcess() -> [Int32: (Int64, Int64)] {
        let out = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]).output
        var result: [Int32: (Int64, Int64)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 4, let dot = f[1].lastIndex(of: "."),
                  let pid = Int32(f[1][f[1].index(after: dot)...]),
                  let i = Int64(f[2]), let o = Int64(f[3]) else { continue }
            result[pid] = (i, o)
        }
        return result
    }

    /// I dispositivi che il Mac ha visto di recente sulla rete locale (tabella ARP).
    public static func lanDevices(gateway: String?) -> [LANDevice] {
        let out = Shell.run("/usr/sbin/arp", ["-an"]).output
        var list: [LANDevice] = []
        for line in out.split(separator: "\n") {
            // ? (192.168.1.1) at a4:91:b1:xx:xx:xx on en0 ifscope [ethernet]
            let parts = line.split(separator: " ")
            guard parts.count >= 6, parts[2] == "at", parts[1].hasPrefix("(") else { continue }
            let ip = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let mac = String(parts[3])
            guard mac != "(incomplete)", mac != "ff:ff:ff:ff:ff:ff", !mac.hasPrefix("1:0:5e"),
                  !mac.hasPrefix("01:00:5e"), !ip.hasPrefix("224."), !ip.hasPrefix("239."),
                  !ip.hasSuffix(".255") else { continue }
            var d = LANDevice(ip: ip, mac: mac, interface: String(parts[5]))
            d.isRouter = ip == gateway
            if !list.contains(where: { $0.ip == ip }) { list.append(d) }
        }
        return list.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// Byte totali ricevuti/inviati per interfaccia (per calcolare la velocità in tempo reale).
    public static func counters() -> [String: (rx: Int64, tx: Int64)] {
        let out = Shell.run("/usr/sbin/netstat", ["-ibn"]).output
        var result: [String: (rx: Int64, tx: Int64)] = [:]
        for line in out.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 10, t[2].hasPrefix("<Link#"), result[String(t[0])] == nil,
                  let rx = Int64(t[t.count - 5]), let tx = Int64(t[t.count - 2]) else { continue }
            result[String(t[0])] = (rx, tx)
        }
        return result
    }
}

// MARK: - Consigli

public struct NetworkAdvice: Identifiable, Sendable {
    public enum Level: Int, Sendable { case ok, info, warning, critical }
    public let id = UUID()
    public let level: Level
    public let title: String
    public let detail: String
}

public enum NetworkAdvisor {
    public static func advice(wifi: WiFiInfo?, details: NetworkDetails, nearby: [NearbyNetwork],
                              speed: SpeedTestResult?, pings: [PingResult]) -> [NetworkAdvice] {
        var out: [NetworkAdvice] = []
        if let w = wifi, w.connected {
            switch w.securityLevel {
            case .open:
                out.append(.init(level: .critical, title: "Rete Wi-Fi aperta",
                                 detail: "Chiunque nei dintorni può vedere il traffico non cifrato. Evita di inserire password e usa una VPN, oppure collegati a un'altra rete."))
            case .weak:
                out.append(.init(level: .warning, title: "Protezione Wi-Fi vecchia (\(w.security))",
                                 detail: "Questa protezione si può forzare. Se la rete è tua, imposta WPA2 o meglio WPA3 nelle impostazioni del router."))
            case .strong:
                out.append(.init(level: .ok, title: "Protezione Wi-Fi moderna (\(w.security))", detail: "Il massimo oggi disponibile."))
            case .good:
                out.append(.init(level: .ok, title: "Protezione Wi-Fi adeguata (\(w.security))",
                                 detail: "Se il router lo permette, WPA3 è ancora più sicura."))
            case .unknown: break
            }
            if w.rssi < -70 {
                out.append(.init(level: .warning, title: "Segnale \(w.signalLabel) (\(w.rssi) dBm)",
                                 detail: "Il Mac è lontano dal router o ci sono muri spessi. Avvicinati, sposta il router in posizione centrale e alta, oppure valuta un ripetitore o un sistema mesh."))
            }
            if w.snr < 20 {
                out.append(.init(level: .info, title: "Molto rumore radio (segnale/rumore \(w.snr) dB)",
                                 detail: "Microonde, telefoni cordless e reti vicine disturbano. Un canale meno affollato o la banda a 5 GHz aiutano."))
            }
            if w.band == "2,4 GHz" {
                out.append(.init(level: .info, title: "Sei sulla banda a 2,4 GHz",
                                 detail: "Arriva più lontano ma è più lenta e affollata. Se il router ha anche la rete a 5 GHz (spesso con «5G» nel nome), usala quando sei vicino."))
            }
            if let c = w.channel {
                let crowd = WiFi.crowding(nearby)[c] ?? 0
                if crowd >= 5 {
                    out.append(.init(level: .info, title: "Canale \(c) affollato (\(crowd) reti vicine)",
                                     detail: "Nelle impostazioni del router scegli il canale automatico o uno meno usato" + (w.band == "2,4 GHz" ? " (sui 2,4 GHz solo 1, 6 o 11)." : ".")))
                }
            }
        } else if wifi?.powerOn == false {
            out.append(.init(level: .info, title: "Wi-Fi spento", detail: "Il Mac usa un'altra connessione."))
        }
        if details.vpnActive {
            out.append(.init(level: .ok, title: "VPN attiva" + (details.vpnNames.isEmpty ? "" : ": " + details.vpnNames.joined(separator: ", ")),
                             detail: "Il traffico passa da un tunnel cifrato. Le velocità misurate dipendono anche dal server VPN."))
        }
        if let p = details.proxy {
            out.append(.init(level: .warning, title: "Proxy impostato: \(p)",
                             detail: "Tutto il traffico web passa da questo server. Se non l'hai messo tu (o la tua azienda), toglilo in Impostazioni › Rete › Dettagli › Proxy: è un trucco usato dai programmi indesiderati."))
        }
        if let s = speed {
            if let r = s.responsiveness, r < 200 {
                out.append(.init(level: .warning, title: "Reattività bassa sotto carico (\(Int(r)) RPM)",
                                 detail: "Quando qualcuno scarica, le videochiamate scattano. Su molti router si risolve attivando «SQM» o «QoS»; anche il cavo al posto del Wi-Fi aiuta."))
            }
            if let w = wifi, w.connected, w.linkRate > 0, s.download > 0, s.download / 1_000_000 > w.linkRate * 0.7 {
                out.append(.init(level: .info, title: "Il limite è il Wi-Fi, non internet",
                                 detail: "Il collegamento Mac-router (\(Int(w.linkRate)) Mbit/s) è quasi saturo. Avvicinati al router o usa un cavo per avere tutta la velocità del contratto."))
            }
        }
        for p in pings {
            if let loss = p.loss, loss > 2 {
                out.append(.init(level: .warning, title: "Pacchetti persi verso \(p.label) (\(Int(loss))%)",
                                 detail: p.label == "router"
                                    ? "Il problema è tra il Mac e il router: segnale Wi-Fi o cavo."
                                    : "Il problema è oltre il router: linea o fornitore. Se succede spesso, segnalalo al fornitore."))
            }
            if let j = p.jitter, j > 30 {
                out.append(.init(level: .info, title: "Latenza instabile verso \(p.label) (variazione \(Int(j)) ms)",
                                 detail: "Le chiamate possono avere audio a scatti."))
            }
        }
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }
}
#endif
