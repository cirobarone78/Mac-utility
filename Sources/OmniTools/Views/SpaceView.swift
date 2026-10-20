import SwiftUI
import UtilityCore

@MainActor
final class SpaceModel: ObservableObject {
    enum Mode: String, CaseIterable { case folders = "Cartelle", largeFiles = "File grandi" }

    @Published var path: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]
    @Published var items: [DiskItem] = []
    @Published var mode: Mode = .folders
    @Published var loading = false
    private var task: Task<Void, Never>?

    var current: URL { path.last! }

    func load() {
        task?.cancel()
        loading = true
        items = []
        let root = current, scanMode = self.mode
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = DiskScanner()
            let result = scanMode == .folders
                ? scanner.children(of: root, isCancelled: { Task.isCancelled })
                : scanner.largeFiles(under: root, isCancelled: { Task.isCancelled })
            if Task.isCancelled { return }
            await MainActor.run {
                self?.items = result
                self?.loading = false
            }
        }
    }

    func open(_ item: DiskItem) {
        guard item.isDirectory else { return }
        path.append(item.url)
        load()
    }

    func goBack(to index: Int) {
        path = Array(path.prefix(index + 1))
        load()
    }
}

struct SpaceView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = SpaceModel()
    @State private var confirm: DiskItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .space, subtitle: "Scopri cosa occupa il disco. Doppio clic per entrare in una cartella.")
            HStack {
                breadcrumbs
                Spacer()
                Picker("", selection: $model.mode) {
                    ForEach(SpaceModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(width: 220)
                Button("Scegli cartella…") {
                    if let url = Finder.chooseFolder(start: model.current) {
                        model.path = [url]
                        model.load()
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            if model.loading {
                ProgressView("Misuro \(Finder.short(model.current))…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let maxBytes = max(1, model.items.first?.bytes ?? 1)
                List(model.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(item.isDirectory ? Brand.accent : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.mode == .folders ? item.url.lastPathComponent : Finder.short(item.url))
                                .lineLimit(1).truncationMode(.middle)
                            SizeBar(fraction: Double(item.bytes) / Double(maxBytes))
                        }
                        Text(Bytes.format(item.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.open(item) }
                    .contextMenu {
                        Button("Mostra nel Finder") { Finder.reveal(item.url) }
                        Button("Sposta nel Cestino…", role: .destructive) { confirm = item }
                            .disabled(state.policy.isProtected(item.url))
                    }
                }
            }
        }
        .onAppear { if model.items.isEmpty { model.load() } }
        .onChange(of: model.mode) { model.load() }
        .confirmationDialog("Spostare nel Cestino?", isPresented: Binding(
            get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { item in
            Button("Sposta nel Cestino (\(Bytes.format(item.bytes)))", role: .destructive) {
                _ = SafeRemover(policy: state.policy).moveToTrash([item])
                model.load()
            }
        } message: { item in
            Text("\(Finder.short(item.url))\nPotrai recuperarlo dal Cestino.")
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.path.enumerated()), id: \.offset) { i, url in
                if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Button(i == 0 ? Finder.short(url) : url.lastPathComponent) { model.goBack(to: i) }
                    .buttonStyle(.link)
            }
        }
        .lineLimit(1)
    }
}
