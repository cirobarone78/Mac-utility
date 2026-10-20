import XCTest
@testable import UtilityCore

final class SafetyPolicyTests: XCTestCase {
    let home = "/Users/prova"
    let policy = SafetyPolicy.default

    func testRootsAndHomeAreProtected() {
        for p in ["/", "/Users", "/Applications", home, home + "/Documents", home + "/Library"] {
            XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: p), home: home), p)
        }
    }

    func testCachesAreNotProtected() {
        XCTAssertFalse(policy.isProtected(URL(fileURLWithPath: home + "/Library/Caches/com.app"), home: home))
        XCTAssertFalse(policy.isProtected(URL(fileURLWithPath: home + "/Downloads/vecchio.dmg"), home: home))
    }

    func testProtectedPathsAndNames() {
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: home + "/Library/Keychains/login.keychain-db"), home: home))
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: home + "/Progetti/app/.git/objects"), home: home))
        XCTAssertTrue(policy.isProtected(URL(fileURLWithPath: "/System/Library"), home: home))
        // Un prefisso simile non basta: /Systemx non è /System.
        XCTAssertFalse(policy.isProtected(URL(fileURLWithPath: home + "/Downloads/Systemx"), home: home))
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var p = SafetyPolicy.default
        p.neverTouchNames.append("Libri")
        try p.save(to: url)
        XCTAssertEqual(SafetyPolicy.load(from: url), p)
    }
}

final class CoreScanTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, bytes: Int, fill: UInt8) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    func testDuplicatesFound() throws {
        _ = try write("a.bin", bytes: 2_000_000, fill: 1)
        _ = try write("sub/b.bin", bytes: 2_000_000, fill: 1)
        _ = try write("c.bin", bytes: 2_000_000, fill: 2)      // stessa dimensione, contenuto diverso
        _ = try write("piccolo.bin", bytes: 10, fill: 1)        // sotto la soglia
        let groups = DuplicateFinder().find(under: dir, policy: SafetyPolicy(neverTouchPaths: [], neverTouchNames: []))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, 2)
        XCTAssertEqual(groups.first?.wasted, 2_000_000)
    }

    func testOldDownloadsFilter() throws {
        let old = try write("Downloads/vecchio.zip", bytes: 5000, fill: 3)
        _ = try write("Downloads/nuovo.zip", bytes: 5000, fill: 4)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200 * 86_400)],
                                              ofItemAtPath: old.path)
        let cat = CleanupCatalog.standard.first { $0.id == "old-downloads" }!
        let found = CleanupCatalog.scan([cat], policy: SafetyPolicy(neverTouchPaths: [], neverTouchNames: []),
                                        home: dir.path)
        XCTAssertEqual(found.map { $0.item.url.lastPathComponent }, ["vecchio.zip"])
    }

    func testChildrenSortedBySize() throws {
        _ = try write("piccola/x", bytes: 10_000, fill: 1)
        _ = try write("grande/y", bytes: 900_000, fill: 1)
        let items = DiskScanner().children(of: dir)
        XCTAssertEqual(items.first?.url.lastPathComponent, "grande")
    }
}

