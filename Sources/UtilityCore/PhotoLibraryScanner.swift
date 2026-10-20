import Foundation
import Photos
import AppKit
import CoreGraphics

/// Una foto della libreria di Foto (iCloud Foto), vista tramite PhotoKit.
public struct LibraryPhoto: Identifiable, Hashable, Sendable {
    public let id: String            // localIdentifier di PhotoKit
    public let width: Int
    public let height: Int
    public let date: Date?
    public let isFavorite: Bool
    public let isScreenshot: Bool
    public let isEdited: Bool
    public let hash: UInt64
    public var pixels: Int { width * height }
}

public struct LibraryGroup: Identifiable, Hashable, Sendable {
    public let id = UUID()
    /// .exact = stessa foto (stesse dimensioni, stesso istante, impronta quasi uguale); .similar = simili.
    public let kind: PhotoGroup.Kind
    /// La prima è quella proposta da tenere.
    public let photos: [LibraryPhoto]

    public init(kind: PhotoGroup.Kind, photos: [LibraryPhoto]) {
        self.kind = kind
        self.photos = photos
    }
}

public enum PhotoLibraryError: LocalizedError {
    case denied
    public var errorDescription: String? {
        "OmniTools non ha accesso a Foto. Concedilo in Impostazioni di Sistema › Privacy e sicurezza › Foto › OmniTools (accesso completo)."
    }
}

/// Lettura della libreria di Foto e operazioni sicure (album da controllare, «Eliminati di recente»).
public enum PhotoLibraryScanner {
    public static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized
    }

    /// Legge tutte le foto (non i video) e ne calcola l'impronta dalle miniature locali:
    /// non scarica gli originali da iCloud.
    public static func scan(progress: (Int, Int) -> Void = { _, _ in },
                            isCancelled: () -> Bool = { false }) -> [LibraryPhoto] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        let manager = PHImageManager.default()
        let request = PHImageRequestOptions()
        request.isSynchronous = true
        request.deliveryMode = .fastFormat
        request.resizeMode = .fast
        request.isNetworkAccessAllowed = false

        var out: [LibraryPhoto] = []
        out.reserveCapacity(assets.count)
        let total = assets.count
        for i in 0..<total {
            if isCancelled() { break }
            let asset = assets.object(at: i)
            var cg: CGImage?
            manager.requestImage(for: asset, targetSize: CGSize(width: 64, height: 64),
                                 contentMode: .aspectFit, options: request) { image, _ in
                cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            guard let cg, let h = PhotoScanner.dHash(cg) else { continue }
            out.append(LibraryPhoto(id: asset.localIdentifier, width: asset.pixelWidth, height: asset.pixelHeight,
                                    date: asset.creationDate, isFavorite: asset.isFavorite,
                                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                    isEdited: asset.hasAdjustments, hash: h))
            if i % 200 == 0 { progress(i, total) }
        }
        progress(total, total)
        return out
    }

    public static func groups(_ photos: [LibraryPhoto], similarity: Int,
                              isCancelled: () -> Bool = { false }) -> [LibraryGroup] {
        let candidates = photos.filter { PhotoScanner.isInformative($0.hash) && $0.height > 0 }
        let clusters = PhotoScanner.cluster(hashes: candidates.map(\.hash),
                                            ratios: candidates.map { Double($0.width) / Double($0.height) },
                                            similarity: similarity, isCancelled: isCancelled)
        return clusters.map { idx in
            let items = idx.map { candidates[$0] }.sorted(by: better)
            return LibraryGroup(kind: isSamePhoto(items) ? .exact : .similar, photos: items)
        }
        .sorted { $0.photos.count > $1.photos.count }
    }

    /// Stesse dimensioni, scattate nello stesso secondo e impronta quasi uguale: è la stessa foto importata più volte.
    static func isSamePhoto(_ items: [LibraryPhoto]) -> Bool {
        guard let first = items.first, let d0 = first.date else { return false }
        return items.allSatisfy {
            $0.width == first.width && $0.height == first.height
                && ($0.hash ^ first.hash).nonzeroBitCount <= 2
                && $0.date.map { abs($0.timeIntervalSince(d0)) < 1 } == true
        }
    }

    /// Quale tenere: preferita, poi più pixel, poi con modifiche, poi non screenshot, poi la più vecchia (l'originale).
    static func better(_ a: LibraryPhoto, _ b: LibraryPhoto) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        if a.pixels != b.pixels { return a.pixels > b.pixels }
        if a.isEdited != b.isEdited { return a.isEdited }
        if a.isScreenshot != b.isScreenshot { return !a.isScreenshot }
        return (a.date ?? .distantFuture) < (b.date ?? .distantFuture)
    }

    // MARK: - Azioni

    public static let reviewAlbumName = "OmniTools – da controllare"

    /// Aggiunge le foto a un album da controllare in Foto (nessuna foto viene eliminata).
    public static func addToReviewAlbum(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var existing: PHAssetCollection?
        albums.enumerateObjects { c, _, stop in
            if c.localizedTitle == reviewAlbumName { existing = c; stop.pointee = true }
        }
        let album = existing
        try await PHPhotoLibrary.shared().performChanges {
            let request = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: reviewAlbumName)
            request.addAssets(assets)
        }
    }

    /// Elimina le foto: macOS chiede conferma e le sposta in «Eliminati di recente» (30 giorni).
    public static func delete(_ ids: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}
