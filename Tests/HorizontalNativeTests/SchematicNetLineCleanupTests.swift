import XCTest
@testable import HorizontalNative

/// Horizon's wire tidy-up (`delete_duplicate_net_lines` + `simplify_net_lines`)
/// as `HorizontalSchematicSheet.simplifyNetLines()` applies it.
final class SchematicNetLineCleanupTests: XCTestCase {
    private let grid = 1_250_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint { .init(x: x * grid, y: y * grid) }

    /// A symbol pin at (0, 0) wired right to a corner junction at (4, 0) and
    /// down to a net label's junction at (4, -2): the jog in the screenshot.
    private func jogSheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: grid)
        sheet.symbolPins = [.init(id: "sym/pin/p26", from: point(0, 0), to: point(-1, 0), width: 0, layer: nil, netID: "net")]
        sheet.junctions = ["corner": point(4, 0), "label": point(4, -2)]
        sheet.junctionNetIDs = ["corner": "net", "label": "net"]
        sheet.netLines = [
            .init(id: "run", from: point(0, 0), to: point(4, 0), width: 0, layer: nil, netID: "net",
                  schematicFrom: .pin("sym/p26"), schematicTo: .junction("corner")),
            .init(id: "jog", from: point(4, 0), to: point(4, -2), width: 0, layer: nil, netID: "net",
                  schematicFrom: .junction("corner"), schematicTo: .junction("label")),
        ]
        sheet.netLabels = [.init(id: "L", text: "Signal 2+", position: point(4, -2), size: 1_500_000,
                                 orientation: "right", netID: "net", junctionID: "label")]
        return sheet
    }

    func testLabelMovedOntoTheCornerLeavesNoZeroLengthWire() {
        var sheet = jogSheet()
        // What the move leaves once the label's junction has merged into the corner.
        sheet.junctions.removeValue(forKey: "corner")
        sheet.junctions["label"] = point(4, 0)
        sheet.netLines[0].schematicTo = .junction("label")
        sheet.netLines[1] = .init(id: "jog", from: point(4, 0), to: point(4, 0), width: 0, layer: nil, netID: "net",
                                  schematicFrom: .junction("label"), schematicTo: .junction("label"))
        sheet.netLabels[0].position = point(4, 0)

        let cleanup = sheet.simplifyNetLines()

        XCTAssertEqual(cleanup.removedNetLineIDs, ["jog"])
        XCTAssertEqual(cleanup.removedJunctionIDs, [])
        XCTAssertEqual(sheet.netLines.map(\.id), ["run"])
        XCTAssertEqual(sheet.netLines[0].to, point(4, 0))
        XCTAssertEqual(sheet.junctions, ["label": point(4, 0)])
        XCTAssertTrue(HorizontalSchematicWarnings.evaluate(sheet).allSatisfy { !$0.messages.contains("Zero length line") })
    }

    func testZeroLengthWireBetweenTwoJunctionsAtOnePointMergesThrough() {
        var sheet = jogSheet()
        // The label's junction lands on the corner but stays a junction of
        // its own: the corner holds only the two wires, so it merges away
        // and the run ends on the label's junction.
        sheet.junctions["label"] = point(4, 0)
        sheet.netLines[1].to = point(4, 0)
        sheet.netLabels[0].position = point(4, 0)

        let cleanup = sheet.simplifyNetLines()

        XCTAssertEqual(cleanup.removedNetLineIDs, ["jog"])
        XCTAssertEqual(cleanup.removedJunctionIDs, ["corner"])
        XCTAssertEqual(sheet.netLines.map(\.id), ["run"])
        XCTAssertEqual(sheet.netLines[0].schematicTo, .junction("label"))
        XCTAssertEqual(sheet.junctions, ["label": point(4, 0)])
    }

    func testLabelMovedPastTheCornerMergesTheStraightRun() {
        var sheet = jogSheet()
        // Label moved up and right, so the corner is now a bend-free junction.
        sheet.junctions["label"] = point(7, 0)
        sheet.netLines[1].to = point(7, 0)
        sheet.netLabels[0].position = point(7, 0)

        let cleanup = sheet.simplifyNetLines()

        XCTAssertEqual(cleanup.removedNetLineIDs, ["jog"])
        XCTAssertEqual(cleanup.removedJunctionIDs, ["corner"])
        XCTAssertEqual(sheet.netLines.count, 1)
        let line = sheet.netLines[0]
        XCTAssertEqual(line.id, "run")
        XCTAssertEqual(line.from, point(0, 0))
        XCTAssertEqual(line.schematicFrom, .pin("sym/p26"))
        XCTAssertEqual(line.to, point(7, 0))
        XCTAssertEqual(line.schematicTo, .junction("label"))
    }

    func testCornerIsKept() {
        var sheet = jogSheet()
        XCTAssertTrue(sheet.simplifyNetLines().isEmpty)
        XCTAssertEqual(sheet.netLines.count, 2)
        XCTAssertEqual(sheet.junctions.count, 2)
    }

    func testPinLabelWireOfZeroLengthIsKept() {
        // A label dropped on a pin gets its own junction and a zero-length
        // pin-to-junction wire, which Horizon keeps.
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: grid)
        sheet.symbolPins = [.init(id: "sym/pin/p1", from: point(0, 0), to: point(-1, 0), width: 0, layer: nil, netID: "net")]
        sheet.junctions = ["j": point(0, 0)]
        sheet.netLines = [.init(id: "stub", from: point(0, 0), to: point(0, 0), width: 0, layer: nil, netID: "net",
                                schematicFrom: .pin("sym/p1"), schematicTo: .junction("j"))]
        sheet.netLabels = [.init(id: "L", text: "N", position: point(0, 0), size: 1_500_000,
                                 orientation: "right", netID: "net", junctionID: "j")]
        XCTAssertTrue(sheet.simplifyNetLines().isEmpty)
        XCTAssertEqual(sheet.netLines.map(\.id), ["stub"])
    }

    func testDuplicateWireIsRemovedEitherWayRound() {
        var sheet = jogSheet()
        sheet.netLines.append(.init(id: "copy", from: point(4, -2), to: point(4, 0), width: 0, layer: nil, netID: "net",
                                    schematicFrom: .junction("label"), schematicTo: .junction("corner")))
        let cleanup = sheet.simplifyNetLines()
        XCTAssertEqual(cleanup.removedNetLineIDs, ["copy"])
        XCTAssertEqual(sheet.netLines.map(\.id), ["run", "jog"])
    }

    func testSelfLoopOnABareJunctionTakesTheJunctionToo() {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: grid)
        sheet.junctions = ["j": point(2, 2)]
        sheet.netLines = [.init(id: "loop", from: point(2, 2), to: point(2, 2), width: 0, layer: nil,
                                schematicFrom: .junction("j"), schematicTo: .junction("j"))]
        let cleanup = sheet.simplifyNetLines()
        XCTAssertEqual(cleanup.removedNetLineIDs, ["loop"])
        XCTAssertEqual(cleanup.removedJunctionIDs, ["j"])
        XCTAssertTrue(sheet.junctions.isEmpty)
    }

    func testJunctionWithAThirdWireOrAPowerSymbolIsNotMerged() {
        var sheet = jogSheet()
        sheet.netLines[1].to = point(8, 0)
        sheet.junctions["label"] = point(8, 0)
        sheet.netLabels[0].position = point(8, 0)
        sheet.junctions["tee"] = point(4, 3)
        sheet.netLines.append(.init(id: "branch", from: point(4, 0), to: point(4, 3), width: 0, layer: nil,
                                    schematicFrom: .junction("corner"), schematicTo: .junction("tee")))
        XCTAssertTrue(sheet.simplifyNetLines().isEmpty)

        sheet.netLines.removeLast()
        sheet.junctions.removeValue(forKey: "tee")
        sheet.powerSymbols = [.init(id: "gnd", junctionID: "corner", netID: "net", orientation: "down", mirrored: false)]
        XCTAssertTrue(sheet.simplifyNetLines().isEmpty)
        XCTAssertEqual(sheet.netLines.count, 2)
    }
}
