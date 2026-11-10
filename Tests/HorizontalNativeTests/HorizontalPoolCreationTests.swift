import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A new pool is the one Horizon's pool manager makes: its files byte for
/// byte, read by the app's pool library, registered, and able to take items
/// the pool editors save.
final class HorizontalPoolCreationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolCreationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalPoolCreationTests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: root)
    }

    func testNewPoolJSONIsWhatHorizonsPoolInfoSaveWrites() throws {
        let pool = root.appendingPathComponent("mine", isDirectory: true)
        let poolJSON = try HorizontalPoolCreation.create(at: pool, name: "My Pool", uuid: "0F1E2D3C-4B5A-4978-8695-a4b3c2d1e0f9")
        XCTAssertEqual(poolJSON, pool.appendingPathComponent("pool.json"))
        // nlohmann's dump(4): keys sorted, four spaces, no final newline;
        // no `version`, which Horizon writes only for a default frame.
        XCTAssertEqual(try String(contentsOf: poolJSON, encoding: .utf8), """
        {
            "default_frame": "00000000-0000-0000-0000-000000000000",
            "default_via": "00000000-0000-0000-0000-000000000000",
            "name": "My Pool",
            "pools_included": [],
            "type": "pool",
            "uuid": "0f1e2d3c-4b5a-4978-8695-a4b3c2d1e0f9"
        }
        """)
    }

    func testNewPoolNamesTheIncludedPoolsInPoolJSON() throws {
        let pool = root.appendingPathComponent("mine", isDirectory: true)
        try HorizontalPoolCreation.create(at: pool, name: "Mine", uuid: "11111111-2222-4333-8444-555555555555",
                                          includedPools: [HorizontalBuiltInPool.horizonPoolUUID])
        XCTAssertEqual(try String(contentsOf: pool.appendingPathComponent("pool.json"), encoding: .utf8), """
        {
            "default_frame": "00000000-0000-0000-0000-000000000000",
            "default_via": "00000000-0000-0000-0000-000000000000",
            "name": "Mine",
            "pools_included": [
                "6d752bc3-29b3-45df-8cf2-1e3aacefbcc6"
            ],
            "type": "pool",
            "uuid": "11111111-2222-4333-8444-555555555555"
        }
        """)
        XCTAssertEqual(HorizontalPoolLibrary.includedPoolUUIDs(of: pool), [HorizontalBuiltInPool.horizonPoolUUID])
    }

    func testNewPoolHasHorizonsDirectoriesKeepFilesAndGitignore() throws {
        let pool = root.appendingPathComponent("mine", isDirectory: true)
        try HorizontalPoolCreation.create(at: pool, name: "Mine")
        let fileManager = FileManager.default
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: pool.path).sorted(), [
            ".gitignore", "3d_models", "decals", "entities", "frames", "packages", "padstacks", "parts", "pool.json",
            "symbols", "units",
        ])
        for name in ["units", "symbols", "entities", "padstacks", "packages", "parts", "frames", "decals", "3d_models"] {
            let directory = pool.appendingPathComponent(name)
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path), [".keep"], name)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(".keep")), Data(), name)
        }
        XCTAssertEqual(try Data(contentsOf: pool.appendingPathComponent(".gitignore")),
                       Data("*.db\n*.db-*\ntmp/*.json\n3d_models/local\n*.imp_meta\n*.autosave\n*.bak".utf8))
    }

    func testNewPoolIsReadByThePoolLibraryAndTakesItemsTheEditorsSave() throws {
        let pool = root.appendingPathComponent("mine", isDirectory: true)
        try HorizontalPoolCreation.create(at: pool, name: "Mine", uuid: "11111111-2222-4333-8444-555555555555")
        let info = HorizontalPoolRegistryStore.poolInfo(at: pool)
        XCTAssertEqual(info.name, "Mine")
        XCTAssertEqual(info.uuid, "11111111-2222-4333-8444-555555555555")
        XCTAssertNil(HorizontalPoolLibrary.accessError(for: pool))
        XCTAssertEqual(HorizontalPoolLibrary.items(inPool: pool, poolName: info.name), [])

        var unit = HorizontalPoolItemFactory.newUnit()
        unit.name = "Resistor"
        let model = HorizontalPoolItemModel.unit(unit)
        let url = HorizontalPoolItemFactory.suggestedURL(for: model, in: pool)
        XCTAssertNil(HorizontalPoolItemFactory.locationProblem(for: url, category: .unit, in: pool))
        try HorizontalPoolItemFactory.write(model, to: url)

        HorizontalPoolLibrary.invalidateCache()
        let items = HorizontalPoolLibrary.items(inPool: pool, poolName: info.name)
        XCTAssertEqual(items.map(\.name), ["Resistor"])
        XCTAssertEqual(items.first?.category, .unit)
        XCTAssertEqual(HorizontalPoolLibrary.poolRoot(forItemURL: url)?.standardizedFileURL.path, pool.standardizedFileURL.path)
    }

    @MainActor
    func testCreatingAndRegisteringAPoolAddsItToTheRegisteredPools() throws {
        let pool = root.appendingPathComponent("mine", isDirectory: true)
        let registered = try HorizontalPoolCreation.createAndRegister(at: pool, name: "Mine")
        defer { HorizontalPoolRegistry.shared.removePool(registered) }
        XCTAssertEqual(registered.name, "Mine")
        XCTAssertEqual(HorizontalPoolRegistryStore.poolURLs().map(\.standardizedFileURL.path), [pool.standardizedFileURL.path])
        XCTAssertTrue(HorizontalPoolRegistry.shared.pools.contains { $0.url.standardizedFileURL.path == pool.standardizedFileURL.path })
    }

    func testANewPoolGoesOnlyIntoAnEmptyFolder() throws {
        let folder = root.appendingPathComponent("full", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(try HorizontalPoolCreation.create(at: folder, name: "Mine")) { error in
            XCTAssertEqual(error as? HorizontalPoolCreation.Failure, .notEmpty(folder.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pool.json").path))
        XCTAssertThrowsError(try HorizontalPoolCreation.create(at: root.appendingPathComponent("blank"), name: "  "))

        // A chosen folder with things in it takes the pool in a folder of its own.
        XCTAssertEqual(HorizontalPoolCreation.destination(inChosenFolder: folder, name: "My Pool").lastPathComponent,
                       HorizontalPoolItemFactory.slug("My Pool", fallback: "pool"))
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(HorizontalPoolCreation.destination(inChosenFolder: empty, name: "My Pool"), empty)
        try HorizontalPoolCreation.create(at: empty, name: "Mine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.appendingPathComponent("pool.json").path))
    }
}