final class FolderOrganizerTests: XCTestCase {
    var dir: URL!
    var records: URL!
    let noRules = SafetyPolicy(neverTouchPaths: [], neverTouchNames: [])

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("org-" + UUID().uuidString)
        dir = base.appendingPathComponent("Download")
        records = base.appendingPathComponent("riordini")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    @discardableResult
    private func make(_ name: String, _ text: String = "x", age days: Double = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.data(using: .utf8)!.write(to: url)
        if days > 0 {
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -days * 86_400),
                                                   .modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    func testTokens() {
        XCTAssertEqual(FolderOrganizer.tokens("Fattura_Enel-2024marzo"), ["fatture", "enel", "2024marzo", "marzo"])
        XCTAssertTrue(FolderOrganizer.tokens("OmniNeo_logo_v2").contains("omnineo"))
        XCTAssertEqual(FolderOrganizer.tokens("Schermata 2026-10-01 alle 10.22.33"), ["screenshot"])
    }

    func testTopicGroupingAndUseless() throws {
        try make("Fattura_Enel_03.pdf", "a")
        try make("fattura TIM marzo.pdf", "b")
        try make("Schermata 2026-10-01 alle 10.22.33.png", "c")
        try make("Screenshot 2026-09-12.png", "d")
        try make("OmniNeo_logo.png", "e")
        try make("omnineo-deploy.zip", "f")
        try make("budget.xlsx", "g")
        try make("budget copia.xlsx", "g")          // copia identica
        try make("vuoto.txt", "")                   // vuoto
        try make("film.mp4.crdownload", "h")        // download a metà
        try make("Zoom.dmg", "i", age: 60)          // installer vecchio

        let plan = FolderOrganizer(strategy: .topic).plan(folder: dir, policy: noRules)
        let names = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.name, Set($0.files.map { $0.url.lastPathComponent })) })
        XCTAssertEqual(names["Fatture"], ["Fattura_Enel_03.pdf", "fattura TIM marzo.pdf"])
        XCTAssertEqual(names["Screenshot"]?.count, 2)
        XCTAssertEqual(names["OmniNeo"], ["OmniNeo_logo.png", "omnineo-deploy.zip"])

        let useless = Dictionary(uniqueKeysWithValues: plan.removals.map { ($0.item.url.lastPathComponent, $0.risk) })
        XCTAssertEqual(useless["budget copia.xlsx"], .safe)
        XCTAssertEqual(useless["vuoto.txt"], .safe)
        XCTAssertEqual(useless["film.mp4.crdownload"], .safe)
        XCTAssertEqual(useless["Zoom.dmg"], .review)
        XCTAssertNil(useless["budget.xlsx"])
        // Un file proposto come inutile non viene anche spostato.
        XCTAssertFalse(plan.groups.flatMap(\.files).contains { $0.url.lastPathComponent == "vuoto.txt" })
    }

    func testApplyAndUndo() throws {
        try make("Preventivo idraulico.pdf", "a")
        try make("preventivo-elettricista.pdf", "b")
        try make("solo.txt", "c")
        let plan = FolderOrganizer(strategy: .topic).plan(folder: dir, policy: noRules)

        var trashed: [DiskItem] = []
        let result = FolderOrganizer.apply(plan, removals: [], policy: noRules, recordsFolder: records) { items in
            trashed = items
            return SafeRemover.Report()
        }
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(result.moved, 3)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Preventivo/Preventivo idraulico.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("solo.txt").path))

        let undo = FolderOrganizer.undoLast(recordsFolder: records)
        XCTAssertEqual(undo?.restored, 3)
        // Una volta ripristinato non si annulla due volte.
        XCTAssertNil(FolderOrganizer.undoLast(recordsFolder: records))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("Preventivo idraulico.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("solo.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("Preventivo").path))
    }

    func testNameClash() throws {
        let sub = dir.appendingPathComponent("PDF")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "old".data(using: .utf8)!.write(to: sub.appendingPathComponent("a.pdf"))
        XCTAssertEqual(FolderOrganizer.uniqueDestination(for: "a.pdf", in: sub).lastPathComponent, "a 2.pdf")
        XCTAssertEqual(FolderOrganizer.sanitize("../Fatture/2024:"), "-Fatture-2024-")
    }
}

