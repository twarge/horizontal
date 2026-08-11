import XCTest
@testable import HorizontalNative

/// Tests the pad-seeded net-propagation engine: nets flow from pads across
/// connected copper; unreachable copper goes net-less; breaking a connection
/// disconnects copper; net collisions resolve to nil. Pure, no GUI.
final class HorizontalBoardConnectivityTests: XCTestCase {

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    /// A square copper pad centered at (cx,cy) carrying `net` (centroid == center,
    /// so the engine's pad-centroid seed lands exactly on the center point).
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

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        vias: [HorizontalMarker] = [],
        packagePads: [HorizontalPolygon] = [],
        lines: [HorizontalSegment] = [],
        arcs: [HorizontalArc] = [],
        junctions: [String: HorizontalPoint] = [:],
        junctionNetIDs: [String: String] = [:]
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                            HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000)],
            userLayers: [], junctions: junctions, junctionNetIDs: junctionNetIDs, netDetails: [:],
            tracks: tracks, netTies: [], lines: lines, arcs: arcs, connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [], packages: [], packagePads: packagePads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func netID(_ board: HorizontalBoard, track id: String) -> String?? {
        board.tracks.first { $0.id == id }?.netID
    }

    // MARK: - Tests

    /// An arc references three junctions — its two endpoints AND its center. The
    /// vacuum must keep all three; otherwise a drawn/converted arc loses its center
    /// junction on recompute and can't be written back to disk.
    func testArcCenterJunctionSurvivesVacuum() {
        let from = p(0, 0)
        let to = p(2_000_000, 0)
        let center = p(1_000_000, 1_000_000)
        let board = makeBoard(
            arcs: [HorizontalArc(id: "a", from: from, to: to, center: center, width: 0, layer: 0)],
            junctions: ["jf": from, "jt": to, "jc": center]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNotNil(out.junctions["jc"], "arc-center junction must survive the vacuum")
        XCTAssertNotNil(out.junctions["jf"])
        XCTAssertNotNil(out.junctions["jt"])
    }

    func testTrackTouchingPadAdoptsItsNet() {
        let board = makeBoard(
            tracks: [track("t", p(0, 0), p(5_000_000, 0))],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(out.tracks[0].netID?.lowercased(), "n1")
    }

    func testFloatingTrackGetsNoNet() {
        let board = makeBoard(
            tracks: [track("t", p(1_000_000, 1_000_000), p(5_000_000, 1_000_000), net: "stray")]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(out.tracks[0].netID, "a track touching no pad must be net-less (orange), stray net wiped")
    }

    func testNetPropagatesThroughChainOfTracks() {
        // padA — t1 — (shared point) — t2 — free end. Both adopt n1.
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0)),
                track("t2", p(5_000_000, 0), p(10_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": p(5_000_000, 0)]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(out.tracks.first { $0.id == "t1" }?.netID?.lowercased(), "n1")
        XCTAssertEqual(out.tracks.first { $0.id == "t2" }?.netID?.lowercased(), "n1")
        XCTAssertEqual(out.junctionNetIDs["j"]?.lowercased(), "n1", "junction adopts the component net")
    }

    func testShortBetweenTwoNetsResolvesToNil() {
        let board = makeBoard(
            tracks: [track("t", p(0, 0), p(10_000_000, 0))],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1"),
                          pad("pkg/pad/2", cx: 10_000_000, cy: 0, net: "n2")]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(out.tracks[0].netID, "a track shorting two nets must resolve to nil (flagged)")
    }

    func testBreakingConnectionDisconnectsCopper() {
        // padA — t1 — j — t2 (free). Both n1. Remove t1 ⇒ t2 orphaned ⇒ nil.
        var board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0)),
                track("t2", p(5_000_000, 0), p(10_000_000, 0)),
            ],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": p(5_000_000, 0)]
        )
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(board.tracks.first { $0.id == "t2" }?.netID?.lowercased(), "n1")

        board.tracks.removeAll { $0.id == "t1" } // break the connection to the pad
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(out.tracks.first { $0.id == "t2" }?.netID, "orphaned copper must disconnect")
    }

    func testViaInheritsComponentNet() {
        let board = makeBoard(
            tracks: [track("t", p(0, 0), p(5_000_000, 0))],
            vias: [HorizontalMarker(id: "v", position: p(5_000_000, 0), size: 600_000, holeSize: 300_000,
                                 layer: nil, connectedLayers: [0, -100], netID: "stray")],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")]
        )
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(out.vias[0].netID?.lowercased(), "n1")
    }

    func testOrphanedJunctionIsVacuumed() {
        var board = makeBoard(
            tracks: [track("t1", p(0, 0), p(5_000_000, 0))],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": p(5_000_000, 0)],
            junctionNetIDs: ["j": "n1"]
        )
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNotNil(board.junctions["j"], "a junction with an incident track is kept")

        board.tracks.removeAll { $0.id == "t1" } // delete the only track meeting it
        let out = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(out.junctions["j"], "an orphaned junction must be vacuumed")
        XCTAssertNil(out.junctionNetIDs["j"])
    }

    func testIdempotent() {
        let board = makeBoard(
            tracks: [track("t1", p(0, 0), p(5_000_000, 0)),
                     track("t2", p(5_000_000, 0), p(10_000_000, 0))],
            packagePads: [pad("pkg/pad/1", cx: 0, cy: 0, net: "n1")],
            junctions: ["j": p(5_000_000, 0)]
        )
        let once = HorizontalBoardConnectivity.recompute(board)
        let twice = HorizontalBoardConnectivity.recompute(once)
        XCTAssertEqual(once.tracks.map(\.netID), twice.tracks.map(\.netID))
        XCTAssertEqual(once.junctionNetIDs, twice.junctionNetIDs)
    }
}
