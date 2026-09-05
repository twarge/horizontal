import XCTest
@testable import HorizontalNative

/// Placing a Library part copies it and everything it depends on into the
/// project pool's cache, the way Horizon's project pool does.
final class HorizontalPoolCacheImporterTests: XCTestCase {
    private var temporaryRoot: URL!
    private var testDefaults: UserDefaults!
    private var poolURL: URL { temporaryRoot.appendingPathComponent("stock", isDirectory: true) }
    private var projectPoolURL: URL { temporaryRoot.appendingPathComponent("project/pool", isDirectory: true) }

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolCacheImporterTests-\(UUID().uuidString)", isDirectory: true)
        testDefaults = UserDefaults(suiteName: "HorizontalPoolCacheImporterTests-\(UUID().uuidString)")
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
        try writeStockPool()
        _ = try write(["type": "pool", "uuid": "proj-pool", "name": "Project"], to: "project/pool/pool.json")
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @discardableResult
    private func write(_ json: JSONDictionary, to relativePath: String) throws -> URL {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func writeStockPool() throws {
        try write(["type": "pool", "uuid": "stock-pool", "name": "Stock"], to: "stock/pool.json")
        try write(
            ["type": "unit", "uuid": "unit-1", "name": "Resistor", "manufacturer": "",
             "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                      "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
            to: "stock/units/passive/resistor.json"
        )
        try write(
            ["type": "symbol", "uuid": "sym-1", "name": "Resistor", "unit": "unit-1",
             "pins": [:], "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
            to: "stock/symbols/passive/resistor.json"
        )
        try write(
            ["type": "entity", "uuid": "ent-1", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
             "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-1"]]],
            to: "stock/entities/passive/resistor.json"
        )
        try write(
            ["type": "padstack", "padstack_type": "top", "uuid": "ps-pool", "name": "Pool padstack",
             "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
            to: "stock/padstacks/smd.json"
        )
        try write(
            ["type": "padstack", "padstack_type": "top", "uuid": "ps-local", "name": "Local padstack",
             "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
            to: "stock/packages/r0603/padstacks/local.json"
        )
        try write(
            ["type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": [],
             "pads": ["pad-1": ["name": "1", "padstack": "ps-pool", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                      "pad-2": ["name": "2", "padstack": "ps-local", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
             "models": ["model-1": ["filename": "3d_models/r0603.step", "x": 0, "y": 0, "z": 0, "roll": 0, "pitch": 0, "yaw": 0]],
             "default_model": "model-1",
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
            to: "stock/packages/r0603/package.json"
        )
        let model = temporaryRoot.appendingPathComponent("stock/3d_models/r0603.step")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("solid".utf8).write(to: model)
        try write(
            ["type": "part", "uuid": "part-base", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RES-0603"], "value": [false, ""], "manufacturer": [false, "Generic"],
             "description": [false, "Resistor"], "datasheet": [false, ""],
             "tags": ["resistor"], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
             "parametric": [:]],
            to: "stock/parts/passive/res-base.json"
        )
        try write(
            ["type": "part", "uuid": "part-1", "base": "part-base",
             "MPN": [false, "RES-0603-10K"], "value": [false, "10k"], "manufacturer": [true, ""],
             "description": [true, ""], "datasheet": [true, ""],
             "tags": [], "inherit_tags": true, "inherit_model": true,
             "pad_map": [:], "parametric": [:]],
            to: "stock/parts/passive/res-10k.json"
        )
    }

    private func libraryItem(_ category: HorizontalPoolItemCategory, uuid: String) throws -> HorizontalPoolLibraryItem {
        let items = HorizontalPoolLibrary.items(inPool: poolURL, poolName: "Stock")
        return try XCTUnwrap(items.first { $0.category == category && $0.uuid == uuid })
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: projectPoolURL.appendingPathComponent(relativePath).path)
    }

    func testCachingAPartCopiesItsWholeDependencyTree() throws {
        let part = try libraryItem(.part, uuid: "part-1")
        let result = try HorizontalPoolCacheImporter.cachePart(part, into: projectPoolURL)

        for path in [
            "parts/cache/part-1.json", "parts/cache/part-base.json",
            "entities/cache/ent-1.json", "units/cache/unit-1.json", "symbols/cache/sym-1.json",
            "packages/cache/pkg-1/package.json", "packages/cache/pkg-1/padstacks/local.json",
            "padstacks/cache/ps-pool.json",
            "3d_models/cache/stock-pool/3d_models/r0603.step",
        ] {
            XCTAssertTrue(exists(path), path)
        }
        XCTAssertFalse(exists("padstacks/cache/ps-local.json"), "package-local padstacks stay with their package")
        XCTAssertEqual(result.writtenFiles.count, 9)

        // The package's model path now points into the cache, as ProjectPool::patch_package does.
        let package = try JSONHelper.loadDictionary(from: projectPoolURL.appendingPathComponent("packages/cache/pkg-1/package.json"))
        let model = package.dictionaryMap("models")["model-1"]
        XCTAssertEqual(model?.string("filename"), "3d_models/cache/stock-pool/3d_models/r0603.step")
        XCTAssertEqual(package.string("name"), "R0603")

        // The cached part loads like any other project pool part.
        let loaded = try XCTUnwrap(HorizontalPoolPart.loadCached(id: "part-1", from: projectPoolURL))
        XCTAssertEqual(loaded.mpn, "RES-0603-10K")
        XCTAssertEqual(loaded.gates.count, 1)
        XCTAssertEqual(loaded.gates.first?.symbolID, "sym-1")
        XCTAssertEqual(loaded.gates.first?.unitID, "unit-1")

        // Caching again finds everything in place and writes nothing.
        let again = try HorizontalPoolCacheImporter.cachePart(part, into: projectPoolURL)
        XCTAssertTrue(again.writtenFiles.isEmpty)
    }

    func testMissingSymbolIsReported() throws {
        try FileManager.default.removeItem(at: poolURL.appendingPathComponent("symbols"))
        HorizontalPoolLibrary.invalidateCache()
        let part = try libraryItem(.part, uuid: "part-base")
        XCTAssertThrowsError(try HorizontalPoolCacheImporter.cachePart(part, into: projectPoolURL)) { error in
            guard case HorizontalPoolCacheImporterError.noSymbol(let unitID) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(unitID, "unit-1")
        }
    }

    func testLibraryScanRecordsASymbolsUnit() throws {
        let symbol = try libraryItem(.symbol, uuid: "sym-1")
        XCTAssertEqual(symbol.symbolUnitID, "unit-1")
        let part = try libraryItem(.part, uuid: "part-1")
        XCTAssertEqual(part.symbolUnitID, "")
    }

    func testLibraryPaneComesBeforeParts() {
        XCTAssertEqual(Array(HorizontalPane.allCases.prefix(2)), [.library, .parts])
    }
}