final class AIAdvisorTests: XCTestCase {
    private func response(_ text: String, stop: String = "end_turn") -> Data {
        let json: [String: Any] = [
            "stop_reason": stop,
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
            "usage": ["input_tokens": 1200, "output_tokens": 300],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParseStructuredReply() throws {
        let text = #"{"summary":"Download misti","proposals":[{"id":0,"action":"move","folder":"Casa","reason":"preventivo","confidence":"alta"},{"id":1,"action":"trash","folder":"","reason":"installer usato","confidence":"media"}]}"#
        let reply = try AIAdvisor.parse(response(text))
        XCTAssertEqual(reply.summary, "Download misti")
        XCTAssertEqual(reply.proposals.map(\.action), ["move", "trash"])
        XCTAssertEqual(reply.inputTokens, 1200)
    }

    func testRefusalAndTruncation() {
        XCTAssertThrowsError(try AIAdvisor.parse(response("", stop: "refusal")))
        XCTAssertThrowsError(try AIAdvisor.parse(response("{", stop: "max_tokens")))
        XCTAssertThrowsError(try AIAdvisor.parse(response("non json")))
    }

    func testSchemaIsValidJSON() throws {
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: AIAdvisor.schema))
    }

    func testMessageContainsOnlyMetadata() {
        let facts = [FileFacts(id: 0, name: "fattura.pdf", kind: "PDF", sizeBytes: 1000,
                               created: "2026-01-02", lastOpened: nil, hint: nil)]
        let msg = AIAdvisor.userMessage(folderName: "Download", facts: facts, instructions: "non toccare OmniNeo")
        XCTAssertTrue(msg.contains("\"name\":\"fattura.pdf\""))
        XCTAssertTrue(msg.contains("non toccare OmniNeo"))
    }

    func testApprovedProposalsBecomePlan() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let a = DiskItem(url: folder.appendingPathComponent("a.pdf"), bytes: 1, isDirectory: false)
        let b = DiskItem(url: folder.appendingPathComponent("b.dmg"), bytes: 2, isDirectory: false)
        let c = DiskItem(url: folder.appendingPathComponent("c.pdf"), bytes: 3, isDirectory: false)
        let advice = AIAdvice(folder: folder, proposals: [
            AIProposal(item: a, action: .move, folder: "Casa", reason: "", confidence: "alta"),
            AIProposal(item: b, action: .trash, folder: "", reason: "", confidence: "alta"),
            AIProposal(item: c, action: .move, folder: "Casa", reason: "", confidence: "alta"),
        ], summary: "", skippedFiles: 0)
        let (plan, removals) = advice.plan(approved: [a.url, b.url])   // c non approvato
        XCTAssertEqual(plan.groups.count, 1)
        XCTAssertEqual(plan.groups[0].files.map(\.url), [a.url])
        XCTAssertEqual(removals.map(\.url), [b.url])
    }
}

final class CacheKnowledgeTests: XCTestCase {
    let caches = CleanupCatalog.standard.first { $0.id == "user-caches" }!

    private func info(_ name: String) -> CacheInfo {
        CacheKnowledge.info(for: DiskItem(url: URL(fileURLWithPath: "/Users/x/Library/Caches/\(name)"),
                                          bytes: 1, isDirectory: true), category: caches)
    }

    func testKnownEntries() {
        XCTAssertTrue(info("Google").title.contains("Chrome"))
        XCTAssertEqual(info("Google").bundleIDs, ["com.google.Chrome"])
        XCTAssertEqual(info("ms-playwright").risk, .review)
        XCTAssertTrue(info("com.apple.bird").neverPropose)
        XCTAssertTrue(info("com.apple.parsecd").title.contains("Spotlight"))
    }

    func testFallbacks() {
        XCTAssertTrue(info("com.apple.qualcosa").title.contains("qualcosa"))
        XCTAssertEqual(info("CartellaIgnota").risk, .safe)
        let derived = CleanupCatalog.standard.first { $0.id == "xcode-derived" }!
        let d = CacheKnowledge.info(for: DiskItem(url: URL(fileURLWithPath: "/x/OmniTools-abcdef"), bytes: 1, isDirectory: true),
                                    category: derived)
        XCTAssertTrue(d.title.contains("«OmniTools»"))
    }
}

