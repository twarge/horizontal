import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Two junctions at one point fold into one only where they are on one net,
/// as Horizon's move merges them: a track end moved or routed onto another
/// net's keeps a junction of its own there, the two tracks keep their nets,
/// and either can be moved away again. A junction on no net folds with any.
/// A via stands on a junction of its own too, so the same holds of a track
/// end moved onto another net's via, and of a via dropped or moved onto
/// another net's copper.
///
/// Before, every junction at the point folded into one. The two tracks then
/// ended on one junction, the copper of both nets went net-less, and a move
/// of the junction took both tracks with it for good.
final class BoardJunctionsOnDifferentNetsTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let via = HorizontalBoardViaTemplate(
        padstackID: HorizontalProjectArchive.horizonPoolCircularVia, diameter: 600_000, holeDiameter: 300_000, fromRules: false,
        parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000])

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func pad(_ package: String, at center: HorizontalPoint, net: String?) -> HorizontalPolygon {
        let half = 300_000.0
        return HorizontalPolygon(
            id: "\(package)/pad/1",
            vertices: [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                       HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)],
            layer: top,
            netID: net
        )
    }

    /// A pad of `upperNet` at (0, 10) with a track to a junction "upper" at
    /// (10, 10), and a pad of `lowerNet` at (0, 0) with a track to a junction
    /// "lower" at (10, 0), all on the top; nets as the canvas has them.
    private func board(upperNet: String?, lowerNet: String? = "n1") -> HorizontalBoard {
        let pads = [pad("u", at: point(0, 10), net: upperNet), pad("l", at: point(0, 0), net: lowerNet)]
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/junction-nets.hprj"), uuid: "b", name: "junction-nets",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: top, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: bottom, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: ["upper": point(10, 10), "lower": point(10, 0)], junctionNetIDs: [:], netDetails: [:],
            tracks: [
                HorizontalSegment(id: "upper-track", from: point(0, 10), to: point(10, 10), width: 200_000, layer: top,
                                  toJunctionID: "upper"),
                HorizontalSegment(id: "lower-track", from: point(0, 0), to: point(10, 0), width: 200_000, layer: top,
                                  toJunctionID: "lower"),
            ],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: pads, packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["u/1": point(0, 10), "l/1": point(0, 0)]
        return HorizontalBoardConnectivity.recompute(board)
    }

    /// The copper of `netID` at `from` moved to `to`, as a move of a junction
    /// or a track end carries it (`BoardMovingPoints`), with the nets the
    /// canvas then gives the board.
    private func moved(_ board: HorizontalBoard, from: HorizontalPoint, to: HorizontalPoint, netID: String?) -> HorizontalBoard {
        var points = BoardMovingPoints()
        points.add(from, to: to, netID: netID)
        var result = board
        points.apply(from: board, to: &result)
        return HorizontalBoardConnectivity.recompute(result)
    }

    private func junctions(at point: HorizontalPoint, in board: HorizontalBoard) -> [String] {
        board.junctions.filter { $0.value == point }.map(\.key).sorted()
    }

    private func track(_ id: String, in board: HorizontalBoard) throws -> HorizontalSegment {
        try XCTUnwrap(board.tracks.first { $0.id == id })
    }

    func testATrackEndMovedOntoAnotherNetsKeepsItsJunctionAndItsNet() throws {
        let start = board(upperNet: "n2")
        XCTAssertEqual(start.junctionNetIDs, ["upper": "n2", "lower": "n1"])

        let shared = point(10, 0)
        let together = moved(start, from: point(10, 10), to: shared, netID: "n2")
        XCTAssertEqual(junctions(at: shared, in: together), ["lower", "upper"], "the two junctions are not folded into one")
        let upper = try track("upper-track", in: together), lower = try track("lower-track", in: together)
        XCTAssertEqual(upper.to, shared)
        XCTAssertEqual(upper.toJunctionID, "upper", "each track ends on its own junction")
        XCTAssertEqual(lower.toJunctionID, "lower")
        XCTAssertEqual(upper.netID, "n2", "and stays on its own net")
        XCTAssertEqual(lower.netID, "n1")
        XCTAssertEqual(together.junctionNetIDs, ["upper": "n2", "lower": "n1"])
        XCTAssertTrue(HorizontalBoardConnectivity.shorts(together).isEmpty, "the two nets are not one piece of copper")
        XCTAssertEqual(
            HorizontalBoardConnectivity.runs(of: [.track("upper-track")], in: together).first??.trackIDs, ["upper-track"])
        // The copper of the two does touch, and the clearance check says so.
        let touching = HorizontalBoardClearanceCheck.run(board: together).filter { $0.check == .copper }
        XCTAssertTrue(
            touching.contains { Set([$0.first.id, $0.second.id]) == ["upper-track", "lower-track"] },
            touching.map(\.title).joined(separator: "\n"))

        // Moved away again, the end goes alone.
        let apart = moved(together, from: shared, to: point(10, 5), netID: "n2")
        XCTAssertEqual(apart.junctions, ["upper": point(10, 5), "lower": shared])
        XCTAssertEqual(try track("upper-track", in: apart).to, point(10, 5))
        XCTAssertEqual(try track("lower-track", in: apart).to, shared, "the other net's track stays where it was")
        XCTAssertEqual(apart.tracks.map(\.netID), ["n2", "n1"])
    }

    func testATrackEndMovedOntoItsOwnNetsFoldsIntoItsJunction() throws {
        let shared = point(10, 0)
        let together = moved(board(upperNet: "n1"), from: point(10, 10), to: shared, netID: "n1")
        XCTAssertEqual(junctions(at: shared, in: together), ["upper"], "one junction, the one that moved")
        XCTAssertEqual(together.tracks.map(\.toJunctionID), ["upper", "upper"])
        XCTAssertEqual(together.tracks.map(\.netID), ["n1", "n1"])
    }

    func testATrackEndOnNoNetFoldsIntoAnyJunctionAndTakesItsNet() throws {
        let start = board(upperNet: nil)
        XCTAssertNil(start.junctionNetIDs["upper"])

        let shared = point(10, 0)
        let together = moved(start, from: point(10, 10), to: shared, netID: nil)
        XCTAssertEqual(junctions(at: shared, in: together).count, 1)
        XCTAssertEqual(together.tracks.map(\.netID), ["n1", "n1"], "the copper on no net joins the net it reached")

        // And a net's end moved onto copper of none.
        let onto = moved(start, from: shared, to: point(10, 10), netID: "n1")
        XCTAssertEqual(junctions(at: point(10, 10), in: onto).count, 1)
        XCTAssertEqual(onto.tracks.map(\.netID), ["n1", "n1"])
    }

    /// A route that ends where another net's track ends lays its last track
    /// onto a junction of its own; one of the same net joins the junction.
    func testARouteEndingOnAnotherNetsJunctionGetsItsOwn() throws {
        let shared = point(10, 0)
        func route(netID: String, on board: inout HorizontalBoard) throws -> HorizontalSegment {
            let from = point(20, 0)
            let head = BoardTrackRouteHead(
                anchor: from, anchorJunctionID: nil, anchorOnPad: false, netID: netID, width: 200_000, layer: top, placesVia: false)
            let laid = BoardTrackRouting.lay(
                [BoardTrackSegmentSpec(from: from, to: shared)], to: shared, endsOnPad: false, via: nil, from: head, on: &board)
            return try track(try XCTUnwrap(laid.trackIDs.first), in: board)
        }

        var other = board(upperNet: "n2")
        let apart = try route(netID: "n2", on: &other)
        XCTAssertNotEqual(apart.toJunctionID, "lower")
        XCTAssertEqual(junctions(at: shared, in: other).count, 2)
        XCTAssertEqual(try track("lower-track", in: other).toJunctionID, "lower")
        XCTAssertEqual(other.junctionNetIDs["lower"], "n1", "the junction it found there keeps its net")

        var same = board(upperNet: "n2")
        let joined = try route(netID: "n1", on: &same)
        XCTAssertEqual(joined.toJunctionID, "lower")
        XCTAssertEqual(junctions(at: shared, in: same), ["lower"])
    }

    /// A via stands on one junction, and a track end of another net moved
    /// onto it keeps its own: the via and its tracks keep their net, and
    /// either goes away again without the other.
    func testATrackEndMovedOntoAnotherNetsViaKeepsItsJunctionAndItsNet() throws {
        let shared = point(10, 0)
        var withVia = board(upperNet: "n2")
        BoardTrackRouting.dropVia(via, at: shared, netID: "n1", preferredJunctionID: "lower", on: &withVia)
        withVia = HorizontalBoardConnectivity.recompute(withVia)
        XCTAssertEqual(withVia.vias.map(\.junctionID), ["lower"])
        XCTAssertEqual(withVia.vias.map(\.netID), ["n1"])

        let together = moved(withVia, from: point(10, 10), to: shared, netID: "n2")
        XCTAssertEqual(junctions(at: shared, in: together), ["lower", "upper"], "the via's junction and the track's")
        XCTAssertEqual(together.vias.map(\.junctionID), ["lower"])
        XCTAssertEqual(together.vias.map(\.netID), ["n1"], "the via stays on its net")
        XCTAssertEqual(together.viaHoles.map(\.netID), ["n1"])
        XCTAssertEqual(try track("upper-track", in: together).netID, "n2")
        XCTAssertEqual(try track("lower-track", in: together).netID, "n1")
        XCTAssertEqual(together.junctionNetIDs, ["upper": "n2", "lower": "n1"])
        XCTAssertTrue(HorizontalBoardConnectivity.shorts(together).isEmpty)
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: bottom, in: together), "lower", "a route from the via starts on its junction")
        XCTAssertEqual(
            Set(BoardSelectMore.selection(from: [HorizontalSelectableRef(id: together.vias[0].id, type: .via)], in: together, stopsAtVias: false)
                .map(\.id)),
            ["lower-track", "lower"], "Select More from the via stays on its copper")

        // The track end goes away again alone.
        let apart = moved(together, from: shared, to: point(10, 5), netID: "n2")
        XCTAssertEqual(apart.junctions, ["upper": point(10, 5), "lower": shared])
        XCTAssertEqual(apart.vias.map(\.position), [shared], "the via stays")
        XCTAssertEqual(try track("lower-track", in: apart).to, shared)

        // And the via goes away with its own track and junction.
        let viaAway = moved(together, from: shared, to: point(15, 0), netID: "n1")
        XCTAssertEqual(viaAway.junctions, ["upper": shared, "lower": point(15, 0)])
        XCTAssertEqual(viaAway.vias.map(\.position), [point(15, 0)])
        XCTAssertEqual(try track("upper-track", in: viaAway).to, shared)
        XCTAssertEqual(viaAway.tracks.map(\.netID), ["n2", "n1"])
    }

    /// A via dropped where junctions of two nets stand goes on the one of its
    /// net, and on one of its own where none is.
    func testAViaDroppedWhereAnotherNetsJunctionStandsLeavesItApart() throws {
        let shared = point(10, 0)
        let together = moved(board(upperNet: "n2"), from: point(10, 10), to: shared, netID: "n2")
        XCTAssertEqual(junctions(at: shared, in: together).count, 2)

        var dropped = together
        let junction = BoardTrackRouting.dropVia(via, at: shared, netID: "n1", preferredJunctionID: nil, on: &dropped)
        dropped = HorizontalBoardConnectivity.recompute(dropped)
        XCTAssertEqual(junction, "lower")
        XCTAssertEqual(junctions(at: shared, in: dropped), ["lower", "upper"])
        XCTAssertEqual(dropped.vias.map(\.netID), ["n1"])
        XCTAssertEqual(dropped.tracks.map(\.netID), ["n2", "n1"])

        var other = together
        let own = BoardTrackRouting.dropVia(via, at: shared, netID: "n3", pinsNet: true, preferredJunctionID: nil, on: &other)
        other = HorizontalBoardConnectivity.recompute(other)
        XCTAssertEqual(Set(junctions(at: shared, in: other)), ["lower", "upper", own], "a junction of its own")
        XCTAssertEqual(other.vias.map(\.netID), ["n3"])
        XCTAssertEqual(other.tracks.map(\.netID), ["n2", "n1"])
        XCTAssertEqual(other.junctionNetIDs[own], "n3")
        XCTAssertEqual(other.junctionNetIDs["upper"], "n2")
        XCTAssertEqual(other.junctionNetIDs["lower"], "n1")
    }

    /// A via that names no junction at its point, as a copy of a block's
    /// layout has none, still joins what is there: the junctions fold
    /// whatever their nets, and the check says the nets are shorted.
    func testAViaThatNamesNoJunctionJoinsTheJunctionsAtItsPoint() throws {
        let shared = point(10, 0)
        var withVia = board(upperNet: "n2")
        withVia.vias.append(HorizontalMarker(id: "bare", position: shared, size: 600_000, holeSize: 300_000, layer: nil))
        withVia = HorizontalBoardConnectivity.recompute(withVia)

        let onto = moved(withVia, from: point(10, 10), to: shared, netID: "n2")
        XCTAssertEqual(junctions(at: shared, in: onto).count, 1, "the via joins them")
        XCTAssertEqual(HorizontalBoardConnectivity.shorts(onto).map(\.nets), [["n1", "n2"]])
    }

    /// Junctions carried with their pads fold the same way where they land:
    /// those of two nets stay two, and one on no net folds with the first it
    /// meets, the last to land being the one kept.
    func testJunctionsCarriedToOnePointFoldOnlyOnTheirNet() throws {
        var board = board(upperNet: "n2")
        board.junctions["free"] = point(20, 0)
        let landing = point(30, 30)
        BoardTrackRouting.carryJunctions([(["upper"], landing, nil), (["lower"], landing, nil)], board: &board)
        XCTAssertEqual(junctions(at: landing, in: board), ["lower", "upper"])
        XCTAssertEqual(board.junctionNetIDs, ["upper": "n2", "lower": "n1"])

        BoardTrackRouting.carryJunctions([(["free"], landing, nil)], board: &board)
        XCTAssertEqual(junctions(at: landing, in: board), ["free", "upper"], "it took in the first it met, and left the other net's")
        XCTAssertEqual(board.junctionNetIDs, ["upper": "n2", "free": "n1"])
        XCTAssertEqual(try track("lower-track", in: board).toJunctionID, "free")
        XCTAssertEqual(try track("upper-track", in: board).toJunctionID, "upper")
    }

    /// Junctions of their own at one point on one net are still one piece of
    /// copper, as copper at one point always was: only two nets keep them
    /// apart.
    func testJunctionsOfTheirOwnOnOneNetAreStillJoined() throws {
        var board = board(upperNet: nil)
        // A second track on the lower junction's point, on a junction of its
        // own, reaching no pad.
        board.junctions["stub"] = point(10, 0)
        board.tracks.append(HorizontalSegment(
            id: "stub-track", from: point(10, 0), to: point(20, 0), width: 200_000, layer: top,
            fromJunctionID: "stub", toJunctionID: nil))
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(try track("stub-track", in: board).netID, "n1")
        XCTAssertEqual(board.junctionNetIDs["stub"], "n1")
    }

    /// Written and read back, the two ends are on their own junctions and
    /// their own nets. The nets come from pinned vias here, a blank board
    /// having no pads.
    func testTheFileKeepsThemApartAndReadsBackOnTheirNets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-junction-nets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Junctions.horizontal")
        try HorizontalProjectArchive.newProject(
            pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia), blankBoard: true
        ).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        let n1 = "11111111-0000-4000-8000-000000000001", n2 = "22222222-0000-4000-8000-000000000002"
        let shared = point(10, 0)
        var board = try XCTUnwrap(project.board)
        var trackIDs = [String: String]()
        for (netID, start) in [(n1, point(0, 0)), (n2, point(0, 10))] {
            let junction = BoardTrackRouting.dropVia(via, at: start, netID: netID, pinsNet: true, preferredJunctionID: nil, on: &board)
            let head = BoardTrackRouteHead(
                anchor: start, anchorJunctionID: junction, anchorOnPad: false, netID: netID, width: 200_000, layer: top,
                placesVia: false)
            let laid = BoardTrackRouting.lay(
                [BoardTrackSegmentSpec(from: start, to: shared)], to: shared, endsOnPad: false, via: nil, from: head, on: &board)
            trackIDs[netID] = try XCTUnwrap(laid.trackIDs.first)
        }
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(junctions(at: shared, in: board).count, 2)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let read = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertEqual(junctions(at: shared, in: read).count, 2, "the file keeps both junctions")
        let first = try track(try XCTUnwrap(trackIDs[n1]), in: read), second = try track(try XCTUnwrap(trackIDs[n2]), in: read)
        XCTAssertNotEqual(first.toJunctionID, second.toJunctionID)
        XCTAssertEqual(first.netID, n1, "and the board opens with each track on its net")
        XCTAssertEqual(second.netID, n2)
        XCTAssertEqual(first.toJunctionID.flatMap { read.junctionNetIDs[$0] }, n1)
        XCTAssertEqual(second.toJunctionID.flatMap { read.junctionNetIDs[$0] }, n2)
    }

    /// A via with another net's track end on it is written on its own
    /// junction, though the other's comes first by id, and reads back on its
    /// net with the track on the other.
    func testAViaIsWrittenOnItsOwnJunctionBesideAnotherNets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-junction-nets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Junctions.horizontal")
        try HorizontalProjectArchive.newProject(
            pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia), blankBoard: true
        ).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        let n1 = "11111111-0000-4000-8000-000000000001", n2 = "22222222-0000-4000-8000-000000000002"
        let viaJunction = "ffffffff-0000-4000-8000-000000000001", trackJunction = "00000000-0000-4000-8000-000000000002"
        let shared = point(10, 0)
        var board = try XCTUnwrap(project.board)
        BoardTrackRouting.dropVia(via, at: shared, netID: n1, pinsNet: true, preferredJunctionID: viaJunction, on: &board)
        let start = BoardTrackRouting.dropVia(via, at: point(0, 10), netID: n2, pinsNet: true, preferredJunctionID: nil, on: &board)
        board.junctions[trackJunction] = shared
        let trackID = UUID().uuidString.lowercased()
        board.tracks.append(HorizontalSegment(
            id: trackID, from: point(0, 10), to: shared, width: 200_000, layer: top, fromJunctionID: start, toJunctionID: trackJunction))
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(board.junctionNetIDs[viaJunction], n1)
        XCTAssertEqual(board.junctionNetIDs[trackJunction], n2)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let read = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).board)
        let viaRead = try XCTUnwrap(read.vias.first { $0.position == shared })
        XCTAssertEqual(viaRead.junctionID, viaJunction, "on its own junction, not the first at its point")
        XCTAssertEqual(viaRead.netID, n1)
        XCTAssertEqual(try track(trackID, in: read).toJunctionID, trackJunction)
        XCTAssertEqual(try track(trackID, in: read).netID, n2, "and the track on it is still on its own net")
        XCTAssertEqual(read.junctionNetIDs[viaJunction], n1)
        XCTAssertEqual(read.junctionNetIDs[trackJunction], n2)
    }

    /// A new track whose end names no junction, as the push and shove router
    /// lays one, is written onto the junction of its own net where two nets'
    /// junctions stand, not onto whichever comes first.
    func testANewTrackEndNamingNoJunctionIsWrittenOntoItsOwnNets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-junction-nets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Junctions.horizontal")
        try HorizontalProjectArchive.newProject(
            pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia), blankBoard: true
        ).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        // Each net a pinned via with a track to the shared point, the first
        // net's junction there first by id; and a third track of the second
        // net from the shared point to another of its vias, naming no
        // junction at either end.
        let n1 = "11111111-0000-4000-8000-000000000001", n2 = "22222222-0000-4000-8000-000000000002"
        let firstJunction = "aaaaaaaa-0000-4000-8000-000000000001", secondJunction = "bbbbbbbb-0000-4000-8000-000000000002"
        let shared = point(10, 0), far = point(20, 0)
        var board = try XCTUnwrap(project.board)
        for (netID, start, junction) in [(n1, point(0, 0), firstJunction), (n2, point(0, 10), secondJunction)] {
            let viaJunction = BoardTrackRouting.dropVia(via, at: start, netID: netID, pinsNet: true, preferredJunctionID: nil, on: &board)
            board.junctions[junction] = shared
            board.tracks.append(HorizontalSegment(
                id: UUID().uuidString.lowercased(), from: start, to: shared, width: 200_000, layer: top,
                fromJunctionID: viaJunction, toJunctionID: junction))
        }
        BoardTrackRouting.dropVia(via, at: far, netID: n2, pinsNet: true, preferredJunctionID: nil, on: &board)
        let unnamed = UUID().uuidString.lowercased()
        board.tracks.append(HorizontalSegment(id: unnamed, from: shared, to: far, width: 200_000, layer: top))
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(try track(unnamed, in: board).netID, n2)
        XCTAssertEqual(board.junctionNetIDs[firstJunction], n1)
        XCTAssertEqual(board.junctionNetIDs[secondJunction], n2)

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let read = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).board)
        let written = try track(unnamed, in: read)
        XCTAssertEqual(written.fromJunctionID, secondJunction, "on its own net's junction")
        XCTAssertEqual(written.netID, n2)
        XCTAssertEqual(read.junctionNetIDs[firstJunction], n1, "and the other net's copper is still its own")
    }
}
