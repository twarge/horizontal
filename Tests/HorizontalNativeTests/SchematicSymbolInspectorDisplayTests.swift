import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A placed symbol's inspector rows for what Horizon's symbol property
/// editor sets: the pool symbol drawing the gate, chosen among those the
/// project pool has for its unit; the pin display mode; display all pads.
/// Each change is one batch of the automation channel's edits, so one undo
/// step.
final class SchematicSymbolInspectorDisplayTests: XCTestCase {
    private var fixture: SchematicProjectEditFixture!

    override func setUpWithError() throws {
        fixture = try SchematicProjectEditFixture(testCase: self)
        try fixture.placeResistors(["R1"])
    }

    private func property(_ id: String, of symbol: HorizontalPlacement, editable: Bool = true) throws -> HorizontalSelectionProperty {
        let choices = HorizontalSchematicSymbolProperties.symbols(drawingTheUnitOf: try XCTUnwrap(symbol.symbolID), poolURL: fixture.poolURL)
        return try XCTUnwrap(HorizontalSchematicSymbolProperties.properties(for: symbol, symbols: choices, editable: editable)
            .first { $0.id == id })
    }

    func testTheSymbolRowOffersEverySymbolThePoolHasForTheUnitByName() throws {
        let symbol = try fixture.symbol("R1")
        let choices = HorizontalSchematicSymbolProperties.symbols(drawingTheUnitOf: try XCTUnwrap(symbol.symbolID), poolURL: fixture.poolURL)
        XCTAssertEqual(choices.map(\.name), ["Resistor", "Resistor (US)"])
        XCTAssertEqual(choices.map(\.id), [fixture.symbol, fixture.otherSymbol])

        let row = try property(HorizontalSchematicSymbolProperties.symbolID, of: symbol)
        XCTAssertEqual(row.value, .choice(fixture.symbol))
        guard case .choice(let options) = row.editor else { return XCTFail("a choice") }
        XCTAssertEqual(options.map(\.title), ["Resistor", "Resistor (US)"])

        XCTAssertEqual(try property(HorizontalSchematicSymbolProperties.symbolID, of: symbol, editable: false).value, .readOnly("Resistor"))
    }

    func testChoosingAnotherSymbolRedrawsTheGateInPlaceWithItsWiringOnTheNewPins() throws {
        try fixture.apply([["op": "terminate_pin", "component": "R1", "pin": "1", "kind": "label", "net": "SIG", "create_net": true]])
        let before = try fixture.symbol("R1")
        let edit = try XCTUnwrap(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.symbolID, value: .choice(fixture.otherSymbol), placements: [before]))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Change Symbol")
        try fixture.apply(edit.ops)

        let after = try fixture.symbol("R1")
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.symbolID, fixture.otherSymbol)
        XCTAssertEqual(after.position, before.position)
        let sheet = try fixture.sheet
        let pinEnd = try XCTUnwrap(sheet.symbolPins.first { $0.id.lowercased() == "\(after.id.lowercased())/pin/\(fixture.pins[0])" }).from
        XCTAssertEqual(pinEnd.x, after.position.x, accuracy: 1, "the American symbol's pin 1 is above it")
        let ends = sheet.netLines.flatMap { [$0.from, $0.to] }
        XCTAssertTrue(ends.contains(pinEnd), "the wire on pin 1 ends where the new symbol draws it")
        XCTAssertEqual(sheet.componentInfo[try XCTUnwrap(after.componentID).lowercased()]?.connections["\(fixture.gate)/\(fixture.pins[0])"]?.netID != nil, true)

        XCTAssertNil(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.symbolID, value: .choice(fixture.otherSymbol), placements: [after]),
                     "choosing the symbol it has changes nothing")
    }

    func testPinDisplayModeAndDisplayAllPadsAreWrittenToTheSymbolInstance() throws {
        let symbol = try fixture.symbol("R1")
        XCTAssertEqual(try property(HorizontalSchematicSymbolProperties.pinDisplayModeID, of: symbol).value, .choice("selected_only"))
        XCTAssertEqual(try property(HorizontalSchematicSymbolProperties.displayAllPadsID, of: symbol).value, .bool(true))

        let mode = try XCTUnwrap(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.pinDisplayModeID, value: .choice("all"), placements: [symbol]))
        let pads = try XCTUnwrap(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.displayAllPadsID, value: .bool(false), placements: [symbol]))
        XCTAssertEqual(mode.actionName, "Set Pin Display Mode")
        try fixture.apply(mode.ops)
        try fixture.apply(pads.ops)

        let after = try fixture.symbol("R1")
        XCTAssertEqual(after.pinDisplayMode, "all")
        XCTAssertFalse(after.displayAllPads)
        let item = try XCTUnwrap(try fixture.sheetJSON().dictionaryMap("symbols").first { $0.key.lowercased() == symbol.id.lowercased() }?.value)
        XCTAssertEqual(item.string("pin_display_mode"), "all")
        XCTAssertEqual(item.bool("display_all_pads"), false)
        XCTAssertNil(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.pinDisplayModeID, value: .choice("all"), placements: [after]))
        XCTAssertNil(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.pinDisplayModeID, value: .choice("everything"), placements: [after]))
    }

    func testPinDisplayModeAppliedToAllSetsEverySelectedSymbolInOneBatch() throws {
        try fixture.placeResistors(["R1", "R2"])
        let symbols = [try fixture.symbol("R1"), try fixture.symbol("R2")]
        let edit = try XCTUnwrap(HorizontalSchematicSymbolProperties.edit(
            propertyID: HorizontalSchematicSymbolProperties.pinDisplayModeID, value: .choice("both"), placements: symbols))
        XCTAssertEqual(edit.ops.count, 2)
        try fixture.apply(edit.ops)
        XCTAssertEqual(try fixture.symbol("R1").pinDisplayMode, "both")
        XCTAssertEqual(try fixture.symbol("R2").pinDisplayMode, "both")
    }
}
