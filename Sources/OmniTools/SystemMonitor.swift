import Foundation
import Darwin
import IOKit.ps

struct SystemSnapshot {
    var cpuUsage: Double = 0            // 0...1
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var battery: Double?                // 0...1, nil se non c'è
    var charging = false
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var topProcesses: [ProcessRow] = []
}

struct ProcessRow: Identifiable {
    let pid: Int
    let cpu: Double
    let memoryBytes: UInt64
    let name: String
    var id: Int { pid }
}

/// Legge CPU, memoria, disco, batteria e processi ogni pochi secondi.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot()
    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func start(every seconds: TimeInterval = 2) {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var s = SystemSnapshot()
        s.cpuUsage = cpuUsage()
        s.memoryUsed = memoryUsed()
        if let v = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
            s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
        (s.battery, s.charging) = battery()
        s.topProcesses = snapshot.topProcesses
        snapshot = s
        Task {
            snapshot.topProcesses = await Self.loadTopProcesses()
        }
    }

    // MARK: - Lettori

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return snapshot.cpuUsage }
        let t = info.cpu_ticks   // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// Come "Memoria usata" in Monitoraggio Attività: memoria delle app + wired + compressa.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(pageSize)
    }

    private func battery() -> (Double?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let cur = d["Current Capacity"] as? Int,
                  let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            return (Double(cur) / Double(max), d["Is Charging"] as? Bool ?? false)
        }
        return (nil, false)
    }

    nonisolated static func loadTopProcesses() async -> [ProcessRow] { topProcesses() }

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
