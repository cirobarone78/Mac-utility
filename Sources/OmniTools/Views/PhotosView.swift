import SwiftUI
import QuickLookThumbnailing
import UtilityCore

@MainActor
final class PhotosModel: ObservableObject {
    enum Tab: String, CaseIterable { case duplicates = "Doppioni", sort = "Riordina per data" }

    @Published var locations: [CloudLocation] = CloudLocations.detect()
    @Published var folder: URL?
    @Published var tab: Tab = .duplicates
    @Published var includeNotDownloaded = false
    @Published var includeVideos = true
    @Published var includeAllFiles = false
    @Published var similarity: Double = 6

    @Published var scanning = false
    @Published var status = ""
    @Published var scan: PhotoScanResult?
    @Published var groups: [PhotoGroup] = []
    @Published var selected: Set<URL> = []
    @Published var moves: [PhotoMove] = []
    @Published var message: String?
    @Published var lastOperationID: String?
    /// true = libreria dell'app Foto invece di una cartella.
    @Published var useLibrary = false
    private var task: Task<Void, Never>?

    init() { folder = locations.first?.url }

    var folderName: String {
        if useLibrary { return "Libreria di Foto (iCloud Foto)" }
        guard let folder else { return "Nessuna cartella" }
        return locations.first { $0.url == folder }?.name ?? Finder.short(folder)
    }

    var isCloud: Bool { folder.map { f in locations.contains { $0.url == f } } ?? false }

