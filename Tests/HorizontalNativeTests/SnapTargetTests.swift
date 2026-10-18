import XCTest
@testable import HorizontalNative

/// What the cursor snaps to on each kind of object
/// (`HorizontalSelectable.anchorSnapPoints`): where it is placed and where it
/// joins things, never the selection box, whose corners and centre sat off the
/// grid and pulled moves off it.
final class SnapTargetTests: XCTestCase {
    private let mm = 1_000_000.0

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func keys(_ points: [HorizontalPoint]) -> Set<String> {
        Set(points.map(HorizontalCanvasModeSupport.pointKey))
    }

    func testAPartSnapsAtItsOriginNotItsBox() {
        let symbol = HorizontalSelectable.bounds(
            ref: HorizontalSelectableRef(id: "r1", type: .schematicSymbol),
            points: [point(-1.27, -3.81), point(1.27, 3.81)],
            fallbackCenter: point(0, 0),
            fallbackSize: 2.54 * mm
        )
        XCTAssertEqual(symbol.anchorSnapPoints, [point(0, 0)])
    }

    func testAWireSnapsAtItsEndsAndNotItsMiddle() {
        let wires = HorizontalCanvasModeSupport.segmentSelectables(
            [HorizontalSegment(id: "w", from: point(0, 0), to: point(3.75, 0), width: 0, layer: nil)],
            type: .lineNet
        )
        XCTAssertEqual(wires.count, 2, "the line and its middle grab handle")
        XCTAssertEqual(keys(wires.flatMap(\.anchorSnapPoints)), keys([point(0, 0), point(3.75, 0)]))
    }

    func testAnArcSnapsAtItsEndsAndCentre() {
        let arc = HorizontalArc(id: "a", from: point(1, 0), to: point(0, 1), center: point(0, 0), width: 0, layer: nil)
        let selectables = HorizontalCanvasModeSupport.arcSelectables([arc], type: .drawingArc)
        XCTAssertEqual(keys(selectables.flatMap(\.anchorSnapPoints)), keys([point(1, 0), point(0, 1), point(0, 0)]))
    }

    func testAPolygonEdgeSnapsAtItsMiddleAsHorizonsDoes() {
        let edge = HorizontalSelectable.line(
            ref: HorizontalSelectableRef(id: "p", type: .polygonEdge, vertex: 0),
            from: point(0, 0), to: point(2, 0), width: 0
        )
        XCTAssertEqual(edge.anchorSnapPoints, [point(1, 0)])
    }

    func testABlockSymbolGivesNoneOfItsOwn() {
        let block = HorizontalSelectable.bounds(
            ref: HorizontalSelectableRef(id: "b", type: .schematicBlockSymbol),
            points: [point(0, 0), point(10, 10)],
            fallbackCenter: point(5, 5),
            fallbackSize: mm
        )
        XCTAssertTrue(block.anchorSnapPoints.isEmpty, "its ports' ends come from the sheet")
    }

    func testGivenAnchorsOverrideTheTypesRule() {
        var package = HorizontalSelectable.bounds(
            ref: HorizontalSelectableRef(id: "u1", type: .boardPackage),
            points: [point(-2, -2), point(2, 2)],
            fallbackCenter: point(0, 0),
            fallbackSize: mm
        )
        package.snapAnchors = [point(0, 0), point(-1.5, 0), point(1.5, 0)]
        XCTAssertEqual(package.anchorSnapPoints, [point(0, 0), point(-1.5, 0), point(1.5, 0)])
    }

    func testTheScenesTargetsAreTheAnchorsOnce() {
        let scene = HorizontalCanvasSelectableScene(selectables: [
            HorizontalSelectable.bounds(
                ref: HorizontalSelectableRef(id: "r1", type: .schematicSymbol),
                points: [point(-1, -3), point(1, 3)],
                fallbackCenter: point(0, 0),
                fallbackSize: mm
            ),
            HorizontalSelectable.point(ref: HorizontalSelectableRef(id: "j", type: .junction), at: point(0, 0)),
            HorizontalSelectable.point(ref: HorizontalSelectableRef(id: "k", type: .junction), at: point(5, 0)),
        ])
        let targets = scene.snapTargets(pointKey: HorizontalCanvasModeSupport.pointKey)
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(keys(targets), keys([point(0, 0), point(5, 0)]))
    }
}
