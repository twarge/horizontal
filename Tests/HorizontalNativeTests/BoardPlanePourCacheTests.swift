import XCTest
@testable import HorizontalNative

/// Reusing a plane's previous fill instead of pouring it again.
///
/// The dangerous failure is silent: skip a plane whose inputs did change and the
/// board shows copper that is not what would be fabricated, with nothing to
/// notice. So most of these tests are about when the cache must NOT be used.
final class BoardPlanePourCacheTests: XCTestCase {
    private let mm = 1_000_000.0
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func square(_ id: String, cx: Double, cy: Double, half: Double,
                        layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: layer,
            netID: net
        )
    }

    private func plane(_ id: String, half: Double, net: String?, layer: Int = 0,
                       priority: Int = 0) -> HorizontalPlane {
        var value = HorizontalPlane(
            id: id, netID: net, polygonID: "poly-\(id)", layer: layer,
            priority: priority, fillStyle: "solid", minWidth: 200_000,
            keepOrphans: false, fragments: []
        )
        value.fallbackPolygon = square("poly-\(id)", cx: 0, cy: 0, half: half, layer: layer, net: net)
        value.fromRules = false
        return value
    }

    private func makeBoard(planes: [HorizontalPlane],
                           tracks: [HorizontalSegment] = [],
                           pads: [HorizontalPolygon] = []) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/cache.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [square("outline", cx: 0, cy: 0, half: 12 * mm,
                              layer: HorizontalBoardLayers.outline)],
            planes: planes, keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [],
            packagePads: pads + [square("pkg/pad/anchor", cx: 8 * mm, cy: 8 * mm,
                                        half: 500_000, layer: 0, net: "gnd"),
                                 square("pkg/pad/anchor2", cx: 8 * mm, cy: -8 * mm,
                                        half: 500_000, layer: -100, net: "gnd")],
            packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [],
            packageTexts: [], texts: [], boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func signature(_ plane: HorizontalPlane, _ board: HorizontalBoard) -> Int {
        HorizontalBoardPlaneUpdater.planeInputSignature(for: plane, in: board)
    }

    // MARK: - Reuse

    /// Pouring an unchanged board a second time must produce the same fills.
    func testSecondPourOfAnUnchangedBoardMatches() throws {
        let board = makeBoard(planes: [plane("p1", half: 10 * mm, net: "gnd")])
        let first = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board, cache: HorizontalPlanePourCache())
        let second = HorizontalBoardPlaneUpdater.updateAllPlanes(in: first.board, cache: first.cache)

        let a = try XCTUnwrap(first.board.planes.first)
        let b = try XCTUnwrap(second.board.planes.first)
        XCTAssertFalse(a.fragments.isEmpty, "precondition: something was poured")
        XCTAssertEqual(a.fragments, b.fragments)
    }

    /// A cached fill is served even when the board handed in has lost its
    /// fragments — after Clear All Planes, or an undo. The cache carries the
    /// geometry, so a skip cannot serve whatever happens to be on the board.
    func testCacheSurvivesAClearedBoard() throws {
        let board = makeBoard(planes: [plane("p1", half: 10 * mm, net: "gnd")])
        let first = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board, cache: HorizontalPlanePourCache())

        var cleared = first.board
        cleared.planes = cleared.planes.map { var p = $0; p.fragments = []; return p }
        let again = HorizontalBoardPlaneUpdater.updateAllPlanes(in: cleared, cache: first.cache)

        XCTAssertEqual(try XCTUnwrap(again.board.planes.first).fragments,
                       try XCTUnwrap(first.board.planes.first).fragments)
    }

    // MARK: - Scoping: what must NOT invalidate

    /// The point of the whole exercise: routing on the bottom must not force the
    /// top plane to pour again.
    func testCopperOnAnotherLayerDoesNotInvalidateAPlane() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let before = makeBoard(planes: [top])
        let after = makeBoard(planes: [top], tracks: [
            HorizontalSegment(id: "t1", from: p(0, 0), to: p(3 * mm, 0),
                              width: 200_000, layer: HorizontalBoardLayers.bottomCopper, netID: "sig")
        ])

        XCTAssertEqual(signature(top, before), signature(top, after))
    }

    // MARK: - Scoping: what MUST invalidate

    func testCopperOnTheSameLayerInvalidatesTheePlane() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let before = makeBoard(planes: [top])
        let after = makeBoard(planes: [top], tracks: [
            HorizontalSegment(id: "t1", from: p(0, 0), to: p(3 * mm, 0),
                              width: 200_000, layer: 0, netID: "sig")
        ])

        XCTAssertNotEqual(signature(top, before), signature(top, after))
    }

    /// A via goes through the board, so the pour reads every via whatever layer
    /// it is pouring. Scoping vias by layer would be wrong.
    func testAViaAnywhereInvalidatesEveryPlane() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let before = makeBoard(planes: [top])
        var after = makeBoard(planes: [top])
        after.vias = [HorizontalMarker(id: "v", position: p(mm, mm), size: 600_000,
                                       layer: HorizontalBoardLayers.bottomCopper)]

        XCTAssertNotEqual(signature(top, before), signature(top, after),
                          "a via reaches this layer even when it is drawn on another")
    }

    /// Likewise a drill hole.
    func testAHoleAnywhereInvalidatesEveryPlane() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let before = makeBoard(planes: [top])
        var after = makeBoard(planes: [top])
        after.packageHoles = [HorizontalHole(
            id: "h", position: p(mm, mm), diameter: 800_000, length: 0,
            shape: .round, plated: false, netID: nil)]

        XCTAssertNotEqual(signature(top, before), signature(top, after))
    }

    func testRuleChangesInvalidateEveryPlane() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let before = makeBoard(planes: [top])
        var after = makeBoard(planes: [top])
        after.rules.planeRules = [HorizontalRulePlane(json: ["enabled": true, "order": 1])]

        XCTAssertNotEqual(signature(top, before), signature(top, after))
    }

    /// An earlier tier's fill is an input to a later one, so a plane can need
    /// re-pouring purely because a higher-priority plane above it moved.
    func testAnEarlierTiersFillInvalidatesALaterPlane() {
        let low = plane("p2", half: 10 * mm, net: "gnd", layer: 0, priority: 5)
        let board = makeBoard(planes: [low])
        let obstacle = HorizontalBoardPlaneUpdater.PlaneObstacle(
            path: [p(0, 0), p(mm, 0), p(mm, mm)], netID: "vcc", layer: 0)

        XCTAssertNotEqual(
            HorizontalBoardPlaneUpdater.planeInputSignature(for: low, in: board),
            HorizontalBoardPlaneUpdater.planeInputSignature(
                for: low, in: board, planeObstacles: [obstacle])
        )
    }

    /// An obstacle on a different layer is not this plane's business.
    func testAnEarlierTiersFillOnAnotherLayerDoesNot() {
        let top = plane("p1", half: 10 * mm, net: "gnd", layer: 0)
        let board = makeBoard(planes: [top])
        let obstacle = HorizontalBoardPlaneUpdater.PlaneObstacle(
            path: [p(0, 0), p(mm, 0), p(mm, mm)], netID: "vcc",
            layer: HorizontalBoardLayers.bottomCopper)

        XCTAssertEqual(
            HorizontalBoardPlaneUpdater.planeInputSignature(for: top, in: board),
            HorizontalBoardPlaneUpdater.planeInputSignature(
                for: top, in: board, planeObstacles: [obstacle])
        )
    }

    func testPlaneSettingsInvalidateItsOwnFill() {
        var changed = plane("p1", half: 10 * mm, net: "gnd")
        let original = plane("p1", half: 10 * mm, net: "gnd")
        changed.minWidth = 500_000
        let board = makeBoard(planes: [original])

        XCTAssertNotEqual(signature(original, board), signature(changed, board))
    }

    /// Deleting a plane must not leave its fill cached forever.
    func testDroppedPlanesAreEvicted() {
        let board = makeBoard(planes: [plane("p1", half: 10 * mm, net: "gnd"),
                                       plane("p2", half: 5 * mm, net: "gnd")])
        let first = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board, cache: HorizontalPlanePourCache())
        XCTAssertEqual(first.cache.count, 2)

        var fewer = board
        fewer.planes = [board.planes[0]]
        let second = HorizontalBoardPlaneUpdater.updateAllPlanes(in: fewer, cache: first.cache)
        XCTAssertEqual(second.cache.count, 1)
    }

    /// The cache must never change what a pour produces — only how long it
    /// takes. A cold pour and a warm one have to agree object for object.
    func testCachedAndUncachedPoursAgree() {
        let board = makeBoard(
            planes: [plane("top", half: 10 * mm, net: "gnd", layer: 0),
                     plane("bottom", half: 10 * mm, net: "gnd", layer: -100, priority: 2)],
            tracks: [HorizontalSegment(id: "t1", from: p(-4 * mm, 0), to: p(4 * mm, 0),
                                       width: 200_000, layer: 0, netID: "sig")]
        )
        let warm = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board, cache: HorizontalPlanePourCache())

        // An edit on the top layer: the top plane must re-pour, the bottom may skip.
        var edited = warm.board
        edited.tracks[0].to = p(5 * mm, 0)

        let cached = HorizontalBoardPlaneUpdater.updateAllPlanes(in: edited, cache: warm.cache).board
        let fresh = HorizontalBoardPlaneUpdater.updateAllPlanes(in: edited, cache: HorizontalPlanePourCache()).board

        XCTAssertEqual(cached.planes.map(\.fragments), fresh.planes.map(\.fragments))
    }
}
