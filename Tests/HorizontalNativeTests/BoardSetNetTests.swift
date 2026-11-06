import XCTest
@testable import HorizontalNative

/// Set Net… on a track or via (`BoardSetNet`), Horizon's Set via net: copper
/// holds no net of its own, so the net goes on every via in the run of
/// copper, pinned as a stitching via's is, and the run's tracks take it from
/// them when connectivity is recomputed. A run that reaches a pad has the
/// pad's net, the schematic's, and a run with no via has nothing to hold one;
/// on those Set Net… is unavailable, and says why. Pure, no GUI.
final class BoardSetNetTests: XCTestCase {
    private let mm = 1_000_000.0

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    private func pad(_ id: String, at center: HorizontalPoint, net: String?) -> HorizontalPolygon {
        let half = 300_000.0
        return HorizontalPolygon(
            id: id,
            vertices: [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                       HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)],
            layer: 0,
            netID: net
        )
    }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: 200_000, layer: 0, netID: nil)
    }

    private func via(_ id: String, at point: HorizontalPoint, pinned net: String? = nil) -> HorizontalMarker {
        HorizontalMarker(id: id, position: point, size: 600_000, holeSize: 300_000, layer: nil,
                         connectedLayers: [0, -100], netID: net, netSetID: net)
    }

    /// The board as the canvas has it: its nets given by connectivity.
    private func board(
        tracks: [HorizontalSegment] = [],
        vias: [HorizontalMarker] = [],
        pads: [HorizontalPolygon] = []
    ) -> HorizontalBoard {
        HorizontalBoardConnectivity.recompute(HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                            HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000)],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [], packages: [], packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        ))
    }

    private let trackRef = HorizontalSelectableRef(id: "t", type: .track, layer: 0)

    private func viaRef(_ id: String = "v") -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .via)
    }

    func testANetlessViaTakesTheNetAndTheTrackOnItFollows() throws {
        var board = board(tracks: [track("t", p(0, 0), p(5, 0))], vias: [via("v", at: p(5, 0))])
        XCTAssertNil(board.tracks[0].netID)
        XCTAssertEqual(BoardSetNet.availability(of: viaRef(), in: board), .available(viaIDs: ["v"]))
        XCTAssertEqual(BoardSetNet.availability(of: trackRef, in: board), .available(viaIDs: ["v"]),
                       "the track's net goes on the via it reaches")

        XCTAssertTrue(BoardSetNet.setNet("GND", on: [trackRef], in: &board))
        XCTAssertEqual(board.vias[0].netSetID, "gnd", "pinned, as a stitching via's net is")
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(board.tracks[0].netID, "gnd")
        XCTAssertEqual(board.vias[0].netID, "gnd")
        XCTAssertFalse(BoardSetNet.setNet("gnd", on: [trackRef], in: &board), "the same net again changes nothing")
    }

    func testEveryViaOnTheRunTakesTheNetAndAPinnedOneCanBeSetAgain() throws {
        // A stitching run: a GND via, a track, and a via that has GND from it.
        var board = board(tracks: [track("t", p(0, 0), p(5, 0))],
                          vias: [via("v1", at: p(0, 0), pinned: "gnd"), via("v2", at: p(5, 0))])
        XCTAssertEqual(board.tracks[0].netID, "gnd")
        XCTAssertNil(board.vias[1].netSetID)
        for ref in [trackRef, viaRef("v1"), viaRef("v2")] {
            XCTAssertEqual(BoardSetNet.availability(of: ref, in: board), .available(viaIDs: ["v1", "v2"]),
                           "a net the run's vias pin is theirs to change: \(ref.type)")
        }

        XCTAssertTrue(BoardSetNet.setNet("sig", on: [viaRef("v2")], in: &board))
        XCTAssertEqual(board.vias.map(\.netSetID), ["sig", "sig"], "so one isn't left pinned on the old net")
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(board.tracks[0].netID, "sig")
    }

    func testATrackThatReachesNoViaHasNothingToHoldANet() throws {
        var board = board(tracks: [track("t", p(0, 0), p(5, 0))])
        let availability = try XCTUnwrap(BoardSetNet.availability(of: trackRef, in: board))
        XCTAssertEqual(availability, .needsVia)
        XCTAssertNotNil(availability.reason)
        XCTAssertFalse(BoardSetNet.setNet("gnd", on: [trackRef], in: &board))
    }

    func testCopperOnAPadsNetIsThePadsAndNetlessCopperOnAPadSaysWhy() throws {
        // On a pad's net: nothing to offer, it is the schematic's.
        let onNet = board(tracks: [track("t", p(0, 0), p(5, 0))], vias: [via("v", at: p(5, 0))],
                          pads: [pad("pkg/pad/1", at: p(0, 0), net: "n1")])
        XCTAssertEqual(onNet.tracks[0].netID, "n1")
        XCTAssertNil(BoardSetNet.availability(of: trackRef, in: onNet))
        XCTAssertNil(BoardSetNet.availability(of: viaRef(), in: onNet))

        // On a pad on no net: the via could hold one, but it would short the pad.
        var netless = board(tracks: [track("t", p(0, 0), p(5, 0))], vias: [via("v", at: p(5, 0))],
                            pads: [pad("pkg/pad/1", at: p(0, 0), net: nil)])
        XCTAssertNil(netless.tracks[0].netID)
        let availability = try XCTUnwrap(BoardSetNet.availability(of: viaRef(), in: netless))
        XCTAssertEqual(availability, .reachesPad)
        XCTAssertNotNil(availability.reason)
        XCTAssertEqual(BoardSetNet.availability(of: trackRef, in: netless), .reachesPad)
        XCTAssertFalse(BoardSetNet.setNet("gnd", on: [viaRef()], in: &netless))
        XCTAssertNil(netless.vias[0].netSetID)

        // A short between two pads' nets: net-less, and no pin overrules it.
        let short = board(tracks: [track("t", p(0, 0), p(5, 0))],
                          pads: [pad("a/pad/1", at: p(0, 0), net: "n1"), pad("b/pad/1", at: p(5, 0), net: "n2")])
        XCTAssertNil(short.tracks[0].netID)
        XCTAssertEqual(BoardSetNet.availability(of: trackRef, in: short), .reachesPad)
    }

    func testOnlyTheRunTheRefIsPartOfTakesTheNet() {
        // Two runs of netless copper; the second's via keeps no net.
        var board = board(tracks: [track("t", p(0, 0), p(5, 0)), track("u", p(0, 10), p(5, 10))],
                          vias: [via("v", at: p(5, 0)), via("w", at: p(5, 10))])
        XCTAssertTrue(BoardSetNet.setNet("gnd", on: [trackRef], in: &board))
        XCTAssertEqual(board.vias.map(\.netSetID), ["gnd", nil])
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(board.tracks.map(\.netID), ["gnd", nil])
    }

    func testOtherObjectsOfferNothing() {
        let board = board(tracks: [track("t", p(0, 0), p(5, 0))])
        XCTAssertNil(BoardSetNet.availability(of: HorizontalSelectableRef(id: "t", type: .boardLine), in: board))
        XCTAssertNil(BoardSetNet.availability(of: HorizontalSelectableRef(id: "missing", type: .via), in: board))
    }

    /// The writer had no hand in a via's pinned net: a via the file had kept
    /// whatever `net_set` it had, so Set Net… on one was lost on save.
    func testAViaTheFileHadIsWrittenWithTheNetPinnedOnIt() {
        var pinned = via("v", at: p(5, 0))
        pinned.netSetID = "6d1f3c2a-0b4e-4f6a-8c1d-2e3f4a5b6c7d"
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(pinned, existing: ["junction": "j"])
        XCTAssertEqual(entry["net_set"] as? String, "6d1f3c2a-0b4e-4f6a-8c1d-2e3f4a5b6c7d")

        let kept = HorizontalProjectJSONApplicator.viaJSONEntry(
            pinned, existing: ["junction": "j", "net_set": "6D1F3C2A-0B4E-4F6A-8C1D-2E3F4A5B6C7D"])
        XCTAssertEqual(kept["net_set"] as? String, "6D1F3C2A-0B4E-4F6A-8C1D-2E3F4A5B6C7D", "an unchanged net keeps its casing")

        let cleared = HorizontalProjectJSONApplicator.viaJSONEntry(via("v", at: p(5, 0)), existing: ["junction": "j", "net_set": "x"])
        XCTAssertNil(cleared["net_set"], "a via pinned on no net has none in the file")
    }
}
