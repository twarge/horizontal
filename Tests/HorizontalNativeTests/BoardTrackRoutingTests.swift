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

    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func square(_ id: String, layer: Int?, net: String = "d1") -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)], layer: layer, netID: net)
    }

    private func platedHole(at point: HorizontalPoint) -> HorizontalHole {
        HorizontalHole(id: "pkg1/hole", position: point, diameter: 300, length: 300, shape: .round, plated: true, netID: "d1")
    }

    func testPadReferenceRespectsLayer() {
        let positions = ["pkg1/padb": p(500, 500)]
        let bottomPad = square("pkg1/pad/padB", layer: bottom)
        // Hit-testing a bottom-layer pad while routing on top copper misses,
        // inside it or at its center: a route on the top doesn't start on or
        // end in a pad on the bottom.
        for point in [p(100, 900), p(500, 500)] {
            XCTAssertNil(
                BoardTrackRouting.padReference(at: point, layer: top, packagePads: [bottomPad], padPositions: positions)
            )
        }
        XCTAssertEqual(
            BoardTrackRouting.padReference(at: p(500, 500), layer: bottom, packagePads: [bottomPad], padPositions: positions)?.path,
            "pkg1/padb"
        )
    }

    func testAThroughHolePadsCenterConnectsFromEveryLayer() {
        let positions = ["pkg1/padb": p(500, 500)]
        // Copper on both sides: either side connects at the center.
        let sides = [square("pkg1/pad/padB", layer: top), square("pkg1/pad/padB/bottom", layer: bottom)]
        for layer in [top, bottom] {
            XCTAssertEqual(
                BoardTrackRouting.padReference(at: p(500, 500), layer: layer, packagePads: sides, padPositions: positions)?.path,
                "pkg1/padb"
            )
        }
        // An inner layer it has no polygon on still reaches it through its
        // plated hole.
        XCTAssertNil(
            BoardTrackRouting.padReference(at: p(500, 500), layer: -1, packagePads: sides, padPositions: positions)
        )
        XCTAssertEqual(
            BoardTrackRouting.padReference(
                at: p(500, 500), layer: -1, packagePads: sides, padPositions: positions,
                packageHoles: [platedHole(at: p(500, 500))]
            )?.path,
            "pkg1/padb"
        )
        // A pad with no copper polygons at all is taken to have copper.
        XCTAssertEqual(
            BoardTrackRouting.padReference(at: p(500, 500), layer: top, packagePads: [], padPositions: positions)?.path,
            "pkg1/padb"
        )
    }

    func testNetAndWidthComeFromCopperOnTheRoutesLayer() {
        let topTrack = HorizontalSegment(id: "t", from: p(0, 0), to: p(1000, 0), width: 350_000, layer: top, netID: "clk")
        func net(at point: HorizontalPoint, layer: Int?, vias: [HorizontalMarker] = [], pads: [HorizontalPolygon] = []) -> String? {
            BoardTrackRouting.netID(
                at: point, layer: layer, junctions: ["j": p(1000, 0)], junctionNetIDs: ["j": "clk"],
                vias: vias, tracks: [topTrack], packagePads: pads, packageHoles: []
            )
        }
        XCTAssertEqual(net(at: p(1000, 0), layer: nil), "clk", "any layer, as before")
        XCTAssertEqual(net(at: p(1000, 0), layer: top), "clk")
        XCTAssertNil(net(at: p(1000, 0), layer: bottom), "its end and junction are on the top only")
        XCTAssertNil(net(at: p(500, 0), layer: bottom), "a bottom route crosses under it")

        let via = HorizontalMarker(id: "v", position: p(1000, 0), size: 600_000, layer: nil, netID: "clk")
        XCTAssertEqual(net(at: p(1000, 0), layer: bottom, vias: [via]), "clk", "a via with no listed layers spans them all")
        var blind = via
        blind.connectedLayers = [top, -1]
        XCTAssertNil(net(at: p(1000, 0), layer: bottom, vias: [blind]))

        let topPad = square("pkg/pad/a", layer: top, net: "d0")
        XCTAssertEqual(net(at: p(500, 500), layer: top, pads: [topPad]), "d0")
        XCTAssertNil(net(at: p(500, 500), layer: bottom, pads: [topPad]))

        XCTAssertEqual(BoardTrackRouting.trackWidth(at: p(500, 0), layer: top, tracks: [topTrack]), 350_000)
        XCTAssertNil(BoardTrackRouting.trackWidth(at: p(500, 0), layer: bottom, tracks: [topTrack]))
    }

    func testARouteSnapsOnlyToCopperOnItsLayer() {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/snap.hprj"), uuid: "b", name: "snap",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.tracks = [
            HorizontalSegment(id: "top", from: p(0, 0), to: p(1000, 0), width: 200, layer: top, netID: nil),
            HorizontalSegment(id: "bottom", from: p(0, 5000), to: p(1000, 5000), width: 200, layer: bottom, netID: nil),
        ]
        board.vias = [HorizontalMarker(id: "v", position: p(3000, 3000), size: 600, layer: nil, netID: nil)]
        // An SMD pad on the top, a through-hole pad with copper on both sides,
        // and its mask opening, which is not copper.
        board.packagePads = [
            HorizontalPolygon(id: "pkg/pad/smd", vertices: [p(9000, 0), p(9100, 0), p(9100, 100)], layer: top, netID: nil),
            HorizontalPolygon(id: "pkg/pad/tht", vertices: [p(8000, 0), p(8100, 0), p(8100, 100)], layer: top, netID: nil),
            HorizontalPolygon(id: "pkg/pad/tht/b", vertices: [p(8000, 0), p(8100, 0), p(8100, 100)], layer: bottom, netID: nil),
            HorizontalPolygon(
                id: "pkg/pad/smd/mask", vertices: [p(9000, 0), p(9100, 0), p(9100, 100)],
                layer: HorizontalBoardLayers.bottomMask, netID: nil),
        ]
        board.packagePadPositions = ["pkg/smd": p(9050, 50), "pkg/tht": p(8050, 50)]

        let onBottom = Set(BoardTrackRouting.snapTargets(on: bottom, in: board).map(key))
        XCTAssertEqual(onBottom, Set([p(0, 5000), p(1000, 5000), p(3000, 3000), p(8050, 50)].map(key)))
        let onTop = Set(BoardTrackRouting.snapTargets(on: top, in: board).map(key))
        XCTAssertEqual(onTop, Set([p(0, 0), p(1000, 0), p(3000, 3000), p(8050, 50), p(9050, 50)].map(key)))
    }

    func testADoubleClickTakesTheSystemsInterval() {
        let first = Date(timeIntervalSinceReferenceDate: 0)
        let second = first.addingTimeInterval(0.42)
        // 0.42 s apart is a double-click at macOS's default 0.5 s, where the
        // canvas's fixed 0.35 s took it for two clicks.
        XCTAssertTrue(HorizontalCanvasInputCore.isDoubleClick(
            at: CGPoint(x: 10, y: 10), time: second, after: CGPoint(x: 12, y: 9), at: first, interval: 0.5))
        XCTAssertFalse(HorizontalCanvasInputCore.isDoubleClick(
            at: CGPoint(x: 10, y: 10), time: second, after: CGPoint(x: 12, y: 9), at: first, interval: 0.35))
        XCTAssertFalse(HorizontalCanvasInputCore.isDoubleClick(
            at: CGPoint(x: 40, y: 10), time: second, after: CGPoint(x: 12, y: 9), at: first, interval: 0.5),
            "too far from the first")
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
