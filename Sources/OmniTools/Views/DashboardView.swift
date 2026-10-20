import SwiftUI
import UtilityCore

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        let s = monitor.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ModuleHeader(module: .dashboard, subtitle: "Lo stato del tuo Mac a colpo d'occhio")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    let usedDisk = s.diskTotal - s.diskFree
                    Gauge3(title: "Disco", value: s.diskTotal > 0 ? Double(usedDisk) / Double(s.diskTotal) : 0,
                           detail: "\(Bytes.format(s.diskFree)) liberi su \(Bytes.format(s.diskTotal))")
                    Gauge3(title: "Memoria", value: Double(s.memoryUsed) / Double(max(1, s.memoryTotal)),
                           detail: "\(Bytes.format(Int64(s.memoryUsed))) di \(Bytes.format(Int64(s.memoryTotal)))")
                    Gauge3(title: "Processore", value: s.cpuUsage,
                           detail: "\(Int(s.cpuUsage * 100))% in uso")
                    if let b = s.battery {
                        Gauge3(title: "Batteria", value: b,
                               detail: s.charging ? "In carica" : "A batteria")
                    }
                }
                .padding(20)

                Text("Azioni rapide").font(.headline).padding(.horizontal, 20)
                HStack(spacing: 12) {
                    quick(.cleanup, "Libera spazio")
                    quick(.space, "Cosa occupa il disco?")
                    quick(.duplicates, "Cerca duplicati")
                }
                .padding(20)
            }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func quick(_ m: Module, _ text: String) -> some View {
        Button { state.selection = m } label: {
            Label(text, systemImage: m.icon).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// Riquadro con anello di riempimento.
struct Gauge3: View {
    let title: String
    let value: Double
    let detail: String

    private var color: Color { value > 0.9 ? .red : value > 0.75 ? .orange : Brand.accent }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 8)
                Circle().trim(from: 0, to: min(1, max(0, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))%").font(.system(.callout, design: .rounded).bold())
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.accent.opacity(0.18)))
        .animation(.easeOut(duration: 0.4), value: value)
    }
}