final class OperationLogTests: XCTestCase {
    func testRestoreMovesBackAndHandlesMissing() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("log-" + UUID().uuidString)
        let log = base.appendingPathComponent("operazioni")
        let original = base.appendingPathComponent("Download/a.txt")
        let fakeTrash = base.appendingPathComponent(".Trash/a.txt")
        try fm.createDirectory(at: fakeTrash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: fakeTrash, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: base) }

        let record = OperationRecord(kind: "Pulizia disco", summary: "prova", moves: [
            .init(from: original.path, to: fakeTrash.path),
            .init(from: base.appendingPathComponent("Download/b.txt").path,
                  to: base.appendingPathComponent(".Trash/b.txt").path),   // Cestino già svuotato
        ])
        OperationLog.save(record, in: log)
        XCTAssertEqual(OperationLog.list(in: log).count, 1)

        let r = OperationLog.restore(record, in: log)
        XCTAssertEqual(r.restored, 1)
        XCTAssertEqual(r.missing, 1)
        XCTAssertTrue(fm.fileExists(atPath: original.path))   // la cartella Download è stata ricreata
        XCTAssertTrue(OperationLog.list(in: log)[0].restored)
        XCTAssertNil(OperationLog.latest(in: log))
        XCTAssertTrue(record.moves[0].toTrash)
    }
}

final class PhotoAndCloudTests: XCTestCase {
    let home = "/Users/prova"

    func testICloudDriveFilesAllowedButAppContainersProtected() {
        let p = SafetyPolicy.default
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        XCTAssertTrue(p.isProtected(URL(fileURLWithPath: drive), home: home))                    // la radice no
        XCTAssertFalse(p.isProtected(URL(fileURLWithPath: drive + "/Foto/a.jpg"), home: home))   // i file sì
        XCTAssertTrue(p.isProtected(URL(fileURLWithPath: home + "/Library/Mobile Documents/com~apple~Pages/x"), home: home))
    }

    func testOldRulesFileGetsICloudException() throws {
        let json = #"{"neverTouchNames":[".git"],"neverTouchPaths":["~/Library/Mobile Documents"]}"#
        let p = try JSONDecoder().decode(SafetyPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(p.allowedPaths, SafetyPolicy.defaultAllowedPaths)
    }

    func testGoogleDriveRootsProtected() {
        let p = SafetyPolicy.default
        let mine = home + "/Library/CloudStorage/GoogleDrive-a@b.it/Il mio Drive"
        XCTAssertTrue(p.isProtected(URL(fileURLWithPath: mine), home: home))
        XCTAssertFalse(p.isProtected(URL(fileURLWithPath: mine + "/doc.pdf"), home: home))
    }

    private func item(_ name: String, hash: UInt64?, w: Int = 400, h: Int = 300, bytes: Int64 = 100) -> PhotoItem {
        PhotoItem(url: URL(fileURLWithPath: "/tmp/\(name)"), bytes: bytes, pixels: w * h, width: w, height: h,
                  date: nil, hasCaptureDate: false, visualHash: hash, isVideo: false)
    }

    func testSimilarGrouping() {
        let base: UInt64 = 0xA5A5_5A5A_F0F0_0F0F
        let groups = PhotoScanner.groups([
            item("a.jpg", hash: base, w: 4000, h: 3000, bytes: 3_000_000),
            item("a-whatsapp.jpg", hash: base ^ 0b111, w: 1600, h: 1200, bytes: 200_000),   // 3 bit diversi
            item("altra.jpg", hash: ~base),
            item("verticale.jpg", hash: base, w: 300, h: 400),                              // proporzioni diverse
            item("bianca.png", hash: 0), item("bianca2.png", hash: 0),                      // uniformi: escluse
        ], similarity: 6)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .similar)
        XCTAssertEqual(groups[0].items.first?.url.lastPathComponent, "a.jpg")   // la più grande si tiene
    }

