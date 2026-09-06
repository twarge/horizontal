import XCTest
@testable import HorizontalNative

/// Outline-layer polygons nest: a polygon inside another is a cutout, and a
/// polygon inside a cutout is board again.
final class HorizontalBoardOutlinesTests: XCTestCase {
    private let mm = 1_000_000.0

    private func square(_ id: String, center: HorizontalPoint, half: Double, layer: Int = HorizontalBoardLayers.outline) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [
                HorizontalPoint(x: center.x - half, y: center.y - half),
                HorizontalPoint(x: center.x + half, y: center.y - half),
                HorizontalPoint(x: center.x + half, y: center.y + half),
                HorizontalPoint(x: center.x - half, y: center.y + half),
            ],
            layer: layer
        )
    }

    func testCutoutsNestUnderTheirOuterPolygon() {
        let polygons = [
            square("cutout", center: HorizontalPoint(x: 10 * mm, y: 10 * mm), half: 3 * mm),
            square("board", center: HorizontalPoint(x: 0, y: 0), half: 30 * mm),
            square("island", center: HorizontalPoint(x: 10 * mm, y: 10 * mm), half: mm),
            square("second board", center: HorizontalPoint(x: 100 * mm, y: 0), half: 20 * mm),
            square("silk", center: HorizontalPoint(x: 0, y: 0), half: 5 * mm, layer: HorizontalBoardLayers.topSilkscreen),
            square("notes", center: HorizontalPoint(x: 0, y: 0), half: 5 * mm, layer: HorizontalBoardLayers.outlineNotes),
        ]
        let shapes = HorizontalBoardOutlines.shapes(from: polygons)
        XCTAssertEqual(shapes.map(\.outer.id), ["board", "second board", "island"])
        let board = shapes[0]
        XCTAssertEqual(board.cutoutPolygons.map(\.id), ["cutout"])
        XCTAssertEqual(board.cutouts.first?.count, 4)
        XCTAssertTrue(shapes[1].cutouts.isEmpty)
        XCTAssertTrue(shapes[2].cutouts.isEmpty, "an island inside a cutout is board of its own")
    }

    func testContainment() {
        let polygon = square("s", center: HorizontalPoint(x: 0, y: 0), half: mm).vertices
        XCTAssertTrue(HorizontalBoardOutlines.contains(HorizontalPoint(x: 0.5 * mm, y: -0.5 * mm), in: polygon))
        XCTAssertFalse(HorizontalBoardOutlines.contains(HorizontalPoint(x: 1.5 * mm, y: 0), in: polygon))
        XCTAssertFalse(HorizontalBoardOutlines.contains(HorizontalPoint(x: 0, y: 0), in: []))
    }
}
