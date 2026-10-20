import Foundation
import ImageIO
import CoreGraphics

/// Una foto (o un video) trovata su disco.
public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let bytes: Int64
    /// Pixel totali (larghezza × altezza); 0 se non noti.
    public let pixels: Int
    public let width: Int
    public let height: Int
    /// Data di scatto (EXIF) se c'è, altrimenti la data di creazione del file.
    public let date: Date?
    public let hasCaptureDate: Bool
    /// Impronta visiva (dHash a 64 bit); nil per video o immagini illeggibili.
    public let visualHash: UInt64?
    public let isVideo: Bool
    public var id: URL { url }
    /// Foto o video (gli altri file servono solo per i doppioni identici).
    public var isMedia: Bool {
        let ext = url.pathExtension.lowercased()
        return PhotoScanner.imageExtensions.contains(ext) || PhotoScanner.videoExtensions.contains(ext)
    }
}

public struct PhotoGroup: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case exact, similar }
    public let id = UUID()
    public let kind: Kind
    /// Ordinate dalla migliore: la prima è quella proposta da tenere.
    public let items: [PhotoItem]
    public var wasted: Int64 { items.dropFirst().reduce(0) { $0 + $1.bytes } }

    public init(kind: Kind, items: [PhotoItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct PhotoScanResult: Sendable {
    public var items: [PhotoItem] = []
    /// File presenti solo nel cloud (non scaricati sul Mac): non analizzati.
    public var notDownloaded: [URL] = []
    public var notDownloadedBytes: Int64 = 0
}

/// Legge le foto di una cartella (anche iCloud Drive o Google Drive), trova doppioni e simili.
public struct PhotoScanner: Sendable {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
                                                      "gif", "webp", "bmp", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "3gp"]

    /// Se false, i file non scaricati vengono saltati (leggerli li scaricherebbe dal cloud).
    public var includeNotDownloaded = false
    public var includeVideos = true
    /// Anche documenti, PDF, archivi… (solo copie identiche, confrontate per contenuto).
    public var includeAllFiles = false

    public init(includeNotDownloaded: Bool = false, includeVideos: Bool = true, includeAllFiles: Bool = false) {
        self.includeNotDownloaded = includeNotDownloaded
        self.includeVideos = includeVideos
        self.includeAllFiles = includeAllFiles
    }

    // MARK: - Lettura

    public func scan(_ root: URL, policy: SafetyPolicy,
                     progress: (Int) -> Void = { _ in },
                     isCancelled: () -> Bool = { false }) -> PhotoScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey,
                                      .totalFileAllocatedSizeKey, .creationDateKey,
                                      .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        var result = PhotoScanResult()
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { _, _ in true })
        while let url = e?.nextObject() as? URL {
            if isCancelled() { break }
            let ext = url.pathExtension.lowercased()
            let isVideo = Self.videoExtensions.contains(ext)
            let isImage = Self.imageExtensions.contains(ext)
            guard isImage || (includeVideos && isVideo) || (includeAllFiles && !isVideo),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  !policy.isProtected(url) else { continue }
            let size = Int64(v.fileSize ?? 0)

            if !Self.isLocal(v, size: size) && !includeNotDownloaded {
                result.notDownloaded.append(url)
                result.notDownloadedBytes += size
                continue
            }
            result.items.append(isImage || isVideo
                ? Self.read(url, bytes: size, created: v.creationDate, isVideo: isVideo)
                : PhotoItem(url: url, bytes: size, pixels: 0, width: 0, height: 0, date: v.creationDate,
                            hasCaptureDate: false, visualHash: nil, isVideo: false))
            if result.items.count % 100 == 0 { progress(result.items.count) }
        }
        return result
    }

    /// Un file "segnaposto" del cloud non occupa spazio sul disco finché non viene scaricato.
    static func isLocal(_ v: URLResourceValues, size: Int64) -> Bool {
        if let status = v.ubiquitousItemDownloadingStatus {
            return status == .current || status == .downloaded
        }
        let allocated = v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? Int(size)
        return !(size > 0 && allocated == 0)
    }

    static func read(_ url: URL, bytes: Int64, created: Date?, isVideo: Bool) -> PhotoItem {
        guard !isVideo, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return PhotoItem(url: url, bytes: bytes, pixels: 0, width: 0, height: 0, date: created,
                             hasCaptureDate: false, visualHash: nil, isVideo: isVideo)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let capture = captureDate(props)
        return PhotoItem(url: url, bytes: bytes, pixels: w * h, width: w, height: h,
                         date: capture ?? created, hasCaptureDate: capture != nil,
                         visualHash: dHash(src), isVideo: false)
    }

    static func captureDate(_ props: [CFString: Any]) -> Date? {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        guard let raw else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: raw)
    }

    /// Impronta visiva "difference hash": miniatura 9×8 in grigi, 1 bit per ogni confronto tra pixel vicini.
    /// Due foto uguali ma ridimensionate o ricompresse hanno impronte quasi identiche.
    static func dHash(_ src: CGImageSource) -> UInt64? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return dHash(thumb)
    }

    public static func dHash(_ thumb: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                      bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if pixels[row * 9 + col] > pixels[row * 9 + col + 1] { hash |= 1 }
            }
        }
        return hash
    }

    // MARK: - Doppioni

    /// - Parameter similarity: differenza massima tra impronte (0 = identiche, 10 = abbastanza simili).
    public static func groups(_ items: [PhotoItem], similarity: Int = 6,
                              isCancelled: () -> Bool = { false }) -> [PhotoGroup] {
        var groups: [PhotoGroup] = []
        var used = Set<URL>()

        // 1. Copie identiche: stessa dimensione e stessa impronta SHA-256 del file.
        for sameSize in Dictionary(grouping: items, by: \.bytes).values where sameSize.count > 1 {
            if isCancelled() { return groups }
            for same in Dictionary(grouping: sameSize, by: { DuplicateFinder.hash($0.url, limit: nil) })
            where same.key != nil && same.value.count > 1 {
                groups.append(PhotoGroup(kind: .exact, items: same.value.sorted(by: better)))
                used.formUnion(same.value.map(\.url))
            }
        }

        // 2. Foto simili: impronte visive vicine (copie ridimensionate, ricompresse, raffiche).
        // Esclusi: immagini quasi uniformi (pagine bianche, schermate nere), la cui impronta
        // è sempre simile anche quando il contenuto è diverso.
        let candidates = items.filter {
            guard !used.contains($0.url), let h = $0.visualHash else { return false }
            return isInformative(h)
        }
        let clusters = cluster(hashes: candidates.map { $0.visualHash! },
                               ratios: candidates.map { $0.height > 0 ? Double($0.width) / Double($0.height) : 0 },
                               similarity: similarity, isCancelled: isCancelled)
        for c in clusters {
            groups.append(PhotoGroup(kind: .similar, items: c.map { candidates[$0] }.sorted(by: better)))
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// Raggruppa gli elementi con impronte vicine e stesse proporzioni (una foto verticale
    /// e una orizzontale non sono "la stessa"). Restituisce gli indici di ogni gruppo.
    public static func cluster(hashes: [UInt64], ratios: [Double], similarity: Int,
                               isCancelled: () -> Bool = { false }) -> [[Int]] {
        var parent = Array(hashes.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in hashes.indices {
            if i % 500 == 0 && isCancelled() { return [] }
            for j in (i + 1)..<hashes.count
            where (hashes[i] ^ hashes[j]).nonzeroBitCount <= similarity && abs(ratios[i] - ratios[j]) < 0.03 {
                let a = find(i), b = find(j)
                if a != b { parent[b] = a }
            }
        }
        return Dictionary(grouping: hashes.indices, by: find).values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    /// Esclude immagini quasi uniformi (pagine bianche, schermate nere): la loro impronta
    /// assomiglia a tutte le altre uniformi anche quando il contenuto è diverso.
    public static func isInformative(_ hash: UInt64) -> Bool { (6...58).contains(hash.nonzeroBitCount) }

    /// Quale tenere: più pixel, poi file più grande, poi con data di scatto, poi nome senza "copia"/"(1)".
    static func better(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        if a.pixels != b.pixels { return a.pixels > b.pixels }
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        if a.hasCaptureDate != b.hasCaptureDate { return a.hasCaptureDate }
        return FolderOrganizer.copyScore(a.url) < FolderOrganizer.copyScore(b.url)
    }
}

// MARK: - Riordino per anno e mese

public struct PhotoMove: Identifiable, Hashable, Sendable {
    public let item: PhotoItem
    /// Percorso relativo della cartella di destinazione, es. "2023/2023-07".
    public let folder: String
    public var id: URL { item.url }
}

public enum PhotoSorter {
    static let monthNames = ["01 gennaio", "02 febbraio", "03 marzo", "04 aprile", "05 maggio", "06 giugno",
                             "07 luglio", "08 agosto", "09 settembre", "10 ottobre", "11 novembre", "12 dicembre"]

    /// Cartella "AAAA/MM mese" di ogni foto; salta quelle già al posto giusto.
    public static func plan(_ items: [PhotoItem], root: URL) -> [PhotoMove] {
        let cal = Calendar(identifier: .gregorian)
        // Si riordinano solo foto e video: i documenti restano dove sono.
        return items.filter(\.isMedia).compactMap { item in
            let folder: String
            if let d = item.date {
                let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
                folder = "\(y)/\(monthNames[m - 1])"
            } else {
                folder = "Senza data"
            }
            let dest = root.appendingPathComponent(folder, isDirectory: true).standardizedFileURL.path
            if item.url.deletingLastPathComponent().standardizedFileURL.path == dest { return nil }
            return PhotoMove(item: item, folder: folder)
        }
    }

    /// Esegue gli spostamenti e li registra in Cronologia (ripristinabili).
    public static func apply(_ moves: [PhotoMove], root: URL, policy: SafetyPolicy,
                             recordsFolder: URL = OperationLog.folder,
                             isCancelled: () -> Bool = { false }) -> OrganizeResult {
        let fm = FileManager.default
        var result = OrganizeResult()
        var done: [OperationRecord.Move] = []
        var created: [String] = []

        for move in moves where !policy.isProtected(move.item.url) {
            if isCancelled() { break }
            var dir = root
            for part in move.folder.split(separator: "/") {
                dir = dir.appendingPathComponent(String(part), isDirectory: true)
                if !fm.fileExists(atPath: dir.path) {
                    do {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                        created.append(dir.path)
                        result.createdFolders += 1
                    } catch {
                        result.errors.append("\(move.folder): \(error.localizedDescription)")
                    }
                }
            }
            let dest = FolderOrganizer.uniqueDestination(for: move.item.url.lastPathComponent, in: dir)
            do {
                try fm.moveItem(at: move.item.url, to: dest)
                done.append(.init(from: move.item.url.path, to: dest.path))
                result.moved += 1
            } catch {
                result.errors.append("\(move.item.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let record = OperationRecord(kind: "Riordino foto",
                                     summary: "\(root.lastPathComponent): \(result.moved) foto in cartelle per anno e mese",
                                     moves: done, createdFolders: created)
        OperationLog.save(record, in: recordsFolder)
        if !done.isEmpty { result.operationID = record.id }
        return result
    }
}
