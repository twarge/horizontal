import XCTest
@testable import HorizontalNative

/// Copper on different layers must only be treated as connected where something
/// actually spans those layers.
///
/// This is not a cosmetic rule. Net resolution requires a component to carry
/// exactly ONE net — a component carrying two resolves to none — so a single
/// false cross-layer join does not merge two nets, it strands both. On a real
/// board (Randi Short) one bottom track ending on a top pad's centre left 46 of
/// 791 tracks with no net at all, drawn as unconnected copper.
final class BoardCrossLayerConnectivityTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func pad(_ id: String, at point: HorizontalPoint, net: String, layer: Int) -> HorizontalPolygon {
        let half = 300_000.0
        return HorizontalPolygon(
            id: id,
            vertices: [p(point.x - half, point.y - half), p(point.x + half, point.y - half),
                       p(point.x + half, point.y + half), p(point.x - half, point.y + half)],
            layer: layer,
            netID: net
        )
    }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: 200_000, layer: layer, netID: nil)
    }

    private func makeBoard(tracks: [HorizontalSegment],
                           pads: [HorizontalPolygon],
                           vias: [HorizontalMarker] = []) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [], packages: [], packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func net(_ board: HorizontalBoard, _ id: String) -> String? {
        board.tracks.first { $0.id == id }?.netID
    }

    /// A top track and a bottom track that share a coordinate with nothing
    /// spanning the layers are two independent nets, not one.
    ///
    /// Before this rule both went net-less: the merged component saw two nets
    /// and so resolved to none.
    func testTouchingTracksOnDifferentLayersStayOnTheirOwnNets() {
        let meeting = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t-top", p(0, 0), meeting, layer: top),
                track("t-bottom", meeting, p(10_000_000, 0), layer: bottom),
            ],
            pads: [
                pad("pkg/pad/a", at: p(0, 0), net: "net-a", layer: top),
                pad("pkg/pad/b", at: p(10_000_000, 0), net: "net-b", layer: bottom),
            ]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(net(resolved, "t-top"), "net-a")
        XCTAssertEqual(net(resolved, "t-bottom"), "net-b")
    }

    /// The same geometry WITH a via is a genuine connection — and because the
    /// two ends carry different nets, that is a short, which resolves to no net
    /// rather than silently picking one.
    func testAViaDoesJoinTheLayers() {
        let meeting = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t-top", p(0, 0), meeting, layer: top),
                track("t-bottom", meeting, p(10_000_000, 0), layer: bottom),
            ],
            pads: [
                pad("pkg/pad/a", at: p(0, 0), net: "net-a", layer: top),
                pad("pkg/pad/b", at: p(10_000_000, 0), net: "net-b", layer: bottom),
            ],
            vias: [HorizontalMarker(id: "v1", position: meeting, size: 600_000, layer: nil)]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(net(resolved, "t-top"), "two nets joined by a via is a short, so neither wins")
        XCTAssertNil(net(resolved, "t-bottom"))
    }

    /// A via carrying one net across layers is the ordinary case and must still
    /// connect: layer-awareness must not break normal routing.
    func testViaCarriesOneNetAcrossLayers() {
        let meeting = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [
                track("t-top", p(0, 0), meeting, layer: top),
                track("t-bottom", meeting, p(10_000_000, 0), layer: bottom),
            ],
            pads: [pad("pkg/pad/a", at: p(0, 0), net: "net-a", layer: top)],
            vias: [HorizontalMarker(id: "v1", position: meeting, size: 600_000, layer: nil)]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(net(resolved, "t-top"), "net-a")
        XCTAssertEqual(net(resolved, "t-bottom"), "net-a", "the far side of a via is the same net")
    }

    /// One pad with copper on both sides is one electrical object, so a bottom
    /// track reaching a through-hole pad takes its net.
    func testThroughHolePadConnectsBothSides() {
        let padCenter = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [track("t-bottom", padCenter, p(10_000_000, 0), layer: bottom)],
            pads: [
                pad("pkg/pad/th", at: padCenter, net: "net-th", layer: top),
                pad("pkg/pad/th/shape/2", at: padCenter, net: "net-th", layer: bottom),
            ]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(net(resolved, "t-bottom"), "net-th")
    }

    /// Same-layer connection — the common case — is unaffected.
    func testSameLayerTracksStillConnect() {
        let board = makeBoard(
            tracks: [
                track("t1", p(0, 0), p(5_000_000, 0), layer: top),
                track("t2", p(5_000_000, 0), p(10_000_000, 0), layer: top),
            ],
            pads: [pad("pkg/pad/a", at: p(0, 0), net: "net-a", layer: top)]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(net(resolved, "t1"), "net-a")
        XCTAssertEqual(net(resolved, "t2"), "net-a")
    }

    /// A bottom track ending on a TOP-only pad's centre gets no net from it —
    /// the exact false join that stranded the real board. It must not pick up
    /// the pad's net, and it must not drag that net into its own component.
    func testBottomTrackDoesNotInheritATopOnlyPadNet() {
        let padCenter = p(5_000_000, 0)
        let board = makeBoard(
            tracks: [track("t-bottom", padCenter, p(10_000_000, 0), layer: bottom)],
            pads: [pad("pkg/pad/smd", at: padCenter, net: "net-top", layer: top)]
        )

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertNil(net(resolved, "t-bottom"))
    }
}
