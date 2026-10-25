import Foundation
import ImageIO
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// MCP field findings 44: what editing Cinnamon and Billo through MCP on
/// October 14 and 17 turned up (items 102–135 in billo's notes).
final class HorizontalMCPFieldFindings44Tests: XCTestCase {
    private struct Part {
        var items: [JSONDictionary]
        var part: String
        var gate: String
        var pins: [String]
        var pads: [String]
        var padstack: String
    }

    /// A one-gate part whose pins run down the symbol's left edge pointing
    /// left, 2.54 mm apart, and whose pads run up the package 2 mm apart,
    /// named "1", "2", ….
    private func part(_ names: [String], unpinnedPads: [String] = []) -> Part {
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = (names + unpinnedPads).map { _ in UUID().uuidString.lowercased() }
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
            package.pads[pads[i]] = HorizontalPad(id: pads[i], name: i < names.count ? String(i + 1) : unpinnedPads[i - names.count], padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: Double(i) * 2_000_000), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        for i in pins.indices { part.padMap[pads[i]] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[i]) }
        return Part(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                    part: part.uuid, gate: gate, pins: pins, pads: pads, padstack: padstack.uuid)
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("field44-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        session = HorizontalDispatchSession()
        handle = try session.open(url: root).handle
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func call(_ method: String, _ args: JSONDictionary = [:], guarded: Bool = true) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        let entry = try session.entry(handle: handle)
        if guarded, ["apply", "pool_write"].contains(method) {
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

    private func rewrite(_ file: String, _ body: (inout JSONDictionary) throws -> Void) throws {
        let url = root.appendingPathComponent(file)
        var json = try JSONHelper.loadDictionary(from: url)
        try body(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        _ = try result("reload_project")
    }

    private func read(_ file: String) throws -> JSONDictionary {
        try JSONHelper.loadDictionary(from: root.appendingPathComponent(file))
    }

    // MARK: - 113, 114: an unnamed net and a short id

    func testAShortIDNamesAnUnnamedNetAndAComponent() throws {
        let resistor = part(["A", "B"])
        let net = "33b623e6-0000-4000-8000-000000000001"
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "ensure_net", "id": net, "name": "TMP"],
                   ["op": "rename_net", "net": net, "name": ""]], ["pool_items": resistor.items])
        // The first eight digits, as a reply shortens them, with the ellipsis.
        try apply([["op": "connect", "component": "R1", "pin": "A", "net": "33b623e6…"]])
        let pins = try XCTUnwrap(try result("get_component", ["refdes": "R1"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pins.first { $0.string("pin") == "A" }?.string("net_id"), net)
        XCTAssertEqual((try result("get_net", ["id": "33b623e6"]) as? JSONDictionary)?.string("id"), net)
        let component = try XCTUnwrap((try result("list_components") as? [JSONDictionary])?.first?.string("id"))
        XCTAssertEqual((try result("get_component", ["id": String(component.prefix(13))]) as? JSONDictionary)?.string("refdes"), "R1")
        try apply([["op": "set_value", "component": String(component.prefix(8)), "value": "10k"]])

        // Two ids that begin alike are named, not guessed between.
        try apply([["op": "ensure_net", "id": "33b623e6-1111-4000-8000-000000000002", "name": "OTHER"]])
        let ambiguous = try error([["op": "connect", "component": "R1", "pin": "B", "net": "33b623e6"]])
        XCTAssertTrue(ambiguous.contains("2 nets"), ambiguous)
        try apply([["op": "connect", "component": "R1", "pin": "B", "net": "33b623e6-0"]])
        // Seven digits are too few to be an id, and stay a name.
        XCTAssertTrue(try error([["op": "connect", "component": "R1", "pin": "B", "net": "33b623e"]]).contains("No net matches 33b623e"))
    }

    // MARK: - 109: a junction placed where one stands

    func testAJunctionPlacedOnOneThatIsThereIsThatOneUnderItsName() throws {
        let resistor = part(["A", "B"])
        let first = try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                               ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                               ["op": "connect", "component": "R1", "pin": "A", "net": "SIG", "create_net": true],
                               ["op": "place_junction", "net": "SIG", "x_mm": 90, "y_mm": 100]], ["pool_items": resistor.items])
        let standing = try XCTUnwrap(changes(first)[3].string("junction"))
        let batch = try apply([
            ["op": "place_junction", "id": "jc42", "net": "SIG", "x_mm": 90, "y_mm": 100],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "jc42"]]
        ], ["detail": "full"])
        XCTAssertEqual(changes(batch)[0].bool("reused"), true)
        XCTAssertEqual(changes(batch)[0].string("junction"), standing)
        XCTAssertEqual(batch.dictionary("handles")?.string("jc42"), standing, "the name stands for the junction reused")
        XCTAssertEqual(batch["reused_handles"] as? [String], ["jc42"])
        let lines = try XCTUnwrap(try result("list_net_lines") as? [JSONDictionary])
        XCTAssertEqual(lines.first?.dictionary("to")?.string("junction"), standing)
        // What the reply says to replay replays.
        let normalized = try XCTUnwrap(batch["normalized_ops"] as? [JSONDictionary])
        XCTAssertEqual(normalized[1].dictionary("to")?.string("junction"), standing)
    }

    // MARK: - 117: every op takes id

    func testEveryOpNamesWhatItActsOnByIDToo() throws {
        let resistor = part(["A", "B"])
        let made = try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                              ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                              ["op": "connect", "component": "R1", "pin": "A", "net": "SIG", "create_net": true],
                              ["op": "place_junction", "id": "j", "net": "SIG", "x_mm": 90, "y_mm": 100],
                              ["op": "draw_net_line", "id": "w", "from": ["kind": "pin", "component": "R1", "pin": "A"],
                               "to": ["kind": "junction", "junction": "j"]]], ["pool_items": resistor.items])
        let line = try XCTUnwrap(changes(made)[4].string("net_line"))
        let both = try error([["op": "remove_net_line", "id": line, "line": UUID().uuidString]])
        XCTAssertTrue(both.contains("one of them"), both)
        let removed = try apply([["op": "remove_net_line", "id": line]])
        XCTAssertEqual(changes(removed).first?.string("net_line"), line)
        // A batch's own names work through id as well.
        try apply([["op": "place_junction", "id": "k", "net": "SIG", "x_mm": 80, "y_mm": 100],
                   ["op": "remove_junction", "id": "k"]])
        XCTAssertNotNil(HorizontalEditOperationKind.removeTrack.params["id"], "list_ops offers id")
    }

    // MARK: - 116, 103: a dry run needs no revision, and replies compact

    func testADryRunNeedsNoRevisionAndItsCompactReplyLeavesTheOpsOut() throws {
        let ops: [JSONDictionary] = [["op": "ensure_net", "id": "n1", "name": "SIG"], ["op": "add_sheet", "name": "Two"]]
        let response = try call("apply", ["ops": ops, "dry_run": true, "detail": "compact"], guarded: false)
        let dry = try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
        let revision = try session.entry(handle: handle).revision
        XCTAssertEqual(dry.string("before_revision"), revision)
        XCTAssertNil(dry["normalized_ops"], "the compact reply leaves the echoed ops out")
        XCTAssertNotNil(dry.dictionary("handles")?.string("n1"))
        // The commit sends the same ops with the plan it was given.
        let committed = try apply(ops, ["plan_digest": try XCTUnwrap(dry.string("plan_digest")), "detail": "compact",
                                        "expected_revision": revision])
        XCTAssertEqual(committed.dictionary("timing")?.bool("reused_dry_run"), true)
        XCTAssertEqual(committed.string("status"), "committed")
        // A commit still needs both.
        let refused = try call("apply", ["ops": ops], guarded: false)
        XCTAssertTrue(((refused["error"] as? JSONDictionary)?.string("message") ?? "").contains("required"), "\(refused)")
    }
    // MARK: - 108: copper by component and pad

    func testTracksAndViasCanBeListedByComponentAndPad() throws {
        let chip = part(["A", "B", "C"])
        try apply([["op": "ensure_component", "refdes": "U1", "part": chip.part],
                   ["op": "ensure_component", "refdes": "U2", "part": chip.part],
                   ["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10],
                   ["op": "place_component", "component": "U2", "x_mm": 30, "y_mm": 10],
                   ["op": "connect", "component": "U1", "pin": "A", "net": "GND", "create_net": true],
                   ["op": "connect", "component": "U2", "pin": "A", "net": "GND"],
                   ["op": "connect", "component": "U1", "pin": "B", "net": "SIG", "create_net": true]], ["pool_items": chip.items])
        // U1.1 runs to a bend and on to U2.1; U1.2 has a stub.
        try apply([["op": "place_track", "from": ["component": "U1", "pad": "1"], "to": ["x_mm": 20, "y_mm": 10], "layer": 0, "width_mm": 0.2],
                   ["op": "place_track", "from": ["x_mm": 20, "y_mm": 10], "to": ["component": "U2", "pad": "1"], "layer": 0, "width_mm": 0.2],
                   ["op": "place_track", "from": ["component": "U1", "pad": "2"], "to": ["x_mm": 15, "y_mm": 12], "layer": 0, "width_mm": 0.2],
                   ["op": "place_via", "x_mm": 10, "y_mm": 11, "net": "SIG", "diameter_mm": 0.3, "hole_mm": 0.15, "padstack": chip.padstack],
                   ["op": "place_via", "x_mm": 50, "y_mm": 50, "net": "SIG", "diameter_mm": 0.3, "hole_mm": 0.15, "padstack": chip.padstack]])
        func tracks(_ args: JSONDictionary) throws -> [JSONDictionary] {
            try XCTUnwrap(try result("list_tracks", args) as? JSONDictionary).dictionaryArray("tracks")
        }
        XCTAssertEqual(try tracks(["component": "U1"]).count, 2)
        XCTAssertEqual(try tracks(["component": "U1", "pads": ["1"]]).count, 1)
        let joined = try tracks(["component": "U1", "pads": ["1"], "connected": true])
        XCTAssertEqual(joined.count, 2, "through the bend, and no further than U2's pad")
        XCTAssertEqual(Set(joined.compactMap { $0.string("net_name") }), ["GND"])
        let missing = try call("list_tracks", ["component": "U1", "pads": ["9"]])
        XCTAssertTrue(((missing["error"] as? JSONDictionary)?.string("message") ?? "").contains("Pads: 1, 2, 3"), "\(missing)")
        let under = try XCTUnwrap(try result("list_vias", ["component": "U1"]) as? JSONDictionary).dictionaryArray("vias")
        XCTAssertEqual(under.count, 1, "only the via inside U1's pads")
    }

    // MARK: - 132, 134, 135: via rules

    func testViasTakeTheirShapeFromTheRuleThatMatchesTheirNet() throws {
        let chip = part(["A"])
        try apply([["op": "ensure_component", "refdes": "U1", "part": chip.part],
                   ["op": "ensure_net", "name": "SYNC"], ["op": "ensure_net", "name": "GND"]], ["pool_items": chip.items])
        let sync = try XCTUnwrap((try result("get_net", ["name": "SYNC"]) as? JSONDictionary)?.string("id"))
        // The rules here are the test's own, without the one Horizon gives a new board.
        let template = try XCTUnwrap(try result("board_rules", ["kind": "via"]) as? JSONDictionary).dictionaryArray("rules")
        XCTAssertEqual(template.count, 1)
        try apply(template.compactMap { $0.string("id") }.map { ["op": "remove_rule", "kind": "via", "id": $0] })

        // 134: a whole rule in one op, ordered after the rules already there.
        let every = try apply([["op": "add_rule", "kind": "via", "fields": [
            "padstack": chip.padstack, "parameter_set": ["via_diameter": 450_000, "hole_diameter": 200_000]]]])
        let everyID = try XCTUnwrap(changes(every).first?.string("rule_id"))
        XCTAssertEqual(changes(every).first?.dictionary("rule")?.int("order"), 0)
        let narrow = try apply([["op": "add_rule", "kind": "via", "fields": [
            "padstack": chip.padstack, "parameter_set": ["via_diameter": 300_000, "hole_diameter": 150_000],
            "match": ["mode": "net", "net": sync]]]])
        let narrowID = try XCTUnwrap(changes(narrow).first?.string("rule_id"))
        // 135: the match keeps the keys the change didn't name.
        let match = try XCTUnwrap(changes(narrow).first?.dictionary("rule")?.dictionary("match"))
        XCTAssertEqual(Set(match.keys), ["mode", "net", "net_class", "net_name_regex"], "\(match)")
        XCTAssertEqual(changes(narrow).first?.dictionary("rule")?.int("order"), 1)
        // Moving the every-net rule last, then adding: after it, not tied with it.
        try apply([["op": "set_rule", "kind": "via", "id": everyID, "fields": ["order": 5]],
                   ["op": "add_rule", "kind": "via", "id": UUID().uuidString, "fields": ["padstack": chip.padstack, "enabled": false]]])
        let rules = try XCTUnwrap(try result("board_rules", ["kind": "via"]) as? JSONDictionary)
        let orders = rules.dictionaryArray("rules").compactMap { $0.int("order") }.sorted()
        XCTAssertEqual(orders, [1, 5, 6], "\(rules)")

        // 132: a via on SYNC takes the narrow rule's shape, one on GND the other's.
        let placed = try apply([["op": "place_via", "x_mm": 43, "y_mm": 7.25, "net": "SYNC"],
                                ["op": "place_via", "x_mm": 50, "y_mm": 7.25, "net": "GND"]])
        XCTAssertEqual(changes(placed)[0].string("source"), "rules")
        XCTAssertEqual(changes(placed)[0].double("diameter_mm"), 0.3)
        XCTAssertEqual(changes(placed)[0].string("via_rule"), narrowID)
        XCTAssertEqual(changes(placed)[1].double("diameter_mm"), 0.45)
        func vias() throws -> [JSONDictionary] {
            try XCTUnwrap(try result("list_vias") as? JSONDictionary).dictionaryArray("vias")
        }
        let syncVia = try XCTUnwrap(try vias().first { $0.string("net_name") == "SYNC" })
        XCTAssertEqual(syncVia.double("size_mm"), 0.3)
        XCTAssertEqual(syncVia.double("hole_mm"), 0.15)
        XCTAssertEqual(syncVia.string("source"), "rules")
        XCTAssertNil(syncVia["unresolved"])

        // Changing the rule changes the vias it shapes; the hole it didn't name stays.
        let changed = try apply([["op": "set_rule", "kind": "via", "id": narrowID, "fields": ["parameter_set": ["via_diameter": 350_000]]]])
        XCTAssertEqual(changes(changed).first?["changed"] as? [String], ["parameter_set/via_diameter"])
        XCTAssertEqual(changes(changed).first?.int("vias_rederived"), 1)
        let resized = try XCTUnwrap(try vias().first { $0.string("net_name") == "SYNC" })
        XCTAssertEqual(resized.double("size_mm"), 0.35)
        XCTAssertEqual(resized.double("hole_mm"), 0.15)

        // A definition, or a size of its own.
        let definition = UUID().uuidString.lowercased()
        try apply([["op": "add_rule", "kind": "via_definitions", "fields": ["via_definitions": [definition: [
            "name": "mini", "padstack": chip.padstack, "parameters": ["via_diameter": 400_000, "hole_diameter": 150_000],
            "span": ["start": 0, "end": -100]]]]]])
        let more = try apply([["op": "place_via", "x_mm": 60, "y_mm": 7.25, "net": "GND", "definition": "mini"],
                              ["op": "place_via", "x_mm": 70, "y_mm": 7.25, "net": "GND", "diameter_mm": 0.6]])
        XCTAssertEqual(changes(more)[0].string("source"), "definition")
        XCTAssertEqual(changes(more)[0].double("diameter_mm"), 0.4)
        XCTAssertEqual(changes(more)[1].string("source"), "local")
        XCTAssertEqual(changes(more)[1].double("hole_mm"), 0.2)

        // A rule-shaped via with nothing to show for it says so.
        try rewrite("board.json") { json in
            var vias = json.dictionaryMap("vias")
            let junction = UUID().uuidString.lowercased()
            var junctions = json.dictionaryMap("junctions")
            junctions[junction] = ["position": [80_000_000, 7_250_000]]
            json["junctions"] = junctions
            vias[UUID().uuidString.lowercased()] = ["junction": junction, "padstack": chip.padstack, "from_rules": true, "parameter_set": [:] as JSONDictionary]
            json["vias"] = vias
        }
        XCTAssertEqual(try vias().filter { $0.bool("unresolved") == true }.count, 1)

        // A via rule needs a padstack.
        try rewrite("board.json") { json in
            var rules = json.dictionary("rules") ?? [:]
            rules.removeValue(forKey: "via")
            rules.removeValue(forKey: "via_definitions")
            json["rules"] = rules
            json["vias"] = [:] as JSONDictionary
        }
        // A new one starts with the board's default via, so a rule told none.
        let bare = try error([["op": "add_rule", "kind": "via", "fields": ["padstack": ""]]])
        XCTAssertTrue(bare.contains("Via rule has no padstack"), bare)
        let started = try apply([["op": "add_rule", "kind": "via"]])
        XCTAssertEqual(changes(started).first?.dictionary("rule")?.string("padstack"), HorizontalProjectArchive.horizonPoolTentedCircularVia)
    }
    // MARK: - 115: where a pin ends on the sheet

    func testAComponentsPinsSayWhereTheyEndOnTheSheet() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100]], ["pool_items": resistor.items])
        func ends() throws -> [String: JSONDictionary] {
            let pins = try XCTUnwrap(try result("get_component", ["refdes": "R1"]) as? JSONDictionary).dictionaryArray("pins")
            return Dictionary(uniqueKeysWithValues: pins.compactMap { pin in
                (pin["at"] as? [JSONDictionary])?.first.map { (pin.string("pin") ?? "", $0) }
            })
        }
        var at = try ends()
        XCTAssertEqual(at["A"]?.double("x_mm"), 100)
        XCTAssertEqual(at["A"]?.double("y_mm"), 100)
        XCTAssertEqual(at["B"]?.double("y_mm") ?? 0, 97.46, accuracy: 1e-9)
        XCTAssertEqual(at["A"]?.string("points"), "left")
        XCTAssertEqual(at["A"]?.int("sheet"), 1)
        try apply([["op": "place_symbol", "component": "R1", "mirror": true]])
        at = try ends()
        XCTAssertEqual(at["A"]?.string("points"), "right", "as drawn, mirrored")
    }

    // MARK: - 118: a label on a wire

    func testALabelPlacedOnAWireSplitsItAndJoinsIt() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                   ["op": "connect", "component": "R1", "pin": "A", "net": "SIG", "create_net": true],
                   ["op": "ensure_net", "name": "OTHER"],
                   ["op": "place_junction", "id": "j1", "net": "SIG", "x_mm": 80, "y_mm": 100],
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "j1"]]],
                  ["pool_items": resistor.items])
        let missing = try XCTUnwrap(try result("check", ["full": true]) as? JSONDictionary).dictionaryArray("messages")
            .first { $0.string("title") == "Label missing" && $0.string("net") == "SIG" }
        let wire = try XCTUnwrap((try result("list_net_lines") as? [JSONDictionary])?.first?.string("id"))
        XCTAssertEqual(missing?["net_lines"] as? [String], [wire], "the finding names the segment's wires")

        XCTAssertTrue(try error([["op": "place_net_label", "net": "OTHER", "x_mm": 90, "y_mm": 100]]).contains("another net"))
        XCTAssertTrue(try error([["op": "place_net_label", "net": "SIG", "x_mm": 100, "y_mm": 100]]).contains("terminate_pin"))
        let placed = try apply([["op": "place_net_label", "net": "SIG", "x_mm": 90, "y_mm": 100]])
        XCTAssertEqual(changes(placed).first?.string("split_net_line"), wire)
        XCTAssertEqual((try result("list_net_lines") as? [JSONDictionary])?.count, 2)
        let after = try XCTUnwrap(try result("check", ["full": true]) as? JSONDictionary).dictionaryArray("messages")
        XCTAssertNil(after.first { $0.string("title") == "Label missing" && $0.string("net") == "SIG" }, "\(after)")
        let overlaps = try XCTUnwrap(try result("find_overlaps") as? JSONDictionary)
        XCTAssertEqual(overlaps.dictionary("totals")?.values.compactMap { $0 as? Int }.reduce(0, +) ?? 0, 0, "\(overlaps)")
    }

    // MARK: - 112: removing a symbol takes the wiring only it used

    func testRemovingASymbolTakesTheWiringOnlyItUsed() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                   ["op": "place_symbol", "component": "R2", "x_mm": 60, "y_mm": 100],
                   ["op": "connect", "component": "R1", "pin": "A", "net": "FB", "create_net": true],
                   ["op": "connect", "component": "R1", "pin": "B", "net": "SIG", "create_net": true],
                   ["op": "connect", "component": "R2", "pin": "B", "net": "SIG"],
                   // R1.A runs to a corner and on to a labelled junction: only R1 uses it.
                   ["op": "place_junction", "id": "a1", "net": "FB", "x_mm": 90, "y_mm": 100],
                   ["op": "place_junction", "id": "a2", "net": "FB", "x_mm": 90, "y_mm": 110],
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "a1"]],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": "a1"], "to": ["kind": "junction", "junction": "a2"]],
                   ["op": "place_net_label", "net": "FB", "x_mm": 90, "y_mm": 110],
                   // R1.B and R2.B share a rail.
                   ["op": "place_junction", "id": "b1", "net": "SIG", "x_mm": 95, "y_mm": 97.46],
                   ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "B"], "to": ["kind": "junction", "junction": "b1"]],
                   ["op": "draw_net_line", "from": ["kind": "junction", "junction": "b1"], "to": ["kind": "pin", "component": "R2", "pin": "B"]]],
                  ["pool_items": resistor.items])
        let kept = try apply([["op": "remove_symbol", "component": "R1", "keep_wiring": true]], ["dry_run": true])
        XCTAssertNil(changes(kept).first?["wiring_removed"])
        let removed = try apply([["op": "remove_symbol", "component": "R1"]])
        let wiring = try XCTUnwrap(changes(removed).first?.dictionary("wiring_removed"), "\(removed)")
        XCTAssertEqual(wiring.int("net_lines"), 2, "the corner run, and the rail's half left with no pin at its end: \(wiring)")
        XCTAssertEqual(wiring.int("net_labels"), 1)
        let dangling = try XCTUnwrap(try result("find_dangling") as? JSONDictionary)
        XCTAssertEqual(dangling.dictionary("totals")?.int("stubs"), 0, "\(dangling)")
        XCTAssertEqual(dangling.dictionary("totals")?.int("unanchored_islands"), 0)
        XCTAssertEqual((try result("list_net_labels") as? [JSONDictionary])?.count, 0)
    }

    // MARK: - 111: remapping a part with copper on pads it lacks

    func testRemapByPadNameAndDropCopperOnPadsTheNewPartLacks() throws {
        let old = part(["A", "B"], unpinnedPads: ["3", "EP"])
        let new = part(["A", "B"], unpinnedPads: ["3"])
        try apply([["op": "ensure_component", "refdes": "U1", "part": old.part],
                   ["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10],
                   ["op": "connect", "component": "U1", "pin": "A", "net": "GND", "create_net": true]],
                  ["pool_items": old.items + new.items])
        try apply([["op": "place_track", "from": ["component": "U1", "pad": "1"], "to": ["x_mm": 5, "y_mm": 10], "layer": 0, "width_mm": 0.2],
                   ["op": "place_track", "from": ["component": "U1", "pad": "3"], "to": ["x_mm": 5, "y_mm": 14], "layer": 0, "width_mm": 0.2, "net": "GND"],
                   ["op": "place_track", "from": ["component": "U1", "pad": "EP"], "to": ["x_mm": 5, "y_mm": 16], "layer": 0, "width_mm": 0.2, "net": "GND"],
                   ["op": "place_via", "x_mm": 10, "y_mm": 16, "net": "GND", "diameter_mm": 0.3, "hole_mm": 0.15, "padstack": old.padstack]])
        let refused = try error([["op": "remap_part", "component": "U1", "part": new.part]])
        XCTAssertTrue(refused.contains("EP") && refused.contains("copper"), refused)
        XCTAssertFalse(refused.contains("needs an unambiguous"), refused)
        let remapped = try XCTUnwrap(changes(try apply([["op": "remap_part", "component": "U1", "part": new.part, "copper": "drop"]])).first)
        XCTAssertEqual(remapped.int("pads_mapped_by_name"), 1, "pad 3 goes to pad 3")
        XCTAssertEqual((remapped["tracks_dropped"] as? [String])?.count, 1)
        XCTAssertEqual((remapped["vias_under_old_footprint"] as? [JSONDictionary])?.count, 1)
        let tracks = try XCTUnwrap(try result("list_tracks") as? JSONDictionary).dictionaryArray("tracks")
        XCTAssertEqual(tracks.count, 2)
    }

    // MARK: - 107: copper joining two nets

    func testCheckReportsCopperThatJoinsTwoNets() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
                   ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
                   ["op": "place_component", "component": "R2", "x_mm": 30, "y_mm": 10],
                   ["op": "connect", "component": "R1", "pin": "A", "net": "GND", "create_net": true],
                   ["op": "connect", "component": "R2", "pin": "A", "net": "GND"],
                   ["op": "connect", "component": "R1", "pin": "B", "net": "GND"],
                   ["op": "ensure_net", "name": "SYNC"]], ["pool_items": resistor.items])
        try apply([["op": "place_track", "from": ["component": "R1", "pad": "1"], "to": ["component": "R2", "pad": "1"], "layer": 0, "width_mm": 0.2]])
        func errors() throws -> [JSONDictionary] {
            try XCTUnwrap(try result("check", ["full": true]) as? JSONDictionary).dictionaryArray("messages").filter { $0.string("category") == "copper" }
        }
        XCTAssertEqual(try errors().count, 0)
        // Moving R1.A to SYNC leaves its track on GND: the reply says so.
        let moved = try apply([["op": "connect", "component": "R1", "pin": "A", "net": "SYNC"]])
        let warning = try XCTUnwrap((moved["warnings"] as? [String])?.first { $0.contains("R1 pad 1") }, "\(moved)")
        XCTAssertTrue(warning.contains("SYNC") && warning.contains("GND"), warning)
        let short = try XCTUnwrap(try errors().first { $0.string("title") == "Copper joins two nets" })
        XCTAssertEqual(short.string("level"), "error")
        let detail = try XCTUnwrap(short.string("detail"))
        XCTAssertTrue(detail.contains("R1.1") && detail.contains("R2.1") && detail.contains("SYNC") && detail.contains("GND"), detail)

        // A pour made while R1.B was on GND runs over it once it moves.
        let square: [JSONDictionary] = [[0, 0], [20, 0], [20, 20], [0, 20]].map { ["x_mm": $0[0], "y_mm": $0[1]] }
        try apply([["op": "connect", "component": "R1", "pin": "A", "net": "GND"],
                   ["op": "place_plane", "net": "GND", "layer": 0, "vertices": square]])
        try result("pour_planes", ["expected_revision": try session.entry(handle: handle).revision, "operation_id": UUID().uuidString])
        XCTAssertEqual(try errors().count, 0)
        try apply([["op": "connect", "component": "R1", "pin": "B", "net": "SYNC"]])
        let copperErrors = try errors()
        let covered = try XCTUnwrap(copperErrors.first { $0.string("title") == "Plane runs over a pad on another net" }, "\(copperErrors)")
        XCTAssertTrue((covered.string("detail") ?? "").contains("R1.2 (SYNC)"), "\(covered)")
    }

    // MARK: - 102: moving parts with their wiring

    func testMovingSymbolsCarriesTheWiringOnlyTheyUse() throws {
        let resistor = part(["A", "B"])
        let made = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": resistor.part],
            ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
            ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
            ["op": "place_symbol", "component": "R2", "x_mm": 60, "y_mm": 100],
            ["op": "connect", "component": "R1", "pin": "A", "net": "GND", "create_net": true],
            ["op": "connect", "component": "R1", "pin": "B", "net": "SIG", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "B", "net": "SIG"],
            // R1.A to a ground symbol of its own.
            ["op": "place_junction", "id": "g", "net": "GND", "x_mm": 90, "y_mm": 100],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "g"]],
            ["op": "place_power_symbol", "net": "GND", "x_mm": 90, "y_mm": 100],
            // R1.B by a corner to a rail junction R2.B also reaches.
            ["op": "place_junction", "id": "c", "net": "SIG", "x_mm": 95, "y_mm": 97.46],
            ["op": "place_junction", "id": "r", "net": "SIG", "x_mm": 80, "y_mm": 97.46],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "B"], "to": ["kind": "junction", "junction": "c"]],
            ["op": "draw_net_line", "id": "cr", "from": ["kind": "junction", "junction": "c"], "to": ["kind": "junction", "junction": "r"]],
            ["op": "draw_net_line", "from": ["kind": "junction", "junction": "r"], "to": ["kind": "pin", "component": "R2", "pin": "B"]]
        ], ["pool_items": resistor.items])
        let handles = try XCTUnwrap(made.dictionary("handles"))
        let ground = try XCTUnwrap(handles.string("g")), corner = try XCTUnwrap(handles.string("c")), rail = try XCTUnwrap(handles.string("r"))
        func position(_ junction: String) throws -> [Double] {
            let row = try XCTUnwrap((try result("list_junctions") as? [JSONDictionary])?.first { $0.string("id") == junction })
            return [row.double("x_mm") ?? .nan, row.double("y_mm") ?? .nan]
        }
        let moved = try XCTUnwrap(changes(try apply([["op": "move_symbols", "symbols": ["R1"], "dy_mm": -10]])).first)
        XCTAssertEqual(Set(moved["junctions"] as? [String] ?? []), [ground, corner])
        XCTAssertEqual(moved["stretched_net_lines"] as? [String], [try XCTUnwrap(handles.string("cr"))])
        XCTAssertEqual(try position(ground), [90, 90])
        XCTAssertEqual(try position(corner)[1], 87.46, accuracy: 1e-9)
        XCTAssertEqual(try position(rail)[1], 97.46, accuracy: 1e-9, "the rail stays")
        let symbol = try XCTUnwrap((try result("list_symbols") as? [JSONDictionary])?.first { $0.string("refdes") == "R1" || $0.string("component") == "R1" }
                                   ?? (try result("list_symbols") as? [JSONDictionary])?.first)
        _ = symbol

        // place_junction moves a junction, with its wires.
        let rerouted = try XCTUnwrap(changes(try apply([["op": "place_junction", "id": rail, "x_mm": 80, "y_mm": 87.46]])).first)
        XCTAssertEqual(rerouted.bool("moved"), true)
        XCTAssertEqual(try position(rail)[1], 87.46, accuracy: 1e-9)

        // Onto another sheet: the wire to the rail that stays is cut, and named.
        try apply([["op": "add_sheet", "name": "Two"]])
        let across = try XCTUnwrap(changes(try apply([["op": "move_symbols", "symbols": ["R1"], "to_sheet": "Two"]])).first)
        XCTAssertEqual((across["cut"] as? [JSONDictionary])?.first?.string("junction"), corner)
        XCTAssertEqual((across["cut"] as? [JSONDictionary])?.first?.string("net_name"), "SIG")
        XCTAssertEqual((across["power_symbols"] as? [String])?.count, 1)
        let two = try XCTUnwrap((try result("list_junctions", ["sheet": 2]) as? [JSONDictionary])?.map { $0.string("id") })
        XCTAssertEqual(Set(two.compactMap { $0 }), [ground, corner])
        XCTAssertEqual((try result("list_power_symbols", ["sheet": 2]) as? [JSONDictionary])?.count, 1)
        XCTAssertEqual((try result("list_net_lines", ["sheet": 2]) as? [JSONDictionary])?.count, 2)
        let one = try XCTUnwrap(try result("list_net_lines", ["sheet": 1]) as? [JSONDictionary])
        XCTAssertEqual(one.count, 1, "R2.B to the rail is left; the rail keeps it")
        XCTAssertEqual(try XCTUnwrap(try result("get_component", ["refdes": "R1"]) as? JSONDictionary).dictionaryArray("symbols").first?.int("sheet"), 2)
    }
    // MARK: - 106: a live document holding its project file alone

    @MainActor
    func testALiveDocumentHoldingItsProjectFileAloneReadsFromDiskAndRefusesEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("field44-hprj-\(UUID().uuidString)")
        try HorizontalProjectArchive.newProject().write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Untitled.hprj")
        // What a Revert leaves: the document's archive is the .hprj alone.
        let document = HorizontalLiveDocument(url: url, title: "Untitled", project: try HorizontalProject.load(from: url),
                                              archive: HorizontalProjectArchive(regularFileData: try Data(contentsOf: url)))
        document.applyArchive = { _, _ in XCTFail("an edit was installed into an archive with no tree") }
        let live = HorizontalDispatchSession()
        let liveHandle = live.registerLive(document)
        defer { live.unregisterLive(handle: liveHandle) }
        let entry = try live.entry(handle: liveHandle)
        XCTAssertTrue(entry.holdsProjectFileOnly)
        XCTAssertEqual(HorizontalDispatchMethods.projectSummary(entry).bool("holds_project_file_only"), true)
        // Reads come from the files, which have the sheet.
        let rendered = try XCTUnwrap(try HorizontalDispatchMethods.handler(named: "render_sheet")?(live, ["handle": liveHandle]) as? JSONDictionary)
        XCTAssertNotNil(rendered["png_base64"] ?? rendered["width"], "\(rendered.keys)")
        // An edit says what is wrong rather than "board.json is not a valid project-relative path".
        XCTAssertThrowsError(try HorizontalDispatchMethods.handler(named: "apply")?(live, [
            "handle": liveHandle, "expected_revision": entry.revision, "operation_id": UUID().uuidString,
            "ops": [["op": "ensure_net", "name": "N"]]])) { error in
            let failure = error as? HorizontalDispatchError
            XCTAssertEqual(failure?.code, .recoveryRequired)
            XCTAssertTrue(failure?.message.contains("Untitled.hprj") == true, failure?.message ?? "")
        }
    }
    // MARK: - 136: a flipped label keeps its way round

    func testALabelsOrientationIsSavedWithTheSheet() throws {
        try apply([["op": "ensure_net", "name": "PWM"], ["op": "ensure_net", "name": "BUS_A"],
                   ["op": "place_net_label", "net": "PWM", "x_mm": 10, "y_mm": 10, "orientation": "right"]])
        var archive = try HorizontalProjectArchive.snapshot(from: root)
        var project = try HorizontalProject.loadSnapshot(of: archive)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        XCTAssertEqual(sheet.netLabels.first?.orientation, "right")
        sheet.netLabels[0].orientation = "left"   // what the canvas's flip does
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        project = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertEqual(project.schematic?.sheets.first?.netLabels.first?.orientation, "left")
    }

    // MARK: - 137, 138: remapping onto one gate, and onto the same package

    func testRemapFoldsASupplyGateIntoTheOneGateAndKeepsPadsOnTheSamePackage() throws {
        // The old part: Main (A, B) and a Power gate (V), two gates of one entity.
        let main = part(["A", "B"])
        var power = HorizontalPoolItemFactory.newUnit()
        let vPin = UUID().uuidString.lowercased()
        power.pins[vPin] = HorizontalUnitPin(id: vPin, primaryName: "V", direction: .bidirectional, alternateNames: [])
        var powerSymbol = HorizontalPoolItemFactory.newSymbol(for: power)
        powerSymbol.pins[vPin] = HorizontalSymbolPin(id: vPin, position: HorizontalPoint(x: 0, y: 0), length: 2_540_000, orientation: .down)
        var entity = try XCTUnwrap(main.items[1]["gates"] as? JSONDictionary)
        let powerGate = UUID().uuidString.lowercased()
        entity[powerGate] = ["name": "Power", "suffix": "P", "swap_group": 0, "unit": power.uuid]
        var twoGates = main.items[1]
        twoGates["gates"] = entity
        // Its part puts V on pad 3 of the same package.
        var oldPart = main.items[5]
        var padMap = try XCTUnwrap(oldPart["pad_map"] as? JSONDictionary)
        let package = try XCTUnwrap(main.items[4]["pads"] as? JSONDictionary)
        let pad3 = UUID().uuidString.lowercased()
        var pads = package
        pads[pad3] = ["name": "3", "padstack": main.padstack, "parameter_set": [:] as JSONDictionary,
                      "placement": ["angle": 0, "mirror": false, "shift": [0, 4_000_000]]] as JSONDictionary
        var packageJSON = main.items[4]
        packageJSON["pads"] = pads
        padMap[pad3] = ["gate": powerGate, "pin": vPin]
        oldPart["pad_map"] = padMap
        // The new part: one gate with A, B and V, in that same package.
        var single = HorizontalPoolItemFactory.newUnit()
        let pins = ["A", "B", "V"].map { _ in UUID().uuidString.lowercased() }
        for (i, name) in ["A", "B", "V"].enumerated() {
            single.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: name, direction: .bidirectional, alternateNames: [])
        }
        let singleEntity = HorizontalPoolItemFactory.newEntity(for: single)
        let singleGate = singleEntity.gates.keys.first!
        var singleSymbol = HorizontalPoolItemFactory.newSymbol(for: single)
        for i in pins.indices {
            singleSymbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_540_000),
                                                             length: 2_540_000, orientation: .left)
        }
        var newPart = HorizontalPoolItemFactory.newPart(entity: singleEntity, packageID: try XCTUnwrap(main.items[4].string("uuid")))
        let padIDs = main.pads + [pad3]
        for i in pins.indices { newPart.padMap[padIDs[i]] = HorizontalPartPadMapEntry(gateID: singleGate, pinID: pins[i]) }
        try apply([["op": "ensure_component", "refdes": "U1", "part": main.part],
                   ["op": "place_symbol", "component": "U1", "gate": "Main", "x_mm": 100, "y_mm": 100],
                   ["op": "place_symbol", "component": "U1", "gate": "Power", "x_mm": 120, "y_mm": 100],
                   ["op": "connect", "component": "U1", "pin": "A", "net": "SIG", "create_net": true],
                   ["op": "connect", "component": "U1", "pin": "V", "net": "VCC", "create_net": true],
                   ["op": "terminate_pin", "component": "U1", "pin": "V"],
                   ["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10],
                   ["op": "place_track", "from": ["component": "U1", "pad": "3"], "to": ["x_mm": 5, "y_mm": 14], "layer": 0, "width_mm": 0.2]],
                  ["pool_items": [main.items[0], twoGates, main.items[2], main.items[3], packageJSON, oldPart, power.json(), powerSymbol.json(),
                                  single.json(), singleEntity.json(), singleSymbol.json(), newPart.json()]])
        let remapped = try XCTUnwrap(changes(try apply([["op": "remap_part", "component": "U1", "part": newPart.uuid]])).first)
        XCTAssertEqual((remapped["symbols_removed"] as? [String])?.count, 1, "the Power gate's symbol folds into Main's")
        XCTAssertEqual(remapped["pins_to_wire"] as? [String], ["V"])
        XCTAssertNotNil(remapped.dictionary("wiring_removed"), "the stub and label V ran to")
        XCTAssertEqual(remapped.int("pads_kept"), 3, "the same package keeps every pad")
        let symbols = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary).dictionaryArray("symbols")
        XCTAssertEqual(symbols.count, 1)
        let pinsNow = try XCTUnwrap(try result("get_component", ["refdes": "U1"]) as? JSONDictionary).dictionaryArray("pins")
        XCTAssertEqual(pinsNow.first { $0.string("pin") == "V" }?.string("net"), "VCC")
        let tracks = try XCTUnwrap(try result("list_tracks", ["component": "U1", "pads": ["3"]]) as? JSONDictionary).dictionaryArray("tracks")
        XCTAssertEqual(tracks.count, 1, "the track on pad 3 stays on pad 3")
        XCTAssertNotNil((try result("get_component", ["refdes": "U1"]) as? JSONDictionary)?.dictionary("board")?.string("package_id"))
    }
    // MARK: - Round 45: items 140–145

    func testATextSaysWhereItRunsAndWhatItCovers() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100]], ["pool_items": resistor.items])
        let clear = try XCTUnwrap(changes(try apply([["op": "place_text", "text": "A note", "x_mm": 20, "y_mm": 20]])).first)
        let extent = try XCTUnwrap(clear.dictionary("extent_mm"))
        XCTAssertLessThan(abs((extent.double("min_x") ?? 0) - 20), 1, "it starts at x, whatever its origin: \(extent)")
        XCTAssertGreaterThan(extent.double("max_x") ?? 0, 25)
        XCTAssertNil(clear["overlaps"])
        let over = try XCTUnwrap(changes(try apply([["op": "place_text", "text": "Across the part", "x_mm": 96, "y_mm": 99]])).first)
        let overlaps = try XCTUnwrap(over["overlaps"] as? [JSONDictionary])
        XCTAssertEqual(overlaps.first { $0.string("kind") == "symbol" }?.string("refdes"), "R1")
    }

    func testTerminatePinTakesOffsheetRefsAndALabelChangesInPlace() throws {
        let resistor = part(["A", "B"])
        let made = try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                              ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
                              ["op": "connect", "component": "R1", "pin": "A", "net": "SYNC", "create_net": true],
                              ["op": "ensure_net", "name": "OTHER"],
                              ["op": "terminate_pin", "component": "R1", "pin": "A", "offsheet_refs": false]], ["pool_items": resistor.items])
        let label = try XCTUnwrap(changes(made)[4].string("net_label"))
        func stored() throws -> JSONDictionary {
            let sheets = try read("top_schematic.json").dictionaryMap("sheets")
            return try XCTUnwrap(sheets.values.compactMap { $0.dictionaryMap("net_labels")[label] }.first)
        }
        XCTAssertEqual(try stored().bool("offsheet_refs"), false, "141")
        // 142: turned and resized where it is, under its own id.
        let edited = try XCTUnwrap(changes(try apply([["op": "place_net_label", "id": label, "orientation": "right", "size_mm": 2]])).first)
        XCTAssertEqual(edited.string("net_label"), label)
        XCTAssertEqual(edited.bool("created"), false)
        XCTAssertEqual(try stored().string("orientation"), "right")
        XCTAssertEqual(try stored().int("size"), 2_000_000)
        XCTAssertTrue(try error([["op": "place_net_label", "id": label, "net": "OTHER"]]).contains("keeps its junction's net"))
        // Moved along x: onto a junction there, and the old one goes.
        let moved = try XCTUnwrap(changes(try apply([["op": "place_net_label", "id": label, "x_mm": 90]])).first)
        XCTAssertNotNil(moved["moved_to"])
        XCTAssertEqual((try result("list_net_labels") as? [JSONDictionary])?.count, 1)
        // A new label can be named, and a later op finds it by the name.
        try apply([["op": "place_net_label", "id": "l1", "net": "OTHER", "x_mm": 10, "y_mm": 10],
                   ["op": "place_net_label", "id": "l1", "orientation": "up"]])
        XCTAssertEqual((try result("list_net_labels") as? [JSONDictionary])?.first { $0.string("net_name") == "OTHER" }?.string("orientation"), "up")
    }

    func testPoolWriteDerivesAnItemFromAnotherWithAPatch() throws {
        let resistor = part(["A", "B"])
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part]], ["pool_items": resistor.items])
        let derived = UUID().uuidString.lowercased()
        let written = try XCTUnwrap(try result("pool_write", ["items": [
            ["from": resistor.part, "uuid": derived, "patch": ["MPN": [false, "DERIVED-1"], "tags": NSNull()]]
        ]]) as? JSONDictionary)
        XCTAssertEqual((written["written"] as? [String])?.count, 1, "\(written)")
        let item = try XCTUnwrap((try result("get_pool_item", ["uuid": derived]) as? JSONDictionary)?.dictionary("item"))
        XCTAssertEqual((item["MPN"] as? [Any])?.last as? String, "DERIVED-1")
        XCTAssertNil(item["tags"], "null removes a key")
        XCTAssertEqual(item.string("entity"), try XCTUnwrap(resistor.items[5].string("entity")), "the rest is the base's")
        let wrong = try call("pool_write", ["items": [["from": resistor.part, "name": "x"]]])
        XCTAssertTrue(((wrong["error"] as? JSONDictionary)?.string("message") ?? "").contains("takes only uuid, patch and type"))
    }

    func testACommitCanNameItsDryRunByDigestAlone() throws {
        let ops: [JSONDictionary] = [["op": "ensure_net", "name": "BYDIGEST"], ["op": "add_sheet", "name": "Two"]]
        let dry = try apply(ops, ["dry_run": true])
        let digest = try XCTUnwrap(dry.string("plan_digest"))
        let committed = try XCTUnwrap(try result("apply", ["plan_digest": digest, "expected_revision": try XCTUnwrap(dry.string("before_revision")),
                                                           "operation_id": UUID().uuidString]) as? JSONDictionary)
        XCTAssertEqual(committed.string("status"), "committed")
        XCTAssertEqual(committed.dictionary("timing")?.bool("reused_dry_run"), true)
        XCTAssertNotNil(try result("get_net", ["name": "BYDIGEST"]))
        // At another revision the digest names nothing, and says so.
        let stale = try call("apply", ["plan_digest": digest])
        XCTAssertTrue(((stale["error"] as? JSONDictionary)?.string("message") ?? "").contains("No dry run at this revision"), "\(stale)")
        // Every other edit is still matched by its request, even one with no
        // ops of its own: pour_planes with a digest no plan has is planned
        // again and found not to match.
        let pour = try call("pour_planes", ["plan_digest": String(repeating: "0", count: 64),
                                            "expected_revision": try session.entry(handle: handle).revision, "operation_id": UUID().uuidString])
        XCTAssertTrue(((pour["error"] as? JSONDictionary)?.string("message") ?? "").contains("does not match this edit"), "\(pour)")
        // A pool_write commits the same way.
        let resistor = part(["A"])
        let poolDry = try XCTUnwrap(try result("pool_write", ["items": resistor.items, "dry_run": true]) as? JSONDictionary)
        let poolCommit = try XCTUnwrap(try result("pool_write", ["plan_digest": try XCTUnwrap(poolDry.string("plan_digest"))]) as? JSONDictionary)
        XCTAssertEqual(poolCommit.dictionary("timing")?.bool("reused_dry_run"), true)
        XCTAssertNotNil(try result("get_pool_item", ["uuid": resistor.part]))
    }
    func testABoardRenderDrawsAPackageBodyAsItsOutline() throws {
        let resistor = part(["A"])
        var items = resistor.items
        let corners = [[-3_000_000, -3_000_000], [3_000_000, -3_000_000], [3_000_000, 3_000_000], [-3_000_000, 3_000_000]]
        items[4]["polygons"] = [UUID().uuidString.lowercased(): [
            "layer": HorizontalBoardLayers.topPackage, "parameter_class": "",
            "vertices": corners.map { ["type": "line", "position": $0, "arc_center": [0, 0], "arc_reverse": false] }
        ] as JSONDictionary]
        try apply([["op": "ensure_component", "refdes": "R1", "part": resistor.part],
                   ["op": "place_component", "component": "R1", "x_mm": 20, "y_mm": 20]], ["pool_items": items])
        func dark(_ region: [Double]) throws -> Int {
            let render = try XCTUnwrap(try result("render_board", [
                "layer_ids": [HorizontalBoardLayers.topPackage], "dpi": 300,
                "region": ["min_x_mm": region[0], "min_y_mm": region[1], "max_x_mm": region[2], "max_y_mm": region[3]]
            ]) as? JSONDictionary)
            let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(render.string("png_base64"))))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil)), 0, nil))
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: pixels.count, by: 4).filter { Int(pixels[$0]) + Int(pixels[$0 + 1]) + Int(pixels[$0 + 2]) < 300 }.count
        }
        XCTAssertGreaterThan(try dark([15, 15, 25, 25]), 0, "the body's outline is drawn")
        XCTAssertEqual(try dark([18.5, 18.5, 21.5, 21.5]), 0, "and nothing inside it, where its pads are")
    }
    // MARK: - Move to other sheet

    func testMoveToOtherSheetTakesEverythingConnectedWhole() throws {
        let resistor = part(["A", "B"])
        let made = try apply([
            ["op": "ensure_component", "refdes": "R1", "part": resistor.part],
            ["op": "ensure_component", "refdes": "R2", "part": resistor.part],
            ["op": "ensure_component", "refdes": "R3", "part": resistor.part],
            ["op": "place_symbol", "component": "R1", "x_mm": 100, "y_mm": 100],
            ["op": "place_symbol", "component": "R2", "x_mm": 60, "y_mm": 100],
            ["op": "place_symbol", "component": "R3", "x_mm": 20, "y_mm": 20],
            ["op": "connect", "component": "R1", "pin": "A", "net": "GND", "create_net": true],
            ["op": "connect", "component": "R1", "pin": "B", "net": "SIG", "create_net": true],
            ["op": "connect", "component": "R2", "pin": "B", "net": "SIG"],
            ["op": "place_junction", "id": "g", "net": "GND", "x_mm": 90, "y_mm": 100],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "A"], "to": ["kind": "junction", "junction": "g"]],
            ["op": "place_power_symbol", "net": "GND", "x_mm": 90, "y_mm": 100],
            ["op": "place_junction", "id": "r", "net": "SIG", "x_mm": 80, "y_mm": 97.46],
            ["op": "draw_net_line", "from": ["kind": "pin", "component": "R1", "pin": "B"], "to": ["kind": "junction", "junction": "r"]],
            ["op": "draw_net_line", "from": ["kind": "junction", "junction": "r"], "to": ["kind": "pin", "component": "R2", "pin": "B"]],
            ["op": "place_net_label", "net": "SIG", "x_mm": 80, "y_mm": 97.46],
            ["op": "place_text", "id": "note", "text": "Divider", "x_mm": 70, "y_mm": 110],
            ["op": "add_sheet", "name": "Two"]
        ], ["pool_items": resistor.items])
        let handles = try XCTUnwrap(made.dictionary("handles"))
        func sheetWarnings() throws -> Int {
            try XCTUnwrap(try result("check", ["full": true]) as? JSONDictionary).dictionaryArray("messages")
                .filter { $0.string("category") == "schematic" }.count
        }
        let warningsBefore = try sheetWarnings()
        XCTAssertTrue(try error([["op": "move_to_other_sheet", "items": ["R1"], "to_sheet": 1]]).contains("already"))
        XCTAssertTrue(try error([["op": "move_to_other_sheet", "items": ["NOPE"], "to_sheet": "Two"]]).contains("NOPE"))

        // Naming R1 alone takes R2 too, across the wire to the rail, with the
        // ground symbol, the label and the junctions; R3 and the note stay.
        let moved = try XCTUnwrap(changes(try apply([["op": "move_to_other_sheet", "items": ["R1"], "to_sheet": "Two", "dx_mm": 5]])).first)
        let byKind = try XCTUnwrap(moved.dictionary("moved"))
        XCTAssertEqual((byKind["symbols"] as? [String])?.count, 2)
        XCTAssertEqual(Set(byKind["junctions"] as? [String] ?? []), [try XCTUnwrap(handles.string("g")), try XCTUnwrap(handles.string("r"))])
        XCTAssertEqual((byKind["net_lines"] as? [String])?.count, 3)
        XCTAssertEqual((byKind["net_labels"] as? [String])?.count, 1)
        XCTAssertEqual((byKind["power_symbols"] as? [String])?.count, 1)
        XCTAssertNil(byKind["texts"])
        XCTAssertEqual(moved.int("pulled_in"), (moved.int("count") ?? 0) - 1)
        XCTAssertEqual((try result("list_symbols", ["sheet": 1]) as? [JSONDictionary])?.count, 1, "R3 stays")
        XCTAssertEqual((try result("list_net_lines", ["sheet": 1]) as? [JSONDictionary])?.count, 0, "nothing is cut")
        XCTAssertEqual((try result("list_net_lines", ["sheet": 2]) as? [JSONDictionary])?.count, 3)
        let rail = try XCTUnwrap((try result("list_junctions", ["sheet": 2]) as? [JSONDictionary])?.first { $0.string("id") == handles.string("r") })
        XCTAssertEqual(rail.double("x_mm") ?? .nan, 85, accuracy: 1e-9, "moved by dx_mm")
        let sig = try XCTUnwrap(try result("get_net", ["name": "SIG"]) as? JSONDictionary)
        XCTAssertEqual((sig["pins"] as? [Any])?.count, 2, "the nets are the block's, untouched")
        XCTAssertEqual(try sheetWarnings(), warningsBefore, "a whole move leaves no pin or label without its wiring")

        // A text named alone goes alone, and a wire brings what it joins.
        let note = try XCTUnwrap(handles.string("note"))
        let text = try XCTUnwrap(changes(try apply([["op": "move_to_other_sheet", "items": [note], "to_sheet": "Two"]])).first)
        XCTAssertEqual(text.dictionary("moved")?["texts"] as? [String], [note])
        XCTAssertEqual(text.int("pulled_in"), 0)
        let wire = try XCTUnwrap((try result("list_net_lines", ["sheet": 2]) as? [JSONDictionary])?.first?.string("id"))
        let back = try XCTUnwrap(changes(try apply([["op": "move_to_other_sheet", "items": [wire], "to_sheet": 1]])).first)
        XCTAssertEqual((back.dictionary("moved")?["symbols"] as? [String])?.count, 2)

        // A graphic line goes with the junctions it is drawn between, and a
        // junction it shares with a wire brings that wiring too.
        var schematic = try read("top_schematic.json")
        var sheets = schematic.dictionaryMap("sheets")
        let first = try XCTUnwrap(sheets.first { $0.value.int("index") == 1 }?.key)
        let (a, b, line) = (UUID().uuidString.lowercased(), UUID().uuidString.lowercased(), UUID().uuidString.lowercased())
        var junctions = sheets[first]?.dictionaryMap("junctions") ?? [:]
        junctions[a] = ["position": [0, 0]]
        junctions[b] = ["position": [10_000_000, 0]]
        sheets[first]?["junctions"] = junctions
        sheets[first]?["lines"] = [line: ["from": a, "to": b, "layer": 0, "width": 0]]
        schematic["sheets"] = sheets
        try HorizontalHorizonJSONWriter.data(schematic).write(to: root.appendingPathComponent("top_schematic.json"))
        _ = try result("reload_project")
        let drawn = try XCTUnwrap(changes(try apply([["op": "move_to_other_sheet", "items": [line], "to_sheet": "Two"]])).first)
        XCTAssertEqual(drawn.dictionary("moved")?["lines"] as? [String], [line])
        XCTAssertEqual(Set(drawn.dictionary("moved")?["junctions"] as? [String] ?? []), [a, b])
        XCTAssertNil(drawn.dictionary("moved")?["symbols"])
        let project = try HorizontalProject.load(from: root)
        let two = try XCTUnwrap(project.schematic?.sheets.first { $0.index == 2 })
        XCTAssertEqual(HorizontalSchematicMoveToSheet.items(for: two.drawingLines.map { HorizontalSelectableRef(id: $0.id, type: .drawingLine) }),
                       [line], "the canvas's ref for it maps back to the line")
    }
}
