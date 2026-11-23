import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A part the project keeps as its own file, outside its pool's cache, that
/// an attached pool holds too under the same uuid: one put in the pool by
/// hand, or by a Copy to Pool the project then undid.
///
/// It read as Project-only, and Copy to Pool refused it because the pool had
/// it, so it stayed the project's own for good. Now the parts review names
/// the pool and calls it the project's own copy, and the copy command, given
/// a pool that has the same part already, writes nothing there and only has
/// the project take the pool's copy, which the pool keeps up to date from
/// then on.
///
/// Stock has an MCU: unit, symbol, entity, a pool padstack, a package with
/// its own padstack and a 3D model, and the part. The project caches the
/// entity's side from Stock, and keeps the part, the package and the model
/// as its own files under the paths Stock files them.
final class ProjectsOwnCopyOfAPoolsPartTests: XCTestCase {
    private var root: URL!
    private var stock: URL { root.appendingPathComponent("stock", isDirectory: true) }
    private var projectPool: URL { root.appendingPathComponent("project/pool", isDirectory: true) }
    private let ownFiles = ["parts/mcu.json", "packages/lqfp/package.json", "packages/lqfp/padstacks/pad.json", "3d_models/own/lqfp.step"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectsOwnCopyOfAPoolsPartTests-\(UUID().uuidString)", isDirectory: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsOwnCopyOfAPoolsPartTests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
        try writeStock()
        try write(["type": "pool", "uuid": "proj-pool", "name": "Project", "pools_included": ["stock-pool"]], to: "project/pool/pool.json")
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: stock))
        try keepThePartAsTheProjectsOwn()
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The pool and the project

    private func write(_ json: JSONDictionary, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        HorizontalPoolLibrary.invalidateCache()
    }

    private func padstack(_ id: String, name: String) -> JSONDictionary {
        ["type": "padstack", "padstack_type": "top", "uuid": id, "name": name,
         "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]]
    }

    private func writeStock() throws {
        try write(["type": "pool", "uuid": "stock-pool", "name": "Stock"], to: "stock/pool.json")
        try write(["type": "unit", "uuid": "unit-mcu", "name": "MCU", "manufacturer": "",
                   "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                            "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
                  to: "stock/units/ic/mcu.json")
        try write(["type": "symbol", "uuid": "sym-mcu", "name": "MCU", "unit": "unit-mcu",
                   "pins": [:], "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
                  to: "stock/symbols/ic/mcu.json")
        try write(["type": "entity", "uuid": "ent-mcu", "name": "MCU", "manufacturer": "", "prefix": "U", "tags": [],
                   "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-mcu"]]],
                  to: "stock/entities/ic/mcu.json")
        try write(padstack("ps-pool", name: "Pool padstack"), to: "stock/padstacks/smd.json")
        try write(padstack("ps-own", name: "Pad 2"), to: "stock/packages/lqfp/padstacks/pad.json")
        try write(["type": "package", "uuid": "pkg-lqfp", "name": "LQFP", "manufacturer": "", "tags": [],
                   "pads": ["pad-1": ["name": "1", "padstack": "ps-pool", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                            "pad-2": ["name": "2", "padstack": "ps-own", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
                   "models": ["model-1": ["filename": "3d_models/own/lqfp.step", "x": 0, "y": 0, "z": 0, "roll": 0, "pitch": 0, "yaw": 0]],
                   "default_model": "model-1",
                   "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
                  to: "stock/packages/lqfp/package.json")
        let model = stock.appendingPathComponent("3d_models/own/lqfp.step")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("solid".utf8).write(to: model)
        try write(["type": "part", "uuid": "part-mcu", "entity": "ent-mcu", "package": "pkg-lqfp", "base": NSNull(),
                   "MPN": [false, "MCU-1"], "value": [false, ""], "manufacturer": [false, "Us"],
                   "description": [false, "A microcontroller"], "datasheet": [false, ""],
                   "tags": [], "inherit_tags": false, "inherit_model": true, "parametric": [:],
                   "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]]],
                  to: "stock/parts/mcu.json")
    }

    /// The project as a part made in it and then copied into Stock leaves
    /// it: what the part needs is cached from Stock, origin recorded; the
    /// part, its package and the model are the project's own files, the same
    /// as Stock's and under the same paths.
    private func keepThePartAsTheProjectsOwn() throws {
        let part = try XCTUnwrap(HorizontalPoolLibrary.items(inPool: stock, poolName: "Stock").first { $0.category == .part })
        _ = try HorizontalPoolCacheImporter.cachePart(part, into: projectPool)
        let fileManager = FileManager.default
        let cached = ["parts/cache/part-mcu.json", "packages/cache/pkg-lqfp", "3d_models/cache/stock-pool"]
        for path in cached {
            try fileManager.removeItem(at: projectPool.appendingPathComponent(path))
        }
        let manifestURL = projectPool.appendingPathComponent(HorizontalPoolCacheProvenance.path)
        var manifest = try HorizontalPoolCacheProvenance.load(Data(contentsOf: manifestURL))
        manifest.files = manifest.files.filter { entry in !cached.contains { entry.key.hasPrefix($0) } }
        try manifest.data().write(to: manifestURL)
        for path in ownFiles {
            let url = projectPool.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: stock.appendingPathComponent(path), to: url)
        }
        HorizontalPoolLibrary.invalidateCache()
    }

    private func files(in directory: URL) throws -> [String: Data] {
        var files = [String: Data]()
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[try HorizontalPoolCacheProvenance.relativePath(url, in: directory)] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func row(_ id: String = "part-mcu", files: [String: Data]? = nil) throws -> HorizontalPartLibraryReview {
        let review = try HorizontalPoolCacheUpdater.review(poolURL: projectPool, files: try files ?? self.files(in: projectPool),
                                                           sourcePools: [stock], references: ["part-mcu": ["U1"]])
        return try XCTUnwrap(review.parts.first { $0.id == id })
    }

    private func edit(_ url: URL, _ change: (inout JSONDictionary) -> Void) throws {
        var json = try JSONHelper.loadDictionary(from: url)
        change(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        HorizontalPoolLibrary.invalidateCache()
    }

    // MARK: - What the review says

    /// The pool that has the part is named, and the part is not one no
    /// attached pool has. A part only the project has is Project-only still.
    func testAPartAnAttachedPoolHasTooIsTheProjectsOwnCopyOfIt() throws {
        let mcu = try row()
        XCTAssertEqual(mcu.status, .projectCopy)
        XCTAssertEqual(mcu.statusTitle, "Project’s own copy")
        XCTAssertEqual(mcu.sourcePool, "Stock")
        XCTAssertFalse(mcu.isInNoAttachedPool, "Stock is attached and has it")
        XCTAssertFalse(mcu.canUpdate, "nothing updates the project's own file")
        XCTAssertTrue(mcu.message.hasPrefix("Stock has this part too, but the project keeps its own copy"), mcu.message)
        XCTAssertEqual(mcu.poolsHoldingOwnCopy.map(\.name), ["Stock"])
        XCTAssertEqual(mcu.poolsHoldingOwnCopy.map(\.url.path), [HorizontalPoolLibrary.canonicalURL(stock).path])

        var alone = try JSONHelper.loadDictionary(from: projectPool.appendingPathComponent("parts/mcu.json"))
        alone["uuid"] = "part-only-here"
        alone["MPN"] = [false, "ONLY-HERE"]
        try write(alone, to: "project/pool/parts/only-here.json")
        let only = try row("part-only-here")
        XCTAssertEqual(only.status, .projectOnly)
        XCTAssertNil(only.sourcePool)
        XCTAssertTrue(only.isInNoAttachedPool)
        XCTAssertEqual(only.poolsHoldingOwnCopy, [])
    }

    // MARK: - Taking the pool's copy

    /// Stock has the part and all it needs, the same as the project's: the
    /// copy writes nothing to Stock. The project's own part and package give
    /// way to cached copies with Stock as their origin, and a later change in
    /// Stock is an update.
    func testUsingThePoolsCopyWritesNothingToThePoolWhichThenKeepsThePartUpToDate() throws {
        let stockBefore = try files(in: stock)
        let copy = try HorizontalPoolPartCopier.plan(partID: "part-mcu", projectFiles: try files(in: projectPool),
                                                     projectPoolURL: projectPool, into: stock)
        XCTAssertTrue(copy.copiesNothing)
        XCTAssertEqual(copy.poolFiles.map(\.path), [])
        XCTAssertEqual(copy.copied, [])
        XCTAssertEqual(copy.recached, ["parts/mcu.json", "packages/lqfp/package.json", "packages/lqfp/padstacks/pad.json"])
        XCTAssertEqual(copy.existing.map(\.kind), ["Part", "Entity", "Unit", "Symbol", "Package", "Padstack"])
        XCTAssertEqual(copy.title, "Use Stock’s copy of MCU-1?")
        XCTAssertEqual(copy.confirmLabel, "Use Pool’s Copy")
        XCTAssertEqual(copy.actionName, "Use Stock’s Copy")
        XCTAssertTrue(copy.summary.hasPrefix("Stock has the part already, and what it needs:\n• Part: MCU-1\n• Entity: MCU\n"), copy.summary)
        XCTAssertTrue(copy.summary.contains("Nothing is written to Stock."), copy.summary)
        XCTAssertFalse(copy.summary.contains("Copies into"), copy.summary)

        try HorizontalPoolPartCopier.writePoolFiles(copy)
        XCTAssertEqual(try files(in: stock), stockBefore, "the pool is as it was")

        var archive = try HorizontalProjectArchive.snapshot(from: root.appendingPathComponent("project"))
        try HorizontalPoolPartCopier.track(copy, in: &archive, poolDirectory: "pool", projectPoolURL: projectPool)
        XCTAssertNil(archive.regularFileData(relativePath: "pool/parts/mcu.json"), "the project's own part is gone")
        XCTAssertNil(archive.regularFileData(relativePath: "pool/packages/lqfp/package.json"))
        XCTAssertNil(archive.regularFileData(relativePath: "pool/packages/lqfp/padstacks/pad.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/parts/cache/part-mcu.json"), "cached from the pool in its place")
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/packages/cache/pkg-lqfp/package.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/3d_models/cache/stock-pool/3d_models/own/lqfp.step"))
        // The project's own model file is no package's now. It stays, for
        // Clean Up Project Pool to offer.
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/3d_models/own/lqfp.step"))

        let taken = HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: "pool")
        let manifest = try HorizontalPoolCacheProvenance.load(taken[HorizontalPoolCacheProvenance.path])
        XCTAssertEqual(manifest.files["parts/cache/part-mcu.json"]?.poolUUID, "stock-pool")
        XCTAssertEqual(manifest.files["parts/cache/part-mcu.json"]?.sourcePath, "parts/mcu.json")
        let current = try row(files: taken)
        XCTAssertEqual(current.status, .current, current.message)
        XCTAssertEqual(current.sourcePool, "Stock")
        XCTAssertEqual(current.poolsHoldingOwnCopy, [])

        try edit(stock.appendingPathComponent("parts/mcu.json")) { $0["description"] = [false, "A better microcontroller"] }
        XCTAssertEqual(try row(files: taken).status, .updateAvailable, "Stock's change reaches the project as an update")

        // Cached from the pool, it is the pool's to update, not to copy again.
        XCTAssertThrowsError(try HorizontalPoolPartCopier.plan(partID: "part-mcu", projectFiles: taken, projectPoolURL: projectPool, into: stock)) {
            XCTAssertTrue(HorizontalCanvasProjectEdit.message(for: $0).contains("already"), HorizontalCanvasProjectEdit.message(for: $0))
        }
    }

    /// Edited in the project since, the part is not the pool's any more:
    /// the review says they differ, and nothing replaces either unasked.
    func testACopyThatDiffersFromThePoolsStaysTheProjectsOwn() throws {
        try edit(projectPool.appendingPathComponent("parts/mcu.json")) { $0["value"] = [false, "edited here"] }
        let mcu = try row()
        XCTAssertEqual(mcu.status, .projectCopy)
        XCTAssertEqual(mcu.sourcePool, "Stock")
        XCTAssertEqual(mcu.message, "Stock has this part too, with other contents than the project’s own copy.")

        XCTAssertThrowsError(try HorizontalPoolPartCopier.plan(partID: "part-mcu", projectFiles: try files(in: projectPool),
                                                               projectPoolURL: projectPool, into: stock)) {
            let message = HorizontalCanvasProjectEdit.message(for: $0)
            XCTAssertTrue(message.contains("same uuid") && message.contains("parts/mcu.json"), message)
        }
    }

    /// A package the pool lacks goes into it as before, with the part
    /// already there listed as not copied.
    func testWhatThePoolLacksIsStillCopiedWhenItHasThePart() throws {
        try FileManager.default.removeItem(at: stock.appendingPathComponent("packages/lqfp"))
        // Stock's part names a package Stock no longer has.
        HorizontalPoolLibrary.invalidateCache()
        let copy = try HorizontalPoolPartCopier.plan(partID: "part-mcu", projectFiles: try files(in: projectPool),
                                                     projectPoolURL: projectPool, into: stock)
        XCTAssertFalse(copy.copiesNothing)
        XCTAssertEqual(Set(copy.poolFiles.map(\.path)), ["packages/lqfp/package.json", "packages/lqfp/padstacks/pad.json"])
        XCTAssertEqual(copy.title, "Copy MCU-1 to Stock?")
        XCTAssertEqual(copy.confirmLabel, "Copy")
        XCTAssertTrue(copy.summary.hasPrefix("Copies into Stock:\n• Package: LQFP"), copy.summary)
        XCTAssertTrue(copy.summary.contains("Already in Stock, not copied:\n• Part: MCU-1"), copy.summary)
        XCTAssertTrue(copy.recached.contains("parts/mcu.json"))
    }
}