    func testSorterPlan() {
        var c = DateComponents(); c.year = 2023; c.month = 7; c.day = 14
        let d = Calendar(identifier: .gregorian).date(from: c)!
        let photo = PhotoItem(url: URL(fileURLWithPath: "/tmp/root/x.jpg"), bytes: 1, pixels: 0, width: 0, height: 0,
                              date: d, hasCaptureDate: true, visualHash: nil, isVideo: false)
        let plan = PhotoSorter.plan([photo], root: URL(fileURLWithPath: "/tmp/root"))
        XCTAssertEqual(plan.first?.folder, "2023/07 luglio")
        let already = PhotoItem(url: URL(fileURLWithPath: "/tmp/root/2023/07 luglio/x.jpg"), bytes: 1, pixels: 0,
                                width: 0, height: 0, date: d, hasCaptureDate: true, visualHash: nil, isVideo: false)
        XCTAssertTrue(PhotoSorter.plan([already], root: URL(fileURLWithPath: "/tmp/root")).isEmpty)
    }
}

final class PhotoLibraryGroupingTests: XCTestCase {
    private func photo(_ id: String, hash: UInt64, w: Int = 4032, h: Int = 3024, at seconds: Double = 0,
                       favorite: Bool = false) -> LibraryPhoto {
        LibraryPhoto(id: id, width: w, height: h, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
                     isFavorite: favorite, isScreenshot: false, isEdited: false, hash: hash)
    }

    func testSamePhotoVersusSimilar() {
        let base: UInt64 = 0xA5A5_5A5A_F0F0_0F0F
        let groups = PhotoLibraryScanner.groups([
            photo("orig", hash: base),
            photo("import-doppio", hash: base),                                 // stessa foto importata due volte
            photo("whatsapp", hash: base ^ 0b1111, w: 1600, h: 1200, at: 3600), // copia ricompressa: simile
            photo("altra", hash: ~base, at: 10),
        ], similarity: 6)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .similar)           // il gruppo contiene anche la copia di WhatsApp
        XCTAssertEqual(groups[0].photos.count, 3)

        let exact = PhotoLibraryScanner.groups([photo("a", hash: base), photo("b", hash: base)], similarity: 6)
        XCTAssertEqual(exact.first?.kind, .exact)
    }

    func testFavoriteIsKept() {
        let base: UInt64 = 0xA5A5_5A5A_F0F0_0F0F
        let g = PhotoLibraryScanner.groups([photo("grande", hash: base),
                                            photo("preferita", hash: base, w: 2000, h: 1500, favorite: true)],
                                           similarity: 6)
        XCTAssertEqual(g.first?.photos.first?.id, "preferita")
    }
}

final class WhatsAppScannerTests: XCTestCase {
    func testScanMediaByChatSkippingDatabase() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wa-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let media = root.appendingPathComponent("Message/Media")
        let chatA = media.appendingPathComponent("393331112222@s.whatsapp.net/a/b")
        let group = media.appendingPathComponent("120363000@g.us/c")
        try fm.createDirectory(at: chatA, withIntermediateDirectories: true)
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        let big = Data(repeating: 7, count: 10_000)
        try big.write(to: chatA.appendingPathComponent("foto.jpg"))
        try big.write(to: group.appendingPathComponent("inoltrata.jpg"))          // stessa foto in un gruppo
        try Data(repeating: 1, count: 6000).write(to: chatA.appendingPathComponent("vocale.opus"))
        try Data("db".utf8).write(to: root.appendingPathComponent("ChatStorage.sqlite"))   // mai toccato

        let r = WhatsAppScanner.scan(root: root, policy: SafetyPolicy(neverTouchPaths: [], neverTouchNames: []))
        XCTAssertEqual(r.media.count, 3)
        XCTAssertFalse(r.media.contains { $0.url.pathExtension == "sqlite" })
        XCTAssertEqual(Set(r.media.map(\.chatName)), ["+393331112222", "Gruppo"])
        XCTAssertEqual(r.media.first { $0.url.lastPathComponent == "vocale.opus" }?.kind, .audio)
        XCTAssertEqual(r.duplicates.count, 1)
    }
}

