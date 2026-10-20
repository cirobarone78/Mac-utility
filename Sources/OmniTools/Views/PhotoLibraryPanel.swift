import SwiftUI
import Photos
import UtilityCore

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published var authorized = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    @Published var scanning = false
    @Published var status = ""
    @Published var photos: [LibraryPhoto] = []
    @Published var groups: [LibraryGroup] = []
    @Published var selected: Set<String> = []
    @Published var similarity: Double = 6
    @Published var message: String?
    @Published var scanned = false
    private var task: Task<Void, Never>?

    func requestAccess() async {
        authorized = await PhotoLibraryScanner.requestAccess()
        if !authorized { message = PhotoLibraryError.denied.localizedDescription }
    }

    func analyze() {
        task?.cancel()
        scanning = true
        message = nil
        groups = []
        selected = []
        let threshold = Int(similarity)
        let box = WeakRef(self)
        task = Task {
            let (found, grouped) = await Self.run(similarity: threshold) { done, total in
                Task { @MainActor in box.value?.status = "Foto lette: \(done) di \(total)…" }
            }
            if Task.isCancelled { return }
            photos = found
            groups = grouped
            // Preselezionate solo le copie della stessa foto (tranne la migliore); le simili le scegli tu.
            selected = Set(grouped.filter { $0.kind == .exact }.flatMap { $0.photos.dropFirst().map(\.id) })
            scanning = false
            scanned = true
            status = ""
        }
    }

    nonisolated static func run(similarity: Int,
                                progress: @escaping @Sendable (Int, Int) -> Void) async -> ([LibraryPhoto], [LibraryGroup]) {
        let photos = PhotoLibraryScanner.scan(progress: progress, isCancelled: { Task.isCancelled })
        return (photos, PhotoLibraryScanner.groups(photos, similarity: similarity, isCancelled: { Task.isCancelled }))
    }

    /// Ricalcola i gruppi con la nuova somiglianza senza rileggere la libreria.
    func regroup() {
        guard !photos.isEmpty else { return }
        groups = PhotoLibraryScanner.groups(photos, similarity: Int(similarity))
        let ids = Set(groups.flatMap { $0.photos.map(\.id) })
        selected = selected.intersection(ids)
    }

    func cancel() {
        task?.cancel()
        scanning = false
    }

    func toggle(_ photo: LibraryPhoto, in group: LibraryGroup) {
        if selected.contains(photo.id) {
            selected.remove(photo.id)
        } else if group.photos.filter({ !selected.contains($0.id) }).count > 1 {
            selected.insert(photo.id)
        }
    }

    func selectSimilarSuggestions() {
        selected.formUnion(groups.filter { $0.kind == .similar }.flatMap { $0.photos.dropFirst().map(\.id) })
    }

    func addToAlbum() async {
        let ids = Array(selected)
        do {
            try await PhotoLibraryScanner.addToReviewAlbum(ids)
            message = "\(ids.count) foto aggiunte all'album «\(PhotoLibraryScanner.reviewAlbumName)» in Foto. Nessuna foto è stata eliminata: aprile in Foto, controllale e, se vuoi, eliminale da lì."
            Journal.append(lines: ["ALBUM\t\(ids.count) foto in «\(PhotoLibraryScanner.reviewAlbumName)»"])
        } catch {
            message = "Non riesco a creare l'album: \(error.localizedDescription)"
        }
    }

    func delete() async {
        let ids = Array(selected)
        do {
            try await PhotoLibraryScanner.delete(ids)
            message = "\(ids.count) foto spostate in «Eliminati di recente» di Foto. Si recuperano da lì per 30 giorni, su tutti i dispositivi."
            Journal.append(lines: ["FOTO ELIMINATE\t\(ids.count) foto in «Eliminati di recente»"])
            let gone = Set(ids)
            photos.removeAll { gone.contains($0.id) }
            groups = groups.compactMap { g in
                let rest = g.photos.filter { !gone.contains($0.id) }
                return rest.count > 1 ? LibraryGroup(kind: g.kind, photos: rest) : nil
            }
            selected = []
        } catch {
            // Anche "Non eliminare" nella conferma di macOS arriva qui: nessuna foto toccata.
            message = "Nessuna foto eliminata. (\(error.localizedDescription))"
        }
    }
}

