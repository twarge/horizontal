import XCTest
@testable import HorizontalNative

/// The registered-pool store and the library scanner behind the pool browser.
final class HorizontalPoolLibraryTests: XCTestCase {
    private var temporaryRoot: URL!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolLibraryTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "HorizontalPoolLibraryTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func write(_ json: JSONDictionary, to relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    // MARK: - Registry store

    func testRegistryRejectsDirectoriesWithoutAPoolJSON() throws {
        let notAPool = temporaryRoot.appendingPathComponent("just-a-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: notAPool, withIntermediateDirectories: true)
        XCTAssertFalse(HorizontalPoolRegistryStore.addPool(at: notAPool))
        XCTAssertTrue(HorizontalPoolRegistryStore.poolURLs().isEmpty)
    }

    func testRegistryPersistsAddsAndRemoves() throws {
        _ = try write(["type": "pool", "uuid": "p1", "name": "My Pool"], to: "pool-a/pool.json")
        let poolURL = temporaryRoot.appendingPathComponent("pool-a", isDirectory: true)

        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: poolURL))
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: poolURL), "re-adding is idempotent")
        XCTAssertEqual(HorizontalPoolRegistryStore.poolURLs().map(\.lastPathComponent), ["pool-a"])
        XCTAssertEqual(HorizontalPoolRegistryStore.poolInfo(at: poolURL).name, "My Pool")

        HorizontalPoolRegistryStore.removePool(at: poolURL)
        XCTAssertTrue(HorizontalPoolRegistryStore.poolURLs().isEmpty)
    }

    func testRegisteredPoolsFeedThePadstackCatalog() throws {
        _ = try write(["type": "pool", "uuid": "base"], to: "registered/pool.json")
        _ = try write(
            ["type": "padstack", "padstack_type": "via", "uuid": "aaaa-via", "name": "Registered via"],
            to: "registered/padstacks/via.json"
        )
        _ = try write(["type": "pool", "uuid": "proj"], to: "project/pool/pool.json")
        let projectPool = temporaryRoot.appendingPathComponent("project/pool", isDirectory: true)

        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(
            at: temporaryRoot.appendingPathComponent("registered", isDirectory: true)
        ))
        HorizontalPoolPadstacks.invalidateCaches()
        defer { HorizontalPoolPadstacks.invalidateCaches() }

        let vias = HorizontalPoolPadstacks.padstacks(ofTypes: ["via"], poolURL: projectPool)
        XCTAssertEqual(vias.map(\.name), ["Registered via"])
    }

    // MARK: - Library scanner

    func testScanBucketsItemsByTypeWithNamesAndDetails() throws {
        _ = try write(["type": "pool", "uuid": "p"], to: "pool/pool.json")
        _ = try write(["type": "unit", "uuid": "u1", "name": "Opamp"], to: "pool/units/opamp.json")
        _ = try write(
            ["type": "padstack", "padstack_type": "via", "uuid": "ps1", "name": "Circular via"],
            to: "pool/padstacks/via.json"
        )
        _ = try write(
            [
                "type": "part", "uuid": "pt1",
                "MPN": [false, "LM358"], "manufacturer": [false, "TI"],
                "tags": ["opamp", "dual"],
            ],
            to: "pool/parts/lm358.json"
        )
        let poolURL = temporaryRoot.appendingPathComponent("pool", isDirectory: true)

        let items = HorizontalPoolLibrary.items(inPool: poolURL, poolName: "Test pool")
        XCTAssertEqual(items.count, 3)

        let unit = items.first { $0.category == .unit }
        XCTAssertEqual(unit?.name, "Opamp")

        let padstack = items.first { $0.category == .padstack }
        XCTAssertEqual(padstack?.name, "Circular via")
        XCTAssertEqual(padstack?.detail, "via")

        let part = items.first { $0.category == .part }
        XCTAssertEqual(part?.name, "LM358")
        XCTAssertEqual(part?.detail, "TI")
        XCTAssertEqual(part?.tags, "opamp dual")
        XCTAssertEqual(part?.poolName, "Test pool")
    }

    func testScanPrefersThePoolItemOverItsCacheCopy() throws {
        _ = try write(["type": "pool", "uuid": "p"], to: "pool/pool.json")
        _ = try write(
            ["type": "padstack", "padstack_type": "via", "uuid": "dup", "name": "Source copy"],
            to: "pool/padstacks/via.json"
        )
        _ = try write(
            ["type": "padstack", "padstack_type": "via", "uuid": "dup", "name": "Cache copy"],
            to: "pool/padstacks/cache/dup.json"
        )
        let poolURL = temporaryRoot.appendingPathComponent("pool", isDirectory: true)

        let items = HorizontalPoolLibrary.items(inPool: poolURL, poolName: "Test pool")
        XCTAssertEqual(items.map(\.name), ["Source copy"])
    }

    // MARK: - Real horizon-pool checkout

    func testStockPoolScanFindsTheExpectedKinds() throws {
        let stockPool = URL(fileURLWithPath: "/Users/kornack/Repositories/horizon-pool")
        guard FileManager.default.fileExists(atPath: stockPool.appendingPathComponent("pool.json").path) else {
            throw XCTSkip("horizon-pool checkout not available")
        }
        let items = HorizontalPoolLibrary.items(inPool: stockPool, poolName: "Horizon pool")
        for category in HorizontalPoolItemCategory.allCases {
            XCTAssertFalse(
                items.filter { $0.category == category }.isEmpty,
                "the stock pool should contain \(category.title)"
            )
        }
        XCTAssertTrue(items.contains { $0.category == .padstack && $0.name == "Circular via" && $0.detail == "via" })
    }
}
