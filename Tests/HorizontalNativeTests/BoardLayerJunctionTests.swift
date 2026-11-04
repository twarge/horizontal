import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A track ending on the top and one ending on the bottom at the same point,
/// with no via there, are on junctions of their own: Horizon joins a track's
/// ends by junction, so one junction would join them where the copper
/// doesn't. Track and net tie ends keep the junction the file names
/// (`HorizontalSegment.fromJunctionID`), the route tool joins only a junction
/// of its own layer (`HorizontalBoard.junctionIDs(at:joining:)`), a via folds
/// the junctions at its point into one, and the writer keeps each end on its
/// junction.
///
/// Before, the model knew a junction only by its position: a route on the
/// bottom that started or ended where a top track ended took the top track's
/// junction, and the writer wrote both ends onto it.
final class BoardLayerJunctionTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let via = HorizontalBoardViaTemplate(
        padstackID: HorizontalProjectArchive.horizonPoolCircularVia, diameter: 600_000, holeDiameter: 300_000, fromRules: false,
        parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000])

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func emptyBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/layer-junctions.hprj"), uuid: "b", name: "layer-junctions",
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

    /// One click of the route tool from `from` to `to` on `layer`, starting
    /// on the junction there it can join, as the tool starts.
    @discardableResult
    private func route(
        from: HorizontalPoint,
        to: HorizontalPoint,
        layer: Int,
        via: HorizontalBoardViaTemplate? = nil,
        on board: inout HorizontalBoard
    ) -> BoardTrackRouteStepResult {
        let head = BoardTrackRouteHead(
            anchor: from, anchorJunctionID: BoardTrackRouting.junctionID(at: from, layer: layer, in: board),
            anchorOnPad: false, netID: nil, width: 200_000, layer: layer, placesVia: via != nil)
        let legs = BoardTrackRouting.route(from: from, to: to, horizontalFirst: true, cornerStyle: .ninety)
        return BoardTrackRouting.lay(legs, to: to, endsOnPad: false, via: via, from: head, on: &board)
    }

    private func junctions(at point: HorizontalPoint, in board: HorizontalBoard) -> [String] {
        board.junctions.filter { $0.value == point }.map(\.key).sorted()
    }

    /// The junction `track` ends on at `point`.
    private func junction(of track: HorizontalSegment, at point: HorizontalPoint) -> String? {
        track.from == point ? track.fromJunctionID : track.to == point ? track.toJunctionID : nil
    }

    func testARouteOnTheBottomEndingWhereATopTrackEndsGetsAJunctionOfItsOwn() throws {
        var board = emptyBoard()
        let shared = point(10, 0)
        let topStep = route(from: point(0, 0), to: shared, layer: top, on: &board)
        let topTrack = try XCTUnwrap(board.tracks.first { $0.id == topStep.trackIDs.first })
        let topJunction = try XCTUnwrap(junction(of: topTrack, at: shared))
        XCTAssertEqual(junctions(at: shared, in: board), [topJunction])

        let bottomStep = route(from: point(10, 10), to: shared, layer: bottom, on: &board)
        let bottomTrack = try XCTUnwrap(board.tracks.first { $0.id == bottomStep.trackIDs.last })
        let bottomJunction = try XCTUnwrap(junction(of: bottomTrack, at: shared))
        XCTAssertNotEqual(bottomJunction, topJunction, "no via joins them")
        XCTAssertEqual(Set(junctions(at: shared, in: board)), [topJunction, bottomJunction])
        XCTAssertEqual(junction(of: board.tracks.first { $0.id == topTrack.id }!, at: shared), topJunction)

        // A second route on the top joins the top's junction, not the bottom's.
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: top, in: board), topJunction)
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: bottom, in: board), bottomJunction)
    }

    func testARouteStartingFromTheBottomWhereATopTrackEndsDoesNotTakeItsJunction() throws {
        var board = emptyBoard()
        let start = point(10, 0)
        route(from: point(0, 0), to: start, layer: top, on: &board)
        let topJunction = try XCTUnwrap(junctions(at: start, in: board).first)
        XCTAssertNil(BoardTrackRouting.junctionID(at: start, layer: bottom, in: board))

        let step = route(from: start, to: point(20, 0), layer: bottom, on: &board)
        let bottomTrack = try XCTUnwrap(board.tracks.first { $0.id == step.trackIDs.first })
        let bottomJunction = try XCTUnwrap(junction(of: bottomTrack, at: start))
        XCTAssertNotEqual(bottomJunction, topJunction)
        XCTAssertEqual(junctions(at: start, in: board).count, 2)
    }

    /// A via dropped where a top and a bottom track end joins them: the
    /// junctions there fold into one, and both tracks end on it.
    func testAViaJoinsTheJunctionsAtItsPoint() throws {
        var board = emptyBoard()
        let shared = point(10, 0)
        route(from: point(0, 0), to: shared, layer: top, on: &board)
        route(from: point(10, 10), to: shared, layer: bottom, on: &board)
        XCTAssertEqual(junctions(at: shared, in: board).count, 2)

        let dropped = BoardTrackRouting.dropVia(via, at: shared, netID: nil, preferredJunctionID: nil, on: &board)
        XCTAssertEqual(junctions(at: shared, in: board), [dropped])
        let ends = board.tracks.compactMap { junction(of: $0, at: shared) }
        XCTAssertEqual(ends, [dropped, dropped], "both tracks end on the via's junction")

        // With the via there, a route on either layer joins its junction.
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: top, in: board), dropped)
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: bottom, in: board), dropped)
    }

    /// A junction spans the layers of its copper as Horizon's layer range
    /// does: lowest to highest layer of the tracks on it, a track end at its
    /// point that names no junction when nothing names it, and a via's span
    /// in place of either. One on no copper spans nothing.
    func testAJunctionSpansTheLayersOfItsCopper() {
        var board = emptyBoard()
        board.junctions = [
            "a": point(0, 0), "b": point(10, 0), "c": point(20, 0),
            "d": point(30, 0), "e": point(40, 0), "f": point(50, 0),
        ]
        func track(_ id: String, _ from: Double, _ to: Double, layer: Int,
                   _ fromJunction: String?, _ toJunction: String?) -> HorizontalSegment {
            HorizontalSegment(id: id, from: point(from, 0), to: point(to, 0), width: 200_000, layer: layer,
                              fromJunctionID: fromJunction, toJunctionID: toJunction)
        }
        board.tracks = [
            track("t1", 0, 10, layer: top, "a", "b"),
            track("t2", 10, 20, layer: bottom, "b", "c"),
            track("t3", 20, 30, layer: bottom, "c", nil),
        ]
        board.vias = [
            HorizontalMarker(id: "blind", position: point(20, 0), size: 600_000, layer: nil,
                             connectedLayers: [HorizontalBoardLayers.in1Copper, bottom]),
            HorizontalMarker(id: "through", position: point(40, 0), size: 600_000, layer: nil),
        ]

        let ranges = board.junctionLayerRanges()
        XCTAssertEqual(ranges["a"], top...top)
        XCTAssertEqual(ranges["b"], bottom...top, "a top and a bottom track with no via span the layers between")
        XCTAssertEqual(ranges["c"], bottom...HorizontalBoardLayers.in1Copper, "the via's span, not its tracks'")
        XCTAssertEqual(ranges["d"], bottom...bottom, "the end naming no junction is on the one nothing names")
        XCTAssertEqual(ranges["e"], bottom...top, "a via with no span listed goes through the board")
        XCTAssertNil(ranges["f"])
    }

    /// A junction nothing names (an end drawn before ends kept their
    /// junction, a pasted track's) still joins copper on any layer, as before.
    func testAJunctionNothingNamesJoinsAnyLayer() {
        var board = emptyBoard()
        let shared = point(10, 0)
        board.junctions["bare"] = shared
        board.tracks.append(HorizontalSegment(id: "t", from: point(0, 0), to: shared, width: 200_000, layer: top))
        XCTAssertEqual(BoardTrackRouting.junctionID(at: shared, layer: bottom, in: board), "bare")
        XCTAssertEqual(board.junctionIDs(at: shared, joining: nil), ["bare"])
    }

    /// Taking the top track off takes its junction with it; the bottom
    /// track's stays. Before, a junction stayed while anything touched its
    /// point.
    func testAJunctionGoesWithTheOnlyTrackOnIt() throws {
        var board = emptyBoard()
        let shared = point(10, 0)
        let topStep = route(from: point(0, 0), to: shared, layer: top, on: &board)
        let bottomStep = route(from: point(10, 10), to: shared, layer: bottom, on: &board)
        let bottomTrack = try XCTUnwrap(board.tracks.first { $0.id == bottomStep.trackIDs.last })
        let bottomJunction = try XCTUnwrap(junction(of: bottomTrack, at: shared))

        board.tracks.removeAll { topStep.trackIDs.contains($0.id) }
        board = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(junctions(at: shared, in: board), [bottomJunction])
    }

    /// Cutting a track to start a route from its middle puts both halves'
    /// ends on the cut's junction.
    func testTheHalvesOfACutTrackEndOnTheCut() throws {
        var board = emptyBoard()
        route(from: point(0, 0), to: point(20, 0), layer: top, on: &board)
        let cut = point(10, 0)
        let split = try XCTUnwrap(BoardTrackLoops.split(at: cut, layer: top, sparing: [], on: &board))
        let halves = board.tracks.filter { $0.from == cut || $0.to == cut }
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves.compactMap { junction(of: $0, at: cut) }, [split.junctionID, split.junctionID])
    }

    /// Written and read back: the two ends stay on junctions of their own,
    /// and a via dropped there afterwards puts them on one, rewriting the end
    /// of the track that was already in the file.
    func testTheWriterKeepsTheJunctionsApartUntilAViaJoinsThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-layer-junctions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Junctions.horizontal")
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia)).write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        let project = try HorizontalProject.load(from: url)

        func save(_ board: HorizontalBoard, in project: HorizontalProject) throws -> (HorizontalProject, HorizontalBoard) {
            try HorizontalProjectJSONApplicator.apply(
                board: HorizontalBoardConnectivity.recompute(board), in: project, to: &archive)
            var reloaded = try HorizontalProject.loadSnapshot(of: archive)
            reloaded.rebaseURLs(onto: project)
            return (reloaded, try XCTUnwrap(reloaded.board))
        }
        func fileEnds(at point: HorizontalPoint, in board: HorizontalBoard) -> [String: String] {
            // The junction each track's end at `point` names in the file, by track.
            var ends = [String: String]()
            for track in board.tracks {
                if let id = junction(of: track, at: point) { ends[track.id] = id }
            }
            return ends
        }

        let shared = point(10, 0)
        var board = try XCTUnwrap(project.board)
        let topStep = route(from: point(0, 0), to: shared, layer: top, on: &board)
        var (saved, read) = try save(board, in: project)
        board = read

        let bottomStep = route(from: point(10, 10), to: shared, layer: bottom, on: &board)
        (saved, read) = try save(board, in: saved)
        let topID = try XCTUnwrap(topStep.trackIDs.first), bottomID = try XCTUnwrap(bottomStep.trackIDs.last)
        var ends = fileEnds(at: shared, in: read)
        XCTAssertEqual(Set(ends.keys), [topID, bottomID])
        XCTAssertNotEqual(ends[topID], ends[bottomID], "the file keeps the two ends on junctions of their own")
        XCTAssertEqual(junctions(at: shared, in: read).count, 2)
        XCTAssertTrue(read.vias.isEmpty)

        board = read
        BoardTrackRouting.dropVia(via, at: shared, netID: nil, preferredJunctionID: nil, on: &board)
        (_, read) = try save(board, in: saved)
        ends = fileEnds(at: shared, in: read)
        XCTAssertEqual(Set(ends.keys), [topID, bottomID])
        XCTAssertEqual(ends[topID], ends[bottomID], "the via's junction holds both")
        XCTAssertEqual(junctions(at: shared, in: read), [try XCTUnwrap(ends[topID])])
        XCTAssertEqual(read.vias.count, 1)
    }
}
