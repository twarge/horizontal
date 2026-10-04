import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// What editing a real board over MCP turned up: pins named with slashes,
/// wires that could not be removed, junctions with no net, sheets that would
/// not go, and replies too large to read. Each test is one of those.
final class HorizontalMCPFieldFindingsTests: XCTestCase {
    private struct Part {
        var items: [JSONDictionary]
        var part: String
        var gate: String
        var pins: [String]
        var names: [String]
    }

    /// A one-gate part whose pins sit down the left edge pointing left, the
    /// way an MCU's pins do, named as given.
    private func part(_ names: [String], value: String = "") -> Part {
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices { unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i]) }
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
        if !value.isEmpty { part.attributes[.value] = HorizontalPartAttribute(value: value) }
        return Part(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                    part: part.uuid, gate: gate, pins: pins, names: names)
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID().uuidString).horizontal")
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
        if ["apply", "pool_write"].contains(method) {
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

    private func error(_ ops: [JSONDictionary], _ extra: JSONDictionary = [:]) throws -> String {
        let response = try call("apply", extra.merging(["ops": ops]) { new, _ in new })
        return try XCTUnwrap((response["error"] as? JSONDictionary)?.string("message"), "expected an error: \(response)")
    }

    private func changes(_ result: JSONDictionary) -> [JSONDictionary] { result.dictionaryArray("changes") }

    /// An MCU-like part, drawn at (100, 100) and connected as named.
    private func placedMCU() throws -> (part: Part, instance: String) {
        let mcu = part(["PA13(JTMS/SWDIO)", "PA14", "VSS", "VSS", "NRST"])
        let instance = UUID().uuidString.lowercased()
        try apply([
            ["op": "ensure_component", "refdes": "U1", "part": mcu.part],
            ["op": "place_symbol", "component": "U1", "x_mm": 100, "y_mm": 100, "id": instance,
             "pin_display_mode": "all", "display_all_pads": false],
            ["op": "connect", "component": "U1", "pin": "PA13(JTMS/SWDIO)", "net": "SWDIO", "create_net": true],
            ["op": "connect", "component": "U1", "pin": "PA14", "net": "SWCLK", "create_net": true]
        ], ["pool_items": mcu.items])
        return (mcu, instance)
    }

    func testPinNamesWithSlashesResolveWholeBeforeGatePin() throws {
        let (mcu, instance) = try placedMCU()
        let component = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary)
        let swdio = component.dictionaryArray("pins").first { $0.string("pin") == "PA13(JTMS/SWDIO)" }
        XCTAssertEqual(swdio?.string("net"), "SWDIO")
        // gate/pin still works, and so does naming the gate separately.
        try apply([["op": "disconnect", "component": "U1", "pin": "Main/PA14"],
                   ["op": "connect", "component": "U1", "gate": "Main", "pin": "PA14", "net": "SWCLK"]])
        // A name two pins share needs a uuid, and says so.
        XCTAssertTrue(try error([["op": "connect", "component": "U1", "pin": "VSS", "net": "SWCLK"]]).contains("uuid"))
        let unknown = try error([["op": "connect", "component": "U1", "pin": "PB7", "net": "SWCLK"]])
        XCTAssertTrue(unknown.contains("NRST"), "an unknown pin lists the pins there are: \(unknown)")

        // The symbol was drawn under the id asked for, with its display options.
        let symbols = try XCTUnwrap(try result("list_symbols") as? [JSONDictionary])
        XCTAssertEqual(symbols.first?.string("id"), instance)
        try apply([["op": "set_symbol_display", "component": "U1", "pin_display_mode": "both", "display_all_pads": true]])
        XCTAssertNotNil(try error([["op": "set_symbol_display", "component": "U1", "pin_display_mode": "loud"]]))
        XCTAssertTrue(try error([["op": "place_symbol", "component": "U1", "x_mm": 1, "y_mm": 1, "id": UUID().uuidString]]).contains("already drawn"))
        _ = mcu
    }

    func testWiresTakePinNamesAndSayWhyAPinCannotBeWired() throws {
        let (_, instance) = try placedMCU()
        let junction = UUID().uuidString.lowercased()
        let wired = try apply([
            ["op": "place_junction", "id": junction, "net": "SWDIO", "x_mm": 90, "y_mm": 100],
            ["op": "draw_net_line", "from": ["kind": "pin", "symbol": instance, "pin": "PA13(JTMS/SWDIO)"],
             "to": ["kind": "junction", "junction": junction]],
            ["op": "place_junction", "net": "SWCLK", "x_mm": 90, "y_mm": 97.46]
        ])
        XCTAssertEqual(changes(wired)[1].string("net_line") != nil, true)
        let clock = try XCTUnwrap(changes(wired)[2].string("junction"))
        // By component and pin name, no instance id needed.
        try apply([["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "PA14"],
                    "to": ["kind": "junction", "junction": clock]]])
        let unconnected = try error([["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "NRST"],
                                      "to": ["kind": "junction", "junction": junction]]])
        XCTAssertTrue(unconnected.contains("no net") && unconnected.contains("NRST"), unconnected)
        let missing = try error([["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "PZ9"],
                                  "to": ["kind": "junction", "junction": junction]]])
        XCTAssertTrue(missing.contains("No pin PZ9"), missing)

        // Coordinates come back with each wire, and pin names with pin ends.
        let lines = try XCTUnwrap(try result("list_net_lines", ["net": "SWDIO"]) as? [JSONDictionary])
        XCTAssertEqual(lines.first?.dictionary("from")?.string("pin_name"), "PA13(JTMS/SWDIO)")
        XCTAssertEqual(lines.first?.dictionary("from_mm")?.double("x_mm"), 100)
        XCTAssertEqual(lines.first?.dictionary("to_mm")?.double("x_mm"), 90)
    }

    func testNetlessJunctionsAreAdoptedRemovedAndPruned() throws {
        let (_, instance) = try placedMCU()
        // A junction left with no net — what retiring a net leaves behind.
        let orphan = try XCTUnwrap(changes(try apply([["op": "ensure_net", "name": "TMP"],
                                                      ["op": "place_junction", "net": "TMP", "x_mm": 80, "y_mm": 100]]))[1].string("junction"))
        let far = try XCTUnwrap(changes(try apply([["op": "place_junction", "net": "TMP", "x_mm": 70, "y_mm": 100]]))[0].string("junction"))
        let island = try XCTUnwrap(changes(try apply([["op": "draw_net_line", "from": ["kind": "junction", "junction": orphan],
                                                       "to": ["kind": "junction", "junction": far]]]))[0].string("net_line"))
        try apply([["op": "retire_net", "net": "TMP"]])
        XCTAssertEqual((try result("list_junctions") as? [JSONDictionary])?.count, 0, "retiring a net takes its wiring")
        XCTAssertEqual((try result("list_net_lines") as? [JSONDictionary])?.count, 0)
        _ = island

        // Wiring with no net at all: a wire to a pin gives it one.
        var archive = try HorizontalProjectArchive.snapshot(from: root)
        var schematic = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
        var sheets = schematic.dictionaryMap("sheets")
        let sheetID = try XCTUnwrap(sheets.keys.first)
        let loose = UUID().uuidString.lowercased(), stray = UUID().uuidString.lowercased(), strayLine = UUID().uuidString.lowercased()
        sheets[sheetID]?["junctions"] = [loose: ["position": [90_000_000, 100_000_000]],
                                         stray: ["position": [60_000_000, 60_000_000]]]
        schematic["sheets"] = sheets
        try HorizontalSchematicClipboardEditor.write(schematic, path: "top_schematic.json", archive: &archive)
        try archive.write(to: root)
        _ = try result("reload_project")
        let adopted = try apply([["op": "draw_net_line", "from": ["kind": "pin", "symbol": instance, "pin": "PA14"],
                                  "to": ["kind": "junction", "junction": loose]]])
        XCTAssertEqual(changes(adopted).first?["adopted_junctions"] as? [String], [loose])
        XCTAssertEqual((try result("list_junctions", ["net": "SWCLK"]) as? [JSONDictionary])?.first?.string("id"), loose)
        // A label for another net is not quietly put on it.
        XCTAssertTrue(try error([["op": "place_net_label", "net": "SWDIO", "x_mm": 90, "y_mm": 100]]).contains("SWCLK"))

        // remove_junction takes the wire with it; prune clears the stray.
        let removed = try apply([["op": "remove_junction", "junction": loose]])
        XCTAssertEqual((changes(removed).first?["net_lines"] as? [String])?.count, 1)
        XCTAssertEqual((try result("list_net_lines") as? [JSONDictionary])?.count, 0)
        let pruned = try apply([["op": "prune_sheet"]])
        XCTAssertEqual(changes(pruned).first?.dictionary("removed")?.int("junctions"), 1)
        XCTAssertEqual((try result("list_junctions") as? [JSONDictionary])?.count, 0)
        _ = strayLine

        // remove_net_line leaves a junction something else stands on.
        let wire = try apply([["op": "terminate_pin", "component": "U1", "pin": "PA13(JTMS/SWDIO)"]])
        let line = try XCTUnwrap(changes(wire).first?.string("net_line"))
        let gone = try apply([["op": "remove_net_line", "line": line]])
        XCTAssertEqual(changes(gone).first?["junctions_removed"] as? [String], [], "the label still stands on it")
        XCTAssertEqual((try result("list_net_labels") as? [JSONDictionary])?.count, 1)
    }

    func testTerminatePinDrawsAStubAwayFromThePin() throws {
        _ = try placedMCU()
        // The pin points left out of a symbol at (100, 100): the stub runs left.
        let label = try apply([["op": "terminate_pin", "component": "U1", "pin": "PA13(JTMS/SWDIO)"]])
        let change = try XCTUnwrap(changes(label).first)
        XCTAssertEqual(change.string("kind"), "label")
        XCTAssertEqual(change.string("orientation"), "left")
        XCTAssertEqual(change.double("x_mm") ?? 0, 97.46, accuracy: 1e-6)
        XCTAssertEqual(change.double("y_mm"), 100)
        let labels = try XCTUnwrap(try result("list_net_labels") as? [JSONDictionary])
        XCTAssertEqual(labels.first?.string("orientation"), "left")

        // A power net ends in a power symbol; a pin on no net is connected first.
        let power = try apply([["op": "ensure_net", "name": "GND", "is_power": true],
                               ["op": "terminate_pin", "component": "U1", "pin": "NRST", "net": "GND", "length_mm": 5.08]])
        let ground = try XCTUnwrap(changes(power).last)
        XCTAssertEqual(ground.string("kind"), "power")
        XCTAssertEqual(ground.bool("connected"), true)
        XCTAssertEqual(ground.double("x_mm") ?? 0, 94.92, accuracy: 1e-6)
        XCTAssertEqual(ground.double("y_mm") ?? 0, 89.84, accuracy: 1e-6)
        let pins = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pins.first { $0.string("pin") == "NRST" }?.string("net"), "GND")
        XCTAssertTrue(try error([["op": "terminate_pin", "component": "U1", "pin": "PA14", "net": "GND"]]).contains("disconnect"))

        // Mirrored symbols point the other way.
        try apply([["op": "place_symbol", "component": "U1", "mirror": true]])
        let mirrored = try apply([["op": "terminate_pin", "component": "U1", "pin": "PA14"]])
        XCTAssertEqual(changes(mirrored).first?.string("orientation"), "right")
    }

    func testNoConnectIsAConnectionWithNoNet() throws {
        _ = try placedMCU()
        try apply([["op": "set_no_connect", "component": "U1", "pins": ["NRST"]]])
        var pins = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pins.first { $0.string("pin") == "NRST" }?.string("connection_state"), "no_connect")
        XCTAssertTrue(try error([["op": "set_no_connect", "component": "U1", "pin": "PA14"]]).contains("disconnect"))
        let taken = try apply([["op": "set_no_connect", "component": "U1", "pin": "PA14", "disconnect": true]])
        XCTAssertEqual((changes(taken).first?["disconnected"] as? [JSONDictionary])?.count, 1)
        try apply([["op": "set_no_connect", "component": "U1", "pins": ["NRST", "PA14"], "no_connect": false]])
        pins = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pins.first { $0.string("pin") == "NRST" }?.string("connection_state"), "unconnected")
    }

    func testRemapMatchesPinsByName() throws {
        let old = part(["VDD", "GND", "OUT"]), new = part(["OUT", "VDD", "GND", "EN"])
        try apply([["op": "ensure_component", "refdes": "U2", "part": old.part],
                   ["op": "place_symbol", "component": "U2", "x_mm": 50, "y_mm": 50],
                   ["op": "connect", "component": "U2", "pin": "VDD", "net": "3V3", "create_net": true],
                   ["op": "connect", "component": "U2", "pin": "OUT", "net": "SIG", "create_net": true],
                   ["op": "terminate_pin", "component": "U2", "pin": "OUT"]],
                  ["pool_items": old.items + new.items])
        let remapped = try apply([["op": "remap_part", "component": "U2", "part": new.part]])
        XCTAssertEqual(changes(remapped).first?.int("mapped_by_name"), 3)
        let pins = try XCTUnwrap(try result("get_component", ["refdes": "U2"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pins.first { $0.string("pin") == "VDD" }?.string("net"), "3V3")
        XCTAssertEqual(pins.first { $0.string("pin") == "OUT" }?.string("net"), "SIG")
        XCTAssertEqual((try result("list_net_lines", ["net": "SIG"]) as? [JSONDictionary])?.first?.dictionary("from")?.string("pin_name"), "OUT")

        // A connected pin with no counterpart is named, and nothing changes.
        let narrow = part(["X"])
        _ = try result("pool_write", ["items": narrow.items])
        let refused = try error([["op": "remap_part", "component": "U2", "part": narrow.part]])
        XCTAssertTrue(refused.contains("VDD") && refused.contains("OUT"), refused)
    }

    func testSheetsCarryTheFrameAndForceClearsThem() throws {
        var frame = HorizontalPoolItemFactory.newFrame()
        frame.name = "A4"
        _ = try result("pool_write", ["items": [frame.json()]])
        try apply([["op": "add_sheet", "name": "Framed", "frame": frame.uuid],
                   ["op": "add_sheet", "name": "Follows"]])
        let schematic = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: try HorizontalProjectArchive.snapshot(from: root))
        let follows = schematic.dictionaryMap("sheets").values.first { $0.string("name") == "Follows" }
        XCTAssertEqual(follows?.string("frame"), frame.uuid, "a new page uses the frame the last page has")

        _ = try placedMCU()
        try apply([["op": "remove_symbol", "component": "U1"],
                   ["op": "place_symbol", "component": "U1", "sheet": "Follows", "x_mm": 100, "y_mm": 100],
                   ["op": "terminate_pin", "component": "U1", "pin": "PA14"]])
        XCTAssertTrue(try error([["op": "remove_sheet", "sheet": "Follows"]]).contains("force"))
        let forced = try apply([["op": "remove_sheet", "sheet": "Follows", "force": true]])
        XCTAssertEqual(changes(forced).first?["unplaced_components"] as? [String], ["U1"])
        XCTAssertNotNil(try result("get_component", ["refdes": "U1"]), "the component stays in the block")
        let check = try XCTUnwrap(try result("project_info") as? JSONDictionary)
        XCTAssertEqual(check["diagnostics"] as? [String], [])
    }

    func testCompactRepliesAndDefiniteFailureStatus() throws {
        let mcu = part(["A", "B"])
        let compact = try apply([["op": "ensure_component", "refdes": "U9", "part": mcu.part],
                                 ["op": "place_symbol", "component": "U9", "x_mm": 0, "y_mm": 0]],
                                ["pool_items": mcu.items, "detail": "compact"])
        XCTAssertNil(compact["normalized_ops"])
        XCTAssertNil(compact["project"])
        XCTAssertNotNil(compact["timing"])
        XCTAssertNotNil(changes(compact).first?.string("component"))
        XCTAssertNotNil(changes(compact).last?.string("symbol_instance"))
        let preview = try apply([["op": "set_value", "component": "U9", "value": "x"]], ["dry_run": true, "detail": "compact"])
        XCTAssertNil(preview["preview"], "a compact dry run leaves the file contents out")

        // A mutation that fails is recorded as not committed under its id.
        let id = UUID().uuidString
        let failed = try call("apply", ["ops": [["op": "set_value", "component": "NOPE", "value": "x"]], "operation_id": id])
        XCTAssertNotNil(failed["error"])
        let status = try XCTUnwrap(try result("transaction_status", ["operation_id": id]) as? JSONDictionary)
        XCTAssertEqual(status.string("status"), "not_committed")
        XCTAssertTrue((status.string("error") ?? "").contains("NOPE"))
        // ... and may still be retried under the same id.
        let retried = try call("apply", ["ops": [["op": "set_value", "component": "U9", "value": "x"]], "operation_id": id])
        XCTAssertNil(retried["error"])
        XCTAssertEqual((try result("transaction_status", ["operation_id": id, "detail": "compact"]) as? JSONDictionary)?.string("status"), "committed")
    }

    func testSearchFindsPartsByValueHoweverItIsWritten() throws {
        let cap = part(["1", "2"], value: "2.2µF")
        _ = try result("pool_write", ["items": cap.items])
        for query in ["2.2 µF", "2.2uF", "2u2", "2.2 uF", "2200nF"] {
            let found = try XCTUnwrap(try result("search_pool", ["query": query, "kind": "part"]) as? JSONDictionary)
            XCTAssertTrue(found.dictionaryArray("items").contains { $0.string("uuid") == cap.part }, query)
        }
        let none = try XCTUnwrap(try result("search_pool", ["query": "4.7uF", "kind": "part"]) as? JSONDictionary)
        XCTAssertFalse(none.dictionaryArray("items").contains { $0.string("uuid") == cap.part })
    }

    // MARK: - Second round: debris, overlaps, notes, replayed dry runs

    func testDanglingWiringIsFoundAndPrunedEvenWhenItNamesANet() throws {
        _ = try placedMCU()
        try apply([["op": "terminate_pin", "component": "U1", "pin": "PA13(JTMS/SWDIO)"]])
        // A GND symbol on a stub to nowhere: the symbol gives it a live net.
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        try apply([["op": "ensure_net", "name": "GND", "is_power": true],
                   ["op": "place_junction", "id": a, "net": "GND", "x_mm": 50, "y_mm": 50],
                   ["op": "place_junction", "id": b, "net": "GND", "x_mm": 60, "y_mm": 50],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": a], "to": ["kind": "junction", "junction": b]],
                   ["op": "place_power_symbol", "net": "GND", "x_mm": 50, "y_mm": 50]])
        // A dead-end run off a pin: pin, junction, junction, nothing.
        let c = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased()
        try apply([["op": "place_junction", "id": c, "net": "SWCLK", "x_mm": 90, "y_mm": 97.46],
                   ["op": "place_junction", "id": d, "net": "SWCLK", "x_mm": 80, "y_mm": 97.46],
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "PA14"], "to": ["kind": "junction", "junction": c]],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": c], "to": ["kind": "junction", "junction": d]]])

        let found = try XCTUnwrap(try result("find_dangling") as? JSONDictionary)
        XCTAssertEqual(found.dictionary("totals")?.int("unanchored_islands"), 1)
        XCTAssertEqual(found.dictionary("totals")?.int("stubs"), 1)
        let island = try XCTUnwrap(found.dictionaryArray("sheets").first?.dictionaryArray("unanchored_islands").first)
        XCTAssertEqual(island["nets"] as? [String], ["GND"])
        XCTAssertEqual(island.dictionary("at")?.double("x_mm"), 50)
        // The run off the pin is one stub: both its wires and both junctions.
        let stub = try XCTUnwrap(found.dictionaryArray("sheets").first?.dictionaryArray("stubs").first)
        XCTAssertEqual((stub["net_lines"] as? [String])?.count, 2)
        XCTAssertEqual(Set(stub["junctions"] as? [String] ?? []), [c, d])
        XCTAssertEqual(stub["ends"] as? [String], [d])
        XCTAssertEqual(stub.dictionary("branches_from")?.string("pin_name"), "PA14")
        XCTAssertEqual(found.dictionary("totals")?.int("stub_net_lines"), 2)
        XCTAssertEqual(found.dictionary("totals")?.int("stub_junctions"), 2)

        // Plain prune keeps it: it names a live net.
        XCTAssertEqual(changes(try apply([["op": "prune_sheet"]])).first?.dictionary("removed")?.int("power_symbols"), 0)
        let pruned = try apply([["op": "prune_sheet", "unanchored": true, "stubs": true]])
        let removed = try XCTUnwrap(changes(pruned).first?.dictionary("removed"))
        XCTAssertEqual(removed.int("power_symbols"), 1)
        XCTAssertEqual(removed.int("net_lines"), 3, "the GND stub, and the dead-end run back to the pin")
        XCTAssertEqual(removed.int("junctions"), 4, "both junctions of each")
        XCTAssertEqual(removed.int("unanchored_islands"), 1)
        XCTAssertEqual(removed.int("stubs"), 1)
        XCTAssertEqual((try result("list_power_symbols") as? [JSONDictionary])?.count, 0)
        XCTAssertEqual((try result("list_net_labels") as? [JSONDictionary])?.count, 1, "wiring that reaches a pin stays")
        XCTAssertEqual((try result("list_net_lines") as? [JSONDictionary])?.count, 1)
        let clean = try XCTUnwrap(try result("find_dangling") as? JSONDictionary)
        XCTAssertEqual(clean.dictionaryArray("sheets").count, 0)
    }

    func testAStubIsTheWholeRunPruneWouldTake() throws {
        _ = try placedMCU()
        // A rail from the pin to a label, and two dead ends off one junction
        // on it: rail, corner, nothing; and a Y whose two arms go nowhere.
        let ids = (0..<7).map { _ in UUID().uuidString.lowercased() }
        let (rail, labelled, corner, end, fork, armA, armB) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5], ids[6])
        func junction(_ id: String, _ x: Double, _ y: Double) -> JSONDictionary {
            ["op": "place_junction", "id": id, "net": "SWCLK", "x_mm": x, "y_mm": y]
        }
        func wire(_ a: String, _ b: String) -> JSONDictionary {
            ["op": "draw_net_line", "from": ["kind": "junction", "junction": a], "to": ["kind": "junction", "junction": b]]
        }
        try apply([junction(rail, 90, 97.46), junction(labelled, 80, 97.46), junction(corner, 90, 110), junction(end, 95, 110),
                   junction(fork, 90, 85), junction(armA, 85, 80), junction(armB, 95, 80),
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "PA14"], "to": ["kind": "junction", "junction": rail]],
                   wire(rail, labelled), ["op": "place_net_label", "net": "SWCLK", "x_mm": 80, "y_mm": 97.46],
                   wire(rail, corner), wire(corner, end), wire(rail, fork), wire(fork, armA), wire(fork, armB)])

        let found = try XCTUnwrap(try result("find_dangling") as? JSONDictionary)
        let totals = try XCTUnwrap(found.dictionary("totals"))
        XCTAssertEqual(totals.int("stubs"), 2, "one per run, however many wires or ends it has")
        XCTAssertEqual(totals.int("stub_net_lines"), 5)
        XCTAssertEqual(totals.int("stub_junctions"), 5)
        let stubs = found.dictionaryArray("sheets").first?.dictionaryArray("stubs") ?? []
        XCTAssertEqual(Set(stubs.map { Set($0["junctions"] as? [String] ?? []) }), [[corner, end], [fork, armA, armB]])
        XCTAssertEqual(Set(stubs.map { Set($0["ends"] as? [String] ?? []) }), [[end], [armA, armB]])
        XCTAssertTrue(stubs.allSatisfy { $0.dictionary("branches_from")?.string("junction") == rail }, "both hang off the rail")

        // A dry run removes what find_dangling said, no more.
        let dry = try apply([["op": "prune_sheet", "stubs": true]], ["dry_run": true, "detail": "compact"])
        let removed = try XCTUnwrap(changes(dry).first?.dictionary("removed"))
        XCTAssertEqual(removed.int("net_lines"), 5)
        XCTAssertEqual(removed.int("junctions"), 5)
        XCTAssertEqual(removed.int("stubs"), 2)
        try apply([["op": "prune_sheet", "stubs": true]])
        XCTAssertEqual((try result("list_net_lines") as? [JSONDictionary])?.count, 2, "the rail stays")
        XCTAssertEqual((try result("find_dangling") as? JSONDictionary)?.dictionaryArray("sheets").count, 0)
    }

    func testAVerboseDryRunPreviewsPathsAndTextOnlyOnRequest() throws {
        let mcu = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "U9", "part": mcu.part]], ["pool_items": mcu.items])
        let ops: [JSONDictionary] = [["op": "set_value", "component": "U9", "value": "x"]]
        let full = try apply(ops, ["dry_run": true])
        let file = try XCTUnwrap(full.dictionaryArray("preview").first)
        XCTAssertNil(file["before"], "no file text unless asked")
        XCTAssertNil(file["after"])
        XCTAssertGreaterThan(file.int("after_bytes") ?? 0, 0)
        let changed = file["changed"] as? [String] ?? []
        XCTAssertTrue(changed.contains { $0.hasSuffix("/value") }, "\(file)")
        let text = try XCTUnwrap(try apply(ops, ["dry_run": true, "detail": "files"]).dictionaryArray("preview").first)
        XCTAssertTrue((text.string("after") ?? "").contains("\"x\""))
        XCTAssertTrue(try error(ops, ["dry_run": true, "detail": "everything"]).contains("compact, full or files"))
    }

    func testOverlapsFindWhatLooksConnectedAndIsNot() throws {
        _ = try placedMCU()
        // A wire running down the pin column, over three pins it does not end on.
        let top = UUID().uuidString.lowercased(), bottom = UUID().uuidString.lowercased()
        // A wire ending part way along another.
        let left = UUID().uuidString.lowercased(), right = UUID().uuidString.lowercased()
        let stem = UUID().uuidString.lowercased(), foot = UUID().uuidString.lowercased()
        try apply([["op": "place_junction", "id": top, "net": "SWDIO", "x_mm": 100, "y_mm": 95],
                   ["op": "place_junction", "id": bottom, "net": "SWDIO", "x_mm": 100, "y_mm": 85],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": top], "to": ["kind": "junction", "junction": bottom]],
                   ["op": "place_junction", "id": left, "net": "SWCLK", "x_mm": 120, "y_mm": 120],
                   ["op": "place_junction", "id": right, "net": "SWCLK", "x_mm": 140, "y_mm": 120],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": left], "to": ["kind": "junction", "junction": right]],
                   ["op": "place_junction", "id": stem, "net": "SWDIO", "x_mm": 130, "y_mm": 120],
                   ["op": "place_junction", "id": foot, "net": "SWDIO", "x_mm": 130, "y_mm": 130],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": stem], "to": ["kind": "junction", "junction": foot]]])
        // Two junctions on one spot that nothing joins: only a raw file says so.
        var archive = try HorizontalProjectArchive.snapshot(from: root)
        var schematic = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
        var sheets = schematic.dictionaryMap("sheets")
        let sheetID = try XCTUnwrap(sheets.keys.first)
        var junctions = sheets[sheetID]!.dictionaryMap("junctions")
        junctions[UUID().uuidString.lowercased()] = ["position": [70_000_000, 70_000_000]]
        junctions[UUID().uuidString.lowercased()] = ["position": [70_000_000, 70_000_000]]
        sheets[sheetID]?["junctions"] = junctions
        schematic["sheets"] = sheets
        try HorizontalSchematicClipboardEditor.write(schematic, path: "top_schematic.json", archive: &archive)
        try archive.write(to: root)
        _ = try result("reload_project")

        let found = try XCTUnwrap(try result("find_overlaps") as? JSONDictionary)
        let totals = try XCTUnwrap(found.dictionary("totals"))
        XCTAssertEqual(totals.int("wire_over_pin"), 3, "\(found)")
        XCTAssertEqual(totals.int("unjoined_junctions"), 1)
        XCTAssertEqual(totals.int("t_without_junction"), 1)
        let findings = found.dictionaryArray("sheets").first?.dictionaryArray("findings") ?? []
        XCTAssertTrue(findings.contains { $0.string("pin") == "U1 NRST" })
        let t = try XCTUnwrap(findings.first { $0.string("kind") == "t_without_junction" })
        XCTAssertEqual(t.bool("same_net"), false, "SWDIO meeting SWCLK with no junction")
    }

    func testNotesTravelWithTheirPartsAndSayWhichPartTheyAreBy() throws {
        _ = try placedMCU()
        let other = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "U2", "part": other.part],
                   ["op": "place_symbol", "component": "U2", "x_mm": 200, "y_mm": 100],
                   ["op": "place_text", "text": "U1 boots from flash", "x_mm": 110, "y_mm": 100],
                   ["op": "place_text", "text": "U2 note", "x_mm": 195, "y_mm": 100],
                   ["op": "place_text", "text": "Lost note", "x_mm": 20, "y_mm": 20]], ["pool_items": other.items])
        let texts = try XCTUnwrap(try result("list_texts") as? [JSONDictionary])
        let boot = try XCTUnwrap(texts.first { $0.string("text") == "U1 boots from flash" })
        XCTAssertEqual(boot.dictionary("near_symbol")?.string("refdes"), "U1")
        XCTAssertEqual(boot.dictionary("near_symbol")?.double("distance_mm") ?? 99, 10, accuracy: 0.01)
        let lost = try XCTUnwrap(texts.first { $0.string("text") == "Lost note" })
        XCTAssertGreaterThan(lost.dictionary("near_symbol")?.double("distance_mm") ?? 0, 80)

        let removed = try apply([["op": "remove_component", "component": "U1", "texts_within_mm": 50]])
        XCTAssertEqual((changes(removed).first?["texts_removed"] as? [String])?.count, 1)
        let left = try XCTUnwrap(try result("list_texts") as? [JSONDictionary]).compactMap { $0.string("text") }.sorted()
        XCTAssertEqual(left, ["Lost note", "U2 note"], "a note nearer another part, or near nothing, stays")
    }

    func testACommitReplayingItsDryRunReusesTheStagedEdit() throws {
        _ = try placedMCU()
        let ops: [JSONDictionary] = [["op": "ensure_net", "name": "SPARE"], ["op": "place_text", "text": "spare", "x_mm": 5, "y_mm": 5]]
        let preview = try apply(ops, ["dry_run": true, "detail": "compact"])
        let digest = try XCTUnwrap(preview.string("plan_digest"))
        XCTAssertNotNil(preview["timing"])
        let committed = try apply(ops, ["plan_digest": digest, "detail": "compact"])
        XCTAssertEqual(committed.dictionary("timing")?.bool("reused_dry_run"), true)
        XCTAssertNil(committed.dictionary("timing")?["load_ms"], "nothing was loaded twice")
        XCTAssertEqual((try result("list_texts") as? [JSONDictionary])?.contains { $0.string("text") == "spare" }, true)
        XCTAssertNotNil(try result("get_net", ["name": "SPARE"]))

        // Once the revision moves, a stale plan is not reused but redone, and
        // its digest no longer matches.
        let again = try apply([["op": "ensure_net", "name": "OTHER"]], ["dry_run": true])
        _ = try apply([["op": "ensure_net", "name": "THIRD"]])
        let stale = try call("apply", ["ops": [["op": "ensure_net", "name": "OTHER"]], "plan_digest": again["plan_digest"]!])
        XCTAssertNotNil(stale["error"])
    }

    func testVersionDescribesTheOpVocabulary() throws {
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "version", "params": [:] as JSONDictionary], in: session)
        let version = try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
        XCTAssertEqual(version.string("ops_digest"), HorizontalEditOperationKind.vocabularyDigest)
        XCTAssertEqual(version.int("ops"), HorizontalEditOperationKind.allCases.count)
    }

    /// Schematic symbols turn the other way when mirrored (Horizon's file
    /// convention). The stub must start where the renderer draws the pin.
    func testTerminatePinFollowsRotatedMirroredSymbols() throws {
        _ = try placedMCU()
        for (angle, mirror) in [(90.0, false), (270.0, true), (180.0, true), (90.0, true)] {
            try apply([["op": "place_symbol", "component": "U1", "angle_deg": angle, "mirror": mirror]])
            let change = try XCTUnwrap(changes(try apply([["op": "terminate_pin", "component": "U1", "pin": "NRST", "net": "RST", "create_net": true]])).first)
            let line = try XCTUnwrap((try result("list_net_lines", ["net": "RST"]) as? [JSONDictionary])?.first { $0.string("id") == change.string("net_line") })
            let from = try XCTUnwrap(line.dictionary("from_mm")), to = try XCTUnwrap(line.dictionary("to_mm"))
            let dx = (to.double("x_mm") ?? 0) - (from.double("x_mm") ?? 0), dy = (to.double("y_mm") ?? 0) - (from.double("y_mm") ?? 0)
            XCTAssertEqual(hypot(dx, dy), 2.54, accuracy: 1e-3, "angle \(angle) mirror \(mirror): \(line)")
            XCTAssertTrue(abs(dx) < 1e-6 || abs(dy) < 1e-6, "the stub runs straight out")
            let overlaps = try XCTUnwrap(try result("find_overlaps") as? JSONDictionary)
            XCTAssertEqual(overlaps.dictionary("totals")?.count ?? 0, 0, "angle \(angle) mirror \(mirror): \(overlaps)")
            try apply([["op": "remove_net_line", "line": change.string("net_line")!],
                       ["op": "remove_net_label", "id": change.string("net_label")!],
                       ["op": "disconnect", "component": "U1", "pin": "NRST"]])
        }
    }

    /// Rewrites one of the project's files the way another program would, and
    /// reloads, so a test can start from what a real project holds.
    private func rewrite(_ file: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        let url = root.appendingPathComponent(file)
        var json = try JSONHelper.loadDictionary(from: url)
        try body(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        _ = try result("reload_project")
    }

    func testABatchNamesWhatItMakesAndUsesTheNames() throws {
        _ = try placedMCU()
        let ops: [JSONDictionary] = [
            ["op": "place_junction", "id": "j1", "net": "SWDIO", "x_mm": 90, "y_mm": 100],
            ["op": "place_junction", "id": "j2", "net": "SWDIO", "x_mm": 90, "y_mm": 95],
            ["op": "draw_net_line", "id": "w1", "from": ["kind": "pin", "component": "U1", "pin": "PA13(JTMS/SWDIO)"],
             "to": ["kind": "junction", "junction": "j1"]],
            ["op": "draw_net_line", "id": "w2", "from": ["kind": "junction", "junction": "j1"], "to": ["kind": "junction", "junction": "j2"]],
            // A junction called SWDIO is a junction's name; the net keeps its own.
            ["op": "place_junction", "id": "SWDIO", "net": "SWDIO", "x_mm": 90, "y_mm": 90],
            ["op": "place_junction", "id": "j3", "net": "SWDIO", "x_mm": 85, "y_mm": 90]
        ]
        let preview = try apply(ops, ["dry_run": true])
        let handles = try XCTUnwrap(preview["handles"] as? [String: String], "\(preview)")
        XCTAssertEqual(Set(handles.keys), ["j1", "j2", "j3", "w1", "w2", "SWDIO"])
        XCTAssertTrue(handles.values.allSatisfy { UUID(uuidString: $0) != nil })
        let normalized = try XCTUnwrap(preview["normalized_ops"] as? [JSONDictionary])
        XCTAssertEqual(normalized[3].dictionary("from")?.string("junction"), handles["j1"])
        XCTAssertEqual(normalized[2].string("id"), handles["w1"])
        XCTAssertEqual(normalized[5].string("net"), "SWDIO", "a junction's name leaves nets alone")

        // Another dry run in between, so the commit cannot reuse the staged
        // plan. It still matches it: at one revision a name is one UUID. (An
        // op given no id at all still gets a fresh one each time.)
        _ = try apply([["op": "ensure_net", "name": "OTHER"]], ["dry_run": true])
        let committed = try apply(ops, ["plan_digest": try XCTUnwrap(preview.string("plan_digest"))])
        XCTAssertNil(committed.dictionary("timing")?["reused_dry_run"])
        XCTAssertEqual(committed["handles"] as? [String: String], handles)
        let junctions = Set((try result("list_junctions") as? [JSONDictionary] ?? []).compactMap { $0.string("id") })
        XCTAssertTrue(junctions.isSuperset(of: [handles["j1"]!, handles["j2"]!, handles["SWDIO"]!]), "\(junctions)")
        XCTAssertTrue((try result("list_net_lines") as? [JSONDictionary] ?? []).contains { $0.string("id") == handles["w1"] })

        // One name, one thing.
        let clash = try error([["op": "place_junction", "id": "x", "net": "SWDIO", "x_mm": 70, "y_mm": 70],
                               ["op": "draw_net_line", "id": "x", "from": ["kind": "junction", "junction": "x"],
                                "to": ["kind": "junction", "junction": handles["j2"]!]]])
        XCTAssertTrue(clash.hasPrefix("ops[1] draw_net_line: ") && clash.contains("already names"), clash)
    }

    func testAFailingOpIsNamedByItsPlaceInTheBatch() throws {
        let response = try call("apply", ["ops": [["op": "ensure_net", "name": "A"],
                                                   ["op": "place_junction", "net": "NOPE", "x_mm": 1, "y_mm": 1]]])
        let failure = try XCTUnwrap(response["error"] as? JSONDictionary)
        XCTAssertTrue(failure.string("message")?.hasPrefix("ops[1] place_junction: ") == true, "\(failure)")
        let details = failure.dictionary("data")?.dictionary("details")
        XCTAssertEqual(details?.int("op_index"), 1)
        XCTAssertEqual(details?.string("op"), "place_junction")
        // An op the engine cannot read is placed too, before anything runs.
        let unread = try error([["op": "ensure_net", "name": "B"], ["op": "set_value", "component": "X", "valu": "1"]])
        XCTAssertTrue(unread.hasPrefix("ops[1] set_value: "), unread)
    }

    func testProjectMetaReachesTheBlockAndTheSchematicsCopies() throws {
        // A project that also keeps its title in the schematic, once for the
        // whole schematic and once on a sheet, as older Horizon files do.
        try rewrite("top_schematic.json") { json in
            json["title_block_values"] = ["project_title": "Roxanne", "author": "T"]
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let id = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[id] as? JSONDictionary)
            sheet["title_block_values"] = ["project_title": "Roxanne"]
            sheets[id] = sheet
            json["sheets"] = sheets
        }
        let change = try XCTUnwrap(changes(try apply([["op": "set_project_meta",
                                                        "values": ["project_title": "Billo", "rev": " 2A ", "author": NSNull()]]])).first)
        XCTAssertEqual(change["changed"] as? [String], ["author", "project_title", "rev"])
        XCTAssertEqual((change["schematic_copies"] as? [String])?.count, 2)

        let block = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_block.json"))
        XCTAssertEqual(block.dictionary("project_meta") as? [String: String], ["project_title": "Billo", "rev": "2A"])
        let schematic = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_schematic.json"))
        let copy = schematic.dictionary("title_block_values")
        XCTAssertEqual(copy?.string("project_title"), "Billo")
        XCTAssertNil(copy?["author"], "removed from the copy as well")
        XCTAssertNil(copy?["rev"], "a copy is changed, not added to")
        XCTAssertEqual(schematic.dictionaryMap("sheets").values.first?.dictionary("title_block_values")?.string("project_title"), "Billo")
        XCTAssertEqual(try session.entry(handle: handle).project.projectMeta["project_title"], "Billo")

        XCTAssertTrue(try error([["op": "set_project_meta", "values": ["rev": 2]]]).contains("must be a string"))
        XCTAssertTrue(try error([["op": "set_project_meta", "values": ["$rev": "2"]]]).contains("not a title-block key"))
    }

    func testExportSettingsChangeOnlyFieldsTheyHold() throws {
        let none = try XCTUnwrap(try result("export_settings") as? JSONDictionary)
        XCTAssertTrue(none.dictionary("odb")?["settings"] is NSNull, "\(none)")
        XCTAssertEqual(none.count, 7)
        XCTAssertTrue(try error([["op": "set_export_settings", "kind": "odb", "fields": ["output_filename": "x.zip"]]])
            .contains("keeps no odb settings"))

        try rewrite("board.json") {
            $0["odb_output_settings"] = ["format": "zip", "job_name": "", "output_directory": "",
                                         "output_filename": "Roxanne Fabrication/Roxanne ODB.zip"]
        }
        try rewrite("top_block.json") {
            $0["bom_export_settings"] = ["include_nopopulate": false, "output_filename": "Roxanne BOM.csv",
                                         "csv_settings": ["order": "asc"]]
        }
        let applied = try apply([
            ["op": "set_export_settings", "kind": "odb", "fields": ["output_filename": "Billo Fabrication/Billo ODB.zip"]],
            ["op": "set_export_settings", "kind": "bom", "fields": ["output_filename": "Billo BOM.csv", "include_nopopulate": true]]
        ])
        XCTAssertEqual(changes(applied).first?["changed"] as? [String], ["output_filename"])
        let odb = try XCTUnwrap(try result("export_settings", ["kind": "odb"]) as? JSONDictionary)
        XCTAssertEqual(odb.count, 1)
        XCTAssertEqual(odb.dictionary("odb")?.dictionary("settings")?.string("output_filename"), "Billo Fabrication/Billo ODB.zip")
        let bom = (try result("export_settings", ["kind": "bom"]) as? JSONDictionary)?.dictionary("bom")?.dictionary("settings")
        XCTAssertEqual(bom?.bool("include_nopopulate"), true)
        XCTAssertEqual(bom?.dictionary("csv_settings")?.string("order"), "asc", "fields left out stay")

        // Horizon reads these back strictly: no new fields, no changed types.
        XCTAssertTrue(try error([["op": "set_export_settings", "kind": "odb", "fields": ["output_name": "x"]]]).contains("no field output_name"))
        XCTAssertTrue(try error([["op": "set_export_settings", "kind": "bom", "fields": ["include_nopopulate": "yes"]]]).contains("true or false"))
        XCTAssertTrue(try error([["op": "set_export_settings", "kind": "plots", "fields": ["a": 1]]]).contains("Known: gerber"))
    }

    func testTextListsLeaveSmashedTextsOutUnlessAsked() throws {
        try apply([["op": "place_board_text", "text": "$project_title", "layer": 20, "x_mm": 0, "y_mm": 0],
                   ["op": "place_board_text", "text": "R1", "layer": 20, "x_mm": 5, "y_mm": 0]])
        let before = try XCTUnwrap(try result("list_board_texts") as? [JSONDictionary])
        let refdes = try XCTUnwrap(before.first { $0.string("text") == "R1" }?.string("id"))
        try rewrite("board.json") { json in
            var texts = try XCTUnwrap(json["texts"] as? JSONDictionary)
            var item = try XCTUnwrap(texts[refdes] as? JSONDictionary)
            item["from_smash"] = true
            texts[refdes] = item
            json["texts"] = texts
        }
        XCTAssertEqual((try result("list_board_texts") as? [JSONDictionary])?.map { $0.string("text") }, ["$project_title"])
        XCTAssertEqual((try result("list_board_texts", ["smashed": true]) as? [JSONDictionary])?.count, 2)
        XCTAssertEqual((try result("list_board_texts", ["smashed": true, "text": "r1"]) as? [JSONDictionary])?.first?.bool("from_smash"), true)
        XCTAssertEqual((try result("list_board_texts", ["text": "PROJECT"]) as? [JSONDictionary])?.count, 1)
        XCTAssertNotNil(try call("list_board_texts", ["smashed": "yes"])["error"])
    }

    // MARK: - Round six: notes 17–20

    /// A smashed text stores "$RD" and named its part only by package UUID,
    /// so asking for U1's silkscreen reference found nothing.
    func testSmashedTextsNameTheirPartAndListWhatTheyDraw() throws {
        let (_, instance) = try placedMCU()
        try apply([["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10],
                   ["op": "set_project_meta", "values": ["project_title": "Billo"]],
                   ["op": "place_board_text", "text": "$project_title", "layer": 20, "x_mm": 0, "y_mm": -5]])
        // Smash U1 as Horizon does: its reference becomes a board text, and
        // the package lists it.
        let smashedID = UUID().uuidString.lowercased()
        var packageID = ""
        try rewrite("board.json") { json in
            var packages = try XCTUnwrap(json["packages"] as? JSONDictionary)
            packageID = try XCTUnwrap(packages.keys.first)
            var package = try XCTUnwrap(packages[packageID] as? JSONDictionary)
            package["smashed"] = true
            package["texts"] = [smashedID]
            packages[packageID] = package
            json["packages"] = packages
            var texts = json["texts"] as? JSONDictionary ?? [:]
            texts[smashedID] = ["from_smash": true, "text": "$RD", "layer": 20, "origin": "center", "font": "simplex",
                                "size": 1_000_000, "width": 150_000,
                                "placement": ["angle": 0, "mirror": false, "shift": [10_000_000, 12_000_000]]]
            json["texts"] = texts
        }

        let free = try XCTUnwrap(try result("list_board_texts") as? [JSONDictionary])
        XCTAssertEqual(free.map { $0.string("drawn") }, ["Billo"], "\(free)")
        let part = try XCTUnwrap(try result("list_board_texts", ["component": "u1"]) as? [JSONDictionary])
        XCTAssertEqual(part.count, 1, "\(part)")
        XCTAssertEqual(part.first?.string("id"), smashedID)
        XCTAssertEqual(part.first?.string("refdes"), "U1")
        XCTAssertEqual(part.first?.string("drawn"), "U1")
        XCTAssertEqual(part.first?.string("package"), packageID)
        XCTAssertEqual((try result("list_board_texts", ["smashed": true, "text": "U1"]) as? [JSONDictionary])?.map { $0.string("id") }, [smashedID],
                       "text matches what is drawn as well as what is stored")
        XCTAssertEqual((try result("list_board_texts", ["text": "billo"]) as? [JSONDictionary])?.count, 1)
        XCTAssertNotNil(try call("list_board_texts", ["component": "U9"])["error"])

        // The same on a sheet, where a smashed symbol keeps "$REFDES".
        let textID = UUID().uuidString.lowercased()
        try rewrite("top_schematic.json") { json in
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let sheetID = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
            var symbols = try XCTUnwrap(sheet["symbols"] as? JSONDictionary)
            var symbol = try XCTUnwrap(symbols[instance] as? JSONDictionary)
            symbol["smashed"] = true
            symbol["texts"] = [textID]
            symbols[instance] = symbol
            sheet["symbols"] = symbols
            var texts = sheet["texts"] as? JSONDictionary ?? [:]
            texts[textID] = ["from_smash": true, "text": "$REFDES", "origin": "center", "font": "simplex", "size": 1_500_000,
                             "width": 0, "placement": ["angle": 0, "mirror": false, "shift": [100_000_000, 105_000_000]]]
            sheet["texts"] = texts
            sheets[sheetID] = sheet
            json["sheets"] = sheets
        }
        let symbolTexts = try XCTUnwrap(try result("list_texts", ["component": "U1"]) as? [JSONDictionary])
        XCTAssertEqual(symbolTexts.map { $0.string("id") }, [textID], "\(symbolTexts)")
        XCTAssertEqual(symbolTexts.first?.string("refdes"), "U1")
        XCTAssertEqual(symbolTexts.first?.string("drawn"), "U1")
        XCTAssertEqual(symbolTexts.first?.string("symbol"), instance)
        XCTAssertEqual((try result("list_texts") as? [JSONDictionary])?.count, 0, "still free text only by default")
    }

    /// The app's own edits wrote files as Foundation pretty-prints them
    /// ("key" : value, two spaces) and an MCP edit writes them as Horizon
    /// does, so a file flipped format with whichever wrote it last: on Billo,
    /// 12,380 lines of diff for a three-field change.
    func testTheAppsOwnEditsWriteFilesAsHorizonDoes() throws {
        try apply([["op": "set_project_meta", "values": ["project_title": "Roxanne", "rev": "1B"]]])
        let before = try Data(contentsOf: root.appendingPathComponent("top_block.json"))
        var archive = try HorizontalProjectArchive.completeProject(from: root)
        try HorizontalProjectJSONApplicator.apply(titleBlockChanges: HorizontalTitleBlockChanges(key: "project_title", value: "Billo"),
                                                  in: try session.entry(handle: handle).project, to: &archive)
        let after = try XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))
        XCTAssertEqual(after, try HorizontalHorizonJSONWriter.data(JSONHelper.loadDictionary(from: after)))
        let old = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: after, as: UTF8.self).components(separatedBy: "\n")
        XCTAssertEqual(old.count, new.count)
        XCTAssertEqual(zip(old, new).filter { $0 != $1 }.map(\.1), ["        \"project_title\": \"Billo\","])
    }

    /// place_text took its id as a text to edit, so a batch could not name a
    /// new one; and an op over a name whose thing an earlier op had taken away
    /// said only "No junction <uuid>".
    func testATextCanBeNamedAndAGoneHandleSaysWhatTookIt() throws {
        _ = try placedMCU()
        let made = try apply([
            ["op": "place_text", "id": "t1", "text": "draft", "x_mm": 20, "y_mm": 20],
            ["op": "place_text", "id": "t1", "text": "final"],
            ["op": "place_text", "id": "t2", "text": "gone", "x_mm": 30, "y_mm": 20],
            ["op": "remove_text", "id": "t2"],
            ["op": "place_board_text", "id": "b1", "text": "R1", "layer": 20, "x_mm": 1, "y_mm": 1],
            ["op": "place_board_text", "id": "b1", "x_mm": 2, "y_mm": 1]
        ])
        let handles = try XCTUnwrap(made["handles"] as? [String: String], "\(made)")
        XCTAssertEqual(Set(handles.keys), ["t1", "t2", "b1"])
        XCTAssertEqual(changes(made).map { $0.bool("created") }, [true, false, true, nil, true, false])
        let texts = try XCTUnwrap(try result("list_texts") as? [JSONDictionary])
        XCTAssertEqual(texts.map { $0.string("id") }, [handles["t1"]])
        XCTAssertEqual(texts.first?.string("text"), "final")
        let board = try XCTUnwrap(try result("list_board_texts") as? [JSONDictionary])
        XCTAssertEqual(board.map { $0.string("id") }, [handles["b1"]])
        XCTAssertEqual(board.first?.double("x_mm"), 2)
        // A mistyped id on a move still finds nothing rather than making a text.
        XCTAssertTrue(try error([["op": "place_text", "id": UUID().uuidString, "x_mm": 1, "y_mm": 1]]).contains("No text"))

        // Removing a wire takes the junctions it leaves bare with it.
        let response = try call("apply", ["ops": [
            ["op": "place_junction", "id": "j1", "net": "SWDIO", "x_mm": 20, "y_mm": 40],
            ["op": "place_junction", "id": "j2", "net": "SWDIO", "x_mm": 30, "y_mm": 40],
            ["op": "draw_net_line", "id": "w1", "from": ["kind": "junction", "junction": "j1"], "to": ["kind": "junction", "junction": "j2"]],
            ["op": "remove_net_line", "line": "w1"],
            ["op": "remove_junction", "junction": "j2"]
        ], "dry_run": true])
        let failure = try XCTUnwrap(response["error"] as? JSONDictionary, "\(response)")
        let message = try XCTUnwrap(failure.string("message"))
        XCTAssertTrue(message.hasPrefix("ops[4] remove_junction: No junction j2 ("), message)
        XCTAssertTrue(message.hasSuffix("ops[3] remove_net_line removed it earlier in this batch."), message)
        let details = failure.dictionary("data")?.dictionary("details")
        XCTAssertEqual(details?.string("handle"), "j2")
        XCTAssertEqual(details?.int("removed_by"), 3)
    }

    // MARK: - Round seven: notes 24–25

    /// On Billo a search for "U1" found nothing: U1's reference is a smashed
    /// text, and those were left out of a search unless smashed was passed too.
    func testATextSearchLooksThroughSmashedTexts() throws {
        let made = try apply([
            ["op": "place_board_text", "id": "note", "text": "R1 sets the gain", "layer": 20, "x_mm": 0, "y_mm": 0],
            ["op": "place_board_text", "id": "ref", "text": "R1", "layer": 20, "x_mm": 5, "y_mm": 0],
            ["op": "place_text", "id": "sheetNote", "text": "R1 sets the gain", "x_mm": 20, "y_mm": 20],
            ["op": "place_text", "id": "sheetRef", "text": "R1", "x_mm": 30, "y_mm": 20]
        ])
        let handles = try XCTUnwrap(made["handles"] as? [String: String])
        // Mark the bare references smashed, as Horizon leaves a part's.
        func smash(_ texts: inout JSONDictionary, _ id: String) throws {
            var item = try XCTUnwrap(texts[id] as? JSONDictionary)
            item["from_smash"] = true
            texts[id] = item
        }
        try rewrite("board.json") { json in
            var texts = try XCTUnwrap(json["texts"] as? JSONDictionary)
            try smash(&texts, try XCTUnwrap(handles["ref"]))
            json["texts"] = texts
        }
        try rewrite("top_schematic.json") { json in
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let sheetID = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
            var texts = try XCTUnwrap(sheet["texts"] as? JSONDictionary)
            try smash(&texts, try XCTUnwrap(handles["sheetRef"]))
            sheet["texts"] = texts
            sheets[sheetID] = sheet
            json["sheets"] = sheets
        }
        func ids(_ method: String, _ args: JSONDictionary = [:]) throws -> Set<String> {
            Set(try XCTUnwrap(try result(method, args) as? [JSONDictionary]).compactMap { $0.string("id") })
        }
        for (method, note, ref) in [("list_board_texts", "note", "ref"), ("list_texts", "sheetNote", "sheetRef")] {
            let note = try XCTUnwrap(handles[note]), ref = try XCTUnwrap(handles[ref])
            XCTAssertEqual(try ids(method), [note], "\(method): free text only by default")
            XCTAssertEqual(try ids(method, ["text": "r1"]), [note, ref], "\(method): a search looks through smashed texts")
            XCTAssertEqual(try ids(method, ["text": "r1", "smashed": false]), [note], "\(method): unless told not to")
            XCTAssertEqual(try ids(method, ["smashed": true]), [note, ref], method)
        }
    }

    /// Moving one text in the app and saving also wrote Billo's 15
    /// no-connects as {} — Horizon EDA reads "net" with at(), so it would
    /// drop them — gave all 64 wires on the sheet a net, and added
    /// grid_settings and allow_upside_down: false. Horizon writes none of that.
    func testAnInAppSaveChangesOnlyWhatItsEditChanged() throws {
        _ = try placedMCU()
        let made = try apply([
            ["op": "set_no_connect", "component": "U1", "pins": ["NRST"]],
            ["op": "place_junction", "id": "j1", "net": "SWCLK", "x_mm": 90, "y_mm": 97.46],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "U1", "pin": "PA14"], "to": ["kind": "junction", "junction": "j1"]],
            ["op": "place_text", "id": "t1", "text": "note", "x_mm": 20, "y_mm": 20]
        ])
        let textID = try XCTUnwrap((made["handles"] as? [String: String])?["t1"])
        // The files as the 18:23 save left Billo: wires without a net, as
        // Horizon writes them, a grid an earlier save added, and the
        // no-connect written as {}.
        var noConnect = ""
        try rewrite("top_schematic.json") { json in
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let sheetID = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
            var lines = try XCTUnwrap(sheet["net_lines"] as? JSONDictionary)
            XCTAssertFalse(lines.isEmpty)
            for (id, line) in lines { lines[id] = (line as? JSONDictionary)?.filter { $0.key != "net" } }
            sheet["net_lines"] = lines
            sheets[sheetID] = sheet
            json["sheets"] = sheets
            json["grid_settings"] = ["current": ["mode": "square", "name": "", "origin": [0, 0],
                                                 "spacing_rect": [1_250_000, 1_250_000], "spacing_square": 1_250_000],
                                     "grids": JSONDictionary()]
        }
        try rewrite("top_block.json") { json in
            var components = try XCTUnwrap(json["components"] as? JSONDictionary)
            for (id, value) in components {
                var component = try XCTUnwrap(value as? JSONDictionary)
                var connections = component["connections"] as? JSONDictionary ?? [:]
                for (path, connection) in connections where (connection as? JSONDictionary)?["net"] is NSNull {
                    noConnect = path
                    connections[path] = JSONDictionary()
                }
                component["connections"] = connections
                components[id] = component
            }
            json["components"] = components
        }
        XCTAssertFalse(noConnect.isEmpty, "set_no_connect writes a null net")
        let schematicBefore = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_schematic.json"))
        let blockBefore = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_block.json"))

        let project = try session.entry(handle: handle).project
        let schematic = try XCTUnwrap(project.schematic)
        var sheet = try XCTUnwrap(schematic.sheets.first)
        let index = try XCTUnwrap(sheet.texts.firstIndex { $0.id.lowercased() == textID.lowercased() })
        sheet.texts[index].position.x += 1_250_000
        var archive = try HorizontalProjectArchive.completeProject(from: root)
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematic.url, in: project, to: &archive)
        let schematicAfter = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        let blockAfter = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json")))

        // The block changes only where it had drifted: the no-connect gets its null net back.
        var expectedBlock = blockBefore
        var components = try XCTUnwrap(expectedBlock["components"] as? JSONDictionary)
        for (id, value) in components {
            var component = try XCTUnwrap(value as? JSONDictionary)
            var connections = component["connections"] as? JSONDictionary ?? [:]
            if connections[noConnect] != nil { connections[noConnect] = ["net": NSNull()] }
            component["connections"] = connections
            components[id] = component
        }
        expectedBlock["components"] = components
        XCTAssertEqual(blockAfter as NSDictionary, expectedBlock as NSDictionary)

        // The schematic: the text moved a grid step, and the grid is gone.
        var expectedSchematic = schematicBefore
        expectedSchematic.removeValue(forKey: "grid_settings")
        var sheets = try XCTUnwrap(expectedSchematic["sheets"] as? JSONDictionary)
        let sheetKey = try XCTUnwrap(sheets.keys.first)
        var sheetJSON = try XCTUnwrap(sheets[sheetKey] as? JSONDictionary)
        var texts = try XCTUnwrap(sheetJSON["texts"] as? JSONDictionary)
        let textKey = try XCTUnwrap(texts.keys.first { $0.lowercased() == textID.lowercased() })
        var text = try XCTUnwrap(texts[textKey] as? JSONDictionary)
        var placement = try XCTUnwrap(text["placement"] as? JSONDictionary)
        var shift = try XCTUnwrap(placement["shift"] as? [Any])
        shift[0] = JSONHelper.doubleValue(shift[0]) + 1_250_000
        placement["shift"] = shift
        text["placement"] = placement
        texts[textKey] = text
        sheetJSON["texts"] = texts
        sheets[sheetKey] = sheetJSON
        expectedSchematic["sheets"] = sheets
        XCTAssertEqual(schematicAfter as NSDictionary, expectedSchematic as NSDictionary)

        // allow_upside_down is written as Horizon writes it: only when set.
        sheet.texts[index].allowUpsideDown = true
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematic.url, in: project, to: &archive)
        let flipped = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        let flippedText = flipped.dictionary("sheets")?.dictionary(sheetKey)?.dictionary("texts")?.dictionary(textKey)
        XCTAssertEqual(flippedText?.bool("allow_upside_down"), true)
    }

    // MARK: - Round eight: notes 27–28

    /// Putting Billo's "Amplifier" back needed a text moved where it was.
    /// place_text with the text's id does that, but nothing apply_ops showed
    /// said so, and for a text that was there, x_mm without y_mm was dropped
    /// without a word.
    func testAnExistingTextMovesInPlaceOnEitherAxis() throws {
        let made = try apply([
            ["op": "place_text", "id": "note", "text": "Amplifier", "x_mm": 178.75, "y_mm": 137.5, "size_mm": 2],
            ["op": "place_board_text", "id": "silk", "text": "REV", "layer": 20, "x_mm": 1, "y_mm": 1]
        ])
        let handles = try XCTUnwrap(made["handles"] as? [String: String])
        let note = try XCTUnwrap(handles["note"]), silk = try XCTUnwrap(handles["silk"])
        func sheetText() throws -> JSONDictionary {
            let json = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_schematic.json"))
            let sheet = try XCTUnwrap(json.dictionary("sheets")?.values.first as? JSONDictionary)
            return try XCTUnwrap(sheet.dictionary("texts")?.dictionary(note))
        }
        // Horizon writes "layer": 0 on every sheet text; a move keeps it.
        try rewrite("top_schematic.json") { json in
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let sheetID = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
            var texts = try XCTUnwrap(sheet["texts"] as? JSONDictionary)
            var text = try XCTUnwrap(texts[note] as? JSONDictionary)
            text["layer"] = 0
            texts[note] = text
            sheet["texts"] = texts
            sheets[sheetID] = sheet
            json["sheets"] = sheets
        }
        var expected = try sheetText()

        let moved = try apply([
            ["op": "place_text", "id": note, "x_mm": 181.25],
            ["op": "place_board_text", "id": silk, "y_mm": 3]
        ])
        XCTAssertEqual(changes(moved).map { $0.bool("created") }, [false, false])
        XCTAssertEqual(changes(moved).map { $0.double("x_mm") }, [181.25, 1], "The reply says where each text is now")
        XCTAssertEqual(changes(moved).map { $0.double("y_mm") }, [137.5, 3])
        // Only the shift changed: same uuid, text, size and layer.
        var placement = try XCTUnwrap(expected["placement"] as? JSONDictionary)
        placement["shift"] = [181_250_000, 137_500_000]
        expected["placement"] = placement
        XCTAssertEqual(try sheetText() as NSDictionary, expected as NSDictionary)
        let board = try XCTUnwrap(try result("list_board_texts") as? [JSONDictionary])
        XCTAssertEqual(board.map { $0.string("id") }, [silk])
        XCTAssertEqual(board.first?.double("x_mm"), 1)
        XCTAssertEqual(board.first?.double("y_mm"), 3)
        XCTAssertEqual(board.first?.int("layer"), 20)

        // A new text still needs both coordinates.
        XCTAssertTrue(try error([["op": "place_text", "text": "half", "x_mm": 1]]).contains("needs \"x_mm\" and \"y_mm\""))
        XCTAssertTrue(try error([["op": "place_board_text", "text": "half", "layer": 20, "y_mm": 1]])
            .contains("needs \"x_mm\" and \"y_mm\""))
    }

    /// The op summaries an agent reads say that place_text and
    /// place_board_text move a text that is there.
    func testTheTextOpsSayTheyMoveATextThatIsThere() {
        for op in [HorizontalEditOperationKind.placeText, .placeBoardText] {
            XCTAssertTrue(op.summary.contains("x_mm, y_mm or both move it"), "\(op.rawValue): \(op.summary)")
            XCTAssertTrue(op.params["x_mm"]?.contains("either alone moves it") == true, op.rawValue)
        }
    }

    // MARK: - Round nine: notes 21–23, 26

    /// Five of Billo's notes, written by place_text, had no "layer"; Horizon
    /// writes "layer": 0 on every sheet text and adds it on its next save.
    func testASheetTextIsWrittenWithTheKeysHorizonWrites() throws {
        let made = try apply([["op": "place_text", "id": "note", "text": "note", "x_mm": 20, "y_mm": 20]])
        let note = try XCTUnwrap((made["handles"] as? [String: String])?["note"])
        func stored() throws -> JSONDictionary {
            let json = try JSONHelper.loadDictionary(from: root.appendingPathComponent("top_schematic.json"))
            let sheet = try XCTUnwrap(json.dictionary("sheets")?.values.first as? JSONDictionary)
            return try XCTUnwrap(sheet.dictionary("texts")?.dictionary(note))
        }
        XCTAssertEqual(Set(try stored().keys), ["font", "from_smash", "layer", "origin", "placement", "size", "text", "width"])
        XCTAssertEqual(try stored().int("layer"), 0)

        // A text an earlier place_text left without one gets it when touched,
        // and nothing else about it changes.
        try rewrite("top_schematic.json") { json in
            var sheets = try XCTUnwrap(json["sheets"] as? JSONDictionary)
            let sheetID = try XCTUnwrap(sheets.keys.first)
            var sheet = try XCTUnwrap(sheets[sheetID] as? JSONDictionary)
            var texts = try XCTUnwrap(sheet["texts"] as? JSONDictionary)
            var text = try XCTUnwrap(texts[note] as? JSONDictionary)
            text.removeValue(forKey: "layer")
            texts[note] = text
            sheet["texts"] = texts
            sheets[sheetID] = sheet
            json["sheets"] = sheets
        }
        var expected = try stored()
        XCTAssertNil(expected["layer"])
        _ = try apply([["op": "place_text", "id": note]])
        expected["layer"] = 0
        XCTAssertEqual(try stored() as NSDictionary, expected as NSDictionary)
    }

    /// A safe save's leftover is named for the file it replaced, and said to
    /// match it or not; another file's, or an ordinary sibling, is not one.
    func testSafeSaveLeftoversAreTheProjectFilesOwn() throws {
        let folder = root.appendingPathComponent("leftovers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = folder.appendingPathComponent("Billo.hprj")
        try Data("{}".utf8).write(to: project)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("Billo.hprj.sb-ec53240b-ZysDK4"))
        try Data("{\"old\":1}".utf8).write(to: folder.appendingPathComponent("Billo.hprj.sb-0badf00d-AbCdEf"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("board.json.sb-12345678-QwErTy"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("top_block.json"))
        let found = HorizontalDispatchMethods.safeSaveLeftovers(of: project)
        XCTAssertEqual(found.map { $0.string("name") }, ["Billo.hprj.sb-0badf00d-AbCdEf", "Billo.hprj.sb-ec53240b-ZysDK4"])
        XCTAssertEqual(found.map { $0.bool("same_as_file") }, [false, true])
        XCTAssertTrue(HorizontalDispatchMethods.safeSaveLeftovers(of: folder.appendingPathComponent("none.hprj")).isEmpty)
    }

    /// The airwire pass tested every node of a poured net against every
    /// vertex of the pour — on Billo, 1.7 s of each 4.5 s dry run. Boxes and
    /// height bands cut that without changing a single answer.
    func testPlanePathContainmentMatchesTheOutlineTest() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ range: ClosedRange<Double>) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        // On a half-unit grid, so points fall on vertex heights and edges.
        func snapped(_ value: Double) -> Double { (value * 2).rounded() / 2 }
        for trial in 0..<24 {
            let count = 3 + trial * 23
            let points = (0..<count).map { index -> HorizontalPoint in
                let angle = Double(index) / Double(count) * 2 * .pi
                let radius = random(4...12)
                return HorizontalPoint(x: snapped(radius * cos(angle)), y: snapped(radius * sin(angle)))
            }
            let path = HorizontalBoard.PlanePath(points)
            for point in points + (0..<1_500).map({ _ in HorizontalPoint(x: snapped(random(-14...14)), y: snapped(random(-14...14))) }) {
                XCTAssertEqual(path.contains(point), HorizontalBoardOutlines.contains(point, in: points), "\(count) vertices at \(point)")
            }
        }
    }
}
