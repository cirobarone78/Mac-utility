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
        if b.pluggedIn {
            out.append(.init(warning: false, text: "Se il Mac resta quasi sempre in carica, tieni attiva la «Carica ottimizzata» (Impostazioni › Batteria › i accanto a Stato della batteria): macOS si ferma all'80% finché non serve."))
        }
        return out
    }
}
#endif
