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
