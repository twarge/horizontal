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
