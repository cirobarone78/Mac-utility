#if os(macOS)
import Foundation
import IOKit
import IOKit.ps

/// Salute della batteria, come la vede macOS.
public struct BatteryHealth: Sendable {
    public var present = false
    public var cycles: Int?
    /// Cicli previsti dal costruttore (di solito 1000).
    public var designCycles: Int?
    /// Capacità massima attuale rispetto a quella da nuova (0...1).
    public var maxCapacity: Double?
    /// "Normale", "Assistenza consigliata"… (da Informazioni di sistema).
    public var condition: String?
    public var charge: Double?
    public var charging = false
    public var pluggedIn = false
    public var temperature: Double?
    public var voltage: Double?
    /// Potenza in watt: positiva in carica, negativa in uso.
    public var watts: Double?
    public var adapterWatts: Int?
    public var minutesRemaining: Int?
    public var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    public var manufactureDate: String?
    /// Limite di carica impostato (macOS 26.4 e successivi), se macOS lo espone.
    public var chargeLimit: Int?

    public init() {}

    /// Collegato, non in carica e sotto il 97%: macOS sta trattenendo la carica (limite o carica ottimizzata).
    public var holdingCharge: Bool {
        guard pluggedIn, !charging, let c = charge else { return false }
        return c < 0.97
    }

    public enum LimitStatus: Sendable, Equatable {
        /// Limite letto dalle impostazioni.
        case set(Int)
        /// Il Mac è collegato ma si ferma a questa percentuale.
        case holding(Int)
        /// Collegato e al 100%: il limite probabilmente non è impostato.
        case full
        /// A batteria o in carica: non si può dire.
        case unknown
    }

    public var limitStatus: LimitStatus {
        if let l = chargeLimit, l < 100 { return .set(l) }
        if holdingCharge, let c = charge { return .holding(Int((c * 100).rounded())) }
        if pluggedIn, let c = charge, c >= 0.99 { return .full }
        return .unknown
    }
}

public struct EnergyUser: Identifiable, Sendable {
    public let pid: Int
    public let name: String
    /// «Impatto energetico» di Monitoraggio Attività.
    public let impact: Double
    public var id: Int { pid }
}

