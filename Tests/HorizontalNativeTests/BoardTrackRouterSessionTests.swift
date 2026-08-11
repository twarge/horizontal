import XCTest
@testable import HorizontalNative

/// The seam between the board and the router.
///
/// The router works in dense net codes and obstacle indices; the board works in
/// net ids and object ids. Everything here is about that translation being
/// right, because a net mapped wrongly means the router either ignores copper it
/// must avoid or avoids copper it is allowed to touch.
final class BoardTrackRouterSessionTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func square(_ id: String, cx: Double, cy: Double, half: Double,
                        layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: layer, netID: net)
    }

    private func board(
        tracks: [HorizontalSegment] = [],
        pads: [HorizontalPolygon] = [],
        holes: [HorizontalHole] = []
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/router.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: holes,
            vias: [], viaHoles: [], packages: [], packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty)
    }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint,
                       net: String?) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: 200_000, layer: 0, netID: net)
    }

    func testAnEmptyBoardRoutesDirectly() {
        let session = HorizontalBoardTrackRouterSession(board: board())
        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "n1", width: 200_000, diagonalFirst: true)

        XCTAssertTrue(result.isComplete)
        XCTAssertNil(session.blockingObjectID(for: result))
    }

    /// Net ids must survive the round trip into dense codes, or the router
    /// avoids the wrong copper.
    func testNetCodesRoundTrip() {
        let session = HorizontalBoardTrackRouterSession(
            board: board(tracks: [track("t1", p(0, 0), p(1_000_000, 0), net: "gnd")]))

        XCTAssertEqual(session.netCode(for: nil), -1, "no net is −1, not a net")
        let code = session.netCode(for: "gnd")
        XCTAssertGreaterThanOrEqual(code, 0)
        XCTAssertEqual(session.netCode(for: "gnd"), code, "and it is stable")
    }

    /// A track of another net across the path must be routed around.
    func testItRoutesAroundForeignCopper() {
        let blocker = track("t1", p(5_000_000, -3_000_000), p(5_000_000, 3_000_000), net: "other")
        let session = HorizontalBoardTrackRouterSession(board: board(tracks: [blocker]))

        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "mine", width: 200_000, diagonalFirst: true)

        XCTAssertTrue(result.isComplete)
        XCTAssertGreaterThan(result.points.count, 2, "it should have gone around")
    }

    /// And copper of the SAME net must not be routed around, or a track could
    /// never join the net it belongs to.
    func testItRoutesStraightThroughItsOwnNet() {
        let ownCopper = track("t1", p(5_000_000, -3_000_000), p(5_000_000, 3_000_000), net: "mine")
        let session = HorizontalBoardTrackRouterSession(board: board(tracks: [ownCopper]))

        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "mine", width: 200_000, diagonalFirst: true)

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.points.count, 2, "same-net copper is not an obstacle")
    }

    /// An unplated hole is not copper and belongs to no net, so it blocks
    /// everything — including a track that would otherwise pass freely.
    func testAMountingHoleBlocksEveryNet() {
        let hole = HorizontalHole(
            id: "h1", position: p(5_000_000, 0), diameter: 3_000_000,
            shape: .round, plated: false, netID: nil)
        let session = HorizontalBoardTrackRouterSession(board: board(holes: [hole]))

        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "mine", width: 200_000, diagonalFirst: true)

        XCTAssertTrue(result.isComplete, "there is open board around it")
        XCTAssertGreaterThan(result.points.count, 2, "but it cannot go straight through a drill")
    }

    /// When a track blocks the route, the UI needs the board's own id to
    /// highlight it — not the router's internal index.
    func testABlockingTrackReportsItsBoardID() {
        let box = [
            track("wall-n", p(8_000_000, 2_000_000), p(12_000_000, 2_000_000), net: "other"),
            track("wall-s", p(8_000_000, -2_000_000), p(12_000_000, -2_000_000), net: "other"),
            track("wall-e", p(12_000_000, -2_000_000), p(12_000_000, 2_000_000), net: "other"),
            track("wall-w", p(8_000_000, -2_000_000), p(8_000_000, 2_000_000), net: "other"),
        ]
        let session = HorizontalBoardTrackRouterSession(board: board(tracks: box))

        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "mine", width: 200_000, diagonalFirst: true)

        XCTAssertFalse(result.isComplete)
        let blocker = session.blockingObjectID(for: result)
        XCTAssertNotNil(blocker, "a blocking track should map back to the board")
        XCTAssertTrue(box.map(\.id).contains(blocker ?? ""), "got \(blocker ?? "nil")")
    }

    /// A pad has no router-owned id, so it must report nil rather than a
    /// fabricated reference.
    func testANonTrackBlockerReportsNoIDRatherThanAWrongOne() {
        let pads = [
            square("pkg/pad/n", cx: 10_000_000, cy: 2_000_000, half: 2_000_000, net: "other"),
            square("pkg/pad/s", cx: 10_000_000, cy: -2_000_000, half: 2_000_000, net: "other"),
            square("pkg/pad/e", cx: 12_000_000, cy: 0, half: 2_000_000, net: "other"),
            square("pkg/pad/w", cx: 8_000_000, cy: 0, half: 2_000_000, net: "other"),
        ]
        let session = HorizontalBoardTrackRouterSession(board: board(pads: pads))
        let result = session.route(
            from: p(0, 0), to: p(10_000_000, 0), layer: 0,
            netID: "mine", width: 200_000, diagonalFirst: true)

        if !result.isComplete {
            XCTAssertNil(session.blockingObjectID(for: result),
                         "a pad is not a router-owned object; nil beats a wrong id")
        }
    }
}
