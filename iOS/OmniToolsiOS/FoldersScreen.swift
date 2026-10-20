import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import UtilityCore

@MainActor
final class FoldersModel: ObservableObject {
    @Published var folder: URL?
    @Published var scanning = false
    @Published var status = ""
    @Published var result: PhotoScanResult?
    @Published var groups: [PhotoGroup] = []
    @Published var moves: [PhotoMove] = []
    @Published var selected: Set<URL> = []
    @Published var message: String?
    @Published var lastOperationID: String?
    private var task: Task<Void, Never>?

    /// Una cartella scelta dall'app File: va "aperta" per poterci lavorare.
    func choose(_ url: URL) {
        folder?.stopAccessingSecurityScopedResource()
        guard url.startAccessingSecurityScopedResource() else {
            message = "iOS non ha concesso l'accesso a questa cartella."
            return
        }
        folder = url
        result = nil
        groups = []
        moves = []
        analyze()
    }

    func analyze() {
        guard let folder else { return }
        task?.cancel()
        scanning = true
        message = nil
        let box = WeakRef(self)
        task = Task {
            let (r, g) = await Self.run(folder) { n in Task { @MainActor in box.value?.status = "\(n) foto lette…" } }
            if Task.isCancelled { return }
            result = r
            groups = g
            selected = Set(g.filter { $0.kind == .exact }.flatMap { $0.items.dropFirst().map(\.url) })
            moves = PhotoSorter.plan(r.items, root: folder)
            scanning = false
        }
    }

    nonisolated static func run(_ folder: URL, progress: @escaping @Sendable (Int) -> Void) async -> (PhotoScanResult, [PhotoGroup]) {
        let policy = SafetyPolicy(neverTouchPaths: [], neverTouchNames: [".git"], allowedPaths: [])
        let r = PhotoScanner().scan(folder, policy: policy, progress: progress, isCancelled: { Task.isCancelled })
        return (r, PhotoScanner.groups(r.items, isCancelled: { Task.isCancelled }))
    }

    func toggle(_ item: PhotoItem, in group: PhotoGroup) {
        if selected.contains(item.url) {
            selected.remove(item.url)
        } else if group.items.filter({ !selected.contains($0.url) }).count > 1 {
            selected.insert(item.url)
        }
    }

    func trash() {
        let items = groups.flatMap(\.items).filter { selected.contains($0.url) }
            .map { DiskItem(url: $0.url, bytes: $0.bytes, isDirectory: false) }
        let policy = SafetyPolicy(neverTouchPaths: [], neverTouchNames: [], allowedPaths: [])
        let r = SafeRemover(policy: policy).moveToTrash(items, kind: "Doppioni foto")
        lastOperationID = r.operationID
        message = "\(r.moved.count) file in «Eliminati di recente» dell'app File."
            + (r.skipped.isEmpty ? "" : " Non spostati: \(r.skipped.count) (\(r.skipped[0].reason)).")
        let moved = Set(r.moved)
        groups = groups.compactMap { g in
            let rest = g.items.filter { !moved.contains($0.url) }
            return rest.count > 1 ? PhotoGroup(kind: g.kind, items: rest) : nil
        }
        selected.subtract(moved)
    }

    func sortByDate() {
        guard let folder else { return }
        let policy = SafetyPolicy(neverTouchPaths: [], neverTouchNames: [], allowedPaths: [])
        let r = PhotoSorter.apply(moves, root: folder, policy: policy)
        lastOperationID = r.operationID
        message = "\(r.moved) foto spostate in cartelle per anno e mese."
        moves = []
    }

    func restoreLast() {
        guard let id = lastOperationID,
              let record = OperationLog.list().first(where: { $0.id == id }), !record.restored else { return }
        message = OperationLog.restore(record).message
        lastOperationID = nil
        analyze()
    }
}

struct FoldersScreen: View {
    @StateObject private var model = FoldersModel()
    @State private var picking = false
    @State private var confirmTrash = false
    @State private var confirmSort = false

    var body: some View {
        NavigationStack {
            Group {
                if model.folder == nil {
                    ContentUnavailableView {
                        Label("Doppioni in una cartella", systemImage: "folder")
                    } description: {
                        Text("Scegli una cartella di iCloud Drive o dell'iPhone dall'app File: OmniTools trova le foto doppie o simili e può riordinarle per anno e mese.")
                    } actions: {
                        Button("Scegli una cartella") { picking = true }.buttonStyle(.borderedProminent)
                    }
                } else if model.scanning {
                    ProgressView(model.status.isEmpty ? "Analisi…" : model.status)
                } else {
                    content
                }
            }
            .navigationTitle(model.folder?.lastPathComponent ?? "Cartelle")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cambia", systemImage: "folder.badge.plus") { picking = true }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.choose(url) }
            }
            .confirmationDialog("Spostare \(model.selected.count) file in «Eliminati di recente»?",
                                isPresented: $confirmTrash, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { model.trash() }
            } message: {
                Text("In iCloud Drive spariscono da tutti i dispositivi; restano recuperabili per 30 giorni dall'app File.")
            }
            .confirmationDialog("Riordinare \(model.moves.count) foto per anno e mese?",
                                isPresented: $confirmSort, titleVisibility: .visible) {
                Button("Riordina") { model.sortByDate() }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if let r = model.result {
                        Text("\(r.items.count) foto · \(model.groups.count) gruppi di doppioni")
                            .font(.footnote)
                        if !r.notDownloaded.isEmpty {
                            Text("\(r.notDownloaded.count) foto sono solo in iCloud e non sono state analizzate.")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    if let m = model.message {
                        Text(m).font(.footnote).foregroundStyle(.secondary)
                        if model.lastOperationID != nil {
                            Button("Ripristina") { model.restoreLast() }
                        }
                    }
                    if !model.moves.isEmpty {
                        Button("Riordina \(model.moves.count) foto per anno e mese") { confirmSort = true }
                    }
                }
                ForEach(model.groups) { group in
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(group.items) { item in
                                    FileThumb(item: item, isBest: item.id == group.items.first?.id,
                                              isSelected: model.selected.contains(item.url))
                                        .onTapGesture { model.toggle(item, in: group) }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Badge(text: group.kind == .exact ? "identiche" : "simili",
                                  color: group.kind == .exact ? Theme.accent : .orange)
                            Text("\(group.items.count) foto")
                        }
                    }
                }
            }
            if !model.selected.isEmpty {
                Button(role: .destructive) { confirmTrash = true } label: {
                    Label("Elimina \(model.selected.count)", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }
}

private struct FileThumb: View {
    let item: PhotoItem
    let isBest: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        SelectableTile(image: image, isBest: isBest, isSelected: isSelected,
                       caption: item.url.lastPathComponent)
            .task(id: item.url) {
                let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 110, height: 110),
                                                           scale: 2, representationTypes: .thumbnail)
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            }
    }
}
