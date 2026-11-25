import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A route begun on a pad is written as on the pad, whatever stands under
/// the pad's centre. On a flex with a net on each side, a bottom track bends
/// on a junction under a top pad; the writer named a track's end by any
/// junction at its point before it looked for a pad, so a top route from that
/// pad was saved onto the bottom track's junction, and read back as taken
/// off the pad.
final class BoardRouteFromPadOverJunctionTests: XCTestCase {
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
            .appendingPathComponent("horizontal-route-from-pad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Route.horizontal")
        try HorizontalProjectArchive.newProject(pool: HorizontalProjectPoolTemplate(defaultViaUUID: HorizontalProjectArchive.horizonPoolCircularVia), blankBoard: true).write(to: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)
        project = try HorizontalProject.load(from: url)
    }

    /// The ends the board file gives the track from `from` to `to`, written
    /// as a commit writes it.
    private func writtenEnds(
        of board: HorizontalBoard, from: HorizontalPoint, to: HorizontalPoint
    ) throws -> (from: JSONDictionary, to: JSONDictionary) {
        try HorizontalProjectJSONApplicator.apply(
            board: HorizontalBoardConnectivity.recompute(board), in: project, to: &archive)
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        let id = try XCTUnwrap(board.tracks.first { $0.from == from && $0.to == to }?.id)
        let track = try XCTUnwrap((json["tracks"] as? JSONDictionary)?[id] as? JSONDictionary)
        return (try XCTUnwrap(track["from"] as? JSONDictionary), try XCTUnwrap(track["to"] as? JSONDictionary))
    }

    /// One straight leg, as the route tool lays it.
    private func route(
        _ from: HorizontalPoint, _ to: HorizontalPoint, layer: Int, fromPad: Bool = false, on board: inout HorizontalBoard
    ) {
        let head = BoardTrackRouteHead(
            anchor: from,
            anchorJunctionID: fromPad ? nil : BoardTrackRouting.junctionID(at: from, layer: layer, in: board),
            anchorOnPad: fromPad, netID: nil, width: 200_000, layer: layer, placesVia: false)
        let legs = BoardTrackRouting.route(from: from, to: to, horizontalFirst: true, cornerStyle: .ninety)
        _ = BoardTrackRouting.lay(legs, to: to, endsOnPad: false, via: nil, from: head, on: &board)
    }

    func testARouteFromAPadOverAnotherLayersJunctionIsWrittenOnThePad() throws {
        var board = try XCTUnwrap(project.board)
        let pad = point(10, 0)
        board.packagePadPositions["pkg/pad"] = pad
        // The other side's track, ending under the pad on a junction of its own.
        route(point(0, 0), pad, layer: bottom, on: &board)
        let under = try XCTUnwrap(board.junctions.first { $0.value == pad }?.key)

        route(pad, point(20, 0), layer: top, fromPad: true, on: &board)
        let ends = try writtenEnds(of: board, from: pad, to: point(20, 0))
        XCTAssertEqual(ends.from["pad"] as? String, "pkg/pad")
        XCTAssertNil(ends.from["junc"] as? String, "not the bottom track's junction, \(under)")
        XCTAssertNotNil(ends.to["junc"] as? String)
    }

    /// With nothing under the pad the end was on the pad already.
    func testARouteFromAPadIsWrittenOnThePad() throws {
        var board = try XCTUnwrap(project.board)
        let pad = point(10, 0)
        board.packagePadPositions["pkg/pad"] = pad
        route(pad, point(20, 0), layer: top, fromPad: true, on: &board)
        let ends = try writtenEnds(of: board, from: pad, to: point(20, 0))
        XCTAssertEqual(ends.from["pad"] as? String, "pkg/pad")
    }
}
