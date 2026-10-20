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
        XCTAssertEqual(undo?.moved, 3)
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
