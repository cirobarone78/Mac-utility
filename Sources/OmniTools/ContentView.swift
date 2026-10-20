import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Strumenti") {
                    ForEach([Module.dashboard, .space, .cleanup, .organize, .duplicates, .system, .startup]) { row($0) }
                }
                Section("Intelligenza artificiale") {
                    row(.assistant)
                }
                Section {
                    row(.rules)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            Group {
                switch state.selection ?? .dashboard {
                case .dashboard: DashboardView()
                case .space: SpaceView()
                case .cleanup: CleanupView()
                case .duplicates: DuplicatesView()
                case .system: SystemView()
                case .startup: StartupView()
                case .organize: OrganizeView()
                case .assistant: AssistantView()
                case .rules: RulesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Brand.background)
        }
    }

    private func row(_ m: Module) -> some View {
        Label(m.title, systemImage: m.icon).tag(m)
    }
}

/// Intestazione comune delle schermate.
struct ModuleHeader: View {
    let module: Module
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: module.icon)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Brand.accent)
                .frame(width: 44, height: 44)
                .background(Brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 8)
    }
}

/// Barra proporzionale per le dimensioni.
struct SizeBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Brand.accent.gradient)
                    .frame(width: max(2, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}
