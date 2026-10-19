import XCTest
import HorizontalProjectIO
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
        HorizontalPoolLibrary.invalidateCache()
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
        XCTAssertEqual(result.writtenFiles.count, 10)
        let metadata = try HorizontalPoolCacheProvenance.load(Data(contentsOf: projectPoolURL.appendingPathComponent(HorizontalPoolCacheProvenance.path)))
        XCTAssertEqual(metadata.files.count, 9)
        XCTAssertEqual(metadata.files["parts/cache/part-1.json"]?.poolUUID, "stock-pool")
        XCTAssertEqual(metadata.files["parts/cache/part-1.json"]?.sourcePath, "parts/passive/res-10k.json")

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

    private func cachedFiles() throws -> [String: Data] {
        var files = [String: Data]()
        let enumerator = FileManager.default.enumerator(at: projectPoolURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[try HorizontalPoolCacheProvenance.relativePath(url, in: projectPoolURL)] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func cachedReview(files: [String: Data]? = nil, pools: [URL]? = nil,
                              references: [String: [String]] = [:]) throws -> HorizontalPoolCacheReview {
        try HorizontalPoolCacheUpdater.review(poolURL: projectPoolURL, files: try files ?? cachedFiles(),
                                              sourcePools: pools ?? [poolURL], references: references)
    }

    private func importFixture() throws {
        _ = try HorizontalPoolCacheImporter.cachePart(libraryItem(.part, uuid: "part-1"), into: projectPoolURL)
    }

    private func changeSource(_ path: String, edit: (inout JSONDictionary) -> Void) throws {
        var json = try JSONHelper.loadDictionary(from: poolURL.appendingPathComponent(path))
        edit(&json)
        try write(json, to: "stock/" + path)
    }

    func testCurrentIncludesModelsAndNormalizesCachedModelPaths() throws {
        try importFixture()
        let review = try cachedReview()
        XCTAssertEqual(review.parts.count, 1)
        XCTAssertEqual(review.parts.first?.status, .current)
        XCTAssertEqual(review.parts.first?.changes.count, 0)
        XCTAssertEqual(review.parts.first?.dependencies.count, 9)
    }

    func testDependencyOnlyUpdateIsReportedOnDerivedPart() throws {
        try importFixture()
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Updated resistor" }
        let review = try cachedReview(references: ["part-1": ["R1", "R2"]])
        let row = try XCTUnwrap(review.parts.first)
        XCTAssertEqual(row.status, .updateAvailable)
        XCTAssertEqual(row.references, ["R1", "R2"])
        XCTAssertEqual(row.changes.map(\.path), ["symbols/cache/sym-1.json"])
        XCTAssertTrue(row.canUpdate)
        let updated = try review.updates(selecting: ["part-1"])
        XCTAssertEqual(updated.count, 2, "one item and the provenance manifest")
        XCTAssertEqual(try JSONHelper.loadDictionary(from: XCTUnwrap(updated["symbols/cache/sym-1.json"])).string("name"), "Updated resistor")
        XCTAssertEqual(try JSONHelper.loadDictionary(from: Data(contentsOf: projectPoolURL.appendingPathComponent("symbols/cache/sym-1.json"))).string("name"), "Resistor", "review and planning do not write")
        var files = try cachedFiles()
        files.merge(updated) { _, new in new }
        XCTAssertEqual(try cachedReview(files: files).parts.first?.status, .current)
    }

    func testFormattingAndEditorMetadataDoNotProduceUpdates() throws {
        try importFixture()
        var json = try JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("symbols/passive/resistor.json"))
        json["_imp"] = ["editor": "temporary"]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: poolURL.appendingPathComponent("symbols/passive/resistor.json"))
        XCTAssertEqual(try cachedReview().parts.first?.status, .current)
    }

    func testUnsavedLocalEditsRequireConfirmationAndAreNotReadFromDisk() throws {
        try importFixture()
        var files = try cachedFiles()
        var symbol = try JSONHelper.loadDictionary(from: XCTUnwrap(files["symbols/cache/sym-1.json"]))
        symbol["name"] = "Unsaved custom symbol"
        files["symbols/cache/sym-1.json"] = try JSONSerialization.data(withJSONObject: symbol)
        let review = try cachedReview(files: files)
        XCTAssertEqual(review.parts.first?.status, .locallyModified)
        XCTAssertTrue(review.parts.first?.needsConfirmation == true)
        XCTAssertThrowsError(try review.updates(selecting: ["part-1"]))
        XCTAssertNotNil(try review.updates(selecting: ["part-1"], allowProjectChanges: true)["symbols/cache/sym-1.json"])
        XCTAssertEqual(try cachedReview().parts.first?.status, .current)
    }

    func testLegacyCopiesAreUnverifiedAndRequireConfirmation() throws {
        try importFixture()
        var files = try cachedFiles()
        files.removeValue(forKey: HorizontalPoolCacheProvenance.path)
        try changeSource("packages/r0603/package.json") { $0["name"] = "New footprint name" }
        let review = try cachedReview(files: files)
        XCTAssertEqual(review.parts.first?.status, .updateAvailable)
        XCTAssertTrue(review.parts.first?.changes.first?.unverified == true)
        XCTAssertThrowsError(try review.updates(selecting: ["part-1"]))
        XCTAssertNoThrow(try review.updates(selecting: ["part-1"], allowProjectChanges: true))
    }

    func testMissingSourceDoesNotClaimCachedPartIsBroken() throws {
        try importFixture()
        let review = try cachedReview(pools: [])
        XCTAssertEqual(review.parts.first?.status, .sourceUnavailable)
        XCTAssertFalse(review.parts.first?.canUpdate ?? true)
        XCTAssertNotNil(HorizontalPoolPart.loadCached(id: "part-1", from: projectPoolURL))
    }

    func testAReviewNamesEachPartsPoolAndWhatTheDesignHasFallenBehindOn() throws {
        try importFixture()
        let used = ["part-1": ["R1", "R2"]]
        var row = try XCTUnwrap(try cachedReview(references: used).parts.first)
        XCTAssertEqual(row.sourcePool, "Stock")
        XCTAssertEqual(row.statusTitle, "Current")
        XCTAssertFalse(row.isInNoAttachedPool)

        // The pool's symbol changes: the part is out of date where it's used.
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Resistor, redrawn" }
        var review = try cachedReview(references: used)
        XCTAssertEqual(review.outdatedInUse.map(\.id), ["part-1"])
        XCTAssertEqual(HorizontalPartLibraryMonitor.noticeText(for: review), "1 part is out of date with its pool (R1, R2)")
        XCTAssertTrue(try cachedReview().outdatedInUse.isEmpty, "a part nothing uses isn't the design's concern")

        // No attached pool has it: not "unavailable", but in none of them.
        review = try cachedReview(pools: [], references: used)
        row = try XCTUnwrap(review.parts.first)
        XCTAssertNil(row.sourcePool)
        XCTAssertEqual(row.statusTitle, "Not in an attached pool")
        XCTAssertTrue(row.isInNoAttachedPool)
        XCTAssertEqual(review.notInAttachedPoolInUse.map(\.id), ["part-1"])
        XCTAssertEqual(HorizontalPartLibraryMonitor.noticeText(for: review), "1 part isn't in any attached pool (R1, R2)")
        XCTAssertNotEqual(HorizontalPartLibraryMonitor.noticeSignature(for: review),
                          HorizontalPartLibraryMonitor.noticeSignature(for: try cachedReview(references: used)),
                          "a dismissed notice comes back when what it is about changes")

        // A pool that has the part but can't update it is a different trouble.
        try FileManager.default.removeItem(at: poolURL.appendingPathComponent("units/passive/resistor.json"))
        HorizontalPoolLibrary.invalidateCache()
        row = try XCTUnwrap(try cachedReview(references: used).parts.first)
        XCTAssertEqual(row.status, .sourceUnavailable)
        XCTAssertEqual(row.sourcePool, "Stock")
        XCTAssertEqual(row.statusTitle, "Source unavailable")
    }

    func testAnItemEditorSaysWhichPoolTheItemIsIn() throws {
        XCTAssertEqual(HorizontalPoolItemEditorSession.location(of: poolURL.appendingPathComponent("symbols/passive/resistor.json"), inPool: poolURL),
                       "Stock")
        // A project's own pool goes by its project, and its cache says where
        // a copy came from.
        let projectPool = temporaryRoot.appendingPathComponent("Billo/pool", isDirectory: true)
        try write(["type": "pool", "uuid": HorizontalProjectArchive.projectPoolUUID, "name": "Project pool"], to: "Billo/pool/pool.json")
        try Data("{}".utf8).write(to: temporaryRoot.appendingPathComponent("Billo/Billo.hprj"))
        setenv("HORIZONTAL_POOLS", poolURL.path, 1)
        defer { unsetenv("HORIZONTAL_POOLS") }
        _ = try HorizontalPoolCacheImporter.cachePart(libraryItem(.part, uuid: "part-1"), into: projectPool)
        XCTAssertEqual(HorizontalPoolItemEditorSession.location(of: projectPool.appendingPathComponent("symbols/cache/sym-1.json"), inPool: projectPool),
                       "the project pool of Billo, cached from Stock")
        XCTAssertEqual(HorizontalPoolItemEditorSession.location(of: projectPool.appendingPathComponent("symbols/mine.json"), inPool: projectPool),
                       "the project pool of Billo")
    }

    /// A part written into the project's pool on Stock's entity and package,
    /// that no pool has.
    private func writeProjectMadePart() throws {
        try write(["type": "part", "uuid": "part-new", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
                   "MPN": [false, "NEW-1"], "value": [false, ""], "manufacturer": [false, "Us"],
                   "description": [false, "Made here"], "datasheet": [false, ""], "tags": [], "inherit_tags": false,
                   "inherit_model": true, "parametric": [:],
                   "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]]],
                  to: "project/pool/parts/cache/part-new.json")
    }

    func testAPartNoAttachedPoolHasCopiesIntoOneAndIsKeptUpToDateFromThere() throws {
        try importFixture()
        try writeProjectMadePart()
        let mine = temporaryRoot.appendingPathComponent("mine", isDirectory: true)
        try write(["type": "pool", "uuid": "mine-pool", "name": "Mine"], to: "mine/pool.json")
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: poolURL))
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: mine))
        let used = ["part-new": ["R9"], "part-1": ["R1"]]
        XCTAssertTrue(try cachedReview(pools: [mine, poolURL], references: used).parts.first { $0.id == "part-new" }?.isInNoAttachedPool == true)

        let copy = try HorizontalPoolPartCopier.plan(partID: "part-new", projectFiles: try cachedFiles(), projectPoolURL: projectPoolURL, into: mine)
        XCTAssertEqual(copy.partName, "NEW-1")
        // Mine includes nothing, so it gets what the part needs too, filed
        // as a pool files things; Stock's cached copies stay Stock's.
        XCTAssertEqual(Set(copy.poolFiles.map(\.path)), [
            "parts/NEW-1.json", "entities/Resistor.json", "units/Resistor.json", "symbols/Resistor.json",
            "packages/R0603/package.json", "packages/R0603/padstacks/local.json", "padstacks/Pool padstack.json", "3d_models/r0603.step"
        ])
        XCTAssertEqual(copy.recached, ["parts/cache/part-new.json"])
        try HorizontalPoolPartCopier.writePoolFiles(copy)
        let package = try JSONHelper.loadDictionary(from: mine.appendingPathComponent("packages/R0603/package.json"))
        XCTAssertEqual(package.dictionaryMap("models").values.first?.string("filename"), "3d_models/r0603.step",
                       "a pool's model paths are its own, not the cache's")
        XCTAssertThrowsError(try HorizontalPoolPartCopier.writePoolFiles(copy), "nothing is written over")

        // The project now takes the part from Mine.
        var archive = try HorizontalProjectArchive.snapshot(from: temporaryRoot.appendingPathComponent("project"))
        try HorizontalPoolPartCopier.track(copy, in: &archive, poolDirectory: "pool", projectPoolURL: projectPoolURL)
        let review = try HorizontalPoolCacheUpdater.review(poolURL: projectPoolURL, files: HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: "pool"),
                                                           sourcePools: [mine, poolURL], references: used)
        let made = try XCTUnwrap(review.parts.first { $0.id == "part-new" })
        XCTAssertEqual(made.status, .current, made.message)
        XCTAssertEqual(made.sourcePool, "Mine")
        XCTAssertEqual(review.parts.first { $0.id == "part-1" }?.sourcePool, "Stock")
        XCTAssertThrowsError(try HorizontalPoolPartCopier.plan(partID: "part-new", projectFiles: HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: "pool"),
                                                               projectPoolURL: projectPoolURL, into: mine)) {
            XCTAssertTrue(HorizontalCanvasProjectEdit.message(for: $0).contains("already"), HorizontalCanvasProjectEdit.message(for: $0))
        }
    }

    func testAPoolThatIncludesThePartsSourcesGetsThePartAlone() throws {
        try importFixture()
        try writeProjectMadePart()
        let mine = temporaryRoot.appendingPathComponent("mine", isDirectory: true)
        try write(["type": "pool", "uuid": "mine-pool", "name": "Mine", "pools_included": ["stock-pool"]], to: "mine/pool.json")
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: poolURL))
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: mine))
        let copy = try HorizontalPoolPartCopier.plan(partID: "part-new", projectFiles: try cachedFiles(), projectPoolURL: projectPoolURL, into: mine)
        XCTAssertEqual(copy.poolFiles.map(\.path), ["parts/NEW-1.json"])

        // A project-local item the pool has under its uuid, differently, stops it.
        var entity = try JSONHelper.loadDictionary(from: projectPoolURL.appendingPathComponent("entities/cache/ent-1.json"))
        entity["uuid"] = "ent-x"
        try write(entity, to: "project/pool/entities/local.json")
        entity["name"] = "Someone else's"
        try write(entity, to: "mine/entities/theirs.json")
        var part = try JSONHelper.loadDictionary(from: projectPoolURL.appendingPathComponent("parts/cache/part-new.json"))
        part["entity"] = "ent-x"
        try write(part, to: "project/pool/parts/cache/part-new.json")
        XCTAssertThrowsError(try HorizontalPoolPartCopier.plan(partID: "part-new", projectFiles: try cachedFiles(), projectPoolURL: projectPoolURL, into: mine)) {
            XCTAssertTrue(HorizontalCanvasProjectEdit.message(for: $0).contains("same uuid"), HorizontalCanvasProjectEdit.message(for: $0))
        }
    }

    func testThePartsPaneListsABaseOnlyWhereTheDesignUsesIt() throws {
        try importFixture()
        let parts = HorizontalPoolPart.loadAll(from: projectPoolURL)
        XCTAssertEqual(Set(parts.map(\.id)), ["part-1", "part-base"], "caching the 10k brings its base along")
        XCTAssertEqual(parts.first { $0.id == "part-1" }?.baseID, "part-base")
        XCTAssertEqual(HorizontalPartBrowserView.listedParts(parts, used: ["part-1"]).map(\.id), ["part-1"])
        XCTAssertEqual(Set(HorizontalPartBrowserView.listedParts(parts, used: ["part-1", "part-base"]).map(\.id)), ["part-1", "part-base"],
                       "a component on the base itself keeps it listed")
    }

    func testMissingDependencyBlocksWholeUpdate() throws {
        try importFixture()
        try FileManager.default.removeItem(at: poolURL.appendingPathComponent("units/passive/resistor.json"))
        HorizontalPoolLibrary.invalidateCache()
        let review = try cachedReview()
        XCTAssertEqual(review.parts.first?.status, .sourceUnavailable)
        XCTAssertTrue(review.parts.first?.message.contains("Missing in source") == true)
        XCTAssertThrowsError(try review.updates(selecting: ["part-1"]))
    }

    func testBinaryModelAndLocalPadstackUpdatesAreIncluded() throws {
        try importFixture()
        try Data("changed solid".utf8).write(to: poolURL.appendingPathComponent("3d_models/r0603.step"))
        try changeSource("packages/r0603/padstacks/local.json") { $0["name"] = "Changed local padstack" }
        let row = try XCTUnwrap(try cachedReview().parts.first)
        XCTAssertEqual(row.status, .updateAvailable)
        XCTAssertEqual(Set(row.changes.map(\.path)), ["packages/cache/pkg-1/padstacks/local.json", "3d_models/cache/stock-pool/3d_models/r0603.step"])
    }

    func testOriginWinsOverAnotherPoolWithSameUUIDs() throws {
        try importFixture()
        let other = temporaryRoot.appendingPathComponent("other")
        try FileManager.default.copyItem(at: poolURL, to: other)
        try write(["type": "pool", "uuid": "other-pool", "name": "Other"], to: "other/pool.json")
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Stock updated" }
        let review = try cachedReview(pools: [other, poolURL])
        XCTAssertEqual(review.parts.first?.status, .updateAvailable)
        XCTAssertEqual(review.parts.first?.changes.first?.origin.poolUUID, "stock-pool")
        var files = try cachedFiles()
        files.removeValue(forKey: HorizontalPoolCacheProvenance.path)
        XCTAssertEqual(try cachedReview(files: files, pools: [other, poolURL]).parts.first?.status, .sourceUnavailable)
    }

    /// Billo's case: SMD rectangular is in Twinleaf Pool and the Horizon pool,
    /// cached with no recorded origin, and 26 parts using it read "The
    /// padstack … is not in any browsed pool."
    func testDependencyInTwoPoolsWithoutOriginComesFromThePartsPool() throws {
        try importFixture()
        var files = try cachedFiles()
        var provenance = try HorizontalPoolCacheProvenance.load(files[HorizontalPoolCacheProvenance.path])
        XCTAssertNotNil(provenance.files.removeValue(forKey: "padstacks/cache/ps-pool.json"))
        files[HorizontalPoolCacheProvenance.path] = try provenance.data()
        try write(["type": "pool", "uuid": "other-pool", "name": "Other"], to: "other/pool.json")
        var padstack = try JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("padstacks/smd.json"))
        try write(padstack, to: "other/padstacks/smd.json")
        let other = temporaryRoot.appendingPathComponent("other")
        let row = try XCTUnwrap(try cachedReview(files: files, pools: [other, poolURL]).parts.first)
        XCTAssertEqual(row.status, .current, row.message)

        padstack["name"] = "Stock updated"
        try write(padstack, to: "stock/padstacks/smd.json")
        let updated = try XCTUnwrap(try cachedReview(files: files, pools: [other, poolURL]).parts.first)
        XCTAssertEqual(updated.status, .updateAvailable, updated.message)
        XCTAssertEqual(updated.changes.map(\.path), ["padstacks/cache/ps-pool.json"])
        XCTAssertEqual(updated.changes.first?.origin.poolUUID, "stock-pool")
    }

    func testDependencyOnlyInOtherPoolsNamesThemInsteadOfNone() throws {
        try importFixture()
        var files = try cachedFiles()
        files.removeValue(forKey: HorizontalPoolCacheProvenance.path)
        let padstack = try JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("padstacks/smd.json"))
        for name in ["Left", "Right"] {
            try write(["type": "pool", "uuid": name.lowercased() + "-pool", "name": name], to: name.lowercased() + "/pool.json")
            try write(padstack, to: name.lowercased() + "/padstacks/smd.json")
        }
        try FileManager.default.removeItem(at: poolURL.appendingPathComponent("padstacks/smd.json"))
        HorizontalPoolLibrary.invalidateCache()
        let pools = ["left", "right"].map { temporaryRoot.appendingPathComponent($0) } + [poolURL]
        let row = try XCTUnwrap(try cachedReview(files: files, pools: pools).parts.first)
        XCTAssertEqual(row.status, .sourceUnavailable)
        XCTAssertTrue(row.message.contains("is in \u{201C}Left\u{201D}, \u{201C}Right\u{201D}"), row.message)
        XCTAssertFalse(row.message.contains("not in any browsed pool"), row.message)
    }

    func testSharedDependencyReportsAllAffectedParts() throws {
        try importFixture()
        var part = try JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("parts/passive/res-10k.json"))
        part["uuid"] = "part-2"
        part["MPN"] = [false, "RES-0603-20K"]
        try write(part, to: "stock/parts/passive/res-20k.json")
        _ = try HorizontalPoolCacheImporter.cachePart(libraryItem(.part, uuid: "part-2"), into: projectPoolURL)
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Shared symbol update" }
        let review = try cachedReview(references: ["part-1": ["R1"], "part-2": ["R2"]])
        XCTAssertEqual(Set(review.affectedParts(selecting: ["part-1"]).map(\.id)), ["part-1", "part-2"])
        XCTAssertEqual(try review.updates(selecting: ["part-1", "part-2"]).count, 2)
    }

    func testRemovingPadRequiresRemapAndCannotBeForced() throws {
        try importFixture()
        try changeSource("packages/r0603/package.json") {
            var pads = $0.dictionaryMap("pads")
            pads.removeValue(forKey: "pad-1")
            $0["pads"] = pads
        }
        let review = try cachedReview()
        XCTAssertEqual(review.parts.first?.status, .updateAvailable)
        XCTAssertFalse(review.parts.first?.canUpdate ?? true)
        XCTAssertTrue(review.parts.first?.message.contains("removed") == true)
        XCTAssertThrowsError(try review.updates(selecting: ["part-1"], allowProjectChanges: true))
    }

    func testChangingPartPadMapRequiresRemap() throws {
        try importFixture()
        try changeSource("parts/passive/res-base.json") {
            $0["pad_map"] = ["pad-1": ["gate": "gate-1", "pin": "pin-2"], "pad-2": ["gate": "gate-1", "pin": "pin-1"]]
        }
        let review = try cachedReview()
        XCTAssertFalse(review.parts.first?.canUpdate ?? true)
        XCTAssertTrue(review.parts.first?.message.lowercased().contains("pad map") == true)
    }

    func testSourceChangedSinceReviewIsRejected() throws {
        try importFixture()
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "First change" }
        let review = try cachedReview()
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Second change" }
        XCTAssertThrowsError(try review.updates(selecting: ["part-1"]))
    }

    func testProjectChangedSinceReviewIsRejectedAndOriginalArchiveIsPreserved() throws {
        try importFixture()
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Source change" }
        let files = try cachedFiles()
        let review = try cachedReview(files: files)
        var archive = HorizontalProjectArchive(root: .directory([:]))
        for (path, data) in files { try archive.replaceRegularFileData(relativePath: "pool/" + path, with: data) }
        let original = archive
        let updated = try HorizontalPoolCacheUpdater.applying(review, selecting: ["part-1"], allowProjectChanges: false, to: archive, poolDirectory: "pool")
        XCTAssertEqual(archive, original)
        XCTAssertNotEqual(updated, original)
        try archive.replaceRegularFileData(relativePath: "pool/parts/cache/part-1.json", with: Data("{}".utf8))
        XCTAssertThrowsError(try HorizontalPoolCacheUpdater.applying(review, selecting: ["part-1"], allowProjectChanges: false, to: archive, poolDirectory: "pool"))
    }

    func testUnsafeModelPathIsRejectedBeforeAnyFilesAreWritten() throws {
        try changeSource("packages/r0603/package.json") {
            $0["models"] = ["model-1": ["filename": "../../outside.step"]]
        }
        XCTAssertThrowsError(try importFixture())
        XCTAssertFalse(exists("parts/cache/part-1.json"))
    }

    func testLegacySourceCanBeChosenExplicitlyAndAllBaselinesAreRecorded() throws {
        try importFixture()
        var files = try cachedFiles()
        files.removeValue(forKey: HorizontalPoolCacheProvenance.path)
        let other = temporaryRoot.appendingPathComponent("other")
        try FileManager.default.copyItem(at: poolURL, to: other)
        try write(["type": "pool", "uuid": "other-pool", "name": "Other"], to: "other/pool.json")
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Chosen source update" }
        let review = try HorizontalPoolCacheUpdater.review(poolURL: projectPoolURL, files: files, sourcePools: [other, poolURL], sourceOverrides: ["part-1": poolURL])
        XCTAssertEqual(review.parts.first?.status, .updateAvailable)
        files.merge(try review.updates(selecting: ["part-1"], allowProjectChanges: true)) { _, new in new }
        XCTAssertEqual(try HorizontalPoolCacheProvenance.load(files[HorizontalPoolCacheProvenance.path]).files.count, 9)
        XCTAssertEqual(try cachedReview(files: files, pools: [other, poolURL]).parts.first?.status, .current)
    }

    func testMovingASourceFileKeepsItsUUIDBasedOrigin() throws {
        try importFixture()
        try changeSource("symbols/passive/resistor.json") { $0["name"] = "Moved symbol" }
        try FileManager.default.moveItem(at: poolURL.appendingPathComponent("symbols/passive/resistor.json"),
                                         to: poolURL.appendingPathComponent("symbols/passive/moved.json"))
        HorizontalPoolLibrary.invalidateCache()
        let review = try cachedReview()
        XCTAssertEqual(review.parts.first?.status, .updateAvailable)
        XCTAssertEqual(review.parts.first?.changes.first?.origin.sourcePath, "symbols/passive/moved.json")
    }

    func testProjectLocalPartOverridesCacheAndHasNoUpdate() throws {
        try importFixture()
        var files = try cachedFiles()
        files["parts/local.json"] = files["parts/cache/part-1.json"]
        let review = try cachedReview(files: files)
        XCTAssertEqual(review.parts.first?.status, .projectOnly)
        XCTAssertFalse(review.parts.first?.canUpdate ?? true)
    }

    func testRetainedModelFilesSeparateUpdatedAndUndoBytes() throws {
        let path = "3d_models/cache/stock-pool/3d_models/r0603.step"
        let before = try HorizontalPoolModelFiles(contents: [path: Data("old model".utf8)])
        let after = try HorizontalPoolModelFiles(contents: [path: Data("new model".utf8)])
        XCTAssertNotEqual(before.directory, after.directory)
        XCTAssertEqual(try Data(contentsOf: before.directory.appendingPathComponent(path)), Data("old model".utf8))
        XCTAssertEqual(try Data(contentsOf: after.directory.appendingPathComponent(path)), Data("new model".utf8))
        var oldArchive = HorizontalProjectArchive(root: .directory([:]))
        try oldArchive.replaceRegularFileData(relativePath: "pool/" + path, with: Data("old model".utf8))
        var newArchive = oldArchive
        try newArchive.replaceRegularFileData(relativePath: "pool/" + path, with: Data("new model".utf8))
        XCTAssertTrue(HorizontalProject.poolModelsChanged(from: oldArchive, to: newArchive, poolDirectory: "pool"))
        XCTAssertFalse(HorizontalProject.poolModelsChanged(from: oldArchive, to: oldArchive, poolDirectory: "pool"))
    }

    func testPoolPathsWithTrailingSlashesAndAliasesRemainRelative() throws {
        let root = URL(fileURLWithPath: projectPoolURL.path + "/", isDirectory: true)
        let file = root.appendingPathComponent(HorizontalPoolCacheProvenance.path)
        XCTAssertEqual(try HorizontalPoolCacheProvenance.relativePath(file, in: root), HorizontalPoolCacheProvenance.path)
        let alias = temporaryRoot.appendingPathComponent("pool-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: projectPoolURL)
        XCTAssertEqual(try HorizontalPoolCacheProvenance.relativePath(file, in: alias), HorizontalPoolCacheProvenance.path)
        XCTAssertThrowsError(try HorizontalPoolCacheProvenance.relativePath(temporaryRoot.appendingPathComponent("outside.json"), in: root))
    }

    func testOneSourceSeenThroughTwoAliasesIsNotAmbiguous() throws {
        try importFixture()
        let alias = temporaryRoot.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: poolURL)
        var files = try cachedFiles()
        files.removeValue(forKey: HorizontalPoolCacheProvenance.path)
        let row = try XCTUnwrap(try cachedReview(files: files, pools: [alias, poolURL]).parts.first)
        XCTAssertEqual(row.status, .current, row.message)
    }
}
