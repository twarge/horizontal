import XCTest
@testable import HorizontalNative

/// Tests the schematic connectivity query extracted into SchematicMovePlanner.
/// Parallels the board-side BoardMovePlanner tests; the dependency-minimal
/// signature avoids needing a 53-field HorizontalSchematicSheet fixture.
final class SchematicMovePlannerTests: XCTestCase {
    private func affected(
        at point: HorizontalPoint,
        netLines: [HorizontalSegment] = [],
        drawingLines: [HorizontalSegment] = [],
        drawingArcs: [HorizontalArc] = [],
        busRipperLines: [HorizontalSegment] = [],
        netTies: [HorizontalSchematicNetTie] = [],
        netLabels: [HorizontalSchematicNetLabel] = [],
        busLabels: [HorizontalBusLabel] = [],
        junctions: [String: HorizontalPoint] = [:],
        powerSymbolAnchors: [String: [HorizontalPoint]] = [:]
    ) -> Set<HorizontalSelectableRef> {
        SchematicMovePlanner.connectionAffectedRefs(
            at: point, netLines: netLines, drawingLines: drawingLines, drawingArcs: drawingArcs,
            busRipperLines: busRipperLines, netTies: netTies, netLabels: netLabels,
            busLabels: busLabels, junctions: junctions, powerSymbolAnchors: powerSymbolAnchors)
    }

    func testNetLineEndpointIsAffected() {
        let line = HorizontalSegment(id: "nl1", from: HorizontalPoint(x: 0, y: 0),
                                  to: HorizontalPoint(x: 100, y: 0), width: 10, layer: 0)
        let refs = affected(at: HorizontalPoint(x: 0, y: 0), netLines: [line])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "nl1", type: .lineNet)))
    }

    func testJunctionAndNetLabelAtPoint() {
        let refs = affected(
            at: HorizontalPoint(x: 50, y: 50),
            netLabels: [HorizontalSchematicNetLabel(id: "L1", text: "N",
                                                 position: HorizontalPoint(x: 50, y: 50), size: 100, orientation: "right")],
            junctions: ["j1": HorizontalPoint(x: 50, y: 50)])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "j1", type: .junction)))
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "L1", type: .netLabel)))
    }

    func testDrawingArcEndpointAndCenter() {
        let arc = HorizontalArc(id: "a1", from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 100, y: 0),
                             center: HorizontalPoint(x: 50, y: 30), width: 10, layer: 0)
        XCTAssertTrue(affected(at: HorizontalPoint(x: 50, y: 30), drawingArcs: [arc])
            .contains(HorizontalSelectableRef(id: "a1", type: .drawingArc)))
    }

    func testPowerSymbolAnchorAtPoint() {
        let refs = affected(at: HorizontalPoint(x: 10, y: 20),
                            powerSymbolAnchors: ["ps1": [HorizontalPoint(x: 10, y: 20)]])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "ps1", type: .powerSymbol)))
    }

    func testBusRipperLineResolvesToRipperID() {
        let line = HorizontalSegment(id: "ripper1/line/seg", from: HorizontalPoint(x: 0, y: 0),
                                  to: HorizontalPoint(x: 5, y: 0), width: 10, layer: 0)
        let refs = affected(at: HorizontalPoint(x: 0, y: 0), busRipperLines: [line])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "ripper1", type: .busRipper)))
    }

    func testNothingAtPointIsEmpty() {
        let line = HorizontalSegment(id: "nl1", from: HorizontalPoint(x: 0, y: 0),
                                  to: HorizontalPoint(x: 100, y: 0), width: 10, layer: 0)
        XCTAssertTrue(affected(at: HorizontalPoint(x: 999, y: 999), netLines: [line]).isEmpty)
    }
}
