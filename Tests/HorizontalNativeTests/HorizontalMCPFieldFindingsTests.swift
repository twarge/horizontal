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
}
