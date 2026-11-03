import XCTest
@testable import HorizontalNative

/// A dashed polyline's segments carry how far along it each starts, so the
/// dashes run on round its corners. Before, every segment started a dash
/// afresh, and an arc, drawn as chords shorter than one dash, came out solid
/// where the straight edges either side of it were dashed.
final class HorizontalMetalLineDashTests: XCTestCase {
    private let mm = 1_000_000.0

    func testDashPhasesAreTheRunningLength() {
        let points = [
            HorizontalPoint(x: 0, y: 0),
            HorizontalPoint(x: 3 * mm, y: 0),
            HorizontalPoint(x: 3 * mm, y: 4 * mm),
            HorizontalPoint(x: 0, y: 0),
        ]
        let phases = HorizontalMetalLinePrimitive.dashPhases(along: points)
        XCTAssertEqual(phases.count, 3)
        XCTAssertEqual(phases[0], 0)
        XCTAssertEqual(phases[1], 3 * mm, accuracy: 1e-6)
        XCTAssertEqual(phases[2], 7 * mm, accuracy: 1e-6)
        XCTAssertEqual(HorizontalMetalLinePrimitive.dashPhases(along: [points[0]]), [])
    }

    func testASelectedArcsDashesRunOnAlongItsChords() throws {
        // A rounded corner's edge, as the board draws it: a quarter arc in chords.
        var polygon = HorizontalPolygon(id: "p", vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 0),
            HorizontalPoint(x: 10 * mm, y: 10 * mm), HorizontalPoint(x: 0, y: 10 * mm),
        ], layer: HorizontalBoardLayers.outline)
        polygon = try XCTUnwrap(HorizontalPolygonRounding(polygon: polygon, vertexIndex: 1)).polygon(radius: 2 * mm)
        let arc = polygon.edgePolyline(at: 1, arcPrecision: 24)
        XCTAssertGreaterThan(arc.count, 3)

        let ref = HorizontalSelectableRef(id: "p", type: .polygonEdge, vertex: 1, layer: HorizontalBoardLayers.outline)
        let selectable = HorizontalSelectable.bounds(ref: ref, points: arc, fallbackCenter: .zero, fallbackSize: mm)
        let color = HorizontalMetalRGBA(red: 1, green: 1, blue: 0, alpha: 1)
        let overlay = HorizontalCanvasModeSupport.metalSelectionOverlay(
            selectablesForRef: { $0 == ref ? [selectable] : [] },
            selectedRefs: [ref],
            hoveredRef: nil,
            style: HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: color, selectedInnerColor: color, selectedHandleInnerColor: color,
                hoverOuterColor: color, hoverInnerColor: color, handleShape: .diamond
            ),
            outlineForSelectable: { _ in
                HorizontalCanvasSelectionOutline(points: arc, closesPath: false, normalOffset: 0, dashesWhenSelected: true)
            }
        )

        XCTAssertEqual(overlay.lines.count, arc.count - 1)
        XCTAssertTrue(overlay.lines.allSatisfy { $0.dashLength > 0 }, "a selected polygon edge is dashed")
        var length = 0.0
        for line in overlay.lines {
            XCTAssertEqual(line.dashPhase, length, accuracy: 1e-6, "each chord starts where the last left off")
            length += hypot(line.to.x - line.from.x, line.to.y - line.from.y)
        }
        XCTAssertEqual(length, .pi * mm, accuracy: 0.01 * mm, "a quarter turn of radius 2 mm")
    }
}
