import XCTest
@testable import HorizontalNative

/// Poured planes in the rats' nest: pads and vias inside a same-net fragment
/// on the plane's layer are one connected piece, so no airwire joins them.
final class BoardPlaneAirwireTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    private let net = "net-a"

    private func square(around center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half)
        ]
    }

    private func pad(_ package: String, _ pad: String, at center: HorizontalPoint, layer: Int) -> HorizontalPolygon {
        HorizontalPolygon(
            id: "\(package)/pad/\(pad)/shape/s",
            polygonVertices: square(around: center, half: 400_000).map { HorizontalPolygonVertex(position: $0) },
            layer: layer,
            netID: net
        )
    }

    private func plane(layer: Int, paths: [[HorizontalPoint]]) -> HorizontalPlane {
        HorizontalPlane(
            id: "plane-\(layer)", netID: net, polygonID: "poly-\(layer)", layer: layer,
            priority: 0, fillStyle: "solid", minWidth: 200_000, keepOrphans: false,
            fragments: [HorizontalPlaneFragment(paths: paths, orphan: false)]
        )
    }

    /// Two pads 10 mm apart on the top copper, no tracks: one airwire unless
    /// a plane joins them.
    private func board(planes: [HorizontalPlane], vias: [HorizontalMarker] = [], extraPads: [(String, String, HorizontalPoint, Int)] = []) -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board(vias: vias)
        let a = HorizontalPoint(x: 0, y: 0)
        let b = HorizontalPoint(x: 10_000_000, y: 0)
        board.packagePads = [pad("pkg-a", "p1", at: a, layer: top), pad("pkg-b", "p1", at: b, layer: top)]
        board.packagePadPositions = ["pkg-a/p1": a, "pkg-b/p1": b]
        for (package, name, center, layer) in extraPads {
            board.packagePads.append(pad(package, name, at: center, layer: layer))
            board.packagePadPositions["\(package)/\(name)"] = center
        }
        board.planes = planes
        board.regenerateAirwires()
        return board
    }

    func testPadsUnderTheSameFragmentNeedNoAirwire() {
        let covering = square(around: HorizontalPoint(x: 5_000_000, y: 0), half: 8_000_000)
        XCTAssertEqual(board(planes: []).airwires.count, 1)
        XCTAssertEqual(board(planes: [plane(layer: top, paths: [covering])]).airwires.count, 0)
    }

    func testAPlaneOnAnotherLayerDoesNotJoinTopPads() {
        let covering = square(around: HorizontalPoint(x: 5_000_000, y: 0), half: 8_000_000)
        XCTAssertEqual(board(planes: [plane(layer: bottom, paths: [covering])]).airwires.count, 1)
    }

    func testAFragmentReachingOnePadLeavesTheAirwire() {
        let onlyA = square(around: HorizontalPoint(x: 0, y: 0), half: 3_000_000)
        XCTAssertEqual(board(planes: [plane(layer: top, paths: [onlyA])]).airwires.count, 1)
    }

    func testAHoleInTheFragmentIsOutsideIt() {
        let covering = square(around: HorizontalPoint(x: 5_000_000, y: 0), half: 8_000_000)
        let holeAroundB = square(around: HorizontalPoint(x: 10_000_000, y: 0), half: 2_000_000)
        XCTAssertEqual(board(planes: [plane(layer: top, paths: [covering, holeAroundB])]).airwires.count, 1)
    }

    func testAViaSpanningThePlaneLayerJoinsThroughIt() {
        // Pad C sits alone on the bottom copper; a via inside the top fill
        // reaches the bottom, but nothing on the bottom joins it to pad C,
        // so C keeps its airwire. A bottom fill over C and the via closes it.
        let c = HorizontalPoint(x: 20_000_000, y: 0)
        let via = HorizontalMarker(id: "via-1", position: HorizontalPoint(x: 5_000_000, y: 0), size: 600_000, holeSize: 300_000, layer: nil, connectedLayers: [top, bottom], netID: net)
        let topFill = square(around: HorizontalPoint(x: 5_000_000, y: 0), half: 8_000_000)
        let bottomFill = square(around: HorizontalPoint(x: 12_500_000, y: 0), half: 9_000_000)
        let onlyTop = board(planes: [plane(layer: top, paths: [topFill])], vias: [via], extraPads: [("pkg-c", "p1", c, bottom)])
        XCTAssertEqual(onlyTop.airwires.count, 1)
        let both = board(planes: [plane(layer: top, paths: [topFill]), plane(layer: bottom, paths: [bottomFill])], vias: [via], extraPads: [("pkg-c", "p1", c, bottom)])
        XCTAssertEqual(both.airwires.count, 0)
    }
}
