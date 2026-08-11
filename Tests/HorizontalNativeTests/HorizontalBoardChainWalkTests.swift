import XCTest
@testable import HorizontalNative

/// Tests the "walk the chain" post-delete selection (Horizon tool_delete): when a
/// single track/via is deleted, the single neighbouring track sharing an endpoint
/// is selected so repeated Delete unzips a trace. Forks / mid-chain segments /
/// pad-only endpoints select nothing. Pure, no GUI.
final class HorizontalBoardChainWalkTests: XCTestCase {

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func pad(_ id: String, cx: Double, cy: Double, net: String, half: Double = 300_000) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: 0,
            netID: net
        )
    }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, net: String? = nil) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: 200_000, layer: 0, netID: net)
    }

    private func via(_ id: String, at point: HorizontalPoint, net: String? = nil) -> HorizontalMarker {
        HorizontalMarker(id: id, position: point, size: 600_000, holeSize: 300_000,
                      layer: nil, connectedLayers: [0, -100], netID: net)
    }

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        vias: [HorizontalMarker] = [],
        packagePads: [HorizontalPolygon] = [],
        junctions: [String: HorizontalPoint] = [:]
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                            HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000)],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [], packages: [], packagePads: packagePads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func trackRef(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .track, layer: 0)
    }

    private func viaRef(_ id: String) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .via)
    }

    // MARK: - Tests

    func testEndOfChainSelectsNeighbour() {
        // pad — t1 — j — t2(free). Deleting t2 selects t1.
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0)),
                track("t2", p(5_000_000, 0), p(10_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": p(5_000_000, 0)]
        )
        let next = HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t2"), in: board)
        XCTAssertEqual(next?.type, .track)
        XCTAssertEqual(next?.id, "t1")
    }

    func testMidChainSelectsNothing() {
        // pad — t1 — j1 — t2 — j2 — t3(free). Deleting the middle t2 is ambiguous.
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0)),
                track("t2", p(5_000_000, 0), p(10_000_000, 0)),
                track("t3", p(10_000_000, 0), p(15_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j1": p(5_000_000, 0), "j2": p(10_000_000, 0)]
        )
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t2"), in: board))
    }

    func testForkSelectsNothing() {
        // Three tracks meet at one junction; deleting one leaves two neighbours.
        let j = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), j),
                track("t2", j, p(10_000_000, 0)),
                track("t3", j, p(5_000_000, 5_000_000)),
            ],
            junctions: ["j": j]
        )
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t1"), in: board))
    }

    func testIsolatedTrackSelectsNothing() {
        let board = makeBoard(tracks: [track("t", p(0, 0), p(5_000_000, 0))])
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t"), in: board))
    }

    func testDoesNotWalkAcrossAPad() {
        // t_left — pad — t_right (two traces leaving one pad). Deleting t_left must
        // NOT jump across the pad to t_right (Horizon's is_junc guard).
        let board = makeBoard(
            tracks: [
                track("tLeft", p(-5_000_000, 0), p(0, 0)),
                track("tRight", p(0, 0), p(5_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")]
        )
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("tLeft"), in: board))
    }

    func testPrefersViaAtSharedPoint() {
        // pad — t1 — j(via) — t2(free). Deleting t2 selects the via, not t1.
        let j = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), j),
                track("t2", j, p(10_000_000, 0)),
            ],
            vias: [via("v", at: j, net: "n1")],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": j]
        )
        let next = HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t2"), in: board)
        XCTAssertEqual(next?.type, .via)
        XCTAssertEqual(next?.id, "v")
    }

    func testDeletingViaSelectsItsSingleTrack() {
        // via at P with one track leaving it. Deleting the via selects the track.
        let pt = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [track("t1", pt, p(10_000_000, 0))],
            vias: [via("v", at: pt, net: "n1")]
        )
        let next = HorizontalBoardChainWalk.selection(afterDeleting: viaRef("v"), in: board)
        XCTAssertEqual(next?.type, .track)
        XCTAssertEqual(next?.id, "t1")
    }

    func testDeletingViaWithTwoTracksSelectsNothing() {
        let pt = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [track("t1", p(0, 0), pt), track("t2", pt, p(10_000_000, 0))],
            vias: [via("v", at: pt, net: "n1")]
        )
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: viaRef("v"), in: board))
    }

    func testLoopSelectsNothing() {
        // Two tracks form a loop: they share BOTH endpoints. Deleting one is
        // ambiguous (the other is found at both ends) — select nothing, matching
        // Horizon's multi=true bail.
        let a = p(0, 0), b = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t1", a, b),
                track("t2", a, b),
            ],
            junctions: ["ja": a, "jb": b]
        )
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t1"), in: board))
    }

    func testViaAtFreeEndDoesNotOverrideTrackNeighbour() {
        // pad — t1 — j — t2 — jEnd(via, no neighbour). Deleting t2: the single
        // neighbour t1 is at j (no via); the via is at the OTHER (free) endpoint.
        // The via must NOT be selected — only a via at the SHARED point wins.
        let j = p(5_000_000, 0)
        let end = p(10_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), j),
                track("t2", j, end),
            ],
            vias: [via("vEnd", at: end, net: "n1")],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": j, "jEnd": end]
        )
        let next = HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t2"), in: board)
        XCTAssertEqual(next?.type, .track)
        XCTAssertEqual(next?.id, "t1")
    }

    func testWalkUnzipsWholeChain() {
        // pad — t1 — j1 — t2 — j2 — t3(free). Deleting from the free end walks
        // t3→t2→t1, removing each segment as it goes.
        var board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0)),
                track("t2", p(5_000_000, 0), p(10_000_000, 0)),
                track("t3", p(10_000_000, 0), p(15_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j1": p(5_000_000, 0), "j2": p(10_000_000, 0)]
        )

        let n1 = HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t3"), in: board)
        XCTAssertEqual(n1?.id, "t2")
        board.tracks.removeAll { $0.id == "t3" }

        let n2 = HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t2"), in: board)
        XCTAssertEqual(n2?.id, "t1")
        board.tracks.removeAll { $0.id == "t2" }

        // t1 now touches only the pad and a free end → nothing left to select.
        XCTAssertNil(HorizontalBoardChainWalk.selection(afterDeleting: trackRef("t1"), in: board))
    }
}
