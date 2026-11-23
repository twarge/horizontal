import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The pin Spotlight: every pin of a microcontroller that offers a function
/// (`USART1_TX`), lit as pins on the schematic and as pads on the board,
/// and a click on a free one moving the function's net there.
final class PinFunctionSpotlightTests: XCTestCase {
    private struct MCU {
        var items: [JSONDictionary]
        var part: String
        var gate: String
        var pins: [String: String]
        var pads: [String: String]
        var unit: HorizontalPoolUnit
    }

    private static let names = ["PA9", "PB6", "PA2", "PA10", "VSS"]
    private static let alternates = [
        "PA9": ["USART1_TX", "TIM1_CH2"],
        "PB6": ["USART1_TX", "I2C1_SCL"],
        "PA2": ["SPI1_SCK/USART1_TX", "TIM2_CH3"],
        "PA10": ["USART1_RX"]
    ]

    /// A one-gate part with an MCU's pins down its left edge.
    private func mcu() -> MCU {
        let names = Self.names
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i], direction: .bidirectional,
                alternateNames: (Self.alternates[names[i]] ?? []).map {
                    HorizontalUnitPinAlternateName(id: UUID().uuidString.lowercased(), name: $0, direction: .bidirectional)
                })
        }
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let gate = entity.gates.keys.first ?? ""
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
        return MCU(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                   part: part.uuid, gate: gate,
                   pins: Dictionary(uniqueKeysWithValues: zip(names, pins)),
                   pads: Dictionary(uniqueKeysWithValues: zip(names, pads)), unit: unit)
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pin-functions-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: root)
        session = HorizontalDispatchSession()
        handle = try session.open(url: root).handle
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        let entry = try session.entry(handle: handle)
        if method == "apply" {
            params["expected_revision"] = entry.revision
            params["operation_id"] = UUID().uuidString
        }
        return try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
    }

    @discardableResult
    private func apply(_ ops: [JSONDictionary], _ extra: JSONDictionary = [:]) throws -> JSONDictionary {
        let response = try call("apply", extra.merging(["ops": ops]) { new, _ in new })
        XCTAssertNil(response["error"], "\(response)")
        return try XCTUnwrap(response["result"] as? JSONDictionary)
    }

    private func error(_ ops: [JSONDictionary]) throws -> String {
        let response = try call("apply", ["ops": ops])
        return try XCTUnwrap((response["error"] as? JSONDictionary)?.string("message"), "expected an error: \(response)")
    }

    private func pins() throws -> [String: JSONDictionary] {
        let response = try call("get_component", ["refdes": "U1"])
        let rows = try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)").dictionaryArray("pins")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.string("pin") ?? "", $0) })
    }

    /// The alternates a pin is drawn as, by name.
    private func chosen(_ pin: JSONDictionary?) -> [String]? {
        pin?.dictionary("selected")?["alternates"] as? [String]
    }

    /// U1 drawn and on the board, PA9 carrying USART1_TX on net TX through
    /// a wire to a junction, PA2 on another net, PB6 free.
    @discardableResult
    private func placed(_ mcu: MCU, items: [JSONDictionary]? = nil) throws -> (symbol: String, junction: String) {
        let symbol = UUID().uuidString.lowercased(), junction = UUID().uuidString.lowercased()
        try apply([
            ["op": "ensure_component", "refdes": "U1", "part": mcu.part],
            ["op": "place_symbol", "component": "U1", "x_mm": 100, "y_mm": 100, "id": symbol],
            ["op": "connect", "component": "U1", "pin": "PA9", "net": "TX", "create_net": true],
            ["op": "connect", "component": "U1", "pin": "PA2", "net": "SCK", "create_net": true],
            ["op": "set_pin_alternate", "component": "U1", "pin": "PA9", "alternate": "USART1_TX"],
            ["op": "place_junction", "id": junction, "net": "TX", "x_mm": 90, "y_mm": 100],
            ["op": "draw_net_line", "from": ["kind": "pin", "symbol": symbol, "pin": "PA9"],
             "to": ["kind": "junction", "junction": junction]],
            ["op": "place_component", "component": "U1", "x_mm": 10, "y_mm": 10]
        ], ["pool_items": items ?? mcu.items])
        return (symbol, junction)
    }

    private func spotlight(askedFrom name: String? = nil, _ mcu: MCU, function: String = "usart1_tx") throws -> HorizontalPinFunctionSpotlight {
        let entry = try session.entry(handle: handle)
        let component = try XCTUnwrap(entry.index.component(refdes: "U1"))
        let path = name.flatMap { mcu.pins[$0] }.map { "\(mcu.gate)/\($0)" }
        return try XCTUnwrap(HorizontalPinFunctionSpotlight(component: component, askedFrom: path, function: function))
    }

    func testAnAlternateNameHoldsEachFunctionItJoinsWithASlash() {
        XCTAssertEqual(HorizontalPinFunctions.names(in: "SPI1_SCK/I2S1_CK"), ["SPI1_SCK", "I2S1_CK"])
        XCTAssertEqual(HorizontalPinFunctions.names(in: "USART1_TX"), ["USART1_TX"])
        XCTAssertEqual(HorizontalPinFunctions.names(in: ["TIM2_CH3", "SPI1_SCK/USART1_TX", "USART1_TX"]),
                       ["SPI1_SCK", "TIM2_CH3", "USART1_TX"], "each once, in natural order")
        XCTAssertTrue(HorizontalPinFunctions.offers("SPI1_SCK/USART1_TX", "usart1_tx"))
        XCTAssertFalse(HorizontalPinFunctions.offers("USART1_TX", "USART1_T"), "a whole name, not a prefix")
    }

    func testEveryPinOfferingTheFunctionIsLitAndStandsAsItIs() throws {
        let mcu = mcu()
        try placed(mcu)
        // Asked from a free pin: the pin drawn as the function carries it.
        let lit = try spotlight(askedFrom: "PB6", mcu)
        XCTAssertEqual(lit.function, "USART1_TX", "as the unit spells it")
        XCTAssertEqual(lit.pins.map(\.name), ["PA2", "PA9", "PB6"], "PA10 offers USART1_RX only")
        XCTAssertEqual(lit.pins.map(\.standing), [.taken, .carrying, .free])
        XCTAssertEqual(lit.carrying?.name, "PA9")
        XCTAssertEqual(lit.pin(padID: try XCTUnwrap(mcu.pads["PB6"]))?.name, "PB6", "each with its pad")
        XCTAssertNil(lit.pin(padID: try XCTUnwrap(mcu.pads["VSS"])))
        XCTAssertTrue(lit.summary.contains("click a free one (PB6) to move it from PA9"), lit.summary)

        // Asked from a pin on a net, that pin carries it, drawn as it or not.
        XCTAssertEqual(try spotlight(askedFrom: "PA2", mcu).carrying?.name, "PA2")
        // A function no pin offers lights nothing.
        let entry = try session.entry(handle: handle)
        XCTAssertNil(HorizontalPinFunctionSpotlight(component: try XCTUnwrap(entry.index.component(refdes: "U1")), function: "CAN1_TX"))
    }

    func testTheSheetLightsOnlyThosePinsAndTheBoardOnlyTheirPads() throws {
        let mcu = mcu()
        let drawn = try placed(mcu)
        var lit = try spotlight(askedFrom: "PA9", mcu)
        let project = try session.entry(handle: handle).project
        let sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let keys = lit.pinKeys(in: sheet)
        XCTAssertEqual(keys, Set(["PA9", "PB6", "PA2"].compactMap { mcu.pins[$0] }.map { "\(drawn.symbol)/\($0)" }))

        let subset = SchematicHighlightSubset.sheet(sheet, netIDs: [], componentIDs: [], pinKeys: keys)
        XCTAssertEqual(Set(subset.symbolPins.compactMap { HorizontalPinFunctionSpotlight.pinKey(forGeometryID: $0.id) }), keys)
        XCTAssertFalse(subset.symbolPins.isEmpty)
        XCTAssertTrue(subset.symbols.isEmpty, "the symbol's body stays dimmed")
        XCTAssertTrue(subset.netLines.isEmpty, "and so does the wiring")
        let names = subset.symbolTexts.filter { $0.id.contains("/pin-name/") }
        XCTAssertEqual(names.count, 3, "each lit pin with its name")
        XCTAssertTrue(SchematicHighlightSubset.sheet(sheet, netIDs: [], componentIDs: []).symbolPins.isEmpty, "none without a Spotlight")

        let board = try XCTUnwrap(project.board)
        let package = try XCTUnwrap(board.packages.first)
        lit.boardComponentIDs = [try XCTUnwrap(package.componentID).lowercased()]
        let paths = lit.padPaths(in: board)
        XCTAssertEqual(paths, Set(["PA9", "PB6", "PA2"].compactMap { mcu.pads[$0] }.map { "\(package.id.lowercased())/\($0)" }))
        let boardSubset = BoardHighlightSubset.board(board, netIDs: [], componentIDs: [], padPaths: paths)
        XCTAssertEqual(Set(boardSubset.packagePads.compactMap { HorizontalBoard.padPath(forPadPolygonID: $0.id) }), paths)
        XCTAssertTrue(boardSubset.packages.isEmpty)

        // The pad under a point is found as its component's.
        let center = try XCTUnwrap(board.packagePadPositions["\(package.id.lowercased())/\(try XCTUnwrap(mcu.pads["PB6"]))"])
        let pad = try XCTUnwrap(HorizontalPinFunctionMenu.pad(at: center, in: board))
        XCTAssertEqual(pad.padID, mcu.pads["PB6"])
        XCTAssertEqual(pad.componentID, package.componentID?.lowercased())
        XCTAssertNil(HorizontalPinFunctionMenu.pad(at: HorizontalPoint(x: center.x + 50_000_000, y: center.y), in: board))
    }

    func testMovingTheFunctionTakesItsNetItsWiresAndItsName() throws {
        let mcu = mcu()
        try placed(mcu)
        let lit = try spotlight(askedFrom: "PA9", mcu)
        let free = try XCTUnwrap(lit.pins.first { $0.name == "PB6" })
        XCTAssertNil(lit.move(to: try XCTUnwrap(lit.pins.first { $0.name == "PA2" })), "a taken pin takes nothing")
        let edit = try XCTUnwrap(lit.move(to: free))
        XCTAssertEqual(edit.actionName, "Move USART1_TX to PB6")
        let change = try XCTUnwrap(try apply(edit.ops).dictionaryArray("changes").first)
        XCTAssertEqual(change.string("to_pin_name"), "PB6")
        XCTAssertEqual((change["net_lines"] as? [String])?.count, 1)

        let rows = try pins()
        XCTAssertEqual(rows["PB6"]?.string("net"), "TX")
        XCTAssertEqual(chosen(rows["PB6"]), ["USART1_TX"])
        XCTAssertNil(rows["PA9"]?.string("net"))
        XCTAssertNil(rows["PA9"]?["selected"], "the old pin is back to its own name")
        let lines = try XCTUnwrap(try call("list_net_lines", ["net": "TX"])["result"] as? [JSONDictionary])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.dictionary("from")?.string("pin_name"), "PB6", "the wire ends on the new pin")

        // The Spotlight made again from the new pin: the pins have traded places.
        let after = try spotlight(askedFrom: "PB6", mcu)
        XCTAssertEqual(after.pins.map(\.standing), [.taken, .free, .carrying])
    }

    func testTheMoveKeepsWhatElseTheOldPinShowed() throws {
        let mcu = mcu()
        try placed(mcu)
        try apply([["op": "set_pin_alternate", "component": "U1", "pin": "PA9", "alternate": ["USART1_TX", "TIM1_CH2"],
                    "use_primary_name": true]])
        try apply([["op": "move_pin_net", "component": "U1", "pin": "PA9", "to_pin": "PB6", "function": "USART1_TX"]])
        let rows = try pins()
        XCTAssertEqual(chosen(rows["PA9"]), ["TIM1_CH2"])
        // Without a function only the net moves.
        try apply([["op": "move_pin_net", "component": "U1", "pin": "PB6", "to_pin": "PA9"]])
        let back = try pins()
        XCTAssertEqual(back["PA9"]?.string("net"), "TX")
        XCTAssertEqual(chosen(back["PB6"]), ["USART1_TX"], "what it is drawn as is left")
    }

    func testANetMovesOnlyFromAPinOnOneToAPinThatIsFree() throws {
        let mcu = mcu()
        try placed(mcu)
        let taken = try error([["op": "move_pin_net", "component": "U1", "pin": "PA9", "to_pin": "PA2"]])
        XCTAssertTrue(taken.contains("PA2 is on SCK"), taken)
        let nothing = try error([["op": "move_pin_net", "component": "U1", "pin": "PB6", "to_pin": "PA10"]])
        XCTAssertTrue(nothing.contains("on no net"), nothing)
        let unoffered = try error([["op": "move_pin_net", "component": "U1", "pin": "PA9", "to_pin": "PA10", "function": "USART1_TX"]])
        XCTAssertTrue(unoffered.contains("USART1_RX"), "the alternates the pin does offer: \(unoffered)")
        try apply([["op": "set_no_connect", "component": "U1", "pin": "PB6"]])
        let marked = try error([["op": "move_pin_net", "component": "U1", "pin": "PA9", "to_pin": "PB6"]])
        XCTAssertTrue(marked.contains("no-connect"), marked)
        XCTAssertEqual(try spotlight(askedFrom: "PA9", mcu).pins.first { $0.name == "PB6" }?.standing, .taken, "a pin marked NC isn't free")
        XCTAssertEqual(try pins()["PA9"]?.string("net"), "TX", "and nothing moved")
    }

    func testTheMenuOffersEachFunctionAndTheMoveToAFreePin() throws {
        let mcu = mcu()
        try placed(mcu)
        let lit = try spotlight(askedFrom: "PA9", mcu)
        var shown = [String]()
        let actions = HorizontalPinSpotlightActions(
            spotlight: lit, canMove: true,
            show: { _, _, function in shown.append(function) }, clear: {}, move: { _ in },
            padTarget: { _, _ in nil }
        )
        func target(_ name: String) throws -> HorizontalPinFunctionTarget {
            HorizontalPinFunctionTarget(componentID: lit.componentID, gateID: mcu.gate, pinID: try XCTUnwrap(mcu.pins[name]), pinName: name,
                                        functions: HorizontalPinFunctions.names(in: Self.alternates[name] ?? []))
        }
        func titles(_ entries: [HorizontalTargetItemMenuEntry]) -> [String] {
            entries.flatMap { entry -> [String] in
                switch entry {
                case .command(let title, _): [title]
                case .submenu(let title, let children): ["\(title) ▸"] + titles(children)
                default: []
                }
            }
        }
        XCTAssertEqual(titles(HorizontalPinFunctionMenu.entries(for: try target("PB6"), actions: actions)),
                       ["Move USART1_TX to PB6", "Spotlight Pins Offering ▸", "I2C1_SCL", "USART1_TX"])
        XCTAssertEqual(titles(HorizontalPinFunctionMenu.entries(for: try target("PA10"), actions: actions)),
                       ["Spotlight Pins Offering USART1_RX"], "one function needs no submenu, and PA10 isn't lit")
        XCTAssertEqual(titles(HorizontalPinFunctionMenu.entries(for: try target("PA2"), actions: actions)),
                       ["Spotlight Pins Offering ▸", "SPI1_SCK", "TIM2_CH3", "USART1_TX"], "a taken pin is offered no move")
        XCTAssertTrue(HorizontalPinFunctionMenu.entries(for: try target("VSS"), actions: actions).isEmpty)
        var readOnly = actions
        readOnly.canMove = false
        XCTAssertNil(HorizontalPinFunctionMenu.movable(try target("PB6"), actions: readOnly))

        // The pin under the pointer on the sheet, with what it offers.
        let sheet = try XCTUnwrap(try session.entry(handle: handle).project.schematic?.sheets.first)
        let stem = try XCTUnwrap(sheet.symbolPins.first {
            $0.id.lowercased().hasSuffix("/pin/\(mcu.pins["PB6"] ?? "")")
        })
        let found = try XCTUnwrap(HorizontalPinFunctionMenu.target(at: stem.from, in: sheet))
        XCTAssertEqual(found.pinName, "PB6")
        XCTAssertEqual(found.functions, ["I2C1_SCL", "USART1_TX"])
        XCTAssertNotNil(HorizontalPinFunctionMenu.movable(found, actions: actions))
    }

    /// Units written before `alt_names` keep a pin's alternates as a bare
    /// `names` array; the sheet reads them under the ids Horizon derives,
    /// which a component's choice names.
    func testASheetReadsAlternatesAUnitStillWritesAsAnArrayOfNames() throws {
        let mcu = mcu()
        var items = mcu.items
        var unit = items[0]
        var unitPins = unit.dictionaryMap("pins")
        for (id, pin) in unitPins {
            var legacy = pin
            legacy["names"] = pin.dictionaryMap("alt_names").values.compactMap { $0.string("name") }.sorted()
            legacy.removeValue(forKey: "alt_names")
            unitPins[id] = legacy
        }
        unit["pins"] = unitPins
        items[0] = unit
        try apply([
            ["op": "ensure_component", "refdes": "U1", "part": mcu.part],
            ["op": "place_symbol", "component": "U1", "x_mm": 100, "y_mm": 100],
            ["op": "set_pin_alternate", "component": "U1", "pin": "PB6", "alternate": "USART1_TX"]
        ], ["pool_items": items])
        let sheet = try XCTUnwrap(try session.entry(handle: handle).project.schematic?.sheets.first)
        let pin = try XCTUnwrap(sheet.symbols.first?.symbolPinNames.first { $0.primaryName == "PB6" })
        XCTAssertEqual(pin.alternateNames.map(\.name), ["I2C1_SCL", "USART1_TX"])
        XCTAssertEqual(pin.alternateNames.first { $0.name == "USART1_TX" }?.id, UUID.horizonAlternatePinNameID(index: 1))
        XCTAssertEqual(pin.state.pinNames, [UUID.horizonAlternatePinNameID(index: 1)], "the choice names the same id")
        XCTAssertEqual(HorizontalPinFunctionMenu.target(at: sheet.symbolPins.first { $0.id.hasSuffix("/pin/\(pin.id)") }?.from, in: sheet)?.functions,
                       ["I2C1_SCL", "USART1_TX"])
    }
}