/// Doppioni e foto simili nella libreria dell'app Foto.
struct PhotoLibraryPanel: View {
    @StateObject private var model = PhotoLibraryModel()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Text("Somiglianza")
                    Slider(value: $model.similarity, in: 0...12, step: 1) { editing in
                        if !editing { model.regroup() }
                    }
                    .frame(width: 140)
                    Text(model.similarity <= 3 ? "quasi identiche" : model.similarity <= 7 ? "molto simili" : "simili")
                        .foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                }
                Spacer()
                if model.scanning {
                    Button("Interrompi") { model.cancel() }
                } else if model.authorized {
                    Button(model.scanned ? "Analizza di nuovo" : "Analizza la libreria") { model.analyze() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Consenti l'accesso a Foto") { Task { await model.requestAccess() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            content
        }
        .confirmationDialog("Eliminare \(model.selected.count) foto dalla libreria?", isPresented: $confirmDelete) {
            Button("Elimina (Eliminati di recente)", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("macOS chiederà un'ultima conferma. Le foto spariranno da tutti i dispositivi collegati a iCloud Foto e resteranno in «Eliminati di recente» per 30 giorni.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.scanning {
            ProgressView(model.status.isEmpty ? "Leggo la libreria di Foto…" : model.status)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.scanned {
            ContentUnavailableView {
                Label("Libreria di Foto", systemImage: "photo.stack")
            } description: {
                Text(model.message ?? "OmniTools legge le miniature che Foto tiene sul Mac (non scarica gli originali da iCloud) e trova le stesse foto importate più volte e le foto molto simili, come le copie ricevute su WhatsApp. Nessuna foto viene toccata finché non scegli tu.")
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let exact = model.groups.filter { $0.kind == .exact }.count
                Text("\(model.photos.count) foto analizzate · \(exact) gruppi della stessa foto · \(model.groups.count - exact) gruppi di foto simili")
                    .font(.callout)
                if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Brand.accent.opacity(0.06))

            if model.groups.isEmpty {
                ContentUnavailableView("Nessun doppione", systemImage: "checkmark.circle",
                                       description: Text("Prova ad aumentare la «Somiglianza»."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.groups) { group in
                            LibraryGroupView(group: group, selected: model.selected) { model.toggle($0, in: group) }
                        }
                    }
                    .padding(20)
                }
                HStack {
                    Button("Seleziona anche i suggerimenti tra le simili") { model.selectSimilarSuggestions() }
                    Button("Deseleziona tutto") { model.selected = [] }
                    Spacer()
                    Text("\(model.selected.count) foto").monospacedDigit()
                    Button("Metti in un album da controllare") { Task { await model.addToAlbum() } }
                        .disabled(model.selected.isEmpty)
                    Button("Elimina…") { confirmDelete = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selected.isEmpty)
                }
                .padding(16)
            }
        }
    }
}

private struct LibraryGroupView: View {
    let group: LibraryGroup
    let selected: Set<String>
    let toggle: (LibraryPhoto) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: group.kind == .exact ? "stessa foto" : "simili",
                      color: group.kind == .exact ? Brand.accent : .orange)
                Text("\(group.photos.count) foto").font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(group.photos) { photo in
                    LibraryTile(photo: photo, isBest: photo.id == group.photos.first?.id,
                                isSelected: selected.contains(photo.id))
                        .onTapGesture { toggle(photo) }
                }
            }
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LibraryTile: View {
    let photo: LibraryPhoto
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
                        Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
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
            Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 4) {
                if photo.isFavorite { Badge(text: "preferita", color: .pink) }
                if photo.isEdited { Badge(text: "modificata", color: .blue) }
                if photo.isScreenshot { Badge(text: "screenshot", color: .gray) }
            }
            if isBest { Text("consigliata da tenere").font(.caption2.bold()).foregroundStyle(Brand.accent) }
        }
        .frame(width: 150)
        .contentShape(Rectangle())
        .task(id: photo.id) { image = await Self.thumbnail(photo.id) }
    }

    private var details: String {
        var parts = ["\(photo.width)×\(photo.height)"]
        if let d = photo.date { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    static func thumbnail(_ id: String) async -> NSImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true     // una miniatura più nitida, se serve, da iCloud
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 220),
                                                  contentMode: .aspectFill, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded || image == nil, !resumed {
                    resumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