    var selectedItems: [PhotoItem] { groups.flatMap(\.items).filter { selected.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func analyze(policy: SafetyPolicy) {
        guard let folder else { return }
        task?.cancel()
        scanning = true
        message = nil
        groups = []
        moves = []
        selected = []
        let opts = (includeNotDownloaded, includeVideos, Int(similarity), includeAllFiles)
        let box = WeakRef(self)
        task = Task {
            let (result, found) = await Self.run(folder, policy: policy, options: opts) { n in
                Task { @MainActor in box.value?.status = "\(n) foto lette…" }
            }
            if Task.isCancelled { return }
            scan = result
            groups = found
            // Preselezionate solo le copie IDENTICHE (tranne la migliore); le simili le scegli tu.
            selected = Set(found.filter { $0.kind == .exact }.flatMap { $0.items.dropFirst().map(\.url) })
            moves = PhotoSorter.plan(result.items, root: folder)
            scanning = false
            status = ""
        }
    }

    nonisolated static func run(_ folder: URL, policy: SafetyPolicy, options: (Bool, Bool, Int, Bool),
                                progress: @escaping @Sendable (Int) -> Void) async -> (PhotoScanResult, [PhotoGroup]) {
        let scanner = PhotoScanner(includeNotDownloaded: options.0, includeVideos: options.1, includeAllFiles: options.3)
        let result = scanner.scan(folder, policy: policy, progress: progress, isCancelled: { Task.isCancelled })
        let groups = PhotoScanner.groups(result.items, similarity: options.2, isCancelled: { Task.isCancelled })
        return (result, groups)
    }

    func cancel() {
        task?.cancel()
        scanning = false
    }

    func selectSimilarSuggestions() {
        selected.formUnion(groups.filter { $0.kind == .similar }.flatMap { $0.items.dropFirst().map(\.url) })
    }

    /// Almeno una foto per gruppo resta sempre.
    func toggle(_ item: PhotoItem, in group: PhotoGroup) {
        if selected.contains(item.url) {
            selected.remove(item.url)
        } else if group.items.filter({ !selected.contains($0.url) }).count > 1 {
            selected.insert(item.url)
        }
    }

    func trash(policy: SafetyPolicy) {
        let items = selectedItems.map { DiskItem(url: $0.url, bytes: $0.bytes, isDirectory: false) }
        let r = SafeRemover(policy: policy).moveToTrash(items, kind: "Doppioni foto")
        lastOperationID = r.operationID
        message = "\(r.moved.count) foto nel Cestino (\(Bytes.format(r.bytes)))."
            + (r.skipped.isEmpty ? "" : " Saltate \(r.skipped.count). Motivo: \(r.skipped[0].reason)")
        let moved = Set(r.moved)
        groups = groups.compactMap { g in
            let rest = g.items.filter { !moved.contains($0.url) }
            return rest.count > 1 ? PhotoGroup(kind: g.kind, items: rest) : nil
        }
        selected.subtract(moved)
    }

    func sort(policy: SafetyPolicy) {
        guard let folder else { return }
        let r = PhotoSorter.apply(moves, root: folder, policy: policy)
        lastOperationID = r.operationID
        message = "\(r.moved) foto spostate in \(r.createdFolders) cartelle nuove."
            + (r.errors.isEmpty ? "" : " Problemi: " + r.errors.prefix(3).joined(separator: "; "))
        moves = []
    }

    func restoreLast() {
        guard let id = lastOperationID else { return }
        message = Restore.run(id) ?? "Già ripristinato."
        lastOperationID = nil
        groups = []
        moves = []
    }
}

struct PhotosView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = PhotosModel()
    @State private var confirmTrash = false
    @State private var confirmSort = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: .photos,
                         subtitle: "Doppioni di foto, video e documenti in iCloud Drive, Google Drive o in qualsiasi cartella. Riordino per anno e mese.")
            if model.useLibrary {
                sourceMenu.padding(.horizontal, 20).padding(.bottom, 4)
                PhotoLibraryPanel()
            } else {
                controls
                Divider()
                content
            }
        }
        .confirmationDialog("Spostare nel Cestino \(model.selected.count) foto?", isPresented: $confirmTrash) {
            Button("Sposta nel Cestino (\(Bytes.format(model.selectedBytes)))", role: .destructive) {
                model.trash(policy: state.policy)
            }
        } message: {
            Text(model.isCloud
                 ? "Questa cartella è sincronizzata: le foto spariranno anche dagli altri dispositivi. Restano recuperabili dal Cestino del Mac, dal cestino del servizio cloud (30 giorni) e da Cronologia › Ripristina."
                 : "Restano recuperabili dal Cestino e da Cronologia › Ripristina.")
        }
        .confirmationDialog("Riordinare \(model.moves.count) foto per anno e mese?", isPresented: $confirmSort) {
            Button("Riordina") { model.sort(policy: state.policy) }
        } message: {
            Text("Verranno create cartelle come «2023/07 luglio» dentro «\(model.folderName)». Su un cloud le modifiche si sincronizzano sugli altri dispositivi. Si annulla da Cronologia › Ripristina.")
        }
    }

    // MARK: - Comandi

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sourceMenu
                Spacer()
                Picker("", selection: $model.tab) {
                    ForEach(PhotosModel.Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(width: 260)
                if model.scanning {
                    Button("Interrompi") { model.cancel() }
                } else {
                    Button("Analizza") { model.analyze(policy: state.policy) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.folder == nil)
                }
            }
            HStack(spacing: 18) {
                Toggle("Video", isOn: $model.includeVideos)
                Toggle("Anche documenti e altri file", isOn: $model.includeAllFiles)
                    .help("PDF, documenti, archivi…: cerca le copie identiche (stesso contenuto, anche con nome diverso).")
                Toggle("Includi anche le foto non scaricate sul Mac", isOn: $model.includeNotDownloaded)
                    .help("Leggerle le scarica dal cloud: servono tempo e spazio libero.")
                if model.tab == .duplicates {
                    HStack(spacing: 6) {
                        Text("Somiglianza")
                        Slider(value: $model.similarity, in: 0...12, step: 1).frame(width: 120)
                        Text(model.similarity <= 3 ? "quasi identiche" : model.similarity <= 7 ? "molto simili" : "simili")
                            .foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                    }
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private var sourceMenu: some View {
        Menu {
            Button("Libreria di Foto (iCloud Foto)") { model.useLibrary = true }
            Divider()
            ForEach(model.locations) { loc in
                Button(loc.name) { model.useLibrary = false; model.folder = loc.url; model.groups = []; model.moves = [] }
            }
            Divider()
            Button("Altra cartella…") {
                if let u = Finder.chooseFolder(start: model.folder) {
                    model.useLibrary = false; model.folder = u; model.groups = []
                }
            }
        } label: {
            Label(model.folderName, systemImage: model.useLibrary ? "photo.stack" : (model.isCloud ? "icloud" : "folder"))
        }
        .frame(maxWidth: 380)
    }

    @ViewBuilder
    private var content: some View {
        if model.scanning {
            ProgressView(model.status.isEmpty ? "Leggo le foto…" : model.status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let scan = model.scan {
            VStack(spacing: 0) {
                summary(scan)
                switch model.tab {
                case .duplicates: duplicates
                case .sort: sorting
                }
            }
        } else {
            ContentUnavailableView {
                Label("Scegli una cartella e premi «Analizza»", systemImage: Module.photos.icon)
            } description: {
                Text(model.locations.isEmpty
                     ? "Non ho trovato iCloud Drive né Google Drive su questo Mac: usa «Altra cartella…»."
                     : "Trovate: " + model.locations.map(\.name).joined(separator: ", ") + ". Nessuna foto viene toccata finché non confermi.")
            } actions: {
                if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() } }
            }
        }
    }

    private func summary(_ scan: PhotoScanResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let exact = model.groups.filter { $0.kind == .exact }
            let similar = model.groups.filter { $0.kind == .similar }
            let docs = scan.items.filter { !$0.isMedia }.count
            Text("\(scan.items.count - docs) foto e video\(docs > 0 ? " e \(docs) altri file" : "") analizzati · \(exact.count) gruppi di copie identiche · \(similar.count) gruppi di foto simili")
                .font(.callout)
            if !scan.notDownloaded.isEmpty {
                Label("\(scan.notDownloaded.count) foto (\(Bytes.format(scan.notDownloadedBytes))) sono solo nel cloud e non sono state analizzate. Per includerle attiva «Includi anche le foto non scaricate»: verranno scaricate sul Mac.",
                      systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let m = model.message {
                HStack {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                    if model.lastOperationID != nil { Button("Ripristina") { model.restoreLast() }.controlSize(.small) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Brand.accent.opacity(0.06))
    }

    // MARK: - Doppioni

    @ViewBuilder
    private var duplicates: some View {
        if model.groups.isEmpty {
            ContentUnavailableView("Nessun doppione", systemImage: "checkmark.circle",
                                   description: Text("Prova ad aumentare la «Somiglianza» per trovare anche le foto simili."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.groups) { group in
                        PhotoGroupView(group: group, selected: model.selected) { model.toggle($0, in: group) }
                    }
                }
                .padding(20)
            }
            HStack {
                Button("Seleziona anche i suggerimenti tra le simili") { model.selectSimilarSuggestions() }
                Button("Deseleziona tutto") { model.selected = [] }
                Spacer()
                Text("\(model.selected.count) foto · \(Bytes.format(model.selectedBytes))").monospacedDigit()
                Button("Sposta nel Cestino…") { confirmTrash = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty)
            }
            .padding(16)
        }
    }

    // MARK: - Riordino

    @ViewBuilder
    private var sorting: some View {
        if model.moves.isEmpty {
            ContentUnavailableView("Niente da riordinare", systemImage: "checkmark.circle",
                                   description: Text("Le foto analizzate sono già nelle cartelle per anno e mese."))
        } else {
            let byFolder = Dictionary(grouping: model.moves, by: \.folder)
                .map { FolderCount(name: $0.key, count: $0.value.count) }
                .sorted { $0.name > $1.name }
            List {
                Section {
                    ForEach(byFolder) { entry in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Brand.accent)
                            Text(entry.name)
                            Spacer()
                            Text("\(entry.count) foto").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cartelle che verranno usate dentro «\(model.folderName)»")
                } footer: {
                    Text("La data è quella di scatto scritta nella foto (EXIF); se manca, quella di creazione del file. Le foto già al posto giusto non vengono toccate.")
                }
            }
            HStack {
                Spacer()
                Button("Riordina \(model.moves.count) foto…") { confirmSort = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }
}

private struct FolderCount: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

/// Un gruppo di doppioni con le anteprime.
private struct PhotoGroupView: View {
    let group: PhotoGroup
    let selected: Set<URL>
    let toggle: (PhotoItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: group.kind == .exact ? "identiche" : "simili",
                      color: group.kind == .exact ? Brand.accent : .orange)
                Text("\(group.items.count) foto · recuperabili \(Bytes.format(group.wasted))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(group.items) { item in
                    PhotoTile(item: item, isBest: item.id == group.items.first?.id,
                              isSelected: selected.contains(item.url))
                        .onTapGesture { toggle(item) }
                }
            }
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PhotoTile: View {
    let item: PhotoItem
    let isBest: Bool
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: item.isVideo ? "video" : (item.isMedia ? "photo" : "doc")).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 150, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.red : (isBest ? Brand.accent : .clear), lineWidth: 3))
                .opacity(isSelected ? 0.55 : 1)

                Image(systemName: isSelected ? "trash.circle.fill" : (isBest ? "star.circle.fill" : "circle"))
                    .font(.title2)
                    .foregroundStyle(isSelected ? .red : (isBest ? Brand.accent : .white))
                    .shadow(radius: 2)
                    .padding(6)
            }
            Text(item.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(folderHint).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            if isBest { Text("consigliata da tenere").font(.caption2.bold()).foregroundStyle(Brand.accent) }
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .help(Finder.short(item.url))
        .contextMenu {
            Button("Apri") { NSWorkspace.shared.open(item.url) }
            Button("Mostra nel Finder") { Finder.reveal(item.url) }
        }
        .task(id: item.url) { image = await Self.thumbnail(item.url) }
    }

    /// La cartella in cui si trova: tra copie identiche è ciò che le distingue.
    private var folderHint: String {
        let parent = item.url.deletingLastPathComponent()
        return "in " + parent.lastPathComponent
    }

    private var details: String {
        var parts = [Bytes.format(item.bytes)]
        if item.width > 0 { parts.append("\(item.width)×\(item.height)") }
        if let d = item.date { parts.append(d.formatted(date: .numeric, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    static func thumbnail(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 300, height: 220),
                                                   scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
