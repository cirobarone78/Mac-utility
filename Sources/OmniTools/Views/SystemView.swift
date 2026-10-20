import SwiftUI
import UtilityCore

struct SystemView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .system, subtitle: "Aggiornato ogni 3 secondi")
            Form {
                Section("Generale") {
                    LabeledContent("Acceso da", value: Self.duration(s.uptime))
                    LabeledContent("Temperatura", value: Self.thermal(s.thermal))
                    LabeledContent("Processore", value: "\(Int(s.cpuUsage * 100))%")
                    LabeledContent("Memoria usata",
                                   value: "\(Bytes.format(Int64(s.memoryUsed))) di \(Bytes.format(Int64(s.memoryTotal)))")
                    LabeledContent("Disco libero", value: s.diskTotal > 0 ? Bytes.format(s.diskFree) : "–")
                    if let b = s.battery {
                        LabeledContent("Batteria", value: "\(Int(b * 100))%\(s.charging ? " (in carica)" : "")")
                    }
                }
                Section("Processi che consumano di più") {
                    ForEach(s.topProcesses) { p in
                        HStack {
                            Text(p.name).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", p.cpu)).monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(Bytes.format(Int64(p.memoryBytes))).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        return f.string(from: t) ?? "–"
    }

    static func thermal(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: "Normale"
        case .fair: "Leggermente alta"
        case .serious: "Alta: il Mac rallenta per raffreddarsi"
        case .critical: "Critica"
        @unknown default: "–"
        }
    }
}