public enum Battery {
    public static func read() -> BatteryHealth {
        var b = BatteryHealth()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                b.present = (d["BatteryInstalled"] as? Bool) ?? true
                b.cycles = d["CycleCount"] as? Int
                b.designCycles = d["DesignCycleCount9C"] as? Int
                b.charging = d["IsCharging"] as? Bool ?? false
                b.pluggedIn = d["ExternalConnected"] as? Bool ?? false
                if let t = d["Temperature"] as? Int { b.temperature = Double(t) / 100 }
                let mv = d["Voltage"] as? Int
                if let mv { b.voltage = Double(mv) / 1000 }
                // Amperage è un intero con segno a 64 bit.
                if let ma = (d["InstantAmperage"] as? Int) ?? (d["Amperage"] as? Int), let mv {
                    b.watts = Double(Int64(truncatingIfNeeded: ma)) * Double(mv) / 1_000_000
                }
                let design = d["DesignCapacity"] as? Int
                let rawMax = (d["AppleRawMaxCapacity"] as? Int) ?? (d["NominalChargeCapacity"] as? Int)
                if let design, let rawMax, design > 0 { b.maxCapacity = Double(rawMax) / Double(design) }
                if let cur = d["CurrentCapacity"] as? Int, let max = d["MaxCapacity"] as? Int, max > 0 {
                    b.charge = Double(cur) / Double(max)
                }
                if let t = d["TimeRemaining"] as? Int, t > 0, t < 6000 { b.minutesRemaining = t }
                if let m = d["ManufactureDate"] as? Int { b.manufactureDate = decodeDate(m) }
                b.chargeLimit = findChargeLimit(d)
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            b.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }
        // La percentuale «Capacità massima» di Impostazioni, se disponibile, prevale sul calcolo.
        let (condition, percent) = systemProfiler()
        b.condition = condition
        if let percent { b.maxCapacity = percent }
        return b
    }

    /// Il nome della chiave non è documentato: si cerca qualsiasi valore «…ChargeLimit…» plausibile.
    static func findChargeLimit(_ dict: [String: Any], depth: Int = 0) -> Int? {
        for (key, value) in dict {
            let k = key.lowercased()
            if k.contains("chargelimit") || k.contains("chargingLimit".lowercased()) || k == "socmax" {
                if let n = value as? Int, (50...100).contains(n) { return n }
            }
            if depth < 2, let sub = value as? [String: Any], let found = findChargeLimit(sub, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    static func systemProfiler() -> (String?, Double?) {
        let out = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]).output
        guard let start = out.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              let items = json["SPPowerDataType"] as? [[String: Any]] else { return (nil, nil) }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let raw = health["sppower_battery_health"] as? String
            let condition: String?
            switch raw ?? "" {
            case "": condition = nil
            case "Good", "Normal": condition = "Normale"
            case "Fair": condition = "Discreta"
            case "Poor", "Service Recommended", "Check Battery": condition = "Assistenza consigliata"
            default: condition = raw
            }
            let pct = (health["sppower_battery_health_maximum_capacity"] as? String)
                .flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }.map { $0 / 100 }
            return (condition, pct)
        }
        return (nil, nil)
    }

    /// Data di fabbricazione nel formato compresso delle batterie (giorno, mese, anno dal 1980).
    static func decodeDate(_ v: Int) -> String? {
        let day = v & 0x1F, month = (v >> 5) & 0xF, year = 1980 + (v >> 9)
        guard (1...31).contains(day), (1...12).contains(month), (2005...2100).contains(year) else { return nil }
        return String(format: "%02d/%02d/%d", day, month, year)
    }

    /// Le app che consumano più energia adesso (come Monitoraggio Attività › Energia).
    public static func energyUsers(limit: Int = 10) -> [EnergyUser] {
        let out = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "\(limit)", "-o", "power",
                                             "-stats", "pid,power,command"]).output
        // Il primo campione non ha ancora i valori: si usa l'ultimo blocco.
        guard let last = out.components(separatedBy: "PID").last else { return [] }
        return last.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let impact = Double(parts[1]) else { return nil }
            return EnergyUser(pid: pid, name: String(parts[2]).trimmingCharacters(in: .whitespaces), impact: impact)
        }
        .filter { $0.impact > 0 }
    }

    public struct Advice: Identifiable, Sendable {
        public let id = UUID()
        public let warning: Bool
        public let text: String
    }

    public static func advice(_ b: BatteryHealth) -> [Advice] {
        var out: [Advice] = []
        if let c = b.maxCapacity {
            if c < 0.8 {
                out.append(.init(warning: true, text: "La batteria tiene il \(Int(c * 100))% della carica di quando era nuova. Sotto l'80% Apple consiglia la sostituzione: dura meno e il Mac può rallentare sotto sforzo."))
            } else {
                out.append(.init(warning: false, text: "Capacità al \(Int(c * 100))%: in buona salute."))
            }
        }
        if let cycles = b.cycles {
            let limit = b.designCycles ?? 1000
            out.append(.init(warning: cycles > limit, text: "\(cycles) cicli di carica su circa \(limit) previsti."
                             + (cycles > limit ? " Ha superato la vita prevista." : "")))
        }
        if let t = b.temperature, t > 40 {
            out.append(.init(warning: true, text: "Temperatura alta (\(Int(t)) °C). Il caldo è il primo nemico della batteria: non tenere il Mac su coperte o al sole, e chiudi le app che consumano molto."))
        }
        return out
    }
}
/// Abitudini di carica: un campione all'ora per una settimana, per capire se il Mac
/// sta quasi sempre collegato al 100% (il caso in cui il limite di carica aiuta di più).
public enum ChargeHabits {
    public struct Sample: Codable, Sendable {
        public let date: Date
        public let pluggedIn: Bool
        public let full: Bool
    }

    public struct Summary: Sendable {
        public let samples: Int
        /// Quota di tempo collegato alla corrente.
        public let pluggedShare: Double
        /// Quota del tempo collegato passata al 100%.
        public let fullWhenPlugged: Double

        /// Almeno 2 giorni di dati, collegato per il 70% del tempo e al 100% per metà di quel tempo.
        public var suggestsLimit: Bool { samples >= 48 && pluggedShare >= 0.7 && fullWhenPlugged >= 0.5 }
    }

    static var url: URL {
        SafetyPolicy.defaultFileURL.deletingLastPathComponent().appendingPathComponent("batteria-abitudini.json")
    }

    static func load() -> [Sample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Sample].self, from: data)) ?? []
    }

    public static func record(_ b: BatteryHealth, now: Date = Date()) {
        guard b.present, let charge = b.charge else { return }
        var list = load().filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
        if let last = list.last, now.timeIntervalSince(last.date) < 50 * 60 { return }   // al massimo uno all'ora
        list.append(Sample(date: now, pluggedIn: b.pluggedIn, full: charge >= 0.99))
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(list).write(to: url, options: .atomic)
    }

    public static func summary() -> Summary { summary(load()) }

    static func summary(_ list: [Sample]) -> Summary {
        let plugged = list.filter(\.pluggedIn)
        return Summary(samples: list.count,
                       pluggedShare: list.isEmpty ? 0 : Double(plugged.count) / Double(list.count),
                       fullWhenPlugged: plugged.isEmpty ? 0 : Double(plugged.filter(\.full).count) / Double(plugged.count))
    }
}
#endif
