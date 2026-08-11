import XCTest
@testable import HorizontalNative

/// Tests the pure board track-drawing helpers extracted from BoardCanvasView
/// into `BoardTrackRouting`. These cover the orthogonal routing geometry, the
/// position-based net resolution, and the default-width heuristic — the parts
/// most likely to harbor subtle bugs — without standing up a SwiftUI view.
final class BoardTrackRoutingTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x, y: y)
    }

    private func key(_ point: HorizontalPoint) -> String {
        HorizontalCanvasModeSupport.pointKey(point)
    }

    // MARK: - Routing geometry

    func testHorizontalFirstRouteBendsAtAnchorRow() {
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(1000, 500), horizontalFirst: true)
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[0], p(0, 0))
        XCTAssertEqual(route[1], p(1000, 0)) // x first, so the corner sits on the anchor row
        XCTAssertEqual(route[2], p(1000, 500))
    }

    func testVerticalFirstRouteBendsAtAnchorColumn() {
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(1000, 500), horizontalFirst: false)
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[1], p(0, 500)) // y first, so the corner sits on the anchor column
        XCTAssertEqual(route[2], p(1000, 500))
    }

    // MARK: - 45° corner geometry

    func testDiagonalStraightFirstRunsLongAxisThenDiagonal() {
        // dx=1000 (long), dy=400 (short), straightFirst → horizontal surplus then 45°.
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(1000, 400), horizontalFirst: true, diagonal: true)
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[0], p(0, 0))
        XCTAssertEqual(route[1], p(600, 0))      // surplus = 1000-400 along x
        XCTAssertEqual(route[2], p(1000, 400))
        // The second leg is a true 45° diagonal.
        XCTAssertEqual(abs(route[2].x - route[1].x), abs(route[2].y - route[1].y))
    }

    func testDiagonalDiagonalFirstLeadsWithDiagonal() {
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(1000, 400), horizontalFirst: false, diagonal: true)
        XCTAssertEqual(route.count, 3)
        XCTAssertEqual(route[1], p(400, 400))    // 45° diagonal covering the short axis first
        XCTAssertEqual(route[2], p(1000, 400))   // then horizontal remainder
        XCTAssertEqual(abs(route[1].x - route[0].x), abs(route[1].y - route[0].y))
    }

    func testDiagonalShortAxisIsVertical() {
        // dy long, dx short → the surplus leg is vertical.
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(300, 1000), horizontalFirst: true, diagonal: true)
        XCTAssertEqual(route, [p(0, 0), p(0, 700), p(300, 1000)])
    }

    func testDiagonalNegativeDirections() {
        let route = BoardTrackRouting.path(from: p(0, 0), to: p(-1000, -400), horizontalFirst: true, diagonal: true)
        XCTAssertEqual(route, [p(0, 0), p(-600, 0), p(-1000, -400)])
    }

    func testDiagonalPerfect45AndAxisAlignedCollapse() {
        // Exact 45° needs no corner.
        XCTAssertEqual(BoardTrackRouting.path(from: p(0, 0), to: p(500, 500), horizontalFirst: true, diagonal: true), [p(0, 0), p(500, 500)])
        // Pure horizontal/vertical collapse too.
        XCTAssertEqual(BoardTrackRouting.path(from: p(0, 0), to: p(900, 0), horizontalFirst: true, diagonal: true), [p(0, 0), p(900, 0)])
        XCTAssertEqual(BoardTrackRouting.path(from: p(0, 0), to: p(0, 900), horizontalFirst: false, diagonal: true), [p(0, 0), p(0, 900)])
    }

    func testStraightRunCollapsesToSingleSegment() {
        let horizontal = BoardTrackRouting.path(from: p(0, 0), to: p(1000, 0), horizontalFirst: true)
        XCTAssertEqual(horizontal, [p(0, 0), p(1000, 0)])

        let vertical = BoardTrackRouting.path(from: p(0, 0), to: p(0, 1000), horizontalFirst: true)
        XCTAssertEqual(vertical, [p(0, 0), p(0, 1000)])
    }

    func testBendModeSeededFromExistingTrackDirection() {
        let horizontalTrack = HorizontalSegment(id: "t", from: p(0, 0), to: p(1000, 0), width: 200_000, layer: 0, netID: "n")
        XCTAssertEqual(BoardTrackRouting.bendModeHorizontalFirst(at: p(1000, 0), tracks: [horizontalTrack]), true)

        let verticalTrack = HorizontalSegment(id: "t", from: p(0, 0), to: p(0, 1000), width: 200_000, layer: 0, netID: "n")
        XCTAssertEqual(BoardTrackRouting.bendModeHorizontalFirst(at: p(0, 1000), tracks: [verticalTrack]), false)

        XCTAssertNil(BoardTrackRouting.bendModeHorizontalFirst(at: p(9, 9), tracks: [horizontalTrack]))
    }

    // MARK: - Net resolution

    func testNetResolvesFromJunction() {
        let net = BoardTrackRouting.netID(
            at: p(500, 500),
            junctions: ["j1": p(500, 500)],
            junctionNetIDs: ["j1": "gnd"],
            vias: [],
            tracks: [],
            packagePads: [],
            packageHoles: []
        )
        XCTAssertEqual(net, "gnd")
    }

    func testNetResolvesFromViaPosition() {
        let via = HorizontalMarker(id: "v1", position: p(100, 200), size: 600_000, layer: nil, netID: "vcc")
        let net = BoardTrackRouting.netID(
            at: p(100, 200),
            junctions: [:],
            junctionNetIDs: [:],
            vias: [via],
            tracks: [],
            packagePads: [],
            packageHoles: []
        )
        XCTAssertEqual(net, "vcc")
    }

    func testNetResolvesAlongTrackBody() {
        // A point on the interior of a track (not an endpoint) still resolves.
        let track = HorizontalSegment(id: "t1", from: p(0, 0), to: p(1000, 0), width: 200_000, layer: 0, netID: "clk")
        let net = BoardTrackRouting.netID(
            at: p(400, 0),
            junctions: [:],
            junctionNetIDs: [:],
            vias: [],
            tracks: [track],
            packagePads: [],
            packageHoles: []
        )
        XCTAssertEqual(net, "clk")
    }

    func testNetResolvesInsidePadPolygon() {
        // A square pad from (0,0) to (1000,1000) carrying net "d0".
        let pad = HorizontalPolygon(
            id: "pad",
            vertices: [p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)],
            layer: 0,
            netID: "d0"
        )
        XCTAssertEqual(
            BoardTrackRouting.netID(
                at: p(500, 500),
                junctions: [:], junctionNetIDs: [:], vias: [], tracks: [],
                packagePads: [pad], packageHoles: []
            ),
            "d0"
        )
        // A click outside the pad finds nothing.
        XCTAssertNil(
            BoardTrackRouting.netID(
                at: p(5000, 5000),
                junctions: [:], junctionNetIDs: [:], vias: [], tracks: [],
                packagePads: [pad], packageHoles: []
            )
        )
    }

    func testNetResolvesNothingOnEmptyCopper() {
        XCTAssertNil(
            BoardTrackRouting.netID(
                at: p(123, 456),
                junctions: [:], junctionNetIDs: [:], vias: [], tracks: [],
                packagePads: [], packageHoles: []
            )
        )
    }

    // MARK: - Start-on-track width inheritance

    func testTrackWidthInheritedFromTrackUnderPoint() {
        let track = HorizontalSegment(id: "t", from: p(0, 0), to: p(1000, 0), width: 350_000, layer: 0, netID: "n")
        // Endpoint hit.
        XCTAssertEqual(BoardTrackRouting.trackWidth(at: p(1000, 0), tracks: [track]), 350_000)
        // Body hit.
        XCTAssertEqual(BoardTrackRouting.trackWidth(at: p(500, 0), tracks: [track]), 350_000)
        // Miss.
        XCTAssertNil(BoardTrackRouting.trackWidth(at: p(500, 500), tracks: [track]))
        // Zero-width tracks don't contribute.
        let zero = HorizontalSegment(id: "z", from: p(0, 0), to: p(1000, 0), width: 0, layer: 0, netID: "n")
        XCTAssertNil(BoardTrackRouting.trackWidth(at: p(500, 0), tracks: [zero]))
    }

    // MARK: - Direct pad connections

    func testPadPathFromPolygonID() {
        XCTAssertEqual(
            BoardTrackRouting.padPath(forPolygonID: "PKG-UUID/pad/PAD-UUID"),
            "pkg-uuid/pad-uuid"
        )
        // Suffixed padstack geometry (e.g. hole shapes) maps to the same path.
        XCTAssertEqual(
            BoardTrackRouting.padPath(forPolygonID: "pkg/pad/padid/hole"),
            "pkg/padid"
        )
        // Non-pad geometry ids return nil.
        XCTAssertNil(BoardTrackRouting.padPath(forPolygonID: "pkg/silkscreen/line1"))
        XCTAssertNil(BoardTrackRouting.padPath(forPolygonID: "loneid"))
    }

    func testPadReferenceSnapsToCenterViaPolygonHit() {
        let pad = HorizontalPolygon(
            id: "pkg1/pad/padA",
            vertices: [p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)],
            layer: 0,
            netID: "d0"
        )
        let positions = ["pkg1/pada": p(500, 500)]
        let ref = BoardTrackRouting.padReference(
            at: p(100, 900), // inside the pad but away from its center
            layer: 0,
            packagePads: [pad],
            padPositions: positions
        )
        XCTAssertEqual(ref?.path, "pkg1/pada")
        XCTAssertEqual(ref?.center, p(500, 500))
    }

    func testPadReferenceRespectsLayerAndExactCenterFallback() {
        let bottomPad = HorizontalPolygon(
            id: "pkg1/pad/padB",
            vertices: [p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)],
            layer: HorizontalBoardLayers.bottomCopper,
            netID: "d1"
        )
        let positions = ["pkg1/padb": p(500, 500)]
        // Hit-testing a bottom-layer pad while routing on top copper misses…
        XCTAssertNil(
            BoardTrackRouting.padReference(
                at: p(100, 900),
                layer: HorizontalBoardLayers.topCopper,
                packagePads: [bottomPad],
                padPositions: positions
            )
        )
        // …but an exact center hit connects layer-agnostically (through-hole).
        XCTAssertEqual(
            BoardTrackRouting.padReference(
                at: p(500, 500),
                layer: HorizontalBoardLayers.topCopper,
                packagePads: [bottomPad],
                padPositions: positions
            )?.path,
            "pkg1/padb"
        )
    }

    // MARK: - Arc corner style

    func testArcCornerHorizontalFirstStraightLegThenArc() {
        // adx (100) > ady (40): horizontal surplus leg, then a quarter arc.
        let specs = BoardTrackRouting.route(from: p(0, 0), to: p(100, 40), horizontalFirst: true, cornerStyle: .arc)
        XCTAssertEqual(specs.count, 2)
        XCTAssertNil(specs[0].center)
        XCTAssertEqual(specs[0].from, p(0, 0))
        XCTAssertEqual(specs[0].to, p(60, 0))      // surplus = 100 - 40
        XCTAssertEqual(specs[1].center, p(60, 40)) // tangent center
        XCTAssertEqual(specs[1].from, p(60, 0))
        XCTAssertEqual(specs[1].to, p(100, 40))
    }

    func testArcCornerVerticalFirstStraightLegThenArc() {
        // yx posture, ady (100) > adx (40): vertical surplus leg, then arc.
        let specs = BoardTrackRouting.route(from: p(0, 0), to: p(40, 100), horizontalFirst: false, cornerStyle: .arc)
        XCTAssertEqual(specs.count, 2)
        XCTAssertNil(specs[0].center)
        XCTAssertEqual(specs[0].to, p(0, 60))      // surplus = 100 - 40
        XCTAssertEqual(specs[1].center, p(40, 60))
        XCTAssertEqual(specs[1].to, p(40, 100))
    }

    func testArcCornerPerfectQuarterHasNoStraightLeg() {
        let specs = BoardTrackRouting.route(from: p(0, 0), to: p(50, 50), horizontalFirst: true, cornerStyle: .arc)
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0].center, p(0, 50))
        XCTAssertEqual(specs[0].from, p(0, 0))
        XCTAssertEqual(specs[0].to, p(50, 50))
    }

    func testArcCornerAxisAlignedIsStraight() {
        let specs = BoardTrackRouting.route(from: p(0, 0), to: p(100, 0), horizontalFirst: true, cornerStyle: .arc)
        XCTAssertEqual(specs.count, 1)
        XCTAssertNil(specs[0].center)
        XCTAssertEqual(specs, [BoardTrackSegmentSpec(from: p(0, 0), to: p(100, 0), center: nil)])
    }

    func testArcPolylineIsAQuarterTurnInFlowOrder() {
        // The arc leg flattens to points that start at `from`, end at `to`, and
        // bow away from the chord (a real curve, not the straight diagonal).
        let specs = BoardTrackRouting.route(from: p(0, 0), to: p(100, 40), horizontalFirst: true, cornerStyle: .arc)
        let arc = specs[1]
        let poly = arc.polyline(arcPrecision: 16)
        XCTAssertEqual(poly.first, p(60, 0))
        XCTAssertEqual(poly.last, p(100, 40))
        // A radius-40 quarter arc centered at (60,40): the mid sample is ~45°
        // off, well away from the straight line between the endpoints.
        let mid = poly[poly.count / 2]
        let onChord = abs((mid.x - 60) * 40 - (mid.y - 0) * 40) < 1 // cross product vs chord (60,0)->(100,40)
        XCTAssertFalse(onChord, "arc midpoint should bow off the chord")
        // Every sample sits on the radius-40 circle about the tangent center.
        for point in poly {
            let r = ((point.x - 60) * (point.x - 60) + (point.y - 40) * (point.y - 40)).squareRoot()
            XCTAssertEqual(r, 40, accuracy: 0.5)
        }
    }

    // MARK: - Via layers

    func testThroughViaLayersTwoLayerBoard() {
        XCTAssertEqual(
            BoardTrackRouting.throughViaLayers(copperLayerCount: 2),
            [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
        )
    }

    func testThroughViaLayersFourLayerBoard() {
        XCTAssertEqual(
            BoardTrackRouting.throughViaLayers(copperLayerCount: 4),
            [HorizontalBoardLayers.topCopper, -1, -2, HorizontalBoardLayers.bottomCopper]
        )
    }

    func testOppositeRoutingLayerToggles() {
        XCTAssertEqual(BoardTrackRouting.oppositeRoutingLayer(HorizontalBoardLayers.topCopper), HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(BoardTrackRouting.oppositeRoutingLayer(HorizontalBoardLayers.bottomCopper), HorizontalBoardLayers.topCopper)
        // From an inner layer, surface to top.
        XCTAssertEqual(BoardTrackRouting.oppositeRoutingLayer(-1), HorizontalBoardLayers.topCopper)
    }

    // MARK: - Default width

    func testDefaultWidthPrefersSameNetMostCommon() {
        let tracks = [
            HorizontalSegment(id: "a", from: p(0, 0), to: p(1, 0), width: 150_000, layer: 0, netID: "n1"),
            HorizontalSegment(id: "b", from: p(0, 0), to: p(1, 0), width: 150_000, layer: 0, netID: "n1"),
            HorizontalSegment(id: "c", from: p(0, 0), to: p(1, 0), width: 999_000, layer: 0, netID: "n2")
        ]
        XCTAssertEqual(BoardTrackRouting.defaultWidth(tracks: tracks, net: "n1"), 150_000)
    }

    func testDefaultWidthFallsBackToBoardMostCommonThenConstant() {
        let tracks = [
            HorizontalSegment(id: "a", from: p(0, 0), to: p(1, 0), width: 250_000, layer: 0, netID: "x"),
            HorizontalSegment(id: "b", from: p(0, 0), to: p(1, 0), width: 250_000, layer: 0, netID: "y")
        ]
        // Net with no existing tracks → board's most common width.
        XCTAssertEqual(BoardTrackRouting.defaultWidth(tracks: tracks, net: "unseen"), 250_000)
        // Empty board → the 0.2 mm constant fallback.
        XCTAssertEqual(BoardTrackRouting.defaultWidth(tracks: [], net: nil), BoardTrackRouting.defaultTrackWidth)
    }
}
