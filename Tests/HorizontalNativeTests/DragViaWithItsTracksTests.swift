import Foundation
import XCTest
@testable import HorizontalNative

/// Dragging a via takes its drill, its junctions and the ends of its net's
/// tracks on every layer it joins; the tracks' far ends stay where they are.
/// A locked via, one with a locked track on it, and one on a pad don't drag.
final class DragViaWithItsTracksTests: XCTestCase {
    private let mm = 1_000_000.0
    private static let net = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let other = "bbbbbbbb-0000-4000-8000-000000000002"

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// A via at v (5, 5) with its junctions on top and bottom, a top track off
    /// it to a and a bottom one to b, and another net's top track ending at
    /// its point.
    private func viaBoard() -> HorizontalBoard {
        let junctions = ["vt": p(5, 5), "vb": p(5, 5), "a": p(0, 5), "b": p(5, 15), "o": p(10, 10)]
        let tracks = [
            HorizontalSegment(id: "top", from: p(5, 5), to: p(0, 5), width: 200_000, layer: HorizontalBoardLayers.topCopper,
                              netID: Self.net, fromJunctionID: "vt", toJunctionID: "a"),
            HorizontalSegment(id: "bottom", from: p(5, 15), to: p(5, 5), width: 200_000, layer: HorizontalBoardLayers.bottomCopper,
                              netID: Self.net, fromJunctionID: "b", toJunctionID: "vb"),
            HorizontalSegment(id: "stranger", from: p(10, 10), to: p(5, 5), width: 200_000, layer: HorizontalBoardLayers.topCopper,
                              netID: Self.other, fromJunctionID: "o", toJunctionID: nil),
        ]
        let via = HorizontalMarker(id: "V", position: p(5, 5), size: 600_000, holeSize: 300_000, layer: nil,
                                   connectedLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper],
                                   netID: Self.net)
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/drag-via.hprj"), uuid: "b", name: "drag via",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: junctions, junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [via],
            viaHoles: [HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: "V"), position: via.position,
                                      diameter: 300_000, plated: true, netID: Self.net)],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func begin(_ board: HorizontalBoard, _ refs: [HorizontalSelectableRef]) -> Result<HorizontalCopperDrag, HorizontalCopperDrag.Refusal> {
        HorizontalCopperDrag.begin(selection: refs, on: board)
    }

    private let viaRef = HorizontalSelectableRef(id: "V", type: .via)

    private func track(_ id: String, in board: HorizontalBoard) throws -> HorizontalSegment {
        try XCTUnwrap(board.tracks.first { $0.id == id })
    }

    func testAViaDragsWithItsTracksOnEveryLayerTheirFarEndsStaying() throws {
        let original = viaBoard()
        let drag = try begin(original, [viaRef]).get()
        XCTAssertEqual(drag.actionName, "Drag Via")
        XCTAssertEqual(drag.anchor, p(5, 5))
        let moved = drag.applied(to: original, shift: p(2, 1))

        XCTAssertEqual(moved.vias[0].position, p(7, 6))
        XCTAssertEqual(moved.viaHoles[0].position, p(7, 6), "the drill went with it")
        XCTAssertEqual(try track("top", in: moved).from, p(7, 6), "the top track still ends on the via")
        XCTAssertEqual(try track("top", in: moved).to, p(0, 5), "its far end stays")
        XCTAssertEqual(try track("bottom", in: moved).to, p(7, 6), "so does the bottom one, on the other layer")
        XCTAssertEqual(try track("bottom", in: moved).from, p(5, 15))
        XCTAssertEqual(try track("stranger", in: moved).to, p(5, 5), "another net's track there stays")
        XCTAssertEqual(moved.junctions["a"], p(0, 5))
        XCTAssertEqual(moved.junctions["b"], p(5, 15))
        let viaJunctions = moved.junctions.filter { $0.value == p(7, 6) }.map(\.key)
        XCTAssertFalse(viaJunctions.isEmpty, "the via's junctions came along")
        XCTAssertTrue(moved.junctions.values.filter { $0 == p(5, 5) }.isEmpty, "none left behind")
        let ends = Set([try track("top", in: moved).fromJunctionID, try track("bottom", in: moved).toJunctionID].compactMap { $0 })
        XCTAssertTrue(ends.isSubset(of: Set(viaJunctions)), "the tracks still name a junction at the via")
    }

    func testNoShiftLeavesTheViaWhereItIs() throws {
        let original = viaBoard()
        let moved = try begin(original, [viaRef]).get().applied(to: original, shift: .zero)
        XCTAssertEqual(moved.vias, original.vias)
        XCTAssertEqual(moved.tracks, original.tracks)
        XCTAssertEqual(moved.junctions, original.junctions)
    }

    func testAViaSelectedWithItsTracksDrags() throws {
        // Neither track can drag keeping its slopes (each ends on the via, and
        // alone at its far end), so the via does.
        let original = viaBoard()
        let refs = [viaRef] + original.tracks.map { HorizontalSelectableRef(id: $0.id, type: .track) }
        guard case .via = try begin(original, refs).get().kind else { return XCTFail("the via drags") }
    }

    func testLockedViasAndViasWithLockedTracksAndOnPadsAreRefused() {
        var locked = viaBoard()
        locked.vias[0].locked = true
        XCTAssertEqual(refusal(begin(locked, [viaRef])), .locked)

        var lockedTrack = viaBoard()
        lockedTrack.tracks[1].locked = true
        XCTAssertEqual(refusal(begin(lockedTrack, [viaRef])), .lockedTrackOnVia)

        var lockedStranger = viaBoard()
        lockedStranger.tracks[2].locked = true
        XCTAssertNil(refusal(begin(lockedStranger, [viaRef])), "another net's locked track isn't the via's")

        var onPad = viaBoard()
        onPad.packagePadPositions = ["pkg/1": p(5, 5)]
        XCTAssertEqual(refusal(begin(onPad, [viaRef])), .viaOnPad)

        var two = viaBoard()
        two.vias.append(HorizontalMarker(id: "W", position: p(20, 20), size: 600_000, layer: nil, netID: Self.net))
        XCTAssertEqual(refusal(begin(two, [viaRef, HorizontalSelectableRef(id: "W", type: .via)])), .nothingToDrag)
    }

    private func refusal(_ result: Result<HorizontalCopperDrag, HorizontalCopperDrag.Refusal>) -> HorizontalCopperDrag.Refusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }
}
