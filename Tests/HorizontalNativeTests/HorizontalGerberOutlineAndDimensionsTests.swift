import XCTest
@testable import HorizontalNative

/// What the Gerber set draws for the board's shape, its dimensions and its
/// plane fills: the outline as its edges, the dimensions on a layer of their
/// own, and a fill's holes cleared rather than filled in.
final class HorizontalGerberOutlineAndDimensionsTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [HorizontalPoint] {
        [point(x0, y0), point(x1, y0), point(x1, y1), point(x0, y1)]
    }

    private func plane(_ id: String, _ paths: [[HorizontalPoint]]) -> HorizontalPlane {
        HorizontalPlane(
            id: id, netID: "gnd", polygonID: "\(id)/polygon", layer: Fixture.top, priority: 0,
            fillStyle: "solid", minWidth: 200_000, keepOrphans: false,
            fragments: [HorizontalPlaneFragment(paths: paths, orphan: false)]
        )
    }

    private let dimension = HorizontalDimension(
        id: "d", p0: HorizontalPoint(x: 0, y: 0), p1: HorizontalPoint(x: 10_000_000, y: 0),
        labelDistance: 2_000_000, labelSize: 1_000_000, mode: .distance
    )

    /// The lines of each region the file draws, in order.
    private func regions(_ gerber: String) -> [[String]] {
        var regions = [[String]]()
        var current: [String]?
        for line in gerber.split(separator: "\n").map(String.init) {
            if line == "G36*" {
                current = []
            } else if line == "G37*" {
                if let current { regions.append(current) }
                current = nil
            } else {
                current?.append(line)
            }
        }
        return regions
    }

    // MARK: Outline

    /// The outline is where the board is cut: its file strokes each edge at
    /// the outline width, as Horizon's does, where it filled the whole board
    /// as one region.
    func testOutlineIsItsEdgesAtTheOutlineWidth() throws {
        let corners = square(0, 0, 20, 10)
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(polygons: [
            HorizontalPolygon(id: "outline", vertices: corners, layer: HorizontalBoardLayers.outline)
        ]))

        let outline = try XCTUnwrap(gerbers[HorizontalBoardLayers.outline])
        XCTAssertFalse(outline.contains("G36*"), "the outline must not be a filled region")
        XCTAssertTrue(outline.contains("%ADD10C,0.010000*%"), "edges are drawn at the outline width")
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % corners.count]
            XCTAssertTrue(
                outline.contains("\(Fixture.coordinate(corner))D02*\n\(Fixture.coordinate(next))D01*"),
                "edge \(index) is missing"
            )
        }
    }

    func testOutlineArcIsDrawnAlongItsCurve() throws {
        var outline = HorizontalPolygon(id: "outline", vertices: square(0, 0, 20, 10), layer: HorizontalBoardLayers.outline)
        // The top edge is an arc about (10, 5), rising to y = 5 + √125 ≈ 16.2.
        outline.polygonVertices[2].type = .arc
        outline.polygonVertices[2].arcCenter = point(10, 5)
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(polygons: [outline]))

        let file = try XCTUnwrap(gerbers[HorizontalBoardLayers.outline])
        XCTAssertFalse(file.contains("G36*"))
        let ys = file.split(separator: "\n").compactMap { line -> Double? in
            guard let y = line.range(of: "Y"), let d = line.range(of: "D0") else { return nil }
            return Double(line[y.upperBound..<d.lowerBound])
        }
        XCTAssertGreaterThan(ys.max() ?? 0, 14_900_000, "the arc's top is drawn")
    }

    // MARK: Dimensions

    func testDimensionsHaveALayerOfTheirOwn() throws {
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(dimensions: [dimension]))

        let dimensions = try XCTUnwrap(gerbers[HorizontalBoardLayers.dimensions], "a board with dimensions writes the layer")
        // The extension line at p0 runs out past the measuring line by half
        // the label size.
        XCTAssertTrue(dimensions.contains("X0Y0D02*\nX0Y2500000D01*"))
        XCTAssertTrue(dimensions.contains("X10000000Y0D02*\nX10000000Y2500000D01*"))
        // The measuring line starts at q0 and an arrowhead opens from it.
        XCTAssertTrue(dimensions.contains("X0Y2000000D02*"))
        XCTAssertFalse(dimensions.contains("G36*"))
        // Two extension lines, two halves of the measuring line, four arrow
        // strokes, and the label's strokes.
        let strokes = dimensions.components(separatedBy: "D01*").count - 1
        XCTAssertGreaterThan(strokes, 8, "the label is drawn too")
        XCTAssertEqual(gerbers.keys.sorted(), [HorizontalBoardLayers.dimensions], "dimensions reach no other layer")
    }

    func testDimensionsLayerIsListedAndOnByDefault() {
        let settings = HorizontalExportSettings(project: Fixture.project(board: Fixture.board())).gerber
        let layer = settings.layers.first { $0.layer == HorizontalBoardLayers.dimensions }
        XCTAssertEqual(layer?.name, "Dimensions")
        XCTAssertEqual(layer?.enabled, true)
        XCTAssertEqual(layer?.filename, " Dimensions.gbr")
    }

    func testABoardWithoutDimensionsWritesNoDimensionsFile() throws {
        let track = HorizontalSegment(id: "t", from: point(0, 0), to: point(5, 0), width: 200_000, layer: Fixture.top, netID: nil)
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(tracks: [track]))
        XCTAssertNil(gerbers[HorizontalBoardLayers.dimensions])
    }

    // MARK: Plane fills

    /// A fill's first path is its outline and the rest its holes. Each path
    /// went out as a dark region, which filled the holes in: a plane's
    /// clearance around a pad of another net fabricated as solid copper.
    func testAFillsHolesAreCleared() throws {
        let outer = square(0, 0, 20, 20)
        let hole = square(5, 5, 10, 10)
        let track = HorizontalSegment(id: "t", from: point(30, 0), to: point(40, 0), width: 200_000, layer: Fixture.top, netID: nil)
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(tracks: [track], planes: [plane("p", [outer, hole])]))

        let top = try XCTUnwrap(gerbers[Fixture.top])
        let lines = top.split(separator: "\n").map(String.init)
        let clear = try XCTUnwrap(lines.firstIndex(of: "%LPC*%"), "the hole is drawn in clear polarity")
        let dark = try XCTUnwrap(lines[clear...].firstIndex(of: "%LPD*%"), "dark polarity comes back")
        let holeRegion = lines[clear..<dark].joined(separator: "\n")
        XCTAssertTrue(holeRegion.contains("\(Fixture.coordinate(hole[0]))D02*"))
        XCTAssertFalse(lines[..<clear].joined(separator: "\n").contains(Fixture.coordinate(hole[0])),
                       "the hole is not drawn dark before it is cleared")
        let trackStart = try XCTUnwrap(lines.firstIndex(of: "\(Fixture.coordinate(track.from))D02*"))
        XCTAssertGreaterThan(trackStart, dark, "the track is drawn after dark polarity is back")
    }

    /// A fill inside another's hole comes after it whatever order the planes
    /// are in, or the larger fill's hole would clear it away.
    func testAFillInsideAnothersHoleIsDrawnAfterIt() throws {
        let island = plane("island", [square(6, 6, 9, 9)])
        let ring = plane("ring", [square(0, 0, 20, 20), square(5, 5, 10, 10)])
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(planes: [island, ring]))

        let regions = regions(try XCTUnwrap(gerbers[Fixture.top]))
        XCTAssertEqual(regions.count, 3)
        XCTAssertEqual(regions.first?.first, "\(Fixture.coordinate(point(0, 0)))D02*", "the ring's outline first")
        XCTAssertEqual(regions.last?.first, "\(Fixture.coordinate(point(6, 6)))D02*", "the island last")
    }
}
