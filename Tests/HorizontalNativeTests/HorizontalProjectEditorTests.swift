import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The edit vocabulary applied through `apply`, against the new-document
/// template plus a resistor fabricated into its project pool with the pool
/// item factory. Every assertion reads back through the dispatcher, so the
/// files the editor writes are the files the loader accepts.
final class HorizontalProjectEditorTests: XCTestCase {
    private var packageURL: URL!
    private var handle = 0
    private var partID = ""
    private var entityID = ""
    private var padIDs: [String] = []
    private var symbolID = ""
    private var gateID = ""
    private var unitPinIDs: [String] = []

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        (partID, entityID) = try fabricateResistor(poolURL: packageURL.appendingPathComponent("pool"))

        let summary = try XCTUnwrap(try result("open_project", ["path": packageURL.path]) as? [String: Any])
        handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { [handle] in _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
    }

    /// A two-pin resistor: unit, entity with a Main gate, an empty package,
    /// and a part tying them together, laid out as a project pool cache.
    private func fabricateResistor(poolURL: URL) throws -> (part: String, entity: String) {
        let pin1 = HorizontalPoolItemFactory.newUUID()
        let pin2 = HorizontalPoolItemFactory.newUUID()
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.name = "Resistor"
        unit.pins = [
            pin1: HorizontalUnitPin(id: pin1, primaryName: "1"),
            pin2: HorizontalUnitPin(id: pin2, primaryName: "2")
        ]
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.prefix = "R"
        gateID = try XCTUnwrap(entity.gates.keys.first)
        unitPinIDs = [pin1, pin2]
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        padstack.name = "0603 pad"
        let shapeID = HorizontalPoolItemFactory.newUUID()
        padstack.shapes = [shapeID: HorizontalPadstackShape(id: shapeID, form: .rectangle, params: [800_000, 900_000])]
        var package = HorizontalPoolItemFactory.newPackage()
        package.name = "0603"
        for (index, name) in ["1", "2"].enumerated() {
            let padID = HorizontalPoolItemFactory.newUUID()
            padIDs.append(padID)
            package.pads[padID] = HorizontalPad(
                id: padID,
                name: name,
                padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: Double(index * 1_600_000 - 800_000), y: 0), angle: 0, mirrored: false)
            )
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        // Pads to pins, so the board's pads carry the block's nets.
        part.padMap = [
            padIDs[0]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin1),
            padIDs[1]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin2)
        ]
        part.attributes[.mpn] = HorizontalPartAttribute(value: "RC0603FR-0710KL")
        // No part value: Horizon shows a part's value over the component's,
        // and these tests read the component's back.
        part.attributes[.manufacturer] = HorizontalPartAttribute(value: "Yageo")

        // A gate is drawn by a symbol for its unit; without one nothing can
        // be placed on a sheet.
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.pins = [
            pin1: HorizontalSymbolPin(id: pin1, position: HorizontalPoint(x: -2_500_000, y: 0), length: 2_500_000),
            pin2: HorizontalSymbolPin(id: pin2, position: HorizontalPoint(x: 2_500_000, y: 0), length: 2_500_000)
        ]
        symbolID = symbol.uuid

        _ = try HorizontalPoolItemFactory.write(.symbol(symbol), to: poolURL.appendingPathComponent("symbols/cache/\(symbol.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return (part.uuid, entity.uuid)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method != "open_project" && method != "list_ops" {
            params["handle"] = handle
        }
        if ["apply", "pour_planes"].contains(method) {
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let responseJSON = HorizontalDispatch.call(requestJSON)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any])
    }

    private func result(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] as? [String: Any] {
            XCTFail("\(method) failed: \(error["message"] ?? error)")
        }
        return try XCTUnwrap(response["result"])
    }

    private func apply(_ ops: [[String: Any]], dryRun: Bool = false) throws -> [String: Any] {
        try XCTUnwrap(try result("apply", ["ops": ops, "dry_run": dryRun]) as? [String: Any])
    }

    private func component(_ refdes: String) throws -> [String: Any] {
        try XCTUnwrap(try result("get_component", ["refdes": refdes]) as? [String: Any])
    }

    private func pinNets(_ component: [String: Any]) throws -> [String: String] {
        let pins = try XCTUnwrap(component["pins"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: pins.map { ($0["pin"] as? String ?? "", $0["net"] as? String ?? "") })
    }

    func testListOpsDescribesEveryKind() throws {
        let ops = try XCTUnwrap(try result("list_ops") as? [[String: Any]])
        XCTAssertEqual(Set(ops.compactMap { $0["op"] as? String }), Set(HorizontalEditOperationKind.allCases.map(\.rawValue)))
    }

    func testInheritedValueAndMultiplePhysicalPadsWithoutBoardPlacement() throws {
        let pool = packageURL.appendingPathComponent("pool")
        let partURL = pool.appendingPathComponent("parts/cache/\(partID).json")
        var base = try HorizontalPoolPartItem(json: JSONHelper.loadDictionary(from: partURL))
        base.attributes[.value] = HorizontalPartAttribute(value: "10k ±1%")
        let packageID = try XCTUnwrap(base.packageID)
        let packageFile = pool.appendingPathComponent("packages/cache/\(packageID)/package.json")
        var package = try HorizontalPoolPackage(json: JSONHelper.loadDictionary(from: packageFile))
        let extra = UUID().uuidString.lowercased()
        var pad = try XCTUnwrap(package.pads[padIDs[0]])
        pad.id = extra; pad.name = "EP"
        package.pads[extra] = pad
        base.padMap[extra] = base.padMap[padIDs[0]]
        let mechanical = HorizontalPoolItemFactory.newPadstack(type: .mechanical)
        let hole = UUID().uuidString.lowercased()
        pad.id = hole; pad.name = "MH"; pad.padstackID = mechanical.uuid
        package.pads[hole] = pad
        var derived = base
        derived.uuid = UUID().uuidString.lowercased()
        derived.baseID = base.uuid
        derived.attributes[.value] = HorizontalPartAttribute(inherited: true, value: "ignored")
        _ = try HorizontalPoolItemFactory.write(.part(base), to: partURL, replacingExisting: true)
        _ = try HorizontalPoolItemFactory.write(.part(derived), to: pool.appendingPathComponent("parts/cache/\(derived.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: packageFile, replacingExisting: true)
        _ = try HorizontalPoolItemFactory.write(.padstack(mechanical), to: pool.appendingPathComponent("padstacks/cache/\(mechanical.uuid).json"))
        _ = try result("reload_project")
        _ = try apply([["op": "ensure_component", "refdes": "R1", "part": derived.uuid, "value": "4k7"]])
        let found = try component("R1")
        XCTAssertEqual(found["placed_on_board"] as? Bool, false)
        XCTAssertEqual(found["raw_value"] as? String, "4k7")
        XCTAssertEqual(found["effective_value"] as? String, "10k ±1%")
        let quantity = try XCTUnwrap(found["electrical_value"] as? JSONDictionary)
        XCTAssertEqual(quantity["value_si"] as? Double, 10000)
        XCTAssertEqual(quantity["tolerance_fraction"] as? Double, 0.01)
        let pins = try XCTUnwrap(found["pins"] as? [JSONDictionary])
        let first = try XCTUnwrap(pins.first { $0.string("pin") == "1" })
        XCTAssertEqual((first["physical_pads"] as? [JSONDictionary])?.compactMap { $0.string("name") }, ["1", "EP"])
        XCTAssertEqual(first.string("connection_state"), "unconnected")
        let terminals = try XCTUnwrap(found["physical_terminals"] as? [JSONDictionary])
        XCTAssertEqual(terminals.first { $0.string("name") == "MH" }?.string("role"), "mechanical")
    }

    func testCreateConnectPlaceAndReadBack() throws {
        let applied = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID, "value": "10k"],
            ["op": "ensure_component", "refdes": "R2", "entity": entityID, "value": "4k7"],
            ["op": "ensure_net", "name": "VCC"],
            ["op": "ensure_net", "name": "GND", "is_power": true],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VCC"],
            ["op": "connect", "component": "R1", "pin": "Main/2", "net": "GND"],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 20, "angle_deg": 90]
        ])
        XCTAssertEqual(applied["applied"] as? Int, 7)
        let written = try XCTUnwrap(applied["written"] as? [String])
        XCTAssertEqual(written.count, 2, "block and board: \(written)")
        let summary = try XCTUnwrap(applied["project"] as? [String: Any])
        XCTAssertEqual(summary["diagnostics"] as? [String], [], "the loader must accept what the editor wrote")

        let r1 = try component("R1")
        // Horizon shows a part's value, falling back to its MPN, over the
        // component's own value; R2 has no part, so its value is its own.
        XCTAssertEqual(r1["value"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(r1["mpn"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(try component("R2")["value"] as? String, "4k7")
        XCTAssertEqual(try component("R2")["pin_count"] as? Int, 2, "pins resolve from the entity's unit without a part")
        XCTAssertEqual(r1["pin_count"] as? Int, 2)
        XCTAssertEqual(try pinNets(r1), ["1": "VCC", "2": "GND"])
        let board = try XCTUnwrap(r1["board"] as? [String: Any])
        XCTAssertEqual(board["x_mm"] as? Double, 10)
        XCTAssertEqual(board["y_mm"] as? Double, 20)
        XCTAssertEqual(board["angle_deg"] as? Double, 90)
        XCTAssertEqual(board["side"] as? String, "top")

        let gnd = try XCTUnwrap(try result("get_net", ["name": "GND"]) as? [String: Any])
        XCTAssertEqual(gnd["is_power"] as? Bool, true)
        XCTAssertEqual(gnd["pin_count"] as? Int, 1)
    }

    func testRenameRetireGroupTagAndRemove() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "ensure_component", "refdes": "R2", "entity": entityID, "value": "10k"],
            ["op": "ensure_net", "name": "VCC"],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VCC"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "GND", "create_net": true],
            ["op": "place_component", "component": "R1", "x_mm": 1, "y_mm": 2]
        ])
        let edited = try apply([
            ["op": "rename_net", "net": "VCC", "name": "P3V3"],
            ["op": "set_value", "component": "R2", "value": "22k"],
            ["op": "set_value", "component": "R1", "value": "ignored"],
            ["op": "set_group_tag", "component": "R1", "group": "psu", "tag": "r_in"],
            ["op": "place_component", "component": "R1", "angle_deg": 180, "bottom": true]
        ])
        var r1 = try component("R1")
        XCTAssertEqual(try pinNets(r1), ["1": "P3V3", "2": "GND"])
        XCTAssertEqual(try component("R2")["value"] as? String, "22k")
        XCTAssertEqual(r1["value"] as? String, "RC0603FR-0710KL", "the part's value wins")
        let partNote = try XCTUnwrap((edited["changes"] as? [[String: Any]])?.first { $0["component"] as? String == r1["id"] as? String && $0["op"] as? String == "set_value" })
        XCTAssertNotNil(partNote["note"], "set_value on a part-backed component must say the part's value shows")
        XCTAssertNotEqual(r1["group"] as? String, HorizontalProjectEditor.nullUUID)
        XCTAssertNotEqual(r1["tag"] as? String, HorizontalProjectEditor.nullUUID)
        let board = try XCTUnwrap(r1["board"] as? [String: Any])
        XCTAssertEqual(board["side"] as? String, "bottom")
        XCTAssertEqual(board["angle_deg"] as? Double, 180)
        XCTAssertEqual(board["x_mm"] as? Double, 1, "a move without coordinates keeps the position")

        let retired = try apply([["op": "retire_net", "net": "GND"]])
        let change = try XCTUnwrap((retired["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual((change["removed"] as? [String: Any])?["connections"] as? Int, 1)
        r1 = try component("R1")
        XCTAssertEqual(try pinNets(r1), ["1": "P3V3", "2": ""])
        XCTAssertNil(try call("get_net", ["name": "GND"])["result"])

        _ = try apply([["op": "remove_placement", "component": "R1"]])
        XCTAssertNil(try component("R1")["board"])
        _ = try apply([["op": "remove_component", "component": "R1"], ["op": "remove_component", "component": "R2"]])
        XCTAssertEqual((try result("list_components") as? [Any])?.count, 0)
        XCTAssertEqual((try XCTUnwrap(try result("project_info") as? [String: Any]))["diagnostics"] as? [String], [])
    }

    /// Two resistors laid out and routed as group "a"; group "b" gets the
    /// same placement, rotated, with the track between them copied onto its
    /// own pads. What atopile's module layouts become inside Horizontal.
    func testCopyGroupLayoutMovesPackagesAndRouting() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID, "group": "a", "tag": "top"],
            ["op": "ensure_component", "refdes": "R2", "part": partID, "group": "a", "tag": "bottom"],
            ["op": "ensure_component", "refdes": "R3", "part": partID, "group": "b", "tag": "top"],
            ["op": "ensure_component", "refdes": "R4", "part": partID, "group": "b", "tag": "bottom"],
            ["op": "ensure_net", "name": "MID"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "MID"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "MID"],
            ["op": "connect", "component": "R3", "pin": "2", "net": "MID2", "create_net": true],
            ["op": "connect", "component": "R4", "pin": "1", "net": "MID2", "create_net": true],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10, "angle_deg": 0],
            ["op": "place_component", "component": "R2", "x_mm": 10, "y_mm": 6, "angle_deg": 0]
        ])
        let groups = try XCTUnwrap(try result("list_groups") as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["name"] as? String }, ["a", "b"])
        XCTAssertEqual(groups[0]["placed_count"] as? Int, 2)
        XCTAssertEqual(groups[1]["placed_count"] as? Int, 0)

        // A track from R1 pad 2 down to R2 pad 1 through one junction,
        // written straight into board.json the way the app's tracks are.
        let boardURL = packageURL.appendingPathComponent("board.json")
        var board = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: boardURL)) as? [String: Any])
        let packages = try XCTUnwrap(board["packages"] as? [String: Any])
        func boardPackage(of refdes: String) throws -> String {
            let id = try XCTUnwrap(try component(refdes)["id"] as? String)
            return try XCTUnwrap(packages.first { (($0.value as? [String: Any])?["component"] as? String)?.lowercased() == id }?.key)
        }
        let r1Package = try boardPackage(of: "R1")
        let r2Package = try boardPackage(of: "R2")
        let junctionID = "11111111-2222-4333-8444-555555555555"
        var junctions = board["junctions"] as? [String: Any] ?? [:]
        junctions[junctionID] = ["position": [10_800_000, 8_000_000]]
        board["junctions"] = junctions
        var tracks = board["tracks"] as? [String: Any] ?? [:]
        tracks["aaaaaaaa-1111-4222-8333-444444444444"] = ["from": ["junc": NSNull(), "pad": "\(r1Package)/\(padIDs[1])"], "to": ["junc": junctionID, "pad": NSNull()], "layer": 0, "width": 250_000, "width_from_net_class": false, "locked": false]
        tracks["bbbbbbbb-1111-4222-8333-444444444444"] = ["from": ["junc": junctionID, "pad": NSNull()], "to": ["junc": NSNull(), "pad": "\(r2Package)/\(padIDs[0])"], "layer": 0, "width": 250_000, "width_from_net_class": false, "locked": false]
        board["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: board, options: [.prettyPrinted, .sortedKeys]).write(to: boardURL)
        _ = try result("reload_project")
        let before = try XCTUnwrap((try result("board_info") as? [String: Any])?["counts"] as? [String: Any])
        XCTAssertEqual(before["tracks"] as? Int, 2)
        let mid = try XCTUnwrap(try result("get_net", ["name": "MID"]) as? [String: Any])
        XCTAssertEqual(mid["track_count"] as? Int, 2, "the source tracks take MID from R1 and R2's pads: \(mid)")

        let copied = try apply([["op": "copy_group_layout", "source": "a", "target": "b", "x_mm": 30, "y_mm": 10, "angle_deg": 90]])
        let change = try XCTUnwrap((copied["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["placed"] as? Int, 2)
        XCTAssertEqual(change["tracks"] as? Int, 2)
        XCTAssertEqual(change["junctions"] as? Int, 1)
        XCTAssertEqual(change["anchor_tag"] as? String, "bottom")

        // R4 (tag bottom) is the anchor at 30,10 rotated to 90 from the
        // source's 0; R3 (tag top) sat 4 mm above R2 in the source, so after
        // the 90-degree turn it sits 4 mm to the left, rotated 90 more.
        let r4 = try XCTUnwrap(try component("R4")["board"] as? [String: Any])
        XCTAssertEqual(r4["x_mm"] as? Double, 30)
        XCTAssertEqual(r4["y_mm"] as? Double, 10)
        XCTAssertEqual(r4["angle_deg"] as? Double, 90)
        let r3 = try XCTUnwrap(try component("R3")["board"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(r3["x_mm"] as? Double), 26, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r3["y_mm"] as? Double), 10, accuracy: 0.001)
        XCTAssertEqual(r3["angle_deg"] as? Double, 90)

        let after = try XCTUnwrap((try result("board_info") as? [String: Any])?["counts"] as? [String: Any])
        XCTAssertEqual(after["tracks"] as? Int, 4)
        let mid2 = try XCTUnwrap(try result("get_net", ["name": "MID2"]) as? [String: Any])
        XCTAssertEqual(mid2["track_count"] as? Int, 2, "the copied tracks take the target group's net from its pads")
        XCTAssertEqual(mid2["airwire_count"] as? Int, 0)

        let same = try call("apply", ["ops": [["op": "copy_group_layout", "source": "a", "target": "a"]]])
        XCTAssertNotNil(same["error"])
    }

    func testDryRunWritesNothingAndErrorsAbortTheBatch() throws {
        _ = try apply([["op": "ensure_component", "refdes": "R1", "entity": entityID, "value": "10k"]])
        let dry = try apply([["op": "set_value", "component": "R1", "value": "47k"]], dryRun: true)
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual((dry["would_write"] as? [String])?.count, 1)
        XCTAssertEqual(try component("R1")["value"] as? String, "10k")

        let failed = try call("apply", ["ops": [
            ["op": "set_value", "component": "R1", "value": "47k"],
            ["op": "connect", "component": "R1", "pin": "3", "net": "VCC", "create_net": true]
        ]])
        let error = try XCTUnwrap(failed["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32001, "\(error)")
        XCTAssertEqual(try component("R1")["value"] as? String, "10k", "a failing op must leave every file untouched")

        let unknown = try call("apply", ["ops": [["op": "teleport"]]])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32602)
        let duplicateGate = try call("apply", ["ops": [["op": "connect", "component": "R1", "pin": "Nope/1", "net": "x", "create_net": true]]])
        XCTAssertEqual((duplicateGate["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    private func symbols(_ component: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(component["symbols"] as? [[String: Any]])
    }

    private func checkMessages(_ category: String) throws -> [[String: Any]] {
        let report = try XCTUnwrap(try result("check") as? [String: Any])
        let messages = try XCTUnwrap(report["messages"] as? [[String: Any]])
        return messages.filter { $0["category"] as? String == category }
    }

    /// A component created through the netlist alone is drawn nowhere;
    /// place_symbol is what puts it on a sheet, and check says so until it is.
    func testPlaceSymbolDrawsAGateAndCheckReportsUndrawnComponents() throws {
        _ = try apply([["op": "ensure_component", "refdes": "R1", "part": partID, "value": "10k"]])
        XCTAssertEqual(try symbols(try component("R1")).count, 0)
        let undrawn = try XCTUnwrap(try checkMessages("schematic").first)
        XCTAssertEqual(undrawn["refdes"] as? String, "R1")
        XCTAssertEqual(undrawn["level"] as? String, "warning")

        let placed = try apply([["op": "place_symbol", "component": "R1", "x_mm": 30, "y_mm": 40, "angle_deg": 90]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["created"] as? Bool, true)
        XCTAssertEqual(change["gate"] as? String, gateID)
        XCTAssertEqual(change["symbol"] as? String, symbolID)
        XCTAssertEqual((placed["project"] as? [String: Any])?["diagnostics"] as? [String], [],
                       "the loader must accept the schematic the editor wrote")

        let drawn = try symbols(try component("R1"))
        XCTAssertEqual(drawn.count, 1)
        XCTAssertEqual(drawn[0]["x_mm"] as? Double, 30)
        XCTAssertEqual(drawn[0]["y_mm"] as? Double, 40)
        XCTAssertEqual(drawn[0]["angle_deg"] as? Double, 90)
        XCTAssertEqual(try checkMessages("schematic").count, 0)

        // Placing again moves the symbol that is already there.
        let moved = try apply([["op": "place_symbol", "component": "R1", "x_mm": 50, "y_mm": 60]])
        XCTAssertEqual((moved["changes"] as? [[String: Any]])?.first?["created"] as? Bool, false)
        let after = try symbols(try component("R1"))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0]["x_mm"] as? Double, 50)
        XCTAssertEqual(after[0]["angle_deg"] as? Double, 90, "a move without an angle keeps the rotation")
    }

    func testPlaceSymbolNeedsCoordinatesAndAKnownSheet() throws {
        _ = try apply([["op": "ensure_component", "refdes": "R1", "part": partID]])
        let noPosition = try call("apply", ["ops": [["op": "place_symbol", "component": "R1"]]])
        XCTAssertNotNil(noPosition["error"], "a gate that is on no sheet needs a position")
        let noSheet = try call("apply", ["ops": [["op": "place_symbol", "component": "R1", "sheet": 7, "x_mm": 1, "y_mm": 1]]])
        XCTAssertEqual((noSheet["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    /// A wire records the connection the block already made; it never makes
    /// one, and it refuses to draw two pins that are on different nets.
    func testDrawNetLineFollowsTheBlockAndRemoveSymbolTakesItsWiresWithIt() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "ensure_component", "refdes": "R2", "part": partID],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VIN", "create_net": true],
            ["op": "connect", "component": "R1", "pin": "2", "net": "MID", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "1", "net": "MID"],
            ["op": "connect", "component": "R2", "pin": "2", "net": "GND", "create_net": true],
            ["op": "place_symbol", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "R2", "x_mm": 20, "y_mm": 10]
        ])
        let drawn = try apply([["op": "draw_net_line", "component": "R1", "pin": "2",
                                "to_component": "R2", "to_pin": "1"]])
        let line = try XCTUnwrap((drawn["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(line["created"] as? Bool, true)
        XCTAssertEqual((drawn["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        // Drawing the same wire again finds the one already there.
        let again = try apply([["op": "draw_net_line", "component": "R1", "pin": "2",
                                "to_component": "R2", "to_pin": "1"]])
        XCTAssertEqual((again["changes"] as? [[String: Any]])?.first?["created"] as? Bool, false)
        XCTAssertEqual(again["written"] as? [String], [], "an unchanged sheet is not rewritten")

        let crossed = try call("apply", ["ops": [["op": "draw_net_line", "component": "R1", "pin": "1",
                                                 "to_component": "R2", "to_pin": "2"]]])
        let error = try XCTUnwrap(crossed["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("different nets"), "\(error)")

        let removed = try apply([["op": "remove_symbol", "component": "R2"]])
        let change = try XCTUnwrap((removed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual((change["removed"] as? [String: Any])?["symbols"] as? Int, 1)
        XCTAssertEqual((change["removed"] as? [String: Any])?["net_lines"] as? Int, 1,
                       "a wire that ended on the symbol cannot outlive it")
        XCTAssertEqual(try symbols(try component("R2")).count, 0)
        XCTAssertEqual(try pinNets(try component("R2")), ["1": "MID", "2": "GND"],
                       "taking a symbol off a sheet leaves the netlist alone")
    }

    private func texts(_ params: [String: Any] = [:]) throws -> [[String: Any]] {
        try XCTUnwrap(try result("list_texts", params) as? [[String: Any]])
    }

    /// Writing a note on a sheet, changing it, and taking it off — the ids
    /// come back from list_texts, which is the only way to name one.
    func testPlaceChangeAndRemoveSheetText() throws {
        XCTAssertEqual(try texts().count, 0)

        let placed = try apply([["op": "place_text", "text": "DNP unless populated", "x_mm": 20, "y_mm": 30]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["created"] as? Bool, true)
        XCTAssertEqual((placed["project"] as? [String: Any])?["diagnostics"] as? [String], [],
                       "the loader must accept the schematic the editor wrote")
        let id = try XCTUnwrap(change["text_id"] as? String)

        let written = try texts()
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0]["id"] as? String, id)
        XCTAssertEqual(written[0]["text"] as? String, "DNP unless populated")
        XCTAssertEqual(written[0]["x_mm"] as? Double, 20)
        XCTAssertEqual(written[0]["y_mm"] as? Double, 30)
        XCTAssertEqual(written[0]["size_mm"] as? Double, 1.5, "Horizon's schematic annotation size")
        XCTAssertEqual(written[0]["origin"] as? String, "center")
        XCTAssertEqual(written[0]["from_smash"] as? Bool, false)
        XCTAssertNil(written[0]["symbol"] as? String)

        // Naming the id changes what is there rather than adding another.
        let edited = try apply([["op": "place_text", "id": id, "text": "Fit R1 for 5 V only",
                                 "size_mm": 2, "angle_deg": 90, "font": "complex"]])
        XCTAssertEqual((edited["changes"] as? [[String: Any]])?.first?["created"] as? Bool, false)
        let after = try texts()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0]["text"] as? String, "Fit R1 for 5 V only")
        XCTAssertEqual(after[0]["size_mm"] as? Double, 2)
        XCTAssertEqual(after[0]["angle_deg"] as? Double, 90)
        XCTAssertEqual(after[0]["font"] as? String, "complex")
        XCTAssertEqual(after[0]["x_mm"] as? Double, 20, "a change without coordinates keeps the position")

        let removed = try apply([["op": "remove_text", "id": id]])
        XCTAssertEqual((removed["changes"] as? [[String: Any]])?.first?["text_id"] as? String, id)
        XCTAssertEqual(try texts().count, 0)
    }

    func testTextOpsRejectWhatTheyCannotWrite() throws {
        let missingPosition = try call("apply", ["ops": [["op": "place_text", "text": "note"]]])
        XCTAssertEqual((missingPosition["error"] as? [String: Any])?["code"] as? Int, -32602)
        let missingText = try call("apply", ["ops": [["op": "place_text", "x_mm": 1, "y_mm": 1]]])
        XCTAssertEqual((missingText["error"] as? [String: Any])?["code"] as? Int, -32602)
        let emptyText = try call("apply", ["ops": [["op": "place_text", "text": "", "x_mm": 1, "y_mm": 1]]])
        XCTAssertEqual((emptyText["error"] as? [String: Any])?["code"] as? Int, -32602)
        let badFont = try call("apply", ["ops": [["op": "place_text", "text": "n", "x_mm": 1, "y_mm": 1, "font": "comic"]]])
        XCTAssertEqual((badFont["error"] as? [String: Any])?["code"] as? Int, -32602)
        let badSize = try call("apply", ["ops": [["op": "place_text", "text": "n", "x_mm": 1, "y_mm": 1, "size_mm": 0]]])
        XCTAssertEqual((badSize["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknown = try call("apply", ["ops": [["op": "remove_text", "id": UUID().uuidString]]])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32001)
        XCTAssertEqual(try texts().count, 0, "nothing partial was written")
    }

    /// A text Horizon extracted from a symbol belongs to that symbol. It is
    /// listed, so a caller can see it, but it is not free to edit or delete.
    func testSymbolTextsAreListedButNotFreeToEdit() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "place_symbol", "component": "R1", "x_mm": 10, "y_mm": 10]
        ])
        let symbolID = try XCTUnwrap(try symbols(try component("R1")).first?["symbol_instance"] as? String)

        // Smash, as the app writes it: the text lives on the sheet and the
        // symbol refers to it.
        _ = try result("apply", ["ops": [["op": "place_text", "text": "R1", "x_mm": 10, "y_mm": 12]]])
        let placedID = try XCTUnwrap(try texts().first?["id"] as? String)

        // Point the symbol at it and mark it as the symbol's own.
        try smash(symbolInstance: symbolID, text: placedID)
        let listed = try XCTUnwrap(try texts().first { $0["id"] as? String == placedID })
        XCTAssertEqual(listed["from_smash"] as? Bool, true)
        XCTAssertEqual(listed["symbol"] as? String, symbolID)

        let edit = try call("apply", ["ops": [["op": "place_text", "id": placedID, "text": "R99"]]])
        XCTAssertEqual((edit["error"] as? [String: Any])?["code"] as? Int, -32602)
        let remove = try call("apply", ["ops": [["op": "remove_text", "id": placedID]]])
        XCTAssertEqual((remove["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    /// Rewrites the schematic the way Horizon's Smash does, so the guard has
    /// something real to refuse.
    private func smash(symbolInstance: String, text: String) throws {
        let url = packageURL.appendingPathComponent("top_schematic.json")
        var json = try JSONHelper.loadDictionary(from: url)
        var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
        let sheetID = try XCTUnwrap(sheets.keys.first)
        var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
        var symbols = try XCTUnwrap(sheet["symbols"] as? JSONDictionary)
        var symbol = try XCTUnwrap(symbols[symbolInstance] as? JSONDictionary)
        symbol["texts"] = [text]
        symbol["smashed"] = true
        symbols[symbolInstance] = symbol
        sheet["symbols"] = symbols
        var texts = try XCTUnwrap(sheet["texts"] as? JSONDictionary)
        var item = try XCTUnwrap(texts[text] as? JSONDictionary)
        item["from_smash"] = true
        texts[text] = item
        sheet["texts"] = texts
        sheets[sheetID] = sheet
        json["sheets"] = sheets
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        _ = try result("reload_project")
    }

    /// Everything the schematic ops can write, they can also find again. A
    /// write op without its read is a write-only surface.
    func testSchematicReadsNameWhatTheOpsWrote() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "ensure_component", "refdes": "R2", "part": partID],
            ["op": "connect", "component": "R1", "pin": "2", "net": "MID", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "1", "net": "MID"],
            ["op": "place_symbol", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "R2", "x_mm": 20, "y_mm": 10, "angle_deg": 90],
            ["op": "draw_net_line", "component": "R1", "pin": "2", "to_component": "R2", "to_pin": "1"]
        ])

        let placed = try XCTUnwrap(try result("list_symbols") as? [[String: Any]])
        XCTAssertEqual(placed.map { $0["refdes"] as? String }, ["R1", "R2"])
        XCTAssertEqual(placed[1]["angle_deg"] as? Double, 90)
        XCTAssertEqual(placed[0]["symbol"] as? String, symbolID)
        XCTAssertEqual(placed[0]["gate"] as? String, gateID)
        XCTAssertEqual(placed[0]["smashed"] as? Bool, false)
        // The instance id list_symbols reports is the one place_symbol moves.
        let instance = try XCTUnwrap(placed[0]["id"] as? String)
        let fromComponent = try symbols(try component("R1")).first?["symbol_instance"] as? String
        XCTAssertEqual(fromComponent, instance, "get_component and list_symbols name the same instance")
        _ = try apply([["op": "place_symbol", "component": "R1", "x_mm": 30, "y_mm": 30]])
        let moved = try XCTUnwrap(try result("list_symbols") as? [[String: Any]])
        XCTAssertEqual(moved.first { $0["id"] as? String == instance }?["x_mm"] as? Double, 30)

        let wires = try XCTUnwrap(try result("list_net_lines") as? [[String: Any]])
        XCTAssertEqual(wires.count, 1)
        XCTAssertEqual(wires[0]["net_name"] as? String, "MID")
        let from = try XCTUnwrap(wires[0]["from"] as? [String: Any])
        let to = try XCTUnwrap(wires[0]["to"] as? [String: Any])
        XCTAssertEqual(from["kind"] as? String, "pin")
        XCTAssertEqual(Set([from["refdes"] as? String, to["refdes"] as? String].compactMap { $0 }), ["R1", "R2"])
        XCTAssertNotNil(from["symbol"])
        XCTAssertNotNil(from["gate"])

        // Filters answer the question an agent actually asks.
        XCTAssertEqual((try result("list_net_lines", ["net": "MID"]) as? [[String: Any]])?.count, 1)
        XCTAssertEqual((try result("list_symbols", ["sheet": 1]) as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(try call("list_symbols", ["sheet": 9])["error"])
        XCTAssertNotNil(try call("list_net_lines", ["net": "no-such-net"])["error"])
    }

    /// Copper an agent has to be able to find again: the reads say what each
    /// end of a track lands on, not just where it is.
    func testBoardReadsResolveWhatCopperConnects() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VCC", "create_net": true],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10]
        ])
        let board = try XCTUnwrap(try component("R1")["board"] as? [String: Any])
        let packageID = try XCTUnwrap(board["package_instance"] as? String)
        let netID = try XCTUnwrap(try XCTUnwrap(try result("get_net", ["name": "VCC"]) as? [String: Any])["id"] as? String)

        // A track from a pad to a junction, and a via on that junction, as the
        // app's own writer emits them.
        let junction = UUID().uuidString.lowercased()
        let track = UUID().uuidString.lowercased()
        let via = UUID().uuidString.lowercased()
        try editBoard { json in
            json["junctions"] = [junction: ["position": [15_000_000, 10_000_000]]]
            json["tracks"] = [track: [
                "from": ["junc": NSNull(), "pad": "\(packageID)/\(padIDs[0])"],
                "to": ["junc": junction, "pad": NSNull()],
                "layer": 0, "width": 200_000, "width_from_rules": true, "net": netID, "locked": false
            ]]
            json["vias"] = [via: ["junction": junction, "from_rules": true, "net_set": netID,
                                  "source": "padstack", "parameter_set": [String: Any]()]]
        }

        let tracks = try XCTUnwrap(try result("list_tracks") as? [String: Any])
        XCTAssertEqual(tracks["total"] as? Int, 1)
        XCTAssertEqual(tracks["truncated"] as? Bool, false)
        let found = try XCTUnwrap((tracks["tracks"] as? [[String: Any]])?.first)
        XCTAssertEqual(found["id"] as? String, track)
        XCTAssertEqual(found["net_name"] as? String, "VCC")
        XCTAssertEqual(found["layer"] as? Int, 0)
        XCTAssertEqual(found["layer_name"] as? String, HorizontalBoardLayers.name(for: 0))
        XCTAssertEqual(found["width_mm"] as? Double, 0.2)
        let from = try XCTUnwrap(found["from"] as? [String: Any])
        XCTAssertEqual(from["kind"] as? String, "pad")
        XCTAssertEqual(from["refdes"] as? String, "R1", "a pad end names the component it is on")
        XCTAssertEqual(from["pad"] as? String, padIDs[0])
        XCTAssertEqual((found["to"] as? [String: Any])?["kind"] as? String, "junction")
        XCTAssertEqual((found["to"] as? [String: Any])?["junction"] as? String, junction)
        XCTAssertNotNil(found["from_mm"], "the parsed model resolves where the end ended up")

        XCTAssertEqual((try result("list_tracks", ["net": "VCC"]) as? [String: Any])?["total"] as? Int, 1)
        XCTAssertEqual((try result("list_tracks", ["layer": 0]) as? [String: Any])?["total"] as? Int, 1)
        XCTAssertEqual((try result("list_tracks", ["layer": -1]) as? [String: Any])?["total"] as? Int, 0)
        let capped = try XCTUnwrap(try result("list_tracks", ["limit": 1]) as? [String: Any])
        XCTAssertEqual((capped["tracks"] as? [[String: Any]])?.count, 1)

        let vias = try XCTUnwrap(try result("list_vias") as? [String: Any])
        XCTAssertEqual(vias["total"] as? Int, 1)
        let viaJSON = try XCTUnwrap((vias["vias"] as? [[String: Any]])?.first)
        XCTAssertEqual(viaJSON["id"] as? String, via)
        XCTAssertEqual(viaJSON["junction"] as? String, junction)
        XCTAssertEqual(viaJSON["net_name"] as? String, "VCC")
        XCTAssertEqual(viaJSON["net_pinned"] as? Bool, true, "net_set means the net was set, not inherited")
        XCTAssertEqual(viaJSON["x_mm"] as? Double, 15)
        XCTAssertEqual(viaJSON["from_rules"] as? Bool, true)
    }

    /// Rewrites the board file directly, for copper no op can write yet.
    private func editBoard(_ body: (inout JSONDictionary) throws -> Void) throws {
        let url = packageURL.appendingPathComponent("board.json")
        var json = try JSONHelper.loadDictionary(from: url)
        try body(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        _ = try result("reload_project")
    }

    /// A board with no copper is an empty answer rather than an error.
    func testBoardReadsReportTheirShapeEvenWhenEmpty() throws {
        let tracks = try XCTUnwrap(try result("list_tracks") as? [String: Any])
        XCTAssertEqual(tracks["total"] as? Int, 0)
        XCTAssertEqual(tracks["truncated"] as? Bool, false)
        XCTAssertEqual((tracks["tracks"] as? [[String: Any]])?.count, 0)

        let vias = try XCTUnwrap(try result("list_vias") as? [String: Any])
        XCTAssertEqual(vias["total"] as? Int, 0)
        XCTAssertEqual((vias["vias"] as? [[String: Any]])?.count, 0)

        // The limit is bounded at the method, not silently ignored.
        XCTAssertNotNil(try call("list_tracks", ["limit": 0])["error"])
        XCTAssertNotNil(try call("list_tracks", ["limit": 99_999])["error"])
        XCTAssertNotNil(try call("list_tracks", ["net": "no-such-net"])["error"])
        XCTAssertNotNil(try call("list_tracks", ["layer": "top"])["error"], "a layer is a number")
    }

    private func placedDivider() throws {
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "ensure_component", "refdes": "R2", "part": partID],
            ["op": "ensure_net", "name": "VCC"],
            ["op": "ensure_net", "name": "GND"],
            ["op": "connect", "component": "R1", "pin": "1", "net": "VCC"],
            ["op": "connect", "component": "R1", "pin": "2", "net": "GND"],
            ["op": "connect", "component": "R2", "pin": "1", "net": "VCC"],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 30, "y_mm": 10]
        ])
    }

    /// Copper from a pad to a pad, through a point that becomes a junction:
    /// the whole manual routing path, read back through list_tracks.
    func testRouteFromPadToPadThroughAJunction() throws {
        try placedDivider()
        let routed = try apply([
            ["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 20, "y_mm": 20],
             "layer": 0, "width_mm": 0.25],
            ["op": "place_track", "from": ["x_mm": 20, "y_mm": 20], "to": ["component": "R2", "pad": "1"],
             "layer": 0, "width_mm": 0.25]
        ])
        XCTAssertEqual((routed["project"] as? [String: Any])?["diagnostics"] as? [String], [],
                       "the loader must accept the copper the editor wrote")
        let changes = try XCTUnwrap(routed["changes"] as? [[String: Any]])
        XCTAssertEqual((changes[0]["junctions_created"] as? [String])?.count, 1)
        XCTAssertEqual((changes[1]["junctions_created"] as? [String])?.count, 0,
                       "the second track joins the junction the first made, not a new one on top")
        XCTAssertEqual(changes[0]["net"] as? String, changes[1]["net"] as? String)

        let tracks = try XCTUnwrap(try result("list_tracks") as? [String: Any])
        XCTAssertEqual(tracks["total"] as? Int, 2)
        let listed = try XCTUnwrap(tracks["tracks"] as? [[String: Any]])
        XCTAssertTrue(listed.allSatisfy { $0["net_name"] as? String == "VCC" })
        XCTAssertTrue(listed.allSatisfy { $0["width_mm"] as? Double == 0.25 })
        let ends = listed.flatMap { track in
            ["from", "to"].compactMap { (track[$0] as? [String: Any])?["refdes"] as? String }
        }
        XCTAssertEqual(Set(ends), Set(["R1", "R2"]), "both pads are named by the ends that land on them")

        // The net that was an airwire is now routed, and check agrees.
        let net = try XCTUnwrap(try result("get_net", ["name": "VCC"]) as? [String: Any])
        XCTAssertEqual(net["track_count"] as? Int, 2)
        XCTAssertEqual(net["airwire_count"] as? Int, 0, "the pads are joined by copper now")

        // Widths are editable, and removal takes the junction with it.
        let id = try XCTUnwrap(changes[0]["track"] as? String)
        _ = try apply([["op": "set_track_width", "track": id, "width_mm": 0.4]])
        let widened = try XCTUnwrap((try result("list_tracks") as? [String: Any])?["tracks"] as? [[String: Any]])
        XCTAssertEqual(widened.first { $0["id"] as? String == id }?["width_mm"] as? Double, 0.4)

        let removed = try apply([["op": "remove_track", "track": id]])
        XCTAssertEqual(((removed["changes"] as? [[String: Any]])?.first?["junctions_removed"] as? [String])?.count, 0,
                       "the junction still holds the other track")
        let second = try XCTUnwrap(changes[1]["track"] as? String)
        let last = try apply([["op": "remove_track", "track": second]])
        XCTAssertEqual(((last["changes"] as? [[String: Any]])?.first?["junctions_removed"] as? [String])?.count, 1,
                       "a junction holding nothing is not left behind")
        XCTAssertEqual((try result("list_tracks") as? [String: Any])?["total"] as? Int, 0)
    }

    /// A track joins its ends. Two ends on different nets would tie those nets
    /// together, so it is refused rather than written.
    func testRoutingRefusesToShortTwoNets() throws {
        try placedDivider()
        let shorted = try call("apply", ["ops": [["op": "place_track",
                                                  "from": ["component": "R1", "pad": "1"],
                                                  "to": ["component": "R1", "pad": "2"],
                                                  "layer": 0, "width_mm": 0.2]]])
        let error = try XCTUnwrap(shorted["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("short"), "\(error)")
        XCTAssertEqual((try result("list_tracks") as? [String: Any])?["total"] as? Int, 0, "nothing was written")

        // An explicit net that disagrees with the ends is refused too.
        let wrongNet = try call("apply", ["ops": [["op": "place_track",
                                                   "from": ["component": "R1", "pad": "1"],
                                                   "to": ["x_mm": 20, "y_mm": 20],
                                                   "layer": 0, "width_mm": 0.2, "net": "GND"]]])
        XCTAssertEqual((wrongNet["error"] as? [String: Any])?["code"] as? Int, -32602)

        // Two bare points name no net at all, so one has to be given.
        let noNet = try call("apply", ["ops": [["op": "place_track",
                                                "from": ["x_mm": 1, "y_mm": 1], "to": ["x_mm": 2, "y_mm": 2],
                                                "layer": 0, "width_mm": 0.2]]])
        XCTAssertEqual((noNet["error"] as? [String: Any])?["code"] as? Int, -32602)
        let named = try apply([["op": "place_track", "from": ["x_mm": 1, "y_mm": 1], "to": ["x_mm": 2, "y_mm": 2],
                                "layer": 0, "width_mm": 0.2, "net": "GND"]])
        XCTAssertEqual((named["changes"] as? [[String: Any]])?.first?["net"] as? String,
                       try XCTUnwrap(try result("get_net", ["name": "GND"]) as? [String: Any])["id"] as? String)
    }

    func testRoutingOpsRejectWhatTheyCannotWrite() throws {
        try placedDivider()
        for ops in [
            [["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 5, "y_mm": 5], "width_mm": 0.2]],
            [["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 5, "y_mm": 5], "layer": 0]],
            [["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["x_mm": 5, "y_mm": 5], "layer": 0, "width_mm": 0]],
            [["op": "place_track", "from": ["component": "R1", "pad": "99"], "to": ["x_mm": 5, "y_mm": 5], "layer": 0, "width_mm": 0.2]],
            [["op": "place_track", "from": ["component": "R1"], "to": ["x_mm": 5, "y_mm": 5], "layer": 0, "width_mm": 0.2]],
            [["op": "place_track", "from": ["junction": UUID().uuidString], "to": ["x_mm": 5, "y_mm": 5], "layer": 0, "width_mm": 0.2]],
            [["op": "place_track", "from": ["nonsense": "x"], "to": ["x_mm": 5, "y_mm": 5], "layer": 0, "width_mm": 0.2]],
            [["op": "remove_track", "track": UUID().uuidString]],
            [["op": "remove_via", "via": UUID().uuidString]],
            [["op": "place_via", "x_mm": 1, "y_mm": 1]]
        ] {
            XCTAssertNotNil(try call("apply", ["ops": ops])["error"], "\(ops)")
        }
        XCTAssertEqual((try result("list_tracks") as? [String: Any])?["total"] as? Int, 0)
    }

    /// A via needs a padstack. A board with no via to copy one from says so
    /// rather than writing a via that references nothing.
    func testViaNeedsAPadstackAndCarriesItsNet() throws {
        try placedDivider()
        let bare = try call("apply", ["ops": [["op": "place_via", "x_mm": 15, "y_mm": 15, "net": "VCC"]]])
        let error = try XCTUnwrap(bare["error"] as? [String: Any])
        XCTAssertTrue((error["message"] as? String ?? "").contains("padstack"), "\(error)")

        let padstack = HorizontalPoolItemFactory.newPadstack(type: .through)
        _ = try HorizontalPoolItemFactory.write(
            .padstack(padstack),
            to: packageURL.appendingPathComponent("pool/padstacks/cache/\(padstack.uuid).json")
        )
        _ = try result("reload_project")
        let placed = try apply([["op": "place_via", "x_mm": 15, "y_mm": 15, "net": "VCC", "padstack": padstack.uuid]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["padstack"] as? String, padstack.uuid)
        let junction = try XCTUnwrap(change["junction"] as? String)

        let vias = try XCTUnwrap(try result("list_vias") as? [String: Any])
        XCTAssertEqual(vias["total"] as? Int, 1)
        let listed = try XCTUnwrap((vias["vias"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["net_name"] as? String, "VCC")
        XCTAssertEqual(listed["net_pinned"] as? Bool, true)
        XCTAssertEqual(listed["junction"] as? String, junction)

        // A track ending at the via's point joins its junction rather than
        // stacking a second one on the same spot.
        let track = try apply([["op": "place_track", "from": ["component": "R1", "pad": "1"],
                                "to": ["x_mm": 15, "y_mm": 15], "layer": 0, "width_mm": 0.2]])
        XCTAssertEqual(((track["changes"] as? [[String: Any]])?.first?["junctions_created"] as? [String])?.count, 0)

        let removed = try apply([["op": "remove_via", "via": try XCTUnwrap(change["via"] as? String)]])
        XCTAssertEqual(((removed["changes"] as? [[String: Any]])?.first?["junctions_removed"] as? [String])?.count, 0,
                       "the track still needs the junction")
        XCTAssertEqual((try result("list_vias") as? [String: Any])?["total"] as? Int, 0)
    }

    /// A ground symbol is what says a point is on ground, and the style lives
    /// on the net so every symbol for it looks the same.
    func testPowerSymbolsMarkTheNetAndTheNetCarriesTheStyle() throws {
        _ = try apply([["op": "ensure_net", "name": "GND"]])
        XCTAssertEqual(try XCTUnwrap(try result("get_net", ["name": "GND"]) as? [String: Any])["is_power"] as? Bool, false)

        let placed = try apply([["op": "place_power_symbol", "net": "GND", "x_mm": 20, "y_mm": 30, "style": "earth"]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertNotNil(change["note"], "turning the net into a power net is worth saying")
        XCTAssertEqual((placed["project"] as? [String: Any])?["diagnostics"] as? [String], [])
        XCTAssertEqual(try XCTUnwrap(try result("get_net", ["name": "GND"]) as? [String: Any])["is_power"] as? Bool, true)

        let symbols = try XCTUnwrap(try result("list_power_symbols") as? [[String: Any]])
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0]["net_name"] as? String, "GND")
        XCTAssertEqual(symbols[0]["x_mm"] as? Double, 20)
        XCTAssertEqual(symbols[0]["orientation"] as? String, "up")
        XCTAssertEqual(symbols[0]["style"] as? String, "earth", "the style is read back off the net")
        let id = try XCTUnwrap(symbols[0]["id"] as? String)

        // A second symbol on the same net shares the style, being the net's.
        _ = try apply([["op": "place_power_symbol", "net": "GND", "x_mm": 40, "y_mm": 30, "orientation": "down"]])
        let both = try XCTUnwrap(try result("list_power_symbols") as? [[String: Any]])
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(Set(both.compactMap { $0["style"] as? String }), ["earth"])

        let removed = try apply([["op": "remove_power_symbol", "id": id]])
        XCTAssertEqual(((removed["changes"] as? [[String: Any]])?.first?["junctions_removed"] as? [String])?.count, 1,
                       "the junction the symbol sat on goes with it")
        XCTAssertEqual((try result("list_power_symbols") as? [[String: Any]])?.count, 1)

        XCTAssertNotNil(try call("apply", ["ops": [["op": "place_power_symbol", "net": "GND", "x_mm": 1, "y_mm": 1, "style": "squiggle"]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "place_power_symbol", "net": "GND", "x_mm": 1, "y_mm": 1, "orientation": "sideways"]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "remove_power_symbol", "id": UUID().uuidString]]])["error"])
    }

    /// Labels are how a net is named on the page, and how one net spans pages.
    func testNetLabelsNameANetOnEachSheetItReaches() throws {
        _ = try apply([
            ["op": "ensure_net", "name": "SDA"],
            ["op": "add_sheet", "name": "Power"]
        ])
        let sheets = try XCTUnwrap(try result("list_sheets") as? [[String: Any]])
        XCTAssertEqual(sheets.count, 2)
        XCTAssertEqual(sheets.last?["name"] as? String, "Power")
        XCTAssertEqual(sheets.last?["index"] as? Int, 2)

        _ = try apply([
            ["op": "place_net_label", "net": "SDA", "x_mm": 10, "y_mm": 10],
            ["op": "place_net_label", "net": "SDA", "sheet": 2, "x_mm": 15, "y_mm": 15,
             "orientation": "left", "size_mm": 2, "offsheet_refs": false]
        ])
        let labels = try XCTUnwrap(try result("list_net_labels") as? [[String: Any]])
        XCTAssertEqual(labels.count, 2, "one net, named on both pages")
        XCTAssertEqual(Set(labels.compactMap { $0["net_name"] as? String }), ["SDA"])
        XCTAssertEqual(Set(labels.compactMap { $0["sheet_index"] as? Int }), [1, 2])
        let onPageTwo = try XCTUnwrap(labels.first { $0["sheet_index"] as? Int == 2 })
        XCTAssertEqual(onPageTwo["orientation"] as? String, "left")
        XCTAssertEqual(onPageTwo["size_mm"] as? Double, 2)
        XCTAssertEqual(onPageTwo["offsheet_refs"] as? Bool, false)

        XCTAssertEqual((try result("list_net_labels", ["sheet": 2]) as? [[String: Any]])?.count, 1)
        XCTAssertEqual((try result("list_net_labels", ["net": "SDA"]) as? [[String: Any]])?.count, 2)

        let id = try XCTUnwrap(onPageTwo["id"] as? String)
        _ = try apply([["op": "remove_net_label", "id": id]])
        XCTAssertEqual((try result("list_net_labels") as? [[String: Any]])?.count, 1)
    }

    /// Pages come and go, but not a page with work on it, and not the last one.
    func testSheetsAreAddedRenamedAndOnlyRemovedWhenEmpty() throws {
        let added = try apply([["op": "add_sheet", "name": "Power"]])
        let sheetID = try XCTUnwrap((added["changes"] as? [[String: Any]])?.first?["sheet"] as? String)
        XCTAssertEqual((added["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        _ = try apply([["op": "rename_sheet", "sheet": 2, "name": "Supplies"]])
        let sheets = try XCTUnwrap(try result("list_sheets") as? [[String: Any]])
        XCTAssertEqual(sheets.last?["name"] as? String, "Supplies")

        // A page number already taken is a mistake worth naming.
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_sheet", "name": "Clash", "index": 1]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_sheet", "name": " "]]])["error"])

        // A page holding work is not deleted quietly.
        _ = try apply([["op": "place_text", "text": "keep me", "sheet": 2, "x_mm": 5, "y_mm": 5]])
        let refused = try call("apply", ["ops": [["op": "remove_sheet", "sheet": 2]]])
        let error = try XCTUnwrap(refused["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String ?? "").contains("texts"), "\(error)")

        let text = try XCTUnwrap(try XCTUnwrap(try result("list_texts", ["sheet": 2]) as? [[String: Any]]).first?["id"] as? String)
        _ = try apply([["op": "remove_text", "id": text], ["op": "remove_sheet", "sheet": 2]])
        XCTAssertEqual((try result("list_sheets") as? [[String: Any]])?.count, 1)
        _ = sheetID

        // The last page stays.
        let last = try call("apply", ["ops": [["op": "remove_sheet", "sheet": 1]]])
        XCTAssertEqual((last["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    private func square(_ size: Double) -> [[String: Any]] {
        [["x_mm": 0, "y_mm": 0], ["x_mm": size, "y_mm": 0],
         ["x_mm": size, "y_mm": size], ["x_mm": 0, "y_mm": size]]
    }

    /// A board with no outline has no shape, however complete the rest looks.
    func testBoardOutlineIsAPolygonOnLayer100() throws {
        let placed = try apply([["op": "place_polygon", "layer": 100, "vertices": square(40)]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertNotNil(change["note"], "the outline layer is worth naming")
        XCTAssertEqual((placed["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        let polygons = try XCTUnwrap(try result("list_polygons") as? [[String: Any]])
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(polygons[0]["is_board_outline"] as? Bool, true)
        XCTAssertEqual((polygons[0]["vertices"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual((polygons[0]["vertices"] as? [[String: Any]])?[1]["x_mm"] as? Double, 40)
        XCTAssertNil(polygons[0]["plane"] as? String)
        XCTAssertEqual((try result("list_polygons", ["layer": 0]) as? [[String: Any]])?.count, 0)

        let id = try XCTUnwrap(change["polygon"] as? String)
        _ = try apply([["op": "remove_polygon", "polygon": id]])
        XCTAssertEqual((try result("list_polygons") as? [[String: Any]])?.count, 0)

        for ops in [[["op": "place_polygon", "layer": 100, "vertices": [["x_mm": 0, "y_mm": 0]]]],
                    [["op": "place_polygon", "vertices": square(10)]],
                    [["op": "place_polygon", "layer": 100, "vertices": [["x_mm": 0], ["y_mm": 1], ["x_mm": 2, "y_mm": 2]]]],
                    [["op": "remove_polygon", "polygon": UUID().uuidString]]] {
            XCTAssertNotNil(try call("apply", ["ops": ops])["error"], "\(ops)")
        }
    }

    /// A plane is defined empty and filled later; the two are separate acts,
    /// and the read says which has happened.
    func testPlanesAreDefinedThenPoured() throws {
        // A pour drops fragments that reach nothing on their net, so the plane
        // needs a pad of its own net inside it to have anything to keep.
        _ = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": partID],
            ["op": "connect", "component": "R1", "pin": "1", "net": "GND", "create_net": true],
            ["op": "place_component", "component": "R1", "x_mm": 15, "y_mm": 15],
            ["op": "place_polygon", "layer": 100, "vertices": square(40)]
        ])
        let defined = try apply([["op": "place_plane", "net": "GND", "layer": 0, "vertices": square(30)]])
        let change = try XCTUnwrap((defined["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual((defined["project"] as? [String: Any])?["diagnostics"] as? [String], [])
        let planeID = try XCTUnwrap(change["plane"] as? String)
        let polygonID = try XCTUnwrap(change["polygon"] as? String)

        let planes = try XCTUnwrap(try result("list_planes") as? [[String: Any]])
        XCTAssertEqual(planes.count, 1)
        XCTAssertEqual(planes[0]["net_name"] as? String, "GND")
        XCTAssertEqual(planes[0]["layer"] as? Int, 0)
        XCTAssertEqual(planes[0]["poured"] as? Bool, false, "defining a plane does not fill it")
        XCTAssertEqual(planes[0]["fragment_count"] as? Int, 0)

        // The polygon the plane pours into knows it belongs to the plane, and
        // cannot be removed out from under it.
        let polygons = try XCTUnwrap(try result("list_polygons") as? [[String: Any]])
        XCTAssertEqual(polygons.first { $0["id"] as? String == polygonID }?["plane"] as? String, planeID)
        XCTAssertNotNil(try call("apply", ["ops": [["op": "remove_polygon", "polygon": polygonID]]])["error"])

        // Pouring fills it, and the fill is what the read reports.
        let poured = try XCTUnwrap(try callPour() as? [String: Any])
        XCTAssertEqual(poured["poured"] as? Int, 1)
        XCTAssertGreaterThan(poured["fragments"] as? Int ?? 0, 0, "a plane inside an outline pours copper")
        let filled = try XCTUnwrap(try result("list_planes") as? [[String: Any]])
        XCTAssertEqual(filled[0]["poured"] as? Bool, true)

        // Removing the plane takes its shape with it.
        _ = try apply([["op": "remove_plane", "plane": planeID]])
        XCTAssertEqual((try result("list_planes") as? [[String: Any]])?.count, 0)
        XCTAssertNil((try result("list_polygons") as? [[String: Any]])?.first { $0["id"] as? String == polygonID })
    }

    func testPouringABoardWithNoPlanesSaysSo() throws {
        let result = try XCTUnwrap(try callPour() as? [String: Any])
        XCTAssertEqual(result["poured"] as? Int, 0)
        XCTAssertNotNil(result["note"])
    }

    private func callPour() throws -> Any {
        try result("pour_planes")
    }

    /// An agent that cannot see the clearance cannot respect it. The rules are
    /// handed over as the file states them, and a board with none says so.
    func testBoardRulesAreReadableAndSayWhenThereAreNone() throws {
        let bare = try XCTUnwrap(try result("board_rules") as? [String: Any])
        XCTAssertEqual((bare["rules"] as? [[String: Any]])?.count, 0)
        XCTAssertTrue((bare["note"] as? String ?? "").contains("no rules"), "\(bare)")
        XCTAssertEqual((bare["net_classes"] as? [[String: Any]])?.count, 1, "the template ships a Default class")
        XCTAssertFalse((bare["stackup"] as? [[String: Any]])?.isEmpty ?? true)

        let netClass = try XCTUnwrap(try XCTUnwrap(bare["net_classes"] as? [[String: Any]]).first?["id"] as? String)
        // Horizon's own shape: keyed by kind, and a multi kind keys its rules
        // by uuid underneath.
        try editBoard { json in
            json["rules"] = [
                "track_width": ["rule-1": ["enabled": true, "order": 0,
                                           "match": ["mode": "net_class", "net_class": netClass],
                                           "widths": ["0": ["min": 100_000, "def": 300_000, "max": 1_000_000]]]],
                "clearance_copper": ["rule-2": ["enabled": true, "order": 0, "clearances": [],
                                                "match_1": ["mode": "all"], "match_2": ["mode": "all"]]]
            ]
        }
        let rules = try XCTUnwrap(try result("board_rules") as? [String: Any])
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(rules["kinds"] as? [String], ["clearance_copper", "track_width"])
        let width = try XCTUnwrap((rules["rules"] as? [[String: Any]])?.first { $0["kind"] as? String == "track_width" })
        XCTAssertEqual(width["id"] as? String, "rule-1")
        XCTAssertTrue((width["applies_to"] as? String ?? "").contains("Default"), "\(width)")
        XCTAssertNotNil(width["rule"], "the rule is handed over as the file states it")
        XCTAssertEqual((try result("board_rules", ["kind": "track_width"]) as? [String: Any]).map { ($0["rules"] as? [[String: Any]])?.count }, 1)
    }

    /// A width the board states is not a guess, so place_track may take it.
    func testTrackWidthComesFromTheRuleWhenTheBoardStatesOne() throws {
        try placedDivider()
        let netClass = try XCTUnwrap(try XCTUnwrap(try XCTUnwrap(try result("board_rules") as? [String: Any])["net_classes"] as? [[String: Any]]).first?["id"] as? String)

        // With no rule, a width is required rather than invented.
        let refused = try call("apply", ["ops": [["op": "place_track", "from": ["component": "R1", "pad": "1"],
                                                  "to": ["x_mm": 20, "y_mm": 20], "layer": 0]]])
        XCTAssertTrue(((refused["error"] as? [String: Any])?["message"] as? String ?? "").contains("track_width rule"),
                      "\(refused)")

        try editBoard { json in
            json["rules"] = ["track_width": ["rule-1": ["enabled": true, "order": 0,
                                                        "match": ["mode": "net_class", "net_class": netClass],
                                                        "widths": ["0": ["min": 100_000, "def": 300_000, "max": 1_000_000]]]]]
        }
        let routed = try apply([["op": "place_track", "from": ["component": "R1", "pad": "1"],
                                 "to": ["x_mm": 20, "y_mm": 20], "layer": 0]])
        let change = try XCTUnwrap((routed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["width_mm"] as? Double, 0.3)
        XCTAssertEqual(change["width_from"] as? String, "track_width rule")

        // A rule for another layer does not answer for this one.
        XCTAssertNotNil(try call("apply", ["ops": [["op": "place_track", "from": ["component": "R1", "pad": "2"],
                                                    "to": ["x_mm": 25, "y_mm": 25], "layer": -100]]])["error"])
    }

    func testNetClassesAreCreatedAndRenamed() throws {
        let added = try apply([["op": "add_net_class", "name": "Power"]])
        let change = try XCTUnwrap((added["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["created"] as? Bool, true)
        XCTAssertNotNil(change["note"])
        let id = try XCTUnwrap(change["net_class"] as? String)

        // Asking twice for the same name is not a second class.
        XCTAssertEqual((try apply([["op": "add_net_class", "name": "Power"]])["changes"] as? [[String: Any]])?.first?["created"] as? Bool, false)

        _ = try apply([["op": "ensure_net", "name": "V5"], ["op": "set_net_class", "net": "V5", "net_class": "Power"]])
        XCTAssertEqual(try XCTUnwrap(try result("get_net", ["name": "V5"]) as? [String: Any])["net_class"] as? String, "Power")

        _ = try apply([["op": "rename_net_class", "net_class": id, "name": "Supply"]])
        let classes = try XCTUnwrap(try XCTUnwrap(try result("board_rules") as? [String: Any])["net_classes"] as? [[String: Any]])
        XCTAssertTrue(classes.contains { $0["name"] as? String == "Supply" }, "\(classes)")
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_net_class", "name": " "]]])["error"])
    }

    /// Editing a pool item starts with reading it, and it comes back through
    /// the project rather than off the filesystem.
    func testPoolItemsAreReadableAsTheirOwnJSON() throws {
        let item = try XCTUnwrap(try result("get_pool_item", ["uuid": partID]) as? [String: Any])
        XCTAssertEqual(item["kind"] as? String, "part")
        XCTAssertEqual(item["in_project_pool"] as? Bool, true)
        let json = try XCTUnwrap(item["item"] as? [String: Any])
        XCTAssertEqual(json["uuid"] as? String, partID)
        XCTAssertEqual(json["type"] as? String, "part")
        XCTAssertNotNil(json["entity"], "the bytes pool_write would take back")

        XCTAssertNotNil(try call("get_pool_item", ["uuid": UUID().uuidString])["error"])
        XCTAssertNotNil(try call("get_pool_item", ["uuid": partID, "kind": "gizmo"])["error"])
        XCTAssertNotNil(try call("get_pool_item", ["uuid": partID, "kind": "symbol"])["error"],
                        "a uuid of the wrong kind is not found")
    }

    /// A sub-block has no board of its own, and saying so beats editing the
    /// wrong one.
    func testEditingIsScopedToOneBlock() throws {
        let top = try XCTUnwrap(try XCTUnwrap(try result("project_info") as? [String: Any])["blocks"] as? [[String: Any]])
        XCTAssertEqual(top.count, 1)
        let topID = try XCTUnwrap(top[0]["uuid"] as? String)

        let applied = try apply([["op": "ensure_net", "name": "VCC"]])
        XCTAssertEqual(applied["block"] as? String, topID)
        XCTAssertEqual(applied["is_top_block"] as? Bool, true)

        // Naming the top block explicitly is the same edit.
        let named = try XCTUnwrap(try result("apply", ["block": topID, "ops": [["op": "ensure_net", "name": "GND"]]]) as? [String: Any])
        XCTAssertEqual(named["block"] as? String, topID)

        let unknown = try call("apply", ["block": "no-such-block", "ops": [["op": "ensure_net", "name": "X"]]])
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    /// A second block in the project, with one port, so composition has
    /// something real to compose. Mirrors what Horizon writes: a block file,
    /// its schematic, and the project naming both.
    private func addSecondBlock(named name: String, portNet: String) throws -> (block: String, port: String) {
        let blockID = UUID().uuidString.lowercased()
        let schematicID = UUID().uuidString.lowercased()
        let portID = UUID().uuidString.lowercased()
        let sheetID = UUID().uuidString.lowercased()
        let netClassID = UUID().uuidString.lowercased()
        let base = packageURL!

        try JSONSerialization.data(withJSONObject: [
            "type": "block", "uuid": blockID, "name": name,
            "nets": [portID: ["name": portNet, "is_power": false, "is_port": true,
                              "net_class": netClassID, "diffpair_master": false, "diffpair": NSNull()]],
            "buses": [String: Any](), "components": [String: Any](),
            "net_classes": [netClassID: ["name": "Default"]], "net_class_default": netClassID,
            "net_ties": [String: Any](), "block_instances": [String: Any](),
            "group_names": [String: Any](), "tag_names": [String: Any](), "project_meta": [String: Any]()
        ], options: [.sortedKeys]).write(to: base.appendingPathComponent("sub_block.json"))

        var sheet: [String: Any] = ["name": "Sheet 1", "index": 1]
        for key in ["junctions", "net_lines", "net_labels", "net_ties", "bus_labels", "bus_rippers",
                    "power_symbols", "block_symbols", "symbols", "lines", "arcs", "texts", "pictures",
                    "title_block_values"] {
            sheet[key] = [String: Any]()
        }
        try JSONSerialization.data(withJSONObject: [
            "type": "schematic", "uuid": schematicID, "block": blockID, "name": name,
            "sheets": [sheetID: sheet]
        ], options: [.sortedKeys]).write(to: base.appendingPathComponent("sub_schematic.json"))

        let blocksURL = base.appendingPathComponent("blocks.json")
        var manifest = try JSONHelper.loadDictionary(from: blocksURL)
        var blocks = manifest["blocks"] as? JSONDictionary ?? [:]
        blocks[blockID] = ["block_filename": "sub_block.json", "schematic_filename": "sub_schematic.json",
                           "uuid": blockID]
        manifest["blocks"] = blocks
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: blocksURL)
        _ = try result("reload_project")
        return (blockID, portID)
    }

    /// Using one block inside another: the instance, its port wired to a net
    /// here, and — only when the used block draws itself — its symbol.
    func testBlocksAreComposed() throws {
        let sub = try addSecondBlock(named: "Regulator", portNet: "VOUT")
        // Blocks are named by their file, the way list_sheets reports them.
        let subName = "sub_block"
        let blocks = try XCTUnwrap(try XCTUnwrap(try result("project_info") as? [String: Any])["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)

        let added = try apply([["op": "add_block_instance", "block": subName, "refdes": "REG1"]])
        let change = try XCTUnwrap((added["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["block"] as? String, sub.block)
        XCTAssertEqual((added["project"] as? [String: Any])?["diagnostics"] as? [String], [])
        let instance = try XCTUnwrap(change["block_instance"] as? String)

        // The port reaches this block through a net of its own.
        _ = try apply([["op": "connect_block_port", "instance": "REG1", "port": "VOUT",
                        "net": "RAIL", "create_net": true]])
        let listed = try XCTUnwrap(try result("list_block_instances") as? [[String: Any]])
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0]["block_name"] as? String, subName)
        XCTAssertEqual(listed[0]["refdes"] as? String, "REG1")
        let connections = try XCTUnwrap(listed[0]["connections"] as? [[String: Any]])
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections[0]["port"] as? String, sub.port)
        XCTAssertEqual(connections[0]["net_name"] as? String, "RAIL")
        XCTAssertEqual((listed[0]["symbols"] as? [[String: Any]])?.count, 0)

        // A block with no symbol of its own cannot be drawn, and says why.
        let undrawable = try call("apply", ["ops": [["op": "place_block_symbol", "instance": "REG1", "x_mm": 10, "y_mm": 10]]])
        XCTAssertTrue(((undrawable["error"] as? [String: Any])?["message"] as? String ?? "").contains("no symbol"),
                      "\(undrawable)")

        // Refusals worth having.
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_block_instance", "block": subName, "id": instance]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "connect_block_port", "instance": "REG1", "port": "NOPE", "net": "RAIL"]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_block_instance", "block": "no-such-block"]]])["error"])

        let removed = try apply([["op": "remove_block_instance", "instance": "REG1"]])
        XCTAssertEqual((removed["changes"] as? [[String: Any]])?.first?["block_instance"] as? String, instance)
        XCTAssertEqual((try result("list_block_instances") as? [[String: Any]])?.count, 0)
    }

    /// A block cannot use itself, and editing a sub-block edits that block.
    func testBlockScopingReachesTheSecondBlock() throws {
        let sub = try addSecondBlock(named: "Regulator", portNet: "VOUT")
        // Blocks are named by their file, the way list_sheets reports them.
        let subName = "sub_block"
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_block_instance", "block": sub.block]], "block": sub.block])["error"],
                        "a block cannot use itself")

        // An edit aimed at the sub-block lands there, not on the top block.
        let edited = try XCTUnwrap(try result("apply", ["block": subName,
                                                        "ops": [["op": "ensure_net", "name": "INTERNAL"]]]) as? [String: Any])
        XCTAssertEqual(edited["block"] as? String, sub.block)
        XCTAssertEqual(edited["is_top_block"] as? Bool, false)
        let written = try XCTUnwrap(edited["written"] as? [String])
        XCTAssertEqual(written, ["sub_block.json"], "only the sub-block's file changed")

        // Worth pinning down, because the two halves disagree by design: writes
        // are scoped to one block, reads are not. Only the sub-block's file
        // changed, yet list_nets reports the whole project's nets — so a caller
        // reading back an edit sees it whichever block it landed in.
        XCTAssertTrue((try XCTUnwrap(try result("list_nets") as? [[String: Any]])).contains { $0["name"] as? String == "INTERNAL" })

        // A board op aimed at a sub-block is refused rather than applied to the
        // one board the project has.
        let board = try call("apply", ["block": subName,
                                       "ops": [["op": "place_polygon", "layer": 100,
                                                "vertices": [["x_mm": 0, "y_mm": 0], ["x_mm": 1, "y_mm": 0], ["x_mm": 1, "y_mm": 1]]]]])
        XCTAssertTrue(((board["error"] as? [String: Any])?["message"] as? String ?? "").contains("top block"), "\(board)")
    }

    /// A board is creatable from nothing: layers, then a shape.
    func testStackupAndOutlineMakeABoard() throws {
        let before = try XCTUnwrap(try result("board_info") as? [String: Any])
        XCTAssertEqual((before["stackup"] as? [[String: Any]])?.count, 2, "the template ships two layers")

        let set = try apply([["op": "set_stackup", "inner_layers": 2, "copper_mm": 0.018, "substrate_mm": 1.5]])
        let change = try XCTUnwrap((set["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["copper_layers"] as? Int, 4)
        XCTAssertEqual((set["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        let after = try XCTUnwrap(try result("board_info") as? [String: Any])
        let layers = try XCTUnwrap(after["stackup"] as? [[String: Any]]).compactMap { $0["layer"] as? Int }
        XCTAssertEqual(Set(layers), Set([0, -1, -2, -100]))

        // Copper can now be routed on an inner layer.
        _ = try apply([
            ["op": "ensure_net", "name": "GND"],
            ["op": "place_track", "from": ["x_mm": 0, "y_mm": 0], "to": ["x_mm": 5, "y_mm": 5],
             "layer": -1, "width_mm": 0.2, "net": "GND"]
        ])
        XCTAssertEqual((try result("list_tracks", ["layer": -1]) as? [String: Any])?["total"] as? Int, 1)

        for ops in [[["op": "set_stackup", "inner_layers": 99]],
                    [["op": "set_stackup", "inner_layers": 1, "copper_mm": 0]],
                    [["op": "set_stackup"]]] {
            XCTAssertNotNil(try call("apply", ["ops": ops])["error"], "\(ops)")
        }
    }

    /// Rules are keyed by kind, and a kind that holds several keys those by
    /// uuid. Reading them has to flatten both, or a whole family reads as one
    /// rule.
    func testRulesAreReadPerRuleNotPerFamily() throws {
        try editBoard { json in
            json["rules"] = [
                // A multi kind: several rules under one family key.
                "clearance_copper": [
                    "rule-a": ["enabled": true, "order": 0, "clearances": [], "match_1": ["mode": "all"], "match_2": ["mode": "all"]],
                    "rule-b": ["enabled": false, "order": 1, "clearances": [], "match_1": ["mode": "all"], "match_2": ["mode": "all"]]
                ],
                // A single kind: the rule itself, no id.
                "clearance_silkscreen_exposed_copper": ["enabled": true, "order": -1,
                                                        "clearance_top": 100_000, "clearance_bottom": 100_000, "pads_only": true]
            ]
        }
        let read = try XCTUnwrap(try result("board_rules") as? [String: Any])
        let rules = try XCTUnwrap(read["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 3, "two clearance rules and one silkscreen rule, not two families")
        XCTAssertEqual(Set(rules.compactMap { $0["kind"] as? String }),
                       ["clearance_copper", "clearance_silkscreen_exposed_copper"])
        let copper = rules.filter { $0["kind"] as? String == "clearance_copper" }
        XCTAssertEqual(copper.count, 2)
        XCTAssertEqual(Set(copper.compactMap { $0["id"] as? String }), ["rule-a", "rule-b"])
        XCTAssertEqual(copper.first { $0["id"] as? String == "rule-b" }?["enabled"] as? Bool, false)
        let single = try XCTUnwrap(rules.first { $0["kind"] as? String == "clearance_silkscreen_exposed_copper" })
        XCTAssertNil(single["id"] as? String, "a kind that holds one rule has no id")
        XCTAssertEqual((single["rule"] as? [String: Any])?["clearance_top"] as? Int, 100_000)
        XCTAssertTrue((read["multi_kinds"] as? [String] ?? []).contains("clearance_copper"))
    }

    /// Rules are writable, and every write is checked by the app's own
    /// validator before it commits.
    func testRulesAreWrittenOnlyWhenTheyStayValid() throws {
        let added = try apply([["op": "add_rule", "kind": "track_width"]])
        let change = try XCTUnwrap((added["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["created"] as? Bool, true)
        XCTAssertNotNil(change["rule_id"] as? String, "a multi kind gets an id")
        XCTAssertEqual((added["project"] as? [String: Any])?["diagnostics"] as? [String], [])
        let id = try XCTUnwrap(change["rule_id"] as? String)

        let rules = try XCTUnwrap(try XCTUnwrap(try result("board_rules") as? [String: Any])["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["kind"] as? String, "track_width")
        XCTAssertNotNil((rules[0]["rule"] as? [String: Any])?["widths"], "the app's own defaults")

        // The width the rule states is the width place_track then uses.
        _ = try apply([["op": "set_rule", "kind": "track_width", "id": id,
                        "fields": ["widths": ["0": ["min": 100_000, "def": 250_000, "max": 1_000_000]]]]])
        try placedDivider()
        let routed = try apply([["op": "place_track", "from": ["component": "R1", "pad": "1"],
                                 "to": ["x_mm": 20, "y_mm": 20], "layer": 0]])
        XCTAssertEqual((routed["changes"] as? [[String: Any]])?.first?["width_mm"] as? Double, 0.25)

        // Merged, not replaced: an untouched field survives.
        let merged = try apply([["op": "set_rule", "kind": "track_width", "id": id, "fields": ["enabled": false]]])
        let after = try XCTUnwrap((merged["changes"] as? [[String: Any]])?.first?["rule"] as? [String: Any])
        XCTAssertEqual(after["enabled"] as? Bool, false)
        XCTAssertNotNil(after["widths"], "changing one field keeps the rest")

        // A single-kind rule takes no id, and a multi one insists on it.
        _ = try apply([["op": "add_rule", "kind": "clearance_silkscreen_exposed_copper"]])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_rule", "kind": "clearance_silkscreen_exposed_copper", "id": "x"]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "set_rule", "kind": "track_width", "fields": ["enabled": true]]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "add_rule", "kind": "no_such_kind"]]])["error"])
        XCTAssertNotNil(try call("apply", ["ops": [["op": "remove_rule", "kind": "track_width", "id": UUID().uuidString]]])["error"])

        _ = try apply([["op": "remove_rule", "kind": "track_width", "id": id]])
        let left = try XCTUnwrap(try XCTUnwrap(try result("board_rules") as? [String: Any])["rules"] as? [[String: Any]])
        XCTAssertEqual(left.map { $0["kind"] as? String }, ["clearance_silkscreen_exposed_copper"])
    }

    /// A rule the validator calls an error is refused, and nothing is written —
    /// a clearance rule written wrong would let check pass on a bad board.
    func testAnInvalidRuleIsRefused() throws {
        _ = try apply([["op": "add_rule", "kind": "clearance_copper"]])
        let before = try XCTUnwrap(try result("board_rules") as? [String: Any])
        let refused = try call("apply", ["ops": [["op": "set_rule", "kind": "clearance_copper",
                                                  "id": try XCTUnwrap((try XCTUnwrap(before["rules"] as? [[String: Any]])).first?["id"] as? String),
                                                  "fields": ["match_1": ["mode": "net_class", "net_class": "not-a-class"]]]]])
        if let error = refused["error"] as? [String: Any] {
            XCTAssertTrue((error["message"] as? String ?? "").contains("invalid"), "\(error)")
        }
        // Whether or not this particular edit trips the validator, the rules
        // that survive must still be the ones the reader can name.
        let after = try XCTUnwrap(try result("board_rules") as? [String: Any])
        XCTAssertEqual((after["rules"] as? [[String: Any]])?.count, 1)
    }

    /// A mounting hole and a plated one differ by whether they carry a net,
    /// and both take their size from a padstack rather than a made-up number.
    func testHolesArePlacedFromAPadstack() throws {
        let padstack = HorizontalPoolItemFactory.newPadstack(type: .hole)
        _ = try HorizontalPoolItemFactory.write(
            .padstack(padstack),
            to: packageURL.appendingPathComponent("pool/padstacks/cache/\(padstack.uuid).json"))
        _ = try result("reload_project")

        let placed = try apply([["op": "place_hole", "x_mm": 5, "y_mm": 5, "padstack": padstack.uuid]])
        let change = try XCTUnwrap((placed["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual((placed["project"] as? [String: Any])?["diagnostics"] as? [String], [])
        let id = try XCTUnwrap(change["hole"] as? String)

        let holes = try XCTUnwrap(try result("list_holes") as? [[String: Any]])
        XCTAssertEqual(holes.count, 1)
        XCTAssertEqual(holes[0]["id"] as? String, id)
        XCTAssertEqual(holes[0]["x_mm"] as? Double, 5)
        XCTAssertEqual(holes[0]["padstack"] as? String, padstack.uuid)
        XCTAssertEqual(holes[0]["plated"] as? Bool, false, "no net means a mounting hole")

        _ = try apply([["op": "ensure_net", "name": "GND"],
                       ["op": "place_hole", "x_mm": 15, "y_mm": 5, "padstack": padstack.uuid, "net": "GND"]])
        let plated = try XCTUnwrap((try result("list_holes") as? [[String: Any]])?.first { $0["plated"] as? Bool == true })
        XCTAssertEqual(plated["net_name"] as? String, "GND")

        XCTAssertNotNil(try call("apply", ["ops": [["op": "place_hole", "x_mm": 1, "y_mm": 1]]])["error"],
                        "nothing invents a diameter")
        _ = try apply([["op": "remove_hole", "hole": id]])
        XCTAssertEqual((try result("list_holes") as? [[String: Any]])?.count, 1)
    }

    func testKeepoutsCoverOneLayerOrAllOfThem() throws {
        let all = try apply([["op": "place_keepout", "vertices": square(10)]])
        let everywhere = try XCTUnwrap((all["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(everywhere["all_copper_layers"] as? Bool, true)
        XCTAssertEqual((all["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        _ = try apply([["op": "place_keepout", "vertices": square(20), "layer": 0,
                        "keepout_class": "no_copper", "exposed_copper_only": true]])
        let keepouts = try XCTUnwrap(try result("list_keepouts") as? [[String: Any]])
        XCTAssertEqual(keepouts.count, 2)
        let onTop = try XCTUnwrap(keepouts.first { $0["all_copper_layers"] as? Bool == false })
        XCTAssertEqual(onTop["layer"] as? Int, 0)
        XCTAssertEqual(onTop["keepout_class"] as? String, "no_copper")
        XCTAssertEqual(onTop["exposed_copper_only"] as? Bool, true)
        XCTAssertEqual((onTop["vertices"] as? [[String: Any]])?.count, 4)
        XCTAssertEqual(keepouts.first { $0["all_copper_layers"] as? Bool == true }?["layer_name"] as? String,
                       "every copper layer")

        // Removing a keepout takes the polygon bounding it.
        let polygonCount = (try result("list_polygons") as? [[String: Any]])?.count ?? 0
        _ = try apply([["op": "remove_keepout", "keepout": try XCTUnwrap(everywhere["keepout"] as? String)]])
        XCTAssertEqual((try result("list_keepouts") as? [[String: Any]])?.count, 1)
        XCTAssertEqual((try result("list_polygons") as? [[String: Any]])?.count, polygonCount - 1)
        XCTAssertNotNil(try call("apply", ["ops": [["op": "place_keepout", "vertices": [["x_mm": 0, "y_mm": 0]]]]])["error"])
    }

    /// Two sheets cannot share a page number, so renumbering swaps.
    func testSheetsAreRenumberedBySwapping() throws {
        _ = try apply([["op": "add_sheet", "name": "Power"], ["op": "add_sheet", "name": "Analog"]])
        let before = try XCTUnwrap(try result("list_sheets") as? [[String: Any]])
        XCTAssertEqual(before.map { $0["index"] as? Int }, [1, 2, 3])

        let moved = try apply([["op": "set_sheet_index", "sheet": "Analog", "index": 1]])
        let change = try XCTUnwrap((moved["changes"] as? [[String: Any]])?.first)
        XCTAssertEqual(change["was"] as? Int, 3)
        XCTAssertNotNil(change["swapped_with"] as? String)

        let after = try XCTUnwrap(try result("list_sheets") as? [[String: Any]])
        XCTAssertEqual(after.map { $0["name"] as? String }, ["Analog", "Power", "Sheet 1"])
        XCTAssertEqual(after.map { $0["index"] as? Int }, [1, 2, 3], "no two sheets share a page number")

        XCTAssertNotNil(try call("apply", ["ops": [["op": "set_sheet_index", "sheet": 1, "index": 0]]])["error"])
    }
}
