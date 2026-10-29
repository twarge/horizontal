import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Loop removal: a route that leaves its net's copper and comes back to it
/// replaces the plain chain of copper that joined the two points, which the
/// click takes off and the canvas hides while the cursor rests there
/// (`BoardTrackLoops`, which both call). A route from or to the middle of a
/// track cuts it there first, so it joins it.
///
/// It went missing with the vendored router, which did this itself; the
/// Swift router only ever added copper, so rerouting a section left the old
/// one in place, and a route from the middle of a track never joined it.
final class BoardTrackLoopTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let net = "5a3e1c2b-7d4f-4e6a-9b8c-1d2e3f4a5b6c"

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func emptyBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/route-loops.hprj"), uuid: "b", name: "route-loops",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    /// Copper drawn as the tool draws it: a junction at every end that is
    /// not a pad, and tracks between, named by `ids` in order.
    private func chain(_ points: [HorizontalPoint], layer: Int, ids: [String], on board: inout HorizontalBoard) {
        for point in points where !board.packagePadPositions.values.contains(point) {
            BoardTrackRouting.mergeJunctions(at: point, preferredID: nil, netID: net, board: &board)
        }
        for (index, id) in ids.enumerated() {
            board.tracks.append(HorizontalSegment(
                id: id, from: points[index], to: points[index + 1], width: 200_000, layer: layer, netID: net))
        }
    }

    private func pad(_ path: String, at point: HorizontalPoint, on board: inout HorizontalBoard) {
        board.packagePadPositions[path] = point
    }

    private func via(_ id: String, at point: HorizontalPoint, on board: inout HorizontalBoard) {
        BoardTrackRouting.mergeJunctions(at: point, preferredID: nil, netID: net, board: &board)
        board.vias.append(HorizontalMarker(
            id: id, position: point, size: 500_000, holeSize: 200_000, layer: nil,
            connectedLayers: [top, bottom], netID: net, netSetID: net))
        board.viaHoles.append(HorizontalHole(
            id: "\(id)/hole", position: point, diameter: 200_000, length: 200_000,
            shape: .round, plated: true, netID: net))
    }

    /// A route in progress, as the canvas keeps one.
    private struct Route {
        var head: BoardTrackRouteHead
        var loopStart: BoardTrackLoopEnd?
        var trackIDs: Set<String> = []
        var removedTracks: [String] = []
        var removedVias: [String] = []
        var split: [String] = []
        /// Whether each click closed a loop, in order.
        var closed: [Bool] = []
    }

    private func route(from anchor: HorizontalPoint, onPad: Bool = false, layer: Int? = nil, in board: HorizontalBoard) -> Route {
        let layer = layer ?? top
        let junction = board.junctions.first { $0.value == anchor }?.key
        return Route(
            head: BoardTrackRouteHead(
                anchor: anchor, anchorJunctionID: junction, anchorOnPad: onPad, netID: net,
                width: 200_000, layer: layer, placesVia: false),
            loopStart: BoardTrackLoops.start(at: anchor, layer: layer, onPad: onPad, in: board)
        )
    }

    /// One click of the route tool: 90° legs from the head to `target`.
    @discardableResult
    private func click(
        _ target: HorizontalPoint,
        endsOnPad: Bool = false,
        removesLoops: Bool = true,
        via: HorizontalBoardViaTemplate? = nil,
        _ route: inout Route,
        on board: inout HorizontalBoard
    ) -> BoardTrackLoopStepResult {
        let legs = BoardTrackRouting.route(from: route.head.anchor, to: target, horizontalFirst: true, cornerStyle: .ninety)
        let step = BoardTrackLoops.lay(
            legs, to: target, endsOnPad: endsOnPad, via: via, from: route.head,
            loopStart: route.loopStart, routeTrackIDs: route.trackIDs, removesLoops: removesLoops, on: &board)
        route.head = step.laid.head
        route.loopStart = step.loopStart
        route.trackIDs = step.routeTrackIDs
        route.removedTracks += step.removedTrackIDs
        route.removedVias += step.removedViaIDs
        route.split += step.splitTrackIDs
        route.closed.append(step.closesLoop)
        return step
    }

    private func ids(_ board: HorizontalBoard) -> Set<String> {
        Set(board.tracks.map(\.id))
    }

    private func joins(_ tracks: [HorizontalSegment], _ a: HorizontalPoint, _ b: HorizontalPoint) -> Bool {
        tracks.contains { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
    }

    /// The everyday case: a detour from one bend of a track to the next
    /// replaces the stretch between them, over a click that reaches nothing.
    func testADetourBetweenTwoPointsOfATrackReplacesTheStretchBetween() {
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(10, 0), j2 = point(20, 0), b = point(30, 0)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        chain([a, j1, j2, b], layer: top, ids: ["a-j1", "j1-j2", "j2-b"], on: &board)

        var route = route(from: j1, in: board)
        XCTAssertEqual(route.loopStart, BoardTrackLoopEnd(point: j1, layer: top), "it starts on the track")
        click(point(10, 5), &route, on: &board)
        XCTAssertTrue(route.removedTracks.isEmpty, "a click in the open replaces nothing")
        XCTAssertTrue(board.tracks.contains { $0.id == "j1-j2" })
        XCTAssertEqual(route.loopStart?.point, j1, "and the stretch still began on the track")

        click(j2, &route, on: &board)
        XCTAssertEqual(route.removedTracks, ["j1-j2"])
        XCTAssertFalse(ids(board).contains("j1-j2"))
        XCTAssertTrue(ids(board).isSuperset(of: ["a-j1", "j2-b"]), "what the route does not bypass stays")
        XCTAssertTrue(joins(board.tracks, point(10, 5), point(20, 5)), "and the detour is there")
        XCTAssertEqual(route.loopStart?.point, j2, "the next stretch starts where this one rejoined")

        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertTrue(resolved.tracks.allSatisfy { $0.netID == nil || $0.netID == net })
        XCTAssertEqual(resolved.junctions.count, board.junctions.count, "every junction still joins copper")
    }

    /// The route only replaces what joins the two points it connects, from a
    /// pad too, and leaves the stretch beyond them.
    func testARouteFromAPadToAJunctionReplacesOnlyThatStretch() {
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(10, 0), b = point(20, 0)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        chain([a, j1, b], layer: top, ids: ["a-j1", "j1-b"], on: &board)

        var route = route(from: a, onPad: true, in: board)
        click(point(0, -5), &route, on: &board)
        click(j1, &route, on: &board)
        XCTAssertEqual(route.removedTracks, ["a-j1"])
        XCTAssertTrue(ids(board).contains("j1-b"))
    }

    /// The old route went down and back through two vias: the new one on top
    /// replaces it all, the vias with their holes, and flags them for the
    /// writer, which keeps a via the model lacks.
    func testARouteReplacesAChainThroughViasAndTheViasGo() {
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(5, 0), v1 = point(10, 0), j2 = point(15, 0), v2 = point(20, 0), b = point(25, 0)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        via("v1", at: v1, on: &board)
        via("v2", at: v2, on: &board)
        chain([a, j1, v1], layer: top, ids: ["t1", "t2"], on: &board)
        chain([v1, j2, v2], layer: bottom, ids: ["t3", "t4"], on: &board)
        chain([v2, b], layer: top, ids: ["t5"], on: &board)

        var route = route(from: a, onPad: true, in: board)
        click(point(0, 5), &route, on: &board)
        click(b, endsOnPad: true, &route, on: &board)
        XCTAssertEqual(Set(route.removedTracks), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(Set(route.removedVias), ["v1", "v2"])
        XCTAssertTrue(board.vias.isEmpty)
        XCTAssertTrue(board.viaHoles.isEmpty, "each via goes with its hole")
        XCTAssertEqual(board.removedViaIDs, ["v1", "v2"])
        XCTAssertEqual(ids(board), route.trackIDs, "only the route is left")
    }

    /// A chain with a branch off it still connects the branch, so it stays;
    /// so does a via that joins a plane, and anything when loops aren't removed.
    func testWhatStillConnectsSomethingStays() {
        var board = emptyBoard()
        let a = point(0, 0), j = point(10, 0), b = point(20, 0), c = point(10, 10)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        pad("pkg/c", at: c, on: &board)
        chain([a, j, b], layer: top, ids: ["a-j", "j-b"], on: &board)
        chain([j, c], layer: top, ids: ["j-c"], on: &board)
        var branched = route(from: a, onPad: true, in: board)
        click(point(0, -5), &branched, on: &board)
        click(b, endsOnPad: true, &branched, on: &board)
        XCTAssertTrue(branched.removedTracks.isEmpty, "the junction has a third track")
        XCTAssertTrue(ids(board).isSuperset(of: ["a-j", "j-b", "j-c"]))

        var planed = emptyBoard()
        let v = point(10, 0)
        pad("pkg/a", at: a, on: &planed)
        pad("pkg/b", at: b, on: &planed)
        via("v", at: v, on: &planed)
        chain([a, v], layer: top, ids: ["a-v"], on: &planed)
        chain([v, b], layer: top, ids: ["v-b"], on: &planed)
        planed.planes.append(HorizontalPlane(
            id: "plane", netID: net, polygonID: "poly", layer: bottom, priority: 0, fillStyle: "solid",
            minWidth: 0, keepOrphans: false,
            fragments: [HorizontalPlaneFragment(paths: [[point(5, -5), point(15, -5), point(15, 5), point(5, 5)]], orphan: false)],
            fallbackPolygon: nil))
        var throughPlane = route(from: a, onPad: true, in: planed)
        click(point(0, -5), &throughPlane, on: &planed)
        click(b, endsOnPad: true, &throughPlane, on: &planed)
        XCTAssertTrue(throughPlane.removedTracks.isEmpty, "the via joins the plane too")
        XCTAssertEqual(planed.vias.map(\.id), ["v"])

        var kept = emptyBoard()
        pad("pkg/a", at: a, on: &kept)
        pad("pkg/b", at: b, on: &kept)
        chain([a, j, b], layer: top, ids: ["a-j", "j-b"], on: &kept)
        var off = route(from: a, onPad: true, in: kept)
        click(point(0, -5), removesLoops: false, &off, on: &kept)
        click(b, endsOnPad: true, removesLoops: false, &off, on: &kept)
        XCTAssertTrue(off.removedTracks.isEmpty)
        XCTAssertTrue(ids(kept).isSuperset(of: ["a-j", "j-b"]), "with loop removal off")
    }

    /// Copper on another layer, which the route does not reach, is not
    /// replaced: a junction carries no layer, and nothing joins the layers there.
    func testCopperOnALayerTheRouteDoesNotReachStays() {
        var board = emptyBoard()
        let j1 = point(0, 0), j2 = point(10, 0)
        chain([j1, j2], layer: bottom, ids: ["bottom"], on: &board)
        var route = route(from: j1, layer: top, in: board)
        XCTAssertNil(route.loopStart, "the top starts on no copper")
        click(point(0, 5), &route, on: &board)
        click(j2, &route, on: &board)
        XCTAssertTrue(route.removedTracks.isEmpty)
        XCTAssertTrue(ids(board).contains("bottom"))
    }

    /// A route from the middle of a track to the middle of the same track
    /// cuts it at both, joins it there, and replaces the part between; the
    /// halves are new tracks, as the writer can only write those whole.
    func testARouteBetweenTwoPointsInTheMiddleOfATrackCutsItAndReplacesThePartBetween() throws {
        var board = emptyBoard()
        let a = point(0, 0), b = point(30, 0)
        chain([a, b], layer: top, ids: ["long"], on: &board)
        let from = point(10, 0), to = point(20, 0)

        var route = route(from: from, in: board)
        XCTAssertEqual(route.loopStart, BoardTrackLoopEnd(point: from, layer: top), "the middle of a track is on copper")
        XCTAssertNil(BoardTrackLoops.start(at: point(10, 1), layer: top, onPad: false, in: board), "beside it is not")
        click(point(10, 5), &route, on: &board)
        XCTAssertEqual(route.split, ["long"], "the first click cuts the track it leaves from")
        XCTAssertTrue(joins(board.tracks, a, from))
        XCTAssertTrue(joins(board.tracks, from, b))
        XCTAssertTrue(board.junctions.values.contains(from), "at a junction the route ends on")

        click(to, &route, on: &board)
        XCTAssertEqual(route.split.count, 2, "and the last, the one it reaches")
        XCTAssertEqual(route.removedTracks.count, 1)
        XCTAssertFalse(joins(board.tracks, from, to), "the part between goes")
        XCTAssertTrue(joins(board.tracks, a, from))
        XCTAssertTrue(joins(board.tracks, to, b))
        XCTAssertFalse(ids(board).contains("long"))
        XCTAssertEqual(board.tracks.count, 5, "two pieces of the old track and the route's three legs")
        XCTAssertTrue(board.junctions.values.contains(to))
        XCTAssertTrue(joins(board.tracks, point(20, 5), to), "the route ends where the piece beyond begins")

        // No junction is left joining nothing: the route meets the old copper at both.
        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(resolved.junctions.count, board.junctions.count)
    }

    /// A click that comes back to copper already joined to where the stretch
    /// began closes a loop, which ends the route as a click on a pad does,
    /// whether or not anything is replaced: with a branch in the way, and with
    /// loop removal off.
    func testAClickBackOnCopperJoinedToTheStretchsStartClosesALoop() {
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(10, 0), j2 = point(20, 0), b = point(30, 0)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        chain([a, j1, j2, b], layer: top, ids: ["a-j1", "j1-j2", "j2-b"], on: &board)
        var replacing = route(from: j1, in: board)
        click(point(10, 5), &replacing, on: &board)
        click(j2, &replacing, on: &board)
        XCTAssertEqual(replacing.closed, [false, true], "a click in the open closes nothing; the click back does")
        XCTAssertEqual(replacing.removedTracks, ["j1-j2"])

        var branched = emptyBoard()
        let j = point(10, 0), c = point(10, 10)
        pad("pkg/a", at: a, on: &branched)
        pad("pkg/b", at: point(20, 0), on: &branched)
        pad("pkg/c", at: c, on: &branched)
        chain([a, j, point(20, 0)], layer: top, ids: ["a-j", "j-b"], on: &branched)
        chain([j, c], layer: top, ids: ["j-c"], on: &branched)
        var around = route(from: a, onPad: true, in: branched)
        click(point(0, -5), &around, on: &branched)
        click(j, &around, on: &branched)
        XCTAssertEqual(around.closed, [false, true], "joined through the branch's junction")
        XCTAssertEqual(around.removedTracks, ["a-j"])

        var kept = emptyBoard()
        pad("pkg/a", at: a, on: &kept)
        pad("pkg/b", at: b, on: &kept)
        chain([a, j1, j2, b], layer: top, ids: ["a-j1", "j1-j2", "j2-b"], on: &kept)
        chain([j1, point(10, 10)], layer: top, ids: ["spur"], on: &kept)
        var plain = route(from: a, onPad: true, in: kept)
        click(point(0, -5), &plain, on: &kept)
        click(j2, &plain, on: &kept)
        XCTAssertEqual(plain.closed, [false, true], "the spur keeps the chain, but the loop is closed")
        XCTAssertTrue(plain.removedTracks.isEmpty)

        var off = emptyBoard()
        pad("pkg/a", at: a, on: &off)
        pad("pkg/b", at: b, on: &off)
        chain([a, j1, j2, b], layer: top, ids: ["a-j1", "j1-j2", "j2-b"], on: &off)
        var unremoved = route(from: j1, in: off)
        click(point(10, 5), removesLoops: false, &unremoved, on: &off)
        click(j2, removesLoops: false, &unremoved, on: &off)
        XCTAssertEqual(unremoved.closed, [false, true], "with loop removal off as well")
        XCTAssertTrue(unremoved.removedTracks.isEmpty)
    }

    /// Copper of the route's net that nothing joins to where the stretch began
    /// closes no loop: the route joins it, and goes on.
    func testCopperNotJoinedToTheStretchsStartClosesNoLoop() {
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(10, 0), k1 = point(20, 0), k2 = point(30, 0)
        pad("pkg/a", at: a, on: &board)
        chain([a, j1], layer: top, ids: ["a-j1"], on: &board)
        chain([k1, k2], layer: top, ids: ["island"], on: &board)
        var route = route(from: j1, in: board)
        click(point(10, 5), &route, on: &board)
        let step = click(k1, &route, on: &board)
        XCTAssertEqual(route.closed, [false, false])
        XCTAssertTrue(route.removedTracks.isEmpty)
        XCTAssertEqual(step.loopStart?.point, k1, "the route reached copper, and the next stretch starts there")
        XCTAssertTrue(ids(board).isSuperset(of: ["a-j1", "island"]))
    }

    /// The click that closes a loop ends the route there, so it drops no via
    /// armed for it, as a click on a pad drops none; a click in the open does.
    func testAClickThatClosesALoopDropsNoArmedVia() {
        let armed = HorizontalBoardViaTemplate(padstackID: "route-via", diameter: 500_000, holeDiameter: 200_000)
        var board = emptyBoard()
        let a = point(0, 0), j1 = point(10, 0), j2 = point(20, 0), b = point(30, 0)
        pad("pkg/a", at: a, on: &board)
        pad("pkg/b", at: b, on: &board)
        chain([a, j1, j2, b], layer: top, ids: ["a-j1", "j1-j2", "j2-b"], on: &board)
        var route = route(from: j1, in: board)
        click(point(10, 5), &route, on: &board)
        route.head.placesVia = true
        let closing = click(j2, via: armed, &route, on: &board)
        XCTAssertTrue(closing.closesLoop)
        XCTAssertEqual(closing.laid.vias, 0)
        XCTAssertTrue(board.vias.isEmpty)
        XCTAssertEqual(closing.laid.head.layer, top, "and the route stays where it is")

        var open = emptyBoard()
        pad("pkg/a", at: a, on: &open)
        chain([a, j1], layer: top, ids: ["a-j1"], on: &open)
        var onward = self.route(from: j1, in: open)
        onward.head.placesVia = true
        let dropped = click(point(10, 5), via: armed, &onward, on: &open)
        XCTAssertFalse(dropped.closesLoop)
        XCTAssertEqual(dropped.laid.vias, 1, "where the route goes on, the via drops")
        XCTAssertEqual(open.vias.map(\.position), [point(10, 5)])
    }

    /// The same route, written and read back: the old track's entry goes, the
    /// halves are written on junctions, and what was replaced stays gone.
    func testACutAndReplacedTrackIsWrittenSo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-route-loops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Loops.horizontal")
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia)).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        var board = try XCTUnwrap(project.board)
        let a = point(0, 0), b = point(30, 0)
        board.junctions["ja"] = a
        board.junctions["jb"] = b
        board.tracks.append(HorizontalSegment(id: "long", from: a, to: b, width: 200_000, layer: top))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        board = try XCTUnwrap(reloaded.board)
        XCTAssertEqual(board.tracks.map(\.id), ["long"])

        let from = point(10, 0), to = point(20, 0)
        var route = route(from: from, in: board)
        click(point(10, 5), &route, on: &board)
        click(to, &route, on: &board)
        board = HorizontalBoardConnectivity.recompute(board)
        try HorizontalProjectJSONApplicator.apply(board: board, in: reloaded, to: &archive)

        let read = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).board)
        XCTAssertFalse(read.tracks.contains { $0.id == "long" })
        XCTAssertEqual(read.tracks.count, 5)
        XCTAssertTrue(joins(read.tracks, a, from))
        XCTAssertTrue(joins(read.tracks, to, b))
        XCTAssertFalse(joins(read.tracks, from, to))
        XCTAssertTrue(joins(read.tracks, point(10, 5), point(20, 5)))
        XCTAssertEqual(Set(read.junctions.values.map { [$0.x, $0.y] }).count, read.junctions.count)
        XCTAssertEqual(read.junctions.count, 6, "both ends, both cuts and the route's two corners")
    }

    /// A via taken off, by a route or by Delete, stays off once written:
    /// the writer keeps a via entry the model merely lacks, so it is flagged.
    func testARemovedViaIsWrittenAsRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-route-loops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Vias.horizontal")
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia)).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        var board = try XCTUnwrap(project.board)
        let a = point(0, 0), v = point(10, 0)
        board.junctions["ja"] = a
        board.junctions["jv"] = v
        board.tracks.append(HorizontalSegment(id: "t", from: a, to: v, width: 200_000, layer: top))
        board.vias.append(HorizontalMarker(
            id: "v", position: v, size: 500_000, holeSize: 200_000, layer: nil, connectedLayers: [top, bottom],
            padstackID: HorizontalProjectArchive.horizonPoolCircularVia))
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try HorizontalProject.loadSnapshot(of: archive).board?.vias.map(\.id), ["v"])

        board.vias.removeAll()
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try HorizontalProject.loadSnapshot(of: archive).board?.vias.map(\.id), ["v"],
                       "absence alone is not a deletion")

        BoardTrackLoops.remove(tracks: [], vias: ["v"], from: &board)
        XCTAssertEqual(board.removedViaIDs, ["v"])
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        XCTAssertEqual(try HorizontalProject.loadSnapshot(of: archive).board?.vias.count, 0)
    }
}
