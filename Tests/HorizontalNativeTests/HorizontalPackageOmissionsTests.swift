import Foundation
import XCTest
@testable import HorizontalNative

/// A package's Omit Silkscreen and Omit Outline hold in the 3D view and the
/// exports as on the board canvas: the loader keeps the omitted artwork so
/// the canvas can toggle the flags live, and the 3D scene and the Gerbers
/// drew every package's silkscreen whatever its flags said.
final class HorizontalPackageOmissionsTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture
    private let mm = 1_000_000.0
    private let silk = HorizontalBoardLayers.topSilkscreen
    private let outline = HorizontalBoardLayers.outline
    private let assembly = HorizontalBoardLayers.topAssembly

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func square(_ id: String, at x: Double, layer: Int) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [point(x, 0), point(x + 1, 0), point(x + 1, 1), point(x, 1)], layer: layer)
    }

    /// Each package `pa`, `pb` and `pc`, at x 0, 10 and 20 mm, has a
    /// silkscreen line, arc, polygon and $RD text, an outline polygon and
    /// line, and an assembly line. `pa` omits its silkscreen and has a
    /// smashed text, `pb` omits its outline, `pc` omits nothing. The board
    /// has a silkscreen line of its own.
    private func board(omitting: Bool = true) -> HorizontalBoard {
        var board = Fixture.board()
        for (package, x) in [("pa", 0.0), ("pb", 10.0), ("pc", 20.0)] {
            board.packages.append(HorizontalPlacement(
                id: package, position: point(x, 0), angle: 0, mirrored: false, label: package, componentID: "c\(package)",
                omitSilkscreen: omitting && package == "pa", omitOutline: omitting && package == "pb"
            ))
            board.packageLines += [
                HorizontalSegment(id: "\(package)/line/silk", from: point(x, 2), to: point(x + 2, 2), width: 150_000, layer: silk, netID: nil),
                HorizontalSegment(id: "\(package)/line/outline", from: point(x, 3), to: point(x + 2, 3), width: 0, layer: outline, netID: nil),
                HorizontalSegment(id: "\(package)/line/assembly", from: point(x, 4), to: point(x + 2, 4), width: 100_000, layer: assembly, netID: nil),
            ]
            board.packageArcs.append(HorizontalArc(
                id: "\(package)/arc/silk", from: point(x, 5), to: point(x + 2, 5), center: point(x + 1, 5), width: 150_000, layer: silk
            ))
            board.packagePolygons += [square("\(package)/polygon/silk", at: x, layer: silk),
                                      square("\(package)/polygon/outline", at: x + 4, layer: outline)]
            board.packageTexts.append(HorizontalText(
                id: "\(package)/text/rd", text: package.uppercased(), position: point(x, 6), size: mm, layer: silk,
                placeholder: HorizontalTextPlaceholder(stored: "$RD", drawn: package.uppercased())
            ))
        }
        var smashed = HorizontalText(id: "pa/text/smashed", text: "PA", position: point(0, 7), size: mm, layer: silk)
        smashed.fromSmash = true
        board.packageTexts.append(smashed)
        board.lines.append(HorizontalSegment(id: "board-silk", from: point(30, 2), to: point(32, 2), width: 150_000, layer: silk, netID: nil))
        return board
    }

    func testTheBoardLosesWhatThePackagesOmit() {
        let full = board()
        let made = full.omittingPackageArtwork()
        func ids<T>(_ items: [T], _ id: (T) -> String) -> Set<String> { Set(items.map(id)) }

        XCTAssertEqual(ids(made.packageLines, \.id), ids(full.packageLines, \.id).subtracting(["pa/line/silk"]),
                       "pa's silkscreen line goes; outline lines stay, as Horizon's omit_outline takes only polygons")
        XCTAssertEqual(ids(made.packageArcs, \.id), ["pb/arc/silk", "pc/arc/silk"])
        XCTAssertEqual(ids(made.packagePolygons, \.id), ids(full.packagePolygons, \.id).subtracting(["pa/polygon/silk", "pb/polygon/outline"]))
        XCTAssertEqual(ids(made.packageTexts, \.id), ["pa/text/smashed", "pb/text/rd", "pc/text/rd"],
                       "the text smashed out of pa is the board's")
        XCTAssertEqual(made.lines, full.lines, "the board's own silkscreen stays")
        XCTAssertEqual(made.packages, full.packages)

        let plain = board(omitting: false)
        let kept = plain.omittingPackageArtwork()
        XCTAssertEqual(kept.packageLines, plain.packageLines, "nothing omitted, nothing taken")
        XCTAssertEqual(kept.packageArcs, plain.packageArcs)
        XCTAssertEqual(kept.packagePolygons, plain.packagePolygons)
        XCTAssertEqual(kept.packageTexts, plain.packageTexts)
    }

    func testThe3DSilkscreenLeavesOutAnOmittedPackagesOwn() {
        func silkOnly(_ board: HorizontalBoard, package: String) -> HorizontalBoard {
            var board = board
            func kept(_ id: String, _ layer: Int?) -> Bool { layer == silk && id.hasPrefix("\(package)/") }
            board.lines = []
            board.packageLines.removeAll { !kept($0.id, $0.layer) }
            board.packageArcs.removeAll { !kept($0.id, $0.layer) }
            board.packagePolygons.removeAll { !kept($0.id, $0.layer) }
            board.packageTexts.removeAll { !kept($0.id, $0.layer) || $0.fromSmash }
            return board
        }
        let shown = silkOnly(board(omitting: false), package: "pa")
        XCTAssertGreaterThan(BoardSceneFactory.silkscreenGeometryCount(for: shown), 0, "pa's silkscreen is drawn")
        let omitted = silkOnly(board(), package: "pa")
        XCTAssertEqual(BoardSceneFactory.silkscreenGeometryCount(for: omitted), 0, "pa omits it")

        var smashed = omitted
        smashed.packageTexts = board().packageTexts.filter(\.fromSmash)
        XCTAssertGreaterThan(BoardSceneFactory.silkscreenGeometryCount(for: smashed), 0, "the text smashed out of pa is drawn")
    }

    /// The top silkscreen Gerber has no line of pa's and the outline Gerber
    /// none of pb's outline polygon; pc's, and the board's own, are there.
    func testTheGerbersLeaveOutWhatThePackagesOmit() throws {
        let gerbers = try Fixture.exportGerbers(board: board())
        let silkscreen = try XCTUnwrap(gerbers[silk])
        XCTAssertFalse(silkscreen.contains(Fixture.coordinate(point(0, 2))), "pa's silkscreen line")
        XCTAssertFalse(silkscreen.contains(Fixture.coordinate(point(0, 0))), "pa's silkscreen polygon")
        XCTAssertTrue(silkscreen.contains(Fixture.coordinate(point(10, 2))), "pb's silkscreen line")
        XCTAssertTrue(silkscreen.contains(Fixture.coordinate(point(20, 2))), "pc's silkscreen line")
        XCTAssertTrue(silkscreen.contains(Fixture.coordinate(point(30, 2))), "the board's own")

        let outlines = try XCTUnwrap(gerbers[outline])
        XCTAssertTrue(outlines.contains(Fixture.coordinate(point(4, 0))), "pa's outline polygon")
        XCTAssertFalse(outlines.contains(Fixture.coordinate(point(14, 0))), "pb omits its outline")
        XCTAssertTrue(outlines.contains(Fixture.coordinate(point(24, 0))), "pc's outline polygon")
    }
}
