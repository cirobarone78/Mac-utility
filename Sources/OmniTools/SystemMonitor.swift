import Foundation
import Darwin
import IOKit.ps

struct SystemSnapshot: Sendable {
    var cpuUsage: Double = 0            // 0...1
    var memoryUsed: UInt64 = 0          // 0 = non disponibile
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskTotal: Int64 = 0            // 0 = non disponibile
    var diskFree: Int64 = 0
    var battery: Double?                // 0...1, nil se non c'è
    var charging = false
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var topProcesses: [ProcessRow] = []
    var ready = false                   // false finché non arriva la prima lettura
}

struct ProcessRow: Identifiable, Sendable {
    let pid: Int
    let cpu: Double
    let memoryBytes: UInt64
    let name: String
    var id: Int { pid }
}

/// Un solo monitor per tutta l'app (finestra e barra dei menu).
/// Ogni lettura avviene fuori dal thread principale, così l'interfaccia non si blocca mai.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    @Published private(set) var snapshot = SystemSnapshot()
    private var loop: Task<Void, Never>?
    private var lastTicks: CPUTicks?
    private var diskCache: (total: Int64, free: Int64, at: Date)?

    func start(every seconds: Double = 3) {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        // Lo spazio su disco cambia piano e la sua lettura può essere lenta: ogni 30 secondi basta.
        let needDisk = diskCache.map { Date().timeIntervalSince($0.at) > 30 } ?? true
        let sample = await Self.sample(previous: lastTicks, readDisk: needDisk)
        lastTicks = sample.ticks
        if let d = sample.disk { diskCache = (d.total, d.free, Date()) }

        var s = sample.snapshot
        s.diskTotal = diskCache?.total ?? 0
        s.diskFree = diskCache?.free ?? 0
        s.ready = true
        snapshot = s
    }

    // MARK: - Letture (fuori dal thread principale)

    struct CPUTicks: Sendable { let busy: UInt64; let total: UInt64 }

    struct Sample: Sendable {
        var snapshot: SystemSnapshot
        var ticks: CPUTicks?
        var disk: (total: Int64, free: Int64)?
    }

    nonisolated static func sample(previous: CPUTicks?, readDisk: Bool) async -> Sample {
        var s = SystemSnapshot()
        let ticks = cpuTicks()
        if let t = ticks, let p = previous, t.total > p.total {
            s.cpuUsage = Double(t.busy - p.busy) / Double(t.total - p.total)
        }
        s.memoryUsed = memoryUsed()
        (s.battery, s.charging) = battery()
        s.topProcesses = topProcesses()
        return Sample(snapshot: s, ticks: ticks, disk: readDisk ? disk() : nil)
    }

    nonisolated static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks   // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return CPUTicks(busy: busy, total: busy + UInt64(t.2))
    }

    /// Come "Memoria usata" in Monitoraggio Attività: memoria delle app + wired + compressa.
    nonisolated static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// Spazio del volume dati (quello della home), non del volume di sistema in sola lettura.
    nonisolated static func disk() -> (total: Int64, free: Int64)? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity else { return nil }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return (Int64(total), free)
    }

    nonisolated static func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let cur = d["Current Capacity"] as? Int,
                  let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            let onAC = (d["Power Source State"] as? String) == "AC Power"
            return (Double(cur) / Double(max), (d["Is Charging"] as? Bool ?? false) || onAC)
        }
        return (nil, false)
    }

    /// I processi che usano più CPU, letti da `ps` (nessun permesso speciale richiesto).
    nonisolated static func topProcesses(limit: Int = 8) -> [ProcessRow] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").prefix(limit).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
                  let rss = UInt64(parts[2]) else { return nil }
            return ProcessRow(pid: pid, cpu: cpu, memoryBytes: rss * 1024, name: String(parts[3]))
        }
    }
}
