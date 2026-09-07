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
        let gateID = try XCTUnwrap(entity.gates.keys.first)
        part.padMap = [
            padIDs[0]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin1),
            padIDs[1]: HorizontalPartPadMapEntry(gateID: gateID, pinID: pin2)
        ]
        part.attributes[.mpn] = HorizontalPartAttribute(value: "RC0603FR-0710KL")
        // No part value: Horizon shows a part's value over the component's,
        // and these tests read the component's back.
        part.attributes[.manufacturer] = HorizontalPartAttribute(value: "Yageo")

        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.padstack(padstack), to: poolURL.appendingPathComponent("padstacks/cache/\(padstack.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
        return (part.uuid, entity.uuid)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
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
}
