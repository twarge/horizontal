import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The schematic's right-click Set Pin … NC and Clear Pin … NC: offered for
/// the pin under the pointer on a placed symbol, as Horizon's Set NC and
/// Clear NC act on one pin, and nothing for a connected pin or a point on
/// no pin. The edit is one set_no_connect, so one undo step.
final class SchematicPinNoConnectMenuTests: XCTestCase {
    private var fixture: SchematicProjectEditFixture!

    override func setUpWithError() throws {
        fixture = try SchematicProjectEditFixture(testCase: self)
        try fixture.placeResistors(["R1"])
    }

    private func pinEnd(_ pin: String, of symbol: HorizontalPlacement) throws -> HorizontalPoint {
        let sheet = try fixture.sheet
        return try XCTUnwrap(sheet.symbolPins.first { $0.id.lowercased() == "\(symbol.id.lowercased())/pin/\(pin)" }).from
    }

    private func titles(_ entries: [HorizontalTargetItemMenuEntry]) -> [String] {
        entries.compactMap { if case .command(let title, _) = $0 { title } else { nil } }
    }

    func testTheMenuOffersSetNCForTheUnconnectedPinUnderThePointerAndClearOnceMarked() throws {
        let symbol = try fixture.symbol("R1")
        let ref = HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol)
        let end = try pinEnd(fixture.pins[1], of: symbol)
        let near = HorizontalPoint(x: end.x + 200_000, y: end.y + 300_000)

        let found = try XCTUnwrap(HorizontalSchematicPinNoConnect.pin(of: symbol.id, nearest: near, in: try fixture.sheet))
        XCTAssertEqual(found.pinID, fixture.pins[1])
        XCTAssertEqual(found.name, "2")
        XCTAssertEqual(titles(HorizontalSchematicPinNoConnect.menuEntries(for: ref, at: near, in: try fixture.sheet)), ["Set Pin 2 NC"])

        let edit = try XCTUnwrap(HorizontalSchematicPinNoConnect.edit(symbol: symbol.id, pin: found.pinID, mark: true, in: try fixture.sheet))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Set Pin 2 NC")
        try fixture.apply(edit.ops)

        let connections = try XCTUnwrap(try fixture.sheet.componentInfo[XCTUnwrap(symbol.componentID).lowercased()]?.connections)
        XCTAssertEqual(connections["\(fixture.gate)/\(fixture.pins[1])"], .notConnected)
        XCTAssertNil(connections["\(fixture.gate)/\(fixture.pins[0])"], "only the pin under the pointer is marked")
        XCTAssertNil(HorizontalSchematicPinNoConnect.edit(symbol: symbol.id, pin: found.pinID, mark: true, in: try fixture.sheet),
                     "marking it again changes nothing")

        XCTAssertEqual(titles(HorizontalSchematicPinNoConnect.menuEntries(for: ref, at: near, in: try fixture.sheet)), ["Clear Pin 2 NC"])
        let clear = try XCTUnwrap(HorizontalSchematicPinNoConnect.edit(symbol: symbol.id, pin: found.pinID, mark: false, in: try fixture.sheet))
        try fixture.apply(clear.ops)
        XCTAssertNil(try fixture.sheet.componentInfo[XCTUnwrap(symbol.componentID).lowercased()]?.connections["\(fixture.gate)/\(fixture.pins[1])"])
    }

    func testAConnectedPinOrAPointOnNoPinOffersNothing() throws {
        try fixture.apply([["op": "connect", "component": "R1", "pin": "1", "net": "SIG", "create_net": true]])
        let symbol = try fixture.symbol("R1")
        let ref = HorizontalSelectableRef(id: symbol.id, type: .schematicSymbol)
        let connected = try pinEnd(fixture.pins[0], of: symbol)
        XCTAssertEqual(HorizontalSchematicPinNoConnect.menuEntries(for: ref, at: connected, in: try fixture.sheet).count, 0)
        XCTAssertNil(HorizontalSchematicPinNoConnect.edit(symbol: symbol.id, pin: fixture.pins[0], mark: true, in: try fixture.sheet))

        // The symbol's middle is 5 mm from either pin's end and 2.5 mm from its line.
        XCTAssertEqual(HorizontalSchematicPinNoConnect.menuEntries(for: ref, at: symbol.position, in: try fixture.sheet).count, 0)
    }
}
