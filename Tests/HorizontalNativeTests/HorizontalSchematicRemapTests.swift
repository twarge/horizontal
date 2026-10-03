import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

final class HorizontalSchematicRemapTests: XCTestCase {
    private struct Connector {
        var items: [JSONDictionary]
        var part: String
        var gate: String
        var pins: [String]
        var pads: [String]
    }

    private func connector(_ count: Int, prefix: String = "") -> Connector {
        let pins = (0..<count).map { _ in UUID().uuidString.lowercased() }
        let pads = (0..<count).map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices { unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: prefix + String(i + 1)) }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: Double(i) * 2_000_000), length: 1_000_000)
        }
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        let shape = UUID().uuidString.lowercased()
        padstack.shapes[shape] = HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])
        var package = HorizontalPoolItemFactory.newPackage()
        for i in pads.indices {
            package.pads[pads[i]] = HorizontalPad(id: pads[i], name: String(i + 1), padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: Double(i) * 2_000_000), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        for i in pins.indices { part.padMap[pads[i]] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[i]) }
        return Connector(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                         part: part.uuid, gate: gate, pins: pins, pads: pads)
    }

    func testNativeWiresResolvePinNetsAndRetargetByIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-wires-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: root)
        func call(_ method: String, _ args: JSONDictionary = [:]) -> JSONDictionary {
            var params = args
            params["handle"] = entry.handle
            if method == "apply" {
                params["expected_revision"] = entry.revision
                params["operation_id"] = UUID().uuidString
            }
            return HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session)
        }
        func result(_ method: String, _ args: JSONDictionary = [:]) throws -> Any {
            let response = call(method, args)
            XCTAssertNil(response["error"], "\(response)")
            return try XCTUnwrap(response["result"])
        }
        let part = connector(2)
        _ = try result("apply", ["pool_items": part.items, "ops": [
            ["op": "ensure_component", "refdes": "J1", "part": part.part],
            ["op": "place_symbol", "component": "J1", "x_mm": 10, "y_mm": 10],
            ["op": "connect", "component": "J1", "pin": "\(part.gate)/\(part.pins[0])", "net": "A", "create_net": true],
            ["op": "connect", "component": "J1", "pin": "\(part.gate)/\(part.pins[1])", "net": "B", "create_net": true]
        ]])
        let instance = try XCTUnwrap((try result("list_symbols") as? [JSONDictionary])?.first?.string("id"))
        let junctions = (0..<4).map { _ in UUID().uuidString.lowercased() }
        let lines = (0..<2).map { _ in UUID().uuidString.lowercased() }
        _ = try result("apply", ["ops": junctions.enumerated().map { i, id -> JSONDictionary in
            ["op": "place_junction", "id": id, "net": i == 3 ? "B" : "A", "x_mm": 20 + i, "y_mm": 10]
        } + [
            ["op": "draw_net_line", "id": lines[0], "from": ["kind": "pin", "symbol": instance, "pin": part.pins[0]],
             "to": ["kind": "junction", "junction": junctions[0]]],
            ["op": "draw_net_line", "id": lines[1], "from": ["kind": "junction", "junction": junctions[0]],
             "to": ["kind": "junction", "junction": junctions[1]]]
        ]])
        // Native Horizon stores endpoint identities, with no cached wire or
        // junction nets. Also exercise omitted null endpoint fields.
        var archive = try HorizontalProjectArchive.snapshot(from: root)
        var schematic = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
        var sheets = schematic.dictionaryMap("sheets")
        let sheetID = try XCTUnwrap(sheets.keys.first)
        var sheet = sheets[sheetID]!
        var rawLines = sheet.dictionaryMap("net_lines"), rawJunctions = sheet.dictionaryMap("junctions")
        for id in lines { rawLines[id]?.removeValue(forKey: "net") }
        rawLines[lines[1]]?["from"] = ["junc": junctions[0]]
        rawLines[lines[1]]?["to"] = ["junc": junctions[1]]
        for id in junctions.prefix(2) { rawJunctions[id]?.removeValue(forKey: "net") }
        // Coincidence is not connectivity: this separate B junction remains B.
        let coincidentPosition = rawJunctions[junctions[1]]?["position"]
        rawJunctions[junctions[3]]?["position"] = coincidentPosition
        sheet["net_lines"] = rawLines
        sheet["junctions"] = rawJunctions
        sheets[sheetID] = sheet
        schematic["sheets"] = sheets
        try HorizontalSchematicClipboardEditor.write(schematic, path: "top_schematic.json", archive: &archive)
        try archive.write(to: root)
        _ = try result("reload_project")
        let baseline = try HorizontalProjectArchive.snapshot(from: root)
        XCTAssertEqual((try result("list_junctions", ["net": "A"]) as? [JSONDictionary])?.count, 3)
        XCTAssertEqual((try result("list_junctions", ["net": "B"]) as? [JSONDictionary])?.count, 1)
        XCTAssertEqual((try result("list_net_lines", ["net": "A"]) as? [JSONDictionary])?.count, 2)
        XCTAssertEqual(baseline, try HorizontalProjectArchive.snapshot(from: root), "Reads must not materialize inferred nets")

        let duplicate = try result("apply", ["ops": [["op": "draw_net_line",
            "from": ["kind": "junction", "junction": junctions[0]], "to": ["kind": "junction", "junction": junctions[1]]]]]) as! JSONDictionary
        XCTAssertEqual(duplicate.dictionaryArray("changes").first?.string("net_line"), lines[1])
        let reused = try result("apply", ["ops": [["op": "place_junction", "net": "A", "x_mm": 20, "y_mm": 10]]]) as! JSONDictionary
        XCTAssertEqual(reused.dictionaryArray("changes").first?.string("junction"), junctions[0])
        _ = try result("apply", ["ops": [["op": "set_net_line_endpoint", "line": lines[1], "end": "to",
                                         "endpoint": ["kind": "junction", "junction": junctions[2]]]]])
        let editedLines = try result("list_net_lines", ["net": "A"]) as! [JSONDictionary]
        XCTAssertEqual(editedLines.first { $0.string("id") == lines[1] }?.dictionary("to")?.string("junction"), junctions[2])
        let after = try HorizontalProjectArchive.snapshot(from: root)
        XCTAssertNotNil(call("apply", ["ops": [["op": "set_net_line_endpoint", "line": lines[1], "end": "to",
                                                "endpoint": ["kind": "junction", "junction": junctions[0]]]]])["error"], "Reject self-loops even when null fields differ")
        XCTAssertNotNil(call("apply", ["ops": [
            ["op": "connect", "component": "J1", "pin": "\(part.gate)/\(part.pins[0])", "net": "B"],
            ["op": "set_net_line_endpoint", "line": lines[1], "end": "to", "endpoint": ["kind": "junction", "junction": junctions[2]]]
        ]])["error"], "Resolve the current batch and reject conflicting net anchors")
        XCTAssertEqual(after, try HorizontalProjectArchive.snapshot(from: root))
    }

    func testFiveToSixPinRemapPreservesWiresCopperAndPool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: root)
        func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
            var params = args
            params["handle"] = entry.handle
            if method == "apply" {
                if params["expected_revision"] == nil { params["expected_revision"] = entry.revision }
                params["operation_id"] = UUID().uuidString
            }
            return try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
                ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
        }
        func result(_ method: String, _ args: JSONDictionary = [:]) throws -> Any {
            let response = try call(method, args)
            XCTAssertNil(response["error"], "\(response)")
            return try XCTUnwrap(response["result"])
        }
        // Differently named pins, so nothing maps by name and pin_map decides.
        let old = connector(5), target = connector(6, prefix: "P")
        _ = try result("apply", ["pool_items": old.items + target.items, "ops": [
            ["op": "ensure_component", "refdes": "J1", "part": old.part],
            ["op": "ensure_component", "refdes": "J2", "part": old.part],
            ["op": "place_symbol", "component": "J1", "x_mm": 10, "y_mm": 10],
            ["op": "place_symbol", "component": "J2", "x_mm": 30, "y_mm": 10],
            ["op": "place_component", "component": "J1", "x_mm": 0, "y_mm": 0]
        ]])
        let symbols = try XCTUnwrap(try result("list_symbols") as? [JSONDictionary])
        let instance = try XCTUnwrap(symbols.first { $0.string("refdes") == "J1" }?.string("id"))
        let other = try XCTUnwrap(try result("get_component", ["refdes": "J2"]) as? JSONDictionary)
        var wiring = [JSONDictionary]()
        for i in old.pins.indices {
            let junction = UUID().uuidString.lowercased()
            wiring += [
                ["op": "ensure_net", "name": "N\(i)"],
                ["op": "connect", "component": "J1", "pin": "\(old.gate)/\(old.pins[i])", "net": "N\(i)"],
                ["op": "place_junction", "id": junction, "net": "N\(i)", "x_mm": 20, "y_mm": 10 + i * 2],
                ["op": "draw_net_line", "from": ["kind": "pin", "symbol": instance, "pin": old.pins[i]], "to": ["kind": "junction", "junction": junction]],
                ["op": "place_track", "from": ["component": "J1", "pad": old.pads[i]], "to": ["x_mm": 10, "y_mm": i * 2], "layer": 0, "width_mm": 0.2]
            ]
        }
        _ = try result("apply", ["ops": wiring])
        let before = try HorizontalProjectArchive.snapshot(from: root)
        let beforeLines = try result("list_net_lines") as! [JSONDictionary]
        let beforeTracks = (try result("list_tracks") as! JSONDictionary).dictionaryArray("tracks")
        let firstWire = try XCTUnwrap(beforeLines.first { $0.dictionary("from")?.string("pin") == old.pins[0] })
        let staleNet = try call("apply", ["ops": [
            ["op": "connect", "component": "J1", "pin": "\(old.gate)/\(old.pins[0])", "net": "N1"],
            ["op": "set_net_line_endpoint", "line": firstWire["id"]!, "end": "to", "endpoint": firstWire["to"]!]
        ]])
        XCTAssertNotNil(staleNet["error"], "A stale wire net must not hide conflicting endpoint connectivity")
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: root))
        let pinMap = Dictionary(uniqueKeysWithValues: old.pins.indices.map { ("\(old.gate)/\(old.pins[$0])", "\(target.gate)/\(target.pins[$0])") })
        var incomplete = pinMap
        incomplete.removeValue(forKey: "\(old.gate)/\(old.pins[0])")
        let refused = try call("apply", ["ops": [["op": "remap_part", "component": "J1", "part": target.part, "pin_map": incomplete]]])
        XCTAssertNotNil(refused["error"])
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: root))
        let sixthJunction = UUID().uuidString.lowercased()
        let ops: [JSONDictionary] = [
            ["op": "remap_part", "component": "J1", "part": target.part, "pin_map": pinMap],
            ["op": "ensure_net", "name": "N5"],
            ["op": "connect", "component": "J1", "pin": "\(target.gate)/\(target.pins[5])", "net": "N5"],
            ["op": "place_junction", "id": sixthJunction, "net": "N5", "x_mm": 20, "y_mm": 20],
            ["op": "draw_net_line", "from": ["kind": "pin", "symbol": instance, "pin": target.pins[5]], "to": ["kind": "junction", "junction": sixthJunction]],
            ["op": "place_track", "from": ["component": "J1", "pad": target.pads[5]], "to": ["x_mm": 10, "y_mm": 10], "layer": 0, "width_mm": 0.2]
        ]
        let preview = try result("apply", ["ops": ops, "dry_run": true]) as! JSONDictionary
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: root))
        let committed = try result("apply", ["ops": preview["normalized_ops"]!, "plan_digest": preview["plan_digest"]!]) as! JSONDictionary
        XCTAssertEqual(committed.string("status"), "committed")
        let lines = try result("list_net_lines") as! [JSONDictionary]
        let tracks = (try result("list_tracks") as! JSONDictionary).dictionaryArray("tracks")
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(tracks.count, 6)
        for original in beforeLines {
            let line = try XCTUnwrap(lines.first { $0.string("id") == original.string("id") })
            XCTAssertEqual(line.string("net"), original.string("net"))
            XCTAssertEqual(line.dictionary("from")?.string("gate"), target.gate)
        }
        for original in beforeTracks {
            let track = try XCTUnwrap(tracks.first { $0.string("id") == original.string("id") })
            XCTAssertEqual(track.string("net"), original.string("net"))
            XCTAssertTrue(target.pads.contains(track.dictionary("from")?.string("pad") ?? ""))
        }
        let after = try HorizontalProjectArchive.snapshot(from: root)
        for path in before.regularFilePaths where path.hasPrefix("pool/") {
            XCTAssertEqual(before.regularFileData(relativePath: path), after.regularFileData(relativePath: path), path)
        }
        let unchanged = try result("get_component", ["refdes": "J2"]) as! JSONDictionary
        XCTAssertEqual(other as NSDictionary, unchanged as NSDictionary)
        XCTAssertEqual((try result("board_info") as! JSONDictionary).dictionary("counts")?.int("airwires"), 0)
        let netlist = try result("netlist") as! JSONDictionary
        _ = try result("reload_project")
        XCTAssertEqual(netlist as NSDictionary, try result("netlist") as! NSDictionary)
    }
}
