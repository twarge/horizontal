import XCTest
@testable import HorizontalNative

/// A plane poured round copper with a curved edge keeps the clearance from
/// the curve, whatever its size. The pour cuts round chords, and a count of
/// chords that suits a small via strays tens of microns inside a mounting
/// hole's pad: the fill then came closer than the rules allow, and the
/// clearance check, which measures a via and a hole as discs, reported it.
final class BoardPlaneRoundCopperClearanceTests: XCTestCase {
    private let mm = 1_000_000.0
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    private func square(_ id: String, cx: Double, cy: Double, half: Double, layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [p(cx - half, cy - half), p(cx + half, cy - half), p(cx + half, cy + half), p(cx - half, cy + half)],
                          layer: layer, netID: net)
    }

    /// A 56 mm square plane of GND on a 60 mm board, anchored by a pad in
    /// its corner, with the given copper of SIG and holes at its middle.
    private func board(pads: [HorizontalPolygon] = [], tracks: [HorizontalSegment] = [], vias: [HorizontalMarker] = [],
                       holes: [HorizontalHole] = []) -> HorizontalBoard {
        var plane = HorizontalPlane(id: "plane", netID: "gnd", polygonID: "poly", layer: 0, priority: 0, fillStyle: "solid",
                                    minWidth: 200_000, keepOrphans: false, fragments: [])
        plane.fallbackPolygon = square("poly", cx: 0, cy: 0, half: 28, net: "gnd")
        plane.fromRules = false
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/round.hprj"), uuid: "b", name: "t", grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:],
            netDetails: ["gnd": HorizontalNetDetails(id: "gnd", name: "GND"), "sig": HorizontalNetDetails(id: "sig", name: "SIG")],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [square("outline", cx: 0, cy: 0, half: 30, layer: HorizontalBoardLayers.outline)],
            planes: [plane], keepouts: [], dimensions: [], decals: [], holes: holes,
            vias: vias, viaHoles: [], packages: [],
            packagePads: pads + [square("anchor/pad/9/shape/a", cx: 25, cy: 25, half: 0.5, net: "gnd")], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty)
    }

    /// Pours the board's plane and checks it: no finding, and the fill's
    /// edge round the copper at the origin no nearer its curve of `radius`
    /// mm than Horizon's 0.1 mm, and no further than 10 µm more.
    private func assertPouredClear(_ board: HorizontalBoard, radius: Double, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        var poured = board
        poured.planes = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board).planes
        let fragment = try XCTUnwrap(poured.planes.first?.fragments.first, "\(what): the plane pours", file: file, line: line)
        let findings = HorizontalBoardClearanceCheck.run(board: poured)
        XCTAssertEqual(findings.map { "\($0.title): \($0.detail)" }, [], what, file: file, line: line)

        // The hole the copper leaves in the fill, edge by edge.
        let hole = try XCTUnwrap(fragment.paths.dropFirst().first, "\(what): the fill is cut round it", file: file, line: line)
        var nearest = Double.infinity
        for index in hole.indices {
            nearest = min(nearest, HorizontalRouteClearanceProbe.segmentDistance(
                .zero, .zero, hole[index], hole[(index + 1) % hole.count]))
        }
        let gap = nearest - radius * mm
        XCTAssertGreaterThanOrEqual(gap, 100_000, "\(what): clear of the curve", file: file, line: line)
        XCTAssertLessThan(gap, 110_000, "\(what): and no further than it need be", file: file, line: line)
    }

    func testAFillClearsARoundViaOfAnySize() throws {
        for diameter in [0.6, 1, 4, 10, 20] {
            let via = HorizontalMarker(id: "v", position: .zero, size: diameter * mm, holeSize: 300_000, layer: 0,
                                       connectedLayers: [0, -100], netID: "sig")
            try assertPouredClear(board(vias: [via]), radius: diameter / 2, "a \(diameter) mm via")
        }
    }

    func testAFillClearsAHoleOfAnySize() throws {
        for diameter in [1.0, 4, 10, 20] {
            try assertPouredClear(board(holes: [HorizontalHole(id: "h", position: .zero, diameter: diameter * mm, plated: false)]),
                                  radius: diameter / 2, "a \(diameter) mm unplated hole")
            try assertPouredClear(
                board(holes: [HorizontalHole(id: "h", position: .zero, diameter: diameter * mm, plated: true, netID: "sig")]),
                radius: diameter / 2, "a \(diameter) mm plated hole")
        }
    }

    /// A circular pad is chords too, as many as its size asks, so the fill
    /// round it is clear of the circle the pad stands for.
    func testAFillClearsACircularPadOfAnySize() throws {
        for diameter in [1.0, 4, 10, 20] {
            let circle = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false).circle(diameter: diameter * mm)
            try assertPouredClear(board(pads: [HorizontalPolygon(id: "pkg/pad/1/shape/a", vertices: circle, layer: 0, netID: "sig")]),
                                  radius: diameter / 2, "a \(diameter) mm circular pad")
            let arcs = HorizontalPolygon(id: "pkg/pad/1/shape/a", polygonVertices: [
                HorizontalPolygonVertex(type: .arc, position: p(diameter / 2, 0), arcCenter: .zero),
                HorizontalPolygonVertex(type: .arc, position: p(-diameter / 2, 0), arcCenter: .zero),
            ], layer: 0, netID: "sig")
            try assertPouredClear(board(pads: [arcs]), radius: diameter / 2, "a \(diameter) mm pad of two arcs")
        }
    }

    /// A dot of very wide track is a disc, and its round end is cut as one.
    func testAFillClearsAWideTracksRoundEnd() throws {
        for width in [0.2, 4, 12] {
            let dot = HorizontalSegment(id: "t", from: .zero, to: .zero, width: width * mm, layer: 0, netID: "sig")
            try assertPouredClear(board(tracks: [dot]), radius: width / 2, "a dot of \(width) mm track")
        }
    }

    /// Enough chords that none strays more than the tolerance from its
    /// curve, and never fewer than asked for.
    func testChordsFollowTheRadius() {
        for radius in [0.05, 0.3, 1, 5, 25, 200].map({ $0 * mm }) {
            let count = HorizontalArcChords.count(radius: radius, atLeast: 32)
            XCTAssertGreaterThanOrEqual(count, 32)
            XCTAssertLessThanOrEqual(radius * (1 - cos(Double.pi / Double(count))), HorizontalArcChords.tolerance + 1e-6)
            if count > 32 {
                XCTAssertGreaterThan(radius * (1 - cos(Double.pi / Double(count - 1))), HorizontalArcChords.tolerance)
            }
        }
        // A 0.6 mm via is cut in the 32 chords it always was.
        XCTAssertEqual(HorizontalArcChords.count(radius: 300_000, atLeast: 32), 32)
        // A quarter turn takes a quarter of the chords.
        XCTAssertEqual(HorizontalArcChords.count(radius: 5 * mm, sweep: Double.pi / 2),
                       Int((Double(HorizontalArcChords.count(radius: 5 * mm)) / 4).rounded(.up)), accuracy: 1)
        XCTAssertEqual(HorizontalArcChords.count(radius: 0), 1)
        // A circle keeps a corner on each quarter turn, so it is as wide as
        // its diameter.
        for diameter in [0.5, 1.3, 7, 31] {
            let circle = HorizontalPlacementTransform(shift: .zero, angle: 0, mirrored: false).circle(diameter: diameter * mm)
            XCTAssertEqual(circle.count % 4, 0)
            let bounds = HorizontalRect(points: circle)
            XCTAssertEqual(bounds.maxX - bounds.minX, diameter * mm, accuracy: 1)
            XCTAssertEqual(bounds.maxY - bounds.minY, diameter * mm, accuracy: 1)
        }
    }
}
