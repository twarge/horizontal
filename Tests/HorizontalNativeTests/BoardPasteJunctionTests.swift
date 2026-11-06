import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Pasted or duplicated copper and drawing go on junctions, which the writer
/// names their ends by (`BoardTrackRouting.attachJunctions`). A copy lands
/// where its original's junctions aren't, and the writer skips a new track,
/// via, line or arc with an end on no junction or pad, so a paste that landed
/// in the open was lost on save.
final class BoardPasteJunctionTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private var archive: HorizontalProjectArchive!
    private var project: HorizontalProject!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-paste-junctions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Paste.horizontal")
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia), blankBoard: true).write(to: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        project = try HorizontalProject.load(from: url)
    }

    /// Writes the board as a commit does and reads it back.
    private func saved(_ board: HorizontalBoard) throws -> HorizontalBoard {
        try HorizontalProjectJSONApplicator.apply(
            board: HorizontalBoardConnectivity.recompute(board), in: project, to: &archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        reloaded.rebaseURLs(onto: project)
        project = reloaded
        return try XCTUnwrap(reloaded.board)
    }

    private func track(_ id: String, _ from: HorizontalPoint, _ to: HorizontalPoint, layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 200_000, layer: layer)
    }

    private let via = HorizontalBoardViaTemplate(
        padstackID: HorizontalProjectArchive.horizonPoolCircularVia, diameter: 600_000, holeDiameter: 300_000,
        fromRules: false, parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000])

    /// Copper laid as the route tool lays it, its ends on junctions.
    @discardableResult
    private func route(_ from: HorizontalPoint, _ to: HorizontalPoint, layer: Int, on board: inout HorizontalBoard) -> [String] {
        let head = BoardTrackRouteHead(
            anchor: from, anchorJunctionID: BoardTrackRouting.junctionID(at: from, layer: layer, in: board),
            anchorOnPad: false, netID: nil, width: 200_000, layer: layer, placesVia: false)
        let legs = BoardTrackRouting.route(from: from, to: to, horizontalFirst: true, cornerStyle: .ninety)
        return BoardTrackRouting.lay(legs, to: to, endsOnPad: false, via: nil, from: head, on: &board).trackIDs
    }

    /// What a paste does to `board`: copies of the tracks, vias and lines
    /// named, moved by `offset`, with new ids, as `appendClipboardClones`
    /// makes them, and then their junctions. Returns the copies' ids.
    @discardableResult
    private func paste(
        tracks: [String] = [], vias: [String] = [], lines: [String] = [],
        by offset: HorizontalPoint, on board: inout HorizontalBoard
    ) -> (tracks: Set<String>, vias: Set<String>, lines: Set<String>) {
        var copies = (tracks: Set<String>(), vias: Set<String>(), lines: Set<String>())
        for var copy in board.tracks.filter({ tracks.contains($0.id) }) {
            copy.id = UUID().uuidString.lowercased()
            copy.from = copy.from + offset
            copy.to = copy.to + offset
            copy.fromJunctionID = nil
            copy.toJunctionID = nil
            board.tracks.append(copy)
            copies.tracks.insert(copy.id)
        }
        for var copy in board.vias.filter({ vias.contains($0.id) }) {
            let original = copy.id
            copy.id = UUID().uuidString.lowercased()
            copy.position = copy.position + offset
            board.vias.append(copy)
            for var hole in board.viaHoles where hole.id.hasPrefix(original) {
                hole.id = copy.id + "/hole"
                hole.position = hole.position + offset
                board.viaHoles.append(hole)
            }
            copies.vias.insert(copy.id)
        }
        for var copy in board.lines.filter({ lines.contains($0.id) }) {
            copy.id = UUID().uuidString.lowercased()
            copy.from = copy.from + offset
            copy.to = copy.to + offset
            board.lines.append(copy)
            copies.lines.insert(copy.id)
        }
        BoardTrackRouting.attachJunctions(tracks: copies.tracks, lines: copies.lines, vias: copies.vias, on: &board)
        return copies
    }

    private func junctions(at point: HorizontalPoint, in board: HorizontalBoard) -> [String] {
        board.junctions.filter { $0.value == point }.map(\.key).sorted()
    }

    func testATrackWithEndsOnNoJunctionIsNotWritten() throws {
        var board = try XCTUnwrap(project.board)
        board.tracks.append(track("loose", point(0, 0), point(10, 0), layer: top))
        let read = try saved(board)
        XCTAssertFalse(read.tracks.contains { $0.id == "loose" }, "what a paste without junctions left")
    }

    func testPastedTracksViasAndLinesAreWrittenAndReadBack() throws {
        var board = try XCTUnwrap(project.board)
        let a = point(0, 0), b = point(10, 0), c = point(10, 10)
        route(a, b, layer: top, on: &board)
        route(b, c, layer: top, on: &board)
        let original = BoardTrackRouting.dropVia(via, at: point(20, 0), netID: nil, preferredJunctionID: nil, on: &board)
        XCTAssertFalse(original.isEmpty)
        let lineEnds = (point(0, 20), point(10, 20))
        BoardTrackRouting.mergeJunctions(at: lineEnds.0, preferredID: nil, netID: nil, board: &board)
        BoardTrackRouting.mergeJunctions(at: lineEnds.1, preferredID: nil, netID: nil, board: &board)
        board.lines.append(HorizontalSegment(
            id: "silk", from: lineEnds.0, to: lineEnds.1, width: 150_000, layer: HorizontalBoardLayers.topSilkscreen))
        board = try saved(board)

        let offset = point(50, 50)
        let copies = paste(
            tracks: board.tracks.map(\.id), vias: board.vias.map(\.id), lines: ["silk"], by: offset, on: &board)
        let read = try saved(board)

        XCTAssertEqual(Set(read.tracks.map(\.id)).intersection(copies.tracks), copies.tracks, "every pasted track is in the file")
        XCTAssertEqual(read.vias.count, 2)
        XCTAssertEqual(Set(read.lines.map(\.id)).intersection(copies.lines), copies.lines)
        // The copies' shared corner is one junction, both copies on it.
        let corner = b + offset
        XCTAssertEqual(junctions(at: corner, in: read).count, 1)
        let onCorner = read.tracks.filter { copies.tracks.contains($0.id) && ($0.from == corner || $0.to == corner) }
        XCTAssertEqual(onCorner.count, 2)
        XCTAssertEqual(
            Set(onCorner.compactMap { $0.from == corner ? $0.fromJunctionID : $0.toJunctionID }).count, 1,
            "the two copies stay joined")
    }

    /// A copy on the bottom whose end lands where only a top track ends gets
    /// a junction of its own there.
    func testAPastedTrackDoesNotTakeAnotherLayersJunction() throws {
        var board = try XCTUnwrap(project.board)
        let landing = point(10, 0)
        route(point(0, 0), landing, layer: top, on: &board)
        let topJunction = try XCTUnwrap(junctions(at: landing, in: board).first)
        board.tracks.append(HorizontalSegment(
            id: "bottom", from: point(10, 10), to: point(20, 10), width: 200_000, layer: bottom))
        let copies = paste(tracks: ["bottom"], by: point(-10, -10), on: &board)

        let copy = try XCTUnwrap(board.tracks.first { copies.tracks.contains($0.id) })
        XCTAssertEqual(copy.to, landing)
        XCTAssertNotNil(copy.toJunctionID)
        XCTAssertNotEqual(copy.toJunctionID, topJunction)
        XCTAssertEqual(junctions(at: landing, in: board).count, 2)
    }

    /// A copy ending on a pad's centre stays on the pad, with no junction
    /// there.
    func testAPastedTrackEndingOnAPadCentreStaysOnThePad() throws {
        var board = try XCTUnwrap(project.board)
        let pad = point(30, 0)
        board.packagePadPositions["pkg/pad"] = pad
        board.tracks.append(HorizontalSegment(id: "t", from: point(0, 0), to: point(10, 0), width: 200_000, layer: top))
        let copies = paste(tracks: ["t"], by: point(20, 0), on: &board)

        let copy = try XCTUnwrap(board.tracks.first { copies.tracks.contains($0.id) })
        XCTAssertNil(copy.toJunctionID)
        XCTAssertNotNil(copy.fromJunctionID)
        XCTAssertTrue(junctions(at: pad, in: board).isEmpty)
    }

    /// A via pasted where a top and a bottom track end joins them, as one
    /// dropped there does.
    func testAPastedViaJoinsTheJunctionsAtItsPoint() throws {
        var board = try XCTUnwrap(project.board)
        let shared = point(10, 0)
        route(point(0, 0), shared, layer: top, on: &board)
        route(point(10, 10), shared, layer: bottom, on: &board)
        XCTAssertEqual(junctions(at: shared, in: board).count, 2)
        BoardTrackRouting.dropVia(via, at: point(30, 0), netID: nil, preferredJunctionID: nil, on: &board)
        let viaID = try XCTUnwrap(board.vias.first?.id)

        paste(vias: [viaID], by: point(-20, 0), on: &board)
        let kept = try XCTUnwrap(junctions(at: shared, in: board).first)
        XCTAssertEqual(junctions(at: shared, in: board), [kept])
        XCTAssertEqual(
            board.tracks.compactMap { $0.from == shared ? $0.fromJunctionID : $0.to == shared ? $0.toJunctionID : nil },
            [kept, kept])
    }
}
