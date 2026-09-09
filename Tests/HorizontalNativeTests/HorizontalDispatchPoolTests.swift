import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Reaching a part the project has never used: finding it in the pools the
/// project draws from, copying it into the project pool, and putting it on a
/// sheet — the whole path, through the dispatcher.
final class HorizontalDispatchPoolTests: XCTestCase {
    private var root: URL!
    private var packageURL: URL!
    private var handle = 0
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dispatch-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }

        testDefaults = UserDefaults(suiteName: "HorizontalDispatchPoolTests-\(UUID().uuidString)")
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
        addTeardownBlock {
            HorizontalPoolRegistryStore.defaults = .standard
            HorizontalPoolLibrary.invalidateCache()
        }
        try writeStockPool()
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: root.appendingPathComponent("stock", isDirectory: true)))

        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let summary = try XCTUnwrap(try result("open_project", ["path": packageURL.path]) as? [String: Any])
        handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { [handle] in _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
    }

    @discardableResult
    private func write(_ json: JSONDictionary, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    /// A resistor in a base pool, complete enough to place: unit, symbol,
    /// entity, padstack, package and part.
    private func writeStockPool() throws {
        try write(["type": "pool", "uuid": "stock-pool", "name": "Stock"], to: "stock/pool.json")
        try write(
            ["type": "unit", "uuid": "unit-1", "name": "Resistor", "manufacturer": "",
             "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                      "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
            to: "stock/units/resistor.json"
        )
        try write(
            ["type": "symbol", "uuid": "sym-1", "name": "Resistor", "unit": "unit-1",
             "pins": ["pin-1": ["position": [-2_500_000, 0], "length": 2_500_000, "orientation": "left",
                                "name_visible": true, "pad_visible": true, "name_orientation": "in_line"],
                      "pin-2": ["position": [2_500_000, 0], "length": 2_500_000, "orientation": "right",
                                "name_visible": true, "pad_visible": true, "name_orientation": "in_line"]],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
            to: "stock/symbols/resistor.json"
        )
        try write(
            ["type": "entity", "uuid": "ent-1", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
             "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-1"]]],
            to: "stock/entities/resistor.json"
        )
        try write(
            ["type": "padstack", "padstack_type": "top", "uuid": "ps-pool", "name": "SMD pad",
             "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
            to: "stock/padstacks/smd.json"
        )
        try write(
            ["type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": [],
             "pads": ["pad-1": ["name": "1", "padstack": "ps-pool", "placement": ["shift": [-800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                      "pad-2": ["name": "2", "padstack": "ps-pool", "placement": ["shift": [800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
             "models": [:], "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
            to: "stock/packages/r0603/package.json"
        )
        try write(
            ["type": "part", "uuid": "part-1", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RC0603FR-0710KL"], "value": [false, "10k"], "manufacturer": [false, "Yageo"],
             "description": [false, "Thick film resistor"], "datasheet": [false, ""],
             "tags": ["resistor", "0603"], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
             "parametric": [:]],
            to: "stock/parts/res-10k.json"
        )
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
        }
        if ["apply", "import_pool_part"].contains(method) {
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

    func testSearchFindsPartsTheProjectPoolDoesNotHave() throws {
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0,
                       "an untouched project pool has no parts")

        let found = try XCTUnwrap(try result("search_pool", ["query": "0710KL", "kind": "part"]) as? [String: Any])
        let items = try XCTUnwrap(found["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["uuid"] as? String, "part-1")
        XCTAssertEqual(items[0]["name"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(items[0]["manufacturer"] as? String, "Yageo")
        XCTAssertEqual(items[0]["pool"] as? String, "Stock")
        XCTAssertEqual(items[0]["in_project_pool"] as? Bool, false)

        let pools = try XCTUnwrap(found["pools"] as? [[String: Any]])
        XCTAssertEqual(pools.first?["is_project_pool"] as? Bool, true)
        XCTAssertTrue(pools.contains { $0["uuid"] as? String == "stock-pool" }, "\(pools)")

        // Tags and manufacturers match as well as names, and kind narrows.
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "Yageo"]) as? [String: Any])["total"] as? Int), 1)
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["kind": "symbol"]) as? [String: Any])["total"] as? Int), 1)
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "nothing here"]) as? [String: Any])["total"] as? Int), 0)

        XCTAssertNotNil(try call("search_pool", ["kind": "gizmo"])["error"])
    }

    func testImportedPartBecomesUsableAndDrawable() throws {
        let dry = try XCTUnwrap(try result("import_pool_part", ["part": "part-1", "dry_run": true]) as? [String: Any])
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0, "a dry run writes nothing")

        let imported = try XCTUnwrap(try result("import_pool_part", ["part": "part-1"]) as? [String: Any])
        XCTAssertEqual(imported["mpn"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(imported["already_cached"] as? Bool, false)
        let written = try XCTUnwrap(imported["written"] as? [String])
        for kind in ["parts/cache/part-1.json", "entities/cache/ent-1.json", "units/cache/unit-1.json",
                     "symbols/cache/sym-1.json", "packages/cache/pkg-1/package.json", "padstacks/cache/ps-pool.json"] {
            XCTAssertTrue(written.contains { $0.hasSuffix(kind) }, "\(kind) missing from \(written)")
        }
        XCTAssertEqual((imported["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        let parts = try XCTUnwrap(try result("list_parts") as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])
        XCTAssertEqual(parts.first?["in_project_pool"] as? Bool, true)
        let again = try XCTUnwrap(try result("search_pool", ["query": "0710KL"]) as? [String: Any])
        XCTAssertEqual((again["items"] as? [[String: Any]])?.first?["in_project_pool"] as? Bool, true)

        // The point of importing: the part can now carry a component, and the
        // symbol that came with it can draw it on a sheet.
        _ = try result("apply", ["ops": [
            ["op": "ensure_component", "refdes": "R1", "part": "part-1"],
            ["op": "place_symbol", "component": "R1", "x_mm": 25, "y_mm": 35]
        ]])
        let component = try XCTUnwrap(try result("get_component", ["refdes": "R1"]) as? [String: Any])
        let symbols = try XCTUnwrap(component["symbols"] as? [[String: Any]])
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0]["x_mm"] as? Double, 25)
        XCTAssertEqual(component["mpn"] as? String, "RC0603FR-0710KL")
    }

    func testImportingTwiceIsIdempotentAndUnknownPartsAreNamed() throws {
        _ = try result("import_pool_part", ["part": "RC0603FR-0710KL"])
        let again = try XCTUnwrap(try result("import_pool_part", ["part": "part-1"]) as? [String: Any])
        XCTAssertEqual(again["already_cached"] as? Bool, true)
        XCTAssertEqual(again["written"] as? [String], [])

        let missing = try call("import_pool_part", ["part": "NOT-A-PART"])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testScopedListPartsSeesTheBasePoolsBeforeAnythingIsImported() throws {
        let all = try XCTUnwrap(try result("list_parts", ["scope": "all"]) as? [[String: Any]])
        XCTAssertEqual(all.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])
        XCTAssertEqual(all.first?["in_project_pool"] as? Bool, false)
        XCTAssertEqual(all.first?["pool"] as? String, "Stock")
        XCTAssertNotNil(try call("list_parts", ["scope": "sideways"])["error"])
    }

    /// A worker process has its own user defaults, so it cannot see the pools
    /// the app registered. Naming the directory reaches them anyway.
    func testAnUnregisteredPoolIsReachableByPath() throws {
        let stock = root.appendingPathComponent("stock", isDirectory: true)
        HorizontalPoolRegistryStore.removePool(at: stock)
        HorizontalPoolLibrary.invalidateCache()
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "0710KL"]) as? [String: Any])["total"] as? Int), 0,
                       "an unregistered pool is not discovered")

        let named = try XCTUnwrap(try result("search_pool", ["query": "0710KL", "pool_path": stock.path]) as? [String: Any])
        XCTAssertEqual((named["items"] as? [[String: Any]])?.first?["uuid"] as? String, "part-1")

        _ = try result("import_pool_part", ["part": "part-1", "pool_path": stock.path])
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])

        let notAPool = try call("search_pool", ["pool_path": root.appendingPathComponent("nowhere").path])
        XCTAssertEqual((notAPool["error"] as? [String: Any])?["code"] as? Int, -32001)
    }
}