final class AllFilesDuplicatesTests: XCTestCase {
    func testDocumentsAndVideosFoundAsExactCopies() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("all-" + UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let pdf = Data(repeating: 3, count: 50_000), video = Data(repeating: 9, count: 70_000)
        try pdf.write(to: dir.appendingPathComponent("contratto.pdf"))
        try pdf.write(to: dir.appendingPathComponent("sub/contratto copia.pdf"))
        try video.write(to: dir.appendingPathComponent("vacanza.mov"))
        try video.write(to: dir.appendingPathComponent("sub/vacanza 2.mov"))
        let policy = SafetyPolicy(neverTouchPaths: [], neverTouchNames: [], allowedPaths: [])

        let mediaOnly = PhotoScanner().scan(dir, policy: policy)
        XCTAssertEqual(mediaOnly.items.count, 2)                       // solo i video
        let all = PhotoScanner(includeAllFiles: true).scan(dir, policy: policy)
        XCTAssertEqual(all.items.count, 4)
        let groups = PhotoScanner.groups(all.items)
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.kind == .exact })
        // Il riordino per data ignora i documenti.
        XCTAssertTrue(PhotoSorter.plan(all.items, root: dir).allSatisfy(\.item.isMedia))
    }
}

final class SmartRenamerTests: XCTestCase {
    func testGenericNames() {
        for n in ["IMG_4021.jpg", "Schermata 2026-10-01 alle 10.22.33.png", "Senza titolo.txt", "Documento (3).pdf",
                  "WhatsApp Image 2024-01-01 at 10.00.00.jpeg", "20240101_123456.jpg", "PXL_20240101_123456.jpg"] {
            XCTAssertTrue(SmartRenamer.isGeneric(URL(fileURLWithPath: "/x/" + n)), n)
        }
        for n in ["Fattura Enel marzo.pdf", "CV Ciro 2026.docx", "Preventivo idraulico.pdf"] {
            XCTAssertFalse(SmartRenamer.isGeneric(URL(fileURLWithPath: "/x/" + n)), n)
        }
    }

    func testSanitizeAndApplyIsRestorable() throws {
        XCTAssertEqual(SmartRenamer.sanitize(" 2024/03/02: Fattura? Enel. "), "2024 03 02 Fattura Enel")
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ren-" + UUID().uuidString)
        let dir = base.appendingPathComponent("Download"), log = base.appendingPathComponent("log")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let file = dir.appendingPathComponent("IMG_1.jpg")
        try Data("x".utf8).write(to: file)
        let p = RenameProposal(item: DiskItem(url: file, bytes: 1, isDirectory: false), newBase: "2024-07-14 Mare", reason: "")
        let r = SmartRenamer.apply([p], folder: dir, policy: SafetyPolicy(neverTouchPaths: [], neverTouchNames: [], allowedPaths: []),
                                   recordsFolder: log)
        XCTAssertEqual(r.moved, 1)
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("2024-07-14 Mare.jpg").path))
        OperationLog.restore(OperationLog.list(in: log)[0], in: log)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }
}

final class XcodeVersionsTests: XCTestCase {
    private func item(_ name: String) -> DiskItem {
        DiskItem(url: URL(fileURLWithPath: "/x/" + name), bytes: 1, isDirectory: true)
    }

    func testNewestDeviceSupportIsNeverProposed() {
        let kept = XcodeVersions.dropNewestVersion([item("16.4 (20E247)"), item("17.0.1 (21A340)"),
                                                    item("iPhone15,2 17.5 (21F79)"), item("15.7 (19H12)")])
        XCTAssertEqual(Set(kept.map(\.url.lastPathComponent)), ["16.4 (20E247)", "17.0.1 (21A340)", "15.7 (19H12)"])
        XCTAssertTrue(XcodeVersions.dropNewestVersion([item("17.0 (21A329)")]).isEmpty)   // una sola: si tiene
    }

    func testVersionCompare() {
        XCTAssertEqual(XcodeVersions.version(in: "Xcode 16.2.1 beta"), [16, 2, 1])
        XCTAssertTrue(XcodeVersions.isNewer([17, 0, 1], than: [17, 0]))
        XCTAssertFalse(XcodeVersions.isNewer([16, 9], than: [17]))
    }
}
