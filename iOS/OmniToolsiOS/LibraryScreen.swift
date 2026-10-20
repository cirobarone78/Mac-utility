import SwiftUI
import Photos
import UtilityCore

@MainActor
final class LibraryModel: ObservableObject {
    @Published var authorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var photos: [LibraryPhoto] = []
    @Published var groups: [LibraryGroup] = []
    @Published var selected: Set<String> = []
    @Published var similarity: Double = 6
    @Published var message: String?
    @Published var scanned = false
    private var task: Task<Void, Never>?

    func requestAccess() async {
        authorized = await PhotoLibraryScanner.requestAccess()
        if !authorized { message = "Consenti l'accesso completo: Impostazioni › Privacy e sicurezza › Foto › OmniTools." }
    }

    func analyze() {
        task?.cancel()
        scanning = true
        progress = 0
        message = nil
        let threshold = Int(similarity)
        let box = WeakRef(self)
        task = Task {
            let (found, grouped) = await Self.run(similarity: threshold) { done, total in
                Task { @MainActor in box.value?.progress = total > 0 ? Double(done) / Double(total) : 0 }
            }
            if Task.isCancelled { return }
            photos = found
            groups = grouped
            selected = Set(grouped.filter { $0.kind == .exact }.flatMap { $0.photos.dropFirst().map(\.id) })
            scanning = false
            scanned = true
        }
    }

    nonisolated static func run(similarity: Int,
                                progress: @escaping @Sendable (Int, Int) -> Void) async -> ([LibraryPhoto], [LibraryGroup]) {
        let photos = PhotoLibraryScanner.scan(progress: progress, isCancelled: { Task.isCancelled })
        return (photos, PhotoLibraryScanner.groups(photos, similarity: similarity, isCancelled: { Task.isCancelled }))
    }

    func cancel() { task?.cancel(); scanning = false }

    func regroup() {
        guard !photos.isEmpty else { return }
        groups = PhotoLibraryScanner.groups(photos, similarity: Int(similarity))
        selected = selected.intersection(Set(groups.flatMap { $0.photos.map(\.id) }))
    }

    func toggle(_ photo: LibraryPhoto, in group: LibraryGroup) {
        if selected.contains(photo.id) {
            selected.remove(photo.id)
        } else if group.photos.filter({ !selected.contains($0.id) }).count > 1 {
            selected.insert(photo.id)   // una foto per gruppo resta sempre
        }
    }

    func selectSimilar() {
        selected.formUnion(groups.filter { $0.kind == .similar }.flatMap { $0.photos.dropFirst().map(\.id) })
    }

    func addToAlbum() async {
        let ids = Array(selected)
        do {
            try await PhotoLibraryScanner.addToReviewAlbum(ids)
            message = "\(ids.count) foto nell'album «\(PhotoLibraryScanner.reviewAlbumName)». Nessuna eliminata: controllale in Foto."
        } catch {
            message = "Non riesco a creare l'album: \(error.localizedDescription)"
        }
    }

    func delete() async {
        let ids = Array(selected)
        do {
            try await PhotoLibraryScanner.delete(ids)
            message = "\(ids.count) foto in «Eliminati di recente» (recuperabili per 30 giorni)."
            let gone = Set(ids)
            photos.removeAll { gone.contains($0.id) }
            groups = groups.compactMap { g in
                let rest = g.photos.filter { !gone.contains($0.id) }
                return rest.count > 1 ? LibraryGroup(kind: g.kind, photos: rest) : nil
            }
            selected = []
        } catch {
            message = "Nessuna foto eliminata."
        }
    }
}

struct LibraryScreen: View {
    @StateObject private var model = LibraryModel()
    @State private var confirmDelete = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !model.authorized {
                    ContentUnavailableView {
                        Label("Doppioni nelle foto", systemImage: "photo.stack")
                    } description: {
                        Text(model.message ?? "OmniTools guarda le miniature delle tue foto per trovare doppioni e foto simili. Niente lascia il telefono e nulla viene eliminato senza conferma.")
                    } actions: {
                        Button("Consenti l'accesso a Foto") { Task { await model.requestAccess() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else if model.scanning {
                    VStack(spacing: 16) {
                        ProgressView(value: model.progress)
                        Text("Leggo le foto… \(Int(model.progress * 100))%").foregroundStyle(.secondary)
                        Button("Interrompi") { model.cancel() }
                    }
                    .padding(40)
                } else if !model.scanned {
                    ContentUnavailableView {
                        Label("Pronto", systemImage: "sparkles")
                    } description: {
                        Text("Con migliaia di foto servono alcuni minuti. Tieni l'app aperta durante l'analisi.")
                    } actions: {
                        Button("Analizza le foto") { model.analyze() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    results
                }
            }
            .navigationTitle("Foto")
            .toolbar {
                if model.scanned && !model.scanning {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Analizza di nuovo", systemImage: "arrow.clockwise") { model.analyze() }
                            Button("Somiglianza…", systemImage: "slider.horizontal.3") { showSettings = true }
                            Button("Seleziona anche le simili", systemImage: "checkmark.circle") { model.selectSimilar() }
                            Button("Deseleziona tutto", systemImage: "circle") { model.selected = [] }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { similaritySheet }
            .confirmationDialog("Eliminare \(model.selected.count) foto?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { Task { await model.delete() } }
            } message: {
                Text("Spariranno da tutti i dispositivi con iCloud Foto e resteranno in «Eliminati di recente» per 30 giorni.")
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    let exact = model.groups.filter { $0.kind == .exact }.count
                    Text("\(model.photos.count) foto · \(exact) gruppi della stessa foto · \(model.groups.count - exact) di foto simili")
                        .font(.footnote)
                    if let m = model.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                }
                if model.groups.isEmpty {
                    Text("Nessun doppione. Prova ad alzare la somiglianza dal menu in alto.").foregroundStyle(.secondary)
                }
                ForEach(model.groups) { group in
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(group.photos) { photo in
                                    LibraryThumb(photo: photo, isBest: photo.id == group.photos.first?.id,
                                                 isSelected: model.selected.contains(photo.id))
                                        .onTapGesture { model.toggle(photo, in: group) }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Badge(text: group.kind == .exact ? "stessa foto" : "simili",
                                  color: group.kind == .exact ? Theme.accent : .orange)
                            Text("\(group.photos.count) foto")
                        }
                    }
                }
            }
            if !model.selected.isEmpty {
                HStack(spacing: 10) {
                    Button { Task { await model.addToAlbum() } } label: {
                        Label("Album", systemImage: "rectangle.stack.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Elimina \(model.selected.count)", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }

    private var similaritySheet: some View {
        NavigationStack {
            Form {
                Section {
                    Slider(value: $model.similarity, in: 0...12, step: 1)
                    Text(model.similarity <= 3 ? "Solo foto quasi identiche" : model.similarity <= 7 ? "Foto molto simili" : "Anche foto solo simili: controlla bene")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Più alta è, più foto finiscono nello stesso gruppo. I gruppi si ricalcolano senza rileggere le foto.")
                }
            }
            .navigationTitle("Somiglianza")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { model.regroup(); showSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct LibraryThumb: View {
    let photo: LibraryPhoto
    let isBest: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        SelectableTile(image: image, isBest: isBest, isSelected: isSelected,
                       caption: photo.isFavorite ? "preferita" : (photo.date?.formatted(date: .abbreviated, time: .omitted) ?? ""))
            .task(id: photo.id) { image = await Self.load(photo.id) }
    }

    static func load(_ id: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 220, height: 220),
                                                  contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if (!degraded || image == nil), !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
