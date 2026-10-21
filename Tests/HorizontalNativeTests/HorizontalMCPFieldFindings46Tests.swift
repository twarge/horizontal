import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// MCP field findings 46: what swapping Billo's MCU to its TFBGA240 package
/// through MCP on October 21 turned up (items 147–150 in the notes).
final class HorizontalMCPFieldFindings46Tests: XCTestCase {
    private struct Part {
        var items: [JSONDictionary]
        var part: String
        var gate: String
        var pins: [String]
    }

    /// A one-gate part whose pins run down the symbol's left edge pointing
    /// left, 2.54 mm apart, each on a pad of its own.
    private func part(_ names: [String]) -> Part {
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i], direction: .bidirectional, alternateNames: [])
        }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_540_000),
                                                       length: 2_540_000, orientation: .left)
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
        return Part(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                    part: part.uuid, gate: gate, pins: pins)
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("field46-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        session = HorizontalDispatchSession()
        handle = try session.open(url: root).handle
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        let entry = try session.entry(handle: handle)
        if method == "apply" {
            if params["expected_revision"] == nil { params["expected_revision"] = entry.revision }
            if params["operation_id"] == nil { params["operation_id"] = UUID().uuidString }
        }
        return try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
    }

    private func result(_ method: String, _ args: JSONDictionary = [:]) throws -> Any {
        let response = try call(method, args)
        XCTAssertNil(response["error"], "\(response)")
        return try XCTUnwrap(response["result"])
    }

    @discardableResult
    private func apply(_ ops: [JSONDictionary], _ extra: JSONDictionary = [:]) throws -> JSONDictionary {
        try XCTUnwrap(try result("apply", extra.merging(["ops": ops]) { new, _ in new }) as? JSONDictionary)
    }

    private func error(_ ops: [JSONDictionary]) throws -> JSONDictionary {
        let response = try call("apply", ["ops": ops])
        return try XCTUnwrap(response["error"] as? JSONDictionary, "expected an error: \(response)")
    }

    private func changes(_ result: JSONDictionary) -> [JSONDictionary] { result.dictionaryArray("changes") }

    private func pins(_ refdes: String) throws -> [JSONDictionary] {
        try XCTUnwrap(try result("get_component", ["refdes": refdes]) as? JSONDictionary).dictionaryArray("pins")
    }

    private func net(of refdes: String, _ pin: String) throws -> String? {
        try pins(refdes).first { $0.string("pin") == pin }?.string("net_id")
    }

    // MARK: - 147: remap_part's pin_map by pin name

    func testPinMapNamesPinsAsConnectDoes() throws {
        let old = part(["A", "VSSA/VREF-"])
        let new = part(["A", "VSSA", "VREF-"])
        try apply([["op": "ensure_component", "refdes": "U1", "part": old.part],
                   ["op": "place_symbol", "component": "U1", "x_mm": 100, "y_mm": 100],
                   ["op": "connect", "component": "U1", "pin": "A", "net": "SIG", "create_net": true],
                   ["op": "connect", "component": "U1", "pin": "VSSA/VREF-", "net": "GND", "create_net": true]],
                  ["pool_items": old.items + new.items])
        let unmatched = try XCTUnwrap(try error([["op": "remap_part", "component": "U1", "part": new.part]]).string("message"))
        XCTAssertTrue(unmatched.contains("VSSA/VREF-") && unmatched.contains("by pin name"), unmatched)
        let unknown = try XCTUnwrap(try error([["op": "remap_part", "component": "U1", "part": new.part,
                                                "pin_map": ["VSSA/VREF-": "AGND"]]]).string("message"))
        XCTAssertTrue(unknown.contains("pin_map") && unknown.contains("AGND"), unknown)

        // A name whose slash is its own, and a gate/pin with the gate by name.
        try apply([["op": "remap_part", "component": "U1", "part": new.part, "pin_map": ["VSSA/VREF-": "Main/VSSA"]]], ["dry_run": true])
        try apply([["op": "remap_part", "component": "U1", "part": new.part, "pin_map": ["VSSA/VREF-": "VSSA"]]])
        let gnd = try XCTUnwrap(try net(of: "U1", "VSSA"))
        XCTAssertEqual((try result("get_net", ["id": gnd]) as? JSONDictionary)?.string("name"), "GND")
        XCTAssertNil(try net(of: "U1", "VREF-"))
        XCTAssertNotNil(try net(of: "U1", "A"))
    }

    // MARK: - 148: a short id wherever an op takes one

    func testAShortIDNamesAWireAJunctionAndAText() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                   ["op": "connect", "component": "R1", "pin": "A", "net": "SIG", "create_net": true],
                   ["op": "place_junction", "id": "j1", "net": "SIG", "x_mm": 80, "y_mm": 100],
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "j1"]],
                   ["op": "place_text", "id": "t1", "text": "note", "x_mm": 50, "y_mm": 50]],
                  ["pool_items": resistor.items])
        let wire = try XCTUnwrap((try result("list_net_lines") as? [JSONDictionary])?.first?.string("id"))
        let junction = try XCTUnwrap((try result("list_junctions") as? [JSONDictionary])?.first?.string("id"))
        let text = try XCTUnwrap((try result("list_texts") as? [JSONDictionary])?.first?.string("id"))

        // A text's short id is that text, moved, not a new one named for it.
        let moved = try apply([["op": "place_text", "id": String(text.prefix(8)), "x_mm": 60]])
        XCTAssertEqual(changes(moved).first?.string("text_id"), text, "\(moved)")
        XCTAssertEqual(changes(moved).first?["created"] as? Bool, false)
        XCTAssertEqual((try result("list_texts") as? [JSONDictionary])?.count, 1)
        // A wire end's junction and the wire itself, as a reply shortens them.
        let rewired = try apply([["op": "set_net_line_endpoint", "line": String(wire.prefix(8)) + "…", "end": "to",
                                  "endpoint": ["kind": "junction", "junction": String(junction.prefix(13))]]], ["dry_run": true])
        XCTAssertEqual(changes(rewired).first?.string("net_line"), wire, "\(rewired)")
        let removed = try apply([["op": "remove_net_line", "id": String(wire.prefix(8))]])
        XCTAssertEqual(changes(removed).first?.string("net_line"), wire)

        // Two junctions beginning alike: the short id names neither.
        try apply([["op": "place_junction", "id": "abcdef12-0000-4000-8000-000000000001", "net": "SIG", "x_mm": 10, "y_mm": 10],
                   ["op": "place_junction", "id": "abcdef12-0000-4000-8000-000000000002", "net": "SIG", "x_mm": 20, "y_mm": 10]])
        let ambiguous = try error([["op": "remove_junction", "junction": "abcdef12"]])
        XCTAssertEqual(ambiguous.int("code"), -32002, "AMBIGUOUS_SELECTOR: \(ambiguous)")
        XCTAssertEqual((ambiguous["data"] as? JSONDictionary)?.dictionary("details")?["candidates"] as? [String],
                       ["abcdef12-0000-4000-8000-000000000001", "abcdef12-0000-4000-8000-000000000002"])
        XCTAssertTrue(ambiguous.string("message")?.hasPrefix("ops[0] remove_junction:") == true, "\(ambiguous)")
        try apply([["op": "remove_junction", "junction": "abcdef12-0000-4000-8000-000000000002"]])
        XCTAssertEqual(changes(try apply([["op": "remove_junction", "junction": "abcdef12"]])).first?.string("junction"),
                       "abcdef12-0000-4000-8000-000000000001")
        // A batch name that only looks like a short id still names a new thing.
        let named = try apply([["op": "place_junction", "id": "c0ffee01", "net": "SIG", "x_mm": 30, "y_mm": 10],
                               ["op": "remove_junction", "junction": "c0ffee01"]])
        XCTAssertNotNil(named.dictionary("handles")?["c0ffee01"], "\(named)")
    }

    // MARK: - 149: a pin onto a net with no name

    func testConnectAndEnsureNetMakeANetWithNoName() throws {
        let resistor = part(["A", "B"])
        let made = try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                              ["op": "connect", "component": "R1", "pin": "A", "create_net": true],
                              ["op": "ensure_net", "id": "n1", "name": ""],
                              ["op": "connect", "component": "R1", "pin": "B", "net": "n1"]],
                             ["pool_items": resistor.items])
        let a = try XCTUnwrap(try net(of: "R1", "A")), b = try XCTUnwrap(try net(of: "R1", "B"))
        XCTAssertNotEqual(a, b, "each is a net of its own")
        XCTAssertEqual(changes(made)[2].string("net"), b)
        for id in [a, b] {
            XCTAssertEqual((try result("get_net", ["id": id]) as? JSONDictionary)?.string("name"), "")
        }
        // "" names no net that is there, so it never finds one.
        try apply([["op": "connect", "component": "R1", "pin": "A", "net": "", "create_net": true]])
        XCTAssertNotEqual(try net(of: "R1", "A"), a)
        XCTAssertTrue(try error([["op": "ensure_net", "name": "", "is_power": true]]).string("message")?.contains("power net needs a name") == true)
        XCTAssertNotNil(try error([["op": "connect", "component": "R1", "pin": "A", "net": ""]]))
    }

    func testAWireBetweenPinsOnNoNetGivesThemOne() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
                   ["op": "ensure_component", "refdes": "R3", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                   ["op": "place_symbol", "component": "R2", "x_mm": 60, "y_mm": 100],
                   ["op": "place_symbol", "component": "R3", "x_mm": 60, "y_mm": 60],
                   ["op": "connect", "component": "R3", "pin": "B", "net": "SIG", "create_net": true],
                   ["op": "connect", "component": "R3", "pin": "A", "net": "OTHER", "create_net": true]],
                  ["pool_items": resistor.items])
        let wired = try XCTUnwrap(changes(try apply([["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"],
                                                      "to": ["kind": "pin", "component": "R2", "pin": "A"]]])).first)
        let made = try XCTUnwrap(wired.string("created_net"), "\(wired)")
        XCTAssertEqual(wired.string("net"), made)
        XCTAssertEqual(wired["connected_pins"] as? [String], ["R1.A", "R2.A"])
        XCTAssertEqual(try net(of: "R1", "A"), made)
        XCTAssertEqual(try net(of: "R2", "A"), made)
        XCTAssertEqual((try result("get_net", ["id": made]) as? JSONDictionary)?.string("name"), "")

        // A free pin takes the net at the wire's other end.
        let joined = try XCTUnwrap(changes(try apply([["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "B"],
                                                       "to": ["kind": "pin", "component": "R3", "pin": "B"]]])).first)
        XCTAssertNil(joined["created_net"])
        XCTAssertEqual(joined["connected_pins"] as? [String], ["R1.B"])
        XCTAssertEqual((try result("get_net", ["id": try XCTUnwrap(try net(of: "R1", "B"))]) as? JSONDictionary)?.string("name"), "SIG")
        // Two nets a wire would short stay apart.
        XCTAssertTrue(try error([["op": "draw_net_line", "from": ["kind": "pin", "component": "R3", "pin": "A"],
                                  "to": ["kind": "pin", "component": "R1", "pin": "B"]]]).string("message")?.contains("different nets") == true)
        let dangling = try XCTUnwrap(try result("find_dangling") as? JSONDictionary)
        XCTAssertEqual(dangling.dictionary("totals")?.values.compactMap { $0 as? Int }.reduce(0, +) ?? 0, 0, "\(dangling)")
    }

    // MARK: - 150: a netlist small enough to read

    func testACompactNetlistNamesEachPinByRefdes() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
                   ["op": "connect", "component": "R1", "pin": "A", "net": "SIG", "create_net": true],
                   ["op": "connect", "component": "R2", "pin": "A", "net": "SIG"],
                   ["op": "connect", "component": "R2", "pin": "B", "net": "GND", "create_net": true]],
                  ["pool_items": resistor.items])
        let compact = try XCTUnwrap(try result("netlist", ["compact": true, "include_unconnected": true]) as? JSONDictionary)
        let sig = try XCTUnwrap(compact.dictionaryArray("nets").first { $0.string("name") == "SIG" })
        XCTAssertEqual(Set(sig["pins"] as? [String] ?? []), ["R1.A", "R2.A"])
        XCTAssertEqual(Set(sig.keys), ["id", "name", "pins"], "nothing that is the default")
        XCTAssertEqual(compact["unconnected_pins"] as? [String], ["R1.B"])
        let full = try XCTUnwrap(try result("netlist", ["include_unconnected": true]) as? JSONDictionary)
        let size = { (json: JSONDictionary) in try JSONSerialization.data(withJSONObject: json).count }
        XCTAssertLessThan(try size(compact) * 4, try size(full), "the ids are what made it big")
    }

    func testACompactNetlistTellsRepeatedPinNamesApartByGate() throws {
        // Two gates, A and B, each with an IN pin.
        var unit = HorizontalPoolItemFactory.newUnit()
        let pin = UUID().uuidString.lowercased()
        unit.pins[pin] = HorizontalUnitPin(id: pin, primaryName: "IN", direction: .input, alternateNames: [])
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let first = try XCTUnwrap(entity.gates.keys.first)
        entity.gates[first]?.name = "A"
        entity.gates[first]?.suffix = "A"
        let second = UUID().uuidString.lowercased()
        entity.gates[second] = HorizontalEntityGate(id: second, name: "B", suffix: "B", unitID: unit.uuid)
        try apply([["op": "ensure_component", "refdes": "U3", "entity": entity.uuid],
                   ["op": "connect", "component": "U3", "gate": "A", "pin": "IN", "net": "X", "create_net": true],
                   ["op": "connect", "component": "U3", "gate": "B", "pin": "IN", "net": "X"]],
                  ["pool_items": [unit.json(), entity.json()]])
        let compact = try XCTUnwrap(try result("netlist", ["compact": true]) as? JSONDictionary)
        let x = try XCTUnwrap(compact.dictionaryArray("nets").first { $0.string("name") == "X" })
        XCTAssertEqual(Set(x["pins"] as? [String] ?? []), ["U3A.IN", "U3B.IN"])
    }
}
