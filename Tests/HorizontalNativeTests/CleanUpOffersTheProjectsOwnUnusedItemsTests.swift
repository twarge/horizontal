import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Clean Up Project Pool offers, after the cached copies, the items the
/// project keeps itself (outside `cache/`) that nothing in the design
/// reaches: a part the board no longer uses, with its entity, units, symbols
/// and package. Nothing else in the app removes one.
///
/// No library has them to copy again, so they are not part of what a cleanup
/// removes by itself: the sheet starts with them unticked, and
/// `clean_up_project_pool` takes one only when `remove` names it.
///
/// The project here keeps a resistor of its own: unit, two symbols, entity,
/// a pool padstack, a package with a padstack and a 3D model, and the part;
/// beside them a frame, a decal, a stray model, and the frame and via its
/// `pool.json` names as defaults. One part in its cache is a library's copy.
final class CleanUpOffersTheProjectsOwnUnusedItemsTests: XCTestCase {
    private var root: URL!
    private var packageURL: URL!
    private var handle = 0

    private let ownTree = [
        "local|parts/own/res.json", "local|entities/own/resistor.json", "local|units/own/resistor.json",
        "local|symbols/own/resistor-ieee.json", "local|symbols/own/resistor.json",
        "local|packages/own/r0603/package.json", "local|padstacks/own/smd.json",
    ]
    private let ownStrays = ["local|frames/own/a4.json", "local|decals/own/logo.json"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-own-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "CleanUpOwnItemsTests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
        addTeardownBlock {
            HorizontalPoolRegistryStore.defaults = .standard
            HorizontalPoolLibrary.invalidateCache()
        }

        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        try writeTheProjectsOwnItems()
        let summary = try XCTUnwrap(try result("open_project", ["path": packageURL.path]) as? [String: Any])
        handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { [handle] in _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
    }

    // MARK: - The project

    private func write(_ json: JSONDictionary, to poolPath: String) throws {
        let url = packageURL.appendingPathComponent("pool/" + poolPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func write(_ text: String, to poolPath: String) throws {
        let url = packageURL.appendingPathComponent("pool/" + poolPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func symbol(_ id: String, name: String) -> JSONDictionary {
        ["type": "symbol", "uuid": id, "name": name, "unit": "unit-own",
         "pins": ["pin-1": ["position": [-2_500_000, 0], "length": 2_500_000, "orientation": "left",
                            "name_visible": true, "pad_visible": true, "name_orientation": "in_line"],
                  "pin-2": ["position": [2_500_000, 0], "length": 2_500_000, "orientation": "right",
                            "name_visible": true, "pad_visible": true, "name_orientation": "in_line"]],
         "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]]
    }

    private func padstack(_ id: String, name: String, type: String = "top") -> JSONDictionary {
        ["type": "padstack", "padstack_type": type, "uuid": id, "name": name,
         "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]]
    }

    private func frame(_ id: String) -> JSONDictionary {
        ["type": "frame", "uuid": id, "name": id, "width": 297_000_000, "height": 210_000_000,
         "lines": [:], "arcs": [:], "texts": [:], "polygons": [:], "junctions": [:]]
    }

    private func part(_ id: String, mpn: String) -> JSONDictionary {
        ["type": "part", "uuid": id, "entity": "ent-own", "package": "pkg-own", "base": NSNull(),
         "MPN": [false, mpn], "value": [false, "10k"], "manufacturer": [false, "Twinleaf"],
         "description": [false, "Thick film resistor"], "datasheet": [false, ""],
         "tags": ["resistor"], "inherit_tags": false, "inherit_model": true,
         "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
         "parametric": [:]]
    }

    private func writeTheProjectsOwnItems() throws {
        try write(["type": "unit", "uuid": "unit-own", "name": "Resistor", "manufacturer": "",
                   "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                            "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
                  to: "units/own/resistor.json")
        try write(symbol("sym-own", name: "Resistor"), to: "symbols/own/resistor.json")
        try write(symbol("sym-own-ieee", name: "Resistor (IEEE)"), to: "symbols/own/resistor-ieee.json")
        try write(["type": "entity", "uuid": "ent-own", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
                   "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-own"]]],
                  to: "entities/own/resistor.json")
        try write(padstack("ps-own", name: "SMD pad"), to: "padstacks/own/smd.json")
        try write(padstack("ps-in-package", name: "Pad 1"), to: "packages/own/r0603/padstacks/pad.json")
        try write(["type": "package", "uuid": "pkg-own", "name": "R0603", "manufacturer": "", "tags": [],
                   "pads": ["pad-1": ["name": "1", "padstack": "ps-in-package",
                                      "placement": ["shift": [-800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                            "pad-2": ["name": "2", "padstack": "ps-own",
                                      "placement": ["shift": [800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
                   "models": ["model-1": ["filename": "3d_models/own/r0603.step", "x": 0, "y": 0, "z": 0, "roll": 0, "pitch": 0, "yaw": 0]],
                   "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
                  to: "packages/own/r0603/package.json")
        try write("solid", to: "3d_models/own/r0603.step")
        try write("stray solid", to: "3d_models/own/stray.step")
        try write(part("part-own", mpn: "OWN-10K"), to: "parts/own/res.json")

        try write(frame("frame-own"), to: "frames/own/a4.json")
        try write(frame("frame-default"), to: "frames/own/default.json")
        try write(padstack("via-default", name: "Via", type: "via"), to: "padstacks/own/via.json")
        try write(["type": "decal", "uuid": "decal-own", "name": "Logo", "polygons": [:], "lines": [:], "arcs": [:], "texts": [:], "junctions": [:]],
                  to: "decals/own/logo.json")
        // A library's copy, in the cache.
        var cached = part("stray-part", mpn: "STRAY-1")
        cached["manufacturer"] = [false, "Yageo"]
        try write(cached, to: "parts/cache/stray-part.json")

        let poolURL = packageURL.appendingPathComponent("pool/pool.json")
        var pool = try JSONHelper.loadDictionary(from: poolURL)
        pool["default_frame"] = "frame-default"
        pool["default_via"] = "via-default"
        try JSONSerialization.data(withJSONObject: pool, options: [.sortedKeys]).write(to: poolURL)
    }

    private func review() throws -> HorizontalPoolCacheCleanupReview {
        let archive = try HorizontalProjectArchive.snapshot(from: packageURL)
        let project = try HorizontalProject.loadSnapshot(of: archive)
        return HorizontalPoolCacheCleanup.review(archive: archive, project: project,
                                                 files: HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: "pool"))
    }

    private func exists(_ poolPath: String) -> Bool {
        FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("pool/" + poolPath).path)
    }

    // MARK: - The dispatcher

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
        }
        if ["apply", "clean_up_project_pool"].contains(method) {
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HorizontalDispatch.call(requestJSON).utf8)) as? [String: Any])
    }

    private func result(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] as? [String: Any] {
            XCTFail("\(method) failed: \(error["message"] ?? error)")
        }
        return try XCTUnwrap(response["result"])
    }

    private func cleanUp(_ params: [String: Any] = [:]) throws -> JSONDictionary {
        try XCTUnwrap(try result("clean_up_project_pool", params) as? JSONDictionary)
    }

    // MARK: - What is offered

    /// With nothing placed, the whole of the project's own resistor is
    /// unused, and is listed after the cache's part: each item by its file,
    /// a package with the padstack in its folder, a model by itself. The
    /// frame and via `pool.json` names as the pool's defaults are not.
    func testTheProjectsOwnUnusedItemsFollowTheCachedOnes() throws {
        let review = try review()
        XCTAssertEqual(review.items.map(\.id), ["part|stray-part"] + ownTree + ownStrays
                       + ["local|3d_models/own/r0603.step", "local|3d_models/own/stray.step"])
        XCTAssertEqual(review.items.filter(\.isProjectLocal).map(\.id), Array(review.items.map(\.id).dropFirst()))

        let part = try XCTUnwrap(review.items.first { $0.id == "local|parts/own/res.json" })
        XCTAssertEqual(part.kind, "part")
        XCTAssertEqual(part.uuid, "part-own")
        XCTAssertEqual(part.name, "OWN-10K / Twinleaf", "named as the cache's parts are")
        XCTAssertEqual(part.paths, ["parts/own/res.json"])

        let package = try XCTUnwrap(review.items.first { $0.kind == "package" })
        XCTAssertEqual(package.name, "R0603")
        XCTAssertEqual(package.paths, ["packages/own/r0603/package.json", "packages/own/r0603/padstacks/pad.json"],
                       "its folder, with the padstack beside it")
        XCTAssertEqual(review.items.last?.kind, "model")
        XCTAssertEqual(review.items.last?.bytes, "stray solid".utf8.count)
    }

    /// Placed on the sheet, the part keeps its tree: entity, unit, both
    /// symbols, package, the pool padstack a pad names and the package's
    /// model. What it never used is still offered.
    func testWhatTheDesignUsesOfItsOwnStays() throws {
        _ = try result("apply", ["ops": [["op": "ensure_component", "refdes": "R1", "part": "part-own"]]])
        let block = try JSONHelper.loadDictionary(from: packageURL.appendingPathComponent("top_block.json"))
        XCTAssertEqual(block.dictionaryMap("components").values.first?.string("part"), "part-own")

        XCTAssertEqual(try review().items.map(\.id), ["part|stray-part"] + ownStrays + ["local|3d_models/own/stray.step"])

        _ = try result("apply", ["ops": [["op": "remove_component", "component": "R1"]]])
        XCTAssertEqual(try review().items.filter(\.isProjectLocal).count, ownTree.count + ownStrays.count + 2,
                       "taken off the sheet again, it is all unused")
    }

    /// A cached copy and one of the project's own can share a uuid, the
    /// project's overriding the library's. Unused, each is offered under its
    /// own id.
    func testAnOverriddenCachedCopyIsOfferedBesideTheProjectsOwn() throws {
        try write(part("part-own", mpn: "OWN-10K"), to: "parts/cache/part-own.json")
        let ids = try review().items.map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), ["part|part-own", "part|stray-part"])
        XCTAssertTrue(ids.contains("local|parts/own/res.json"))
        XCTAssertEqual(Set(ids).count, ids.count, "no two share an id")
    }

    /// A package folder that holds another package below is not that
    /// package's alone: it goes as its file. The one below goes as its
    /// folder.
    func testAPackageWithAnotherBelowItGoesAsItsFileAlone() throws {
        func package(_ id: String) -> JSONDictionary {
            ["type": "package", "uuid": id, "name": id, "manufacturer": "", "tags": [], "pads": [:], "models": [:],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]]
        }
        try write(package("pkg-family"), to: "packages/family/package.json")
        try write(padstack("ps-family", name: "Shared"), to: "packages/family/padstacks/shared.json")
        try write(package("pkg-variant"), to: "packages/family/variant/package.json")
        try write(padstack("ps-variant", name: "Its own"), to: "packages/family/variant/padstacks/pad.json")

        let items = try review().items
        XCTAssertEqual(items.first { $0.id == "local|packages/family/package.json" }?.paths, ["packages/family/package.json"])
        XCTAssertEqual(items.first { $0.id == "local|packages/family/variant/package.json" }?.paths,
                       ["packages/family/variant/package.json", "packages/family/variant/padstacks/pad.json"])
    }

    // MARK: - What a cleanup removes

    /// Only the cached copies are chosen to begin with, which is what the
    /// sheet ticks.
    func testOnlyTheCachedCopiesAreChosenToBeginWith() throws {
        let review = try review()
        XCTAssertEqual(review.defaultSelection, ["part|stray-part"])
        XCTAssertTrue(review.items.count > 1)
    }

    /// A dry run lists the project's own marked `project_local`. Left to
    /// itself the cleanup removes the cache's part and none of them; named,
    /// they go, a package with its folder.
    func testACleanUpRemovesTheProjectsOwnOnlyWhenNamed() throws {
        let dry = try cleanUp(["dry_run": true])
        let rows = try XCTUnwrap(dry["items"] as? [JSONDictionary])
        XCTAssertEqual(rows.count, 1 + ownTree.count + ownStrays.count + 2)
        XCTAssertEqual(rows.filter { $0.bool("project_local") == true }.compactMap { $0.string("id") }.prefix(ownTree.count).map { $0 }, ownTree)
        XCTAssertNil(rows.first { $0.string("id") == "part|stray-part" }?["project_local"], "a cached copy is not marked")
        XCTAssertEqual(dry["remove"] as? [String], ["part|stray-part"], "what it would remove by itself")

        let committed = try cleanUp(["plan_digest": try XCTUnwrap(dry.string("plan_digest")),
                                     "review_digest": try XCTUnwrap(dry.string("review_digest"))])
        XCTAssertEqual(committed.string("status"), "committed")
        XCTAssertEqual(committed["remove"] as? [String], ["part|stray-part"])
        XCTAssertFalse(exists("parts/cache/stray-part.json"))
        for path in ["parts/own/res.json", "entities/own/resistor.json", "packages/own/r0603/package.json",
                     "3d_models/own/stray.step", "frames/own/a4.json"] {
            XCTAssertTrue(exists(path), "\(path) is the project's own, and stays")
        }

        // Nothing is left in the cache: run again, it removes nothing and
        // still lists what the project keeps.
        let again = try cleanUp()
        XCTAssertEqual(again["remove"] as? [String], [])
        XCTAssertEqual((again["items"] as? [JSONDictionary])?.count, ownTree.count + ownStrays.count + 2)
        XCTAssertTrue(exists("parts/own/res.json"))

        // The default frame is not an unused item, so it can't be named.
        XCTAssertNotNil(try call("clean_up_project_pool", ["remove": ["local|frames/own/default.json"], "dry_run": true])["error"])

        let named = ["local|parts/own/res.json", "local|packages/own/r0603/package.json", "local|3d_models/own/stray.step"]
        let plan = try cleanUp(["dry_run": true, "remove": named])
        XCTAssertEqual(plan["remove"] as? [String], named)
        let removed = try cleanUp(["remove": named, "plan_digest": try XCTUnwrap(plan.string("plan_digest")),
                                   "review_digest": try XCTUnwrap(plan.string("review_digest"))])
        XCTAssertEqual(removed.string("status"), "committed")
        XCTAssertFalse(exists("parts/own/res.json"))
        XCTAssertFalse(exists("packages/own/r0603"), "the package's folder went with it")
        XCTAssertFalse(exists("3d_models/own/stray.step"))
        XCTAssertTrue(exists("entities/own/resistor.json"), "not named, it stays")
        XCTAssertTrue(exists("3d_models/own/r0603.step"))
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0, "the part has left the project's parts")
    }
}
