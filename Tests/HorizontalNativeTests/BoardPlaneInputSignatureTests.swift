import XCTest
@testable import HorizontalNative

/// The fingerprint that decides whether plane fills are out of date.
///
/// Two ways to get this wrong, each bad in its own direction: miss a change the
/// pour reads and the app shows fills that no longer describe the board, saying
/// nothing; include the pour's own output and every pour instantly invalidates
/// itself, so the control never stops asking to be pressed.
final class BoardPlaneInputSignatureTests: XCTestCase {
    private let mm = 1_000_000.0
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func square(_ id: String, cx: Double, cy: Double, half: Double,
                        layer: Int = 0, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(
            id: id,
            vertices: [p(cx - half, cy - half), p(cx + half, cy - half),
                       p(cx + half, cy + half), p(cx - half, cy + half)],
            layer: layer,
            netID: net
        )
    }

    private func plane(_ id: String, half: Double, net: String?) -> HorizontalPlane {
        var value = HorizontalPlane(
            id: id, netID: net, polygonID: "poly-\(id)", layer: 0,
            priority: 0, fillStyle: "solid", minWidth: 200_000,
            keepOrphans: false, fragments: []
        )
        value.fallbackPolygon = square("poly-\(id)", cx: 0, cy: 0, half: half, layer: 0, net: net)
        value.fromRules = false
        return value
    }

    private func makeBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/sig.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [HorizontalSegment(id: "t1", from: p(0, 0), to: p(5 * mm, 0),
                                       width: 200_000, layer: 0, netID: "gnd")],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [square("outline", cx: 0, cy: 0, half: 12 * mm,
                              layer: HorizontalBoardLayers.outline)],
            planes: [plane("p1", half: 10 * mm, net: "gnd")],
            keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [],
            packagePads: [square("pkg/pad/a", cx: 8 * mm, cy: 8 * mm, half: 500_000, net: "gnd")],
            packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [],
            packageTexts: [], texts: [], boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func signature(_ board: HorizontalBoard) -> Int {
        HorizontalBoardPlaneInputs.signature(of: board)
    }

    func testIdenticalBoardsMatch() {
        XCTAssertEqual(signature(makeBoard()), signature(makeBoard()))
    }

    /// The critical exclusion: pouring changes only `fragments`, so a poured
    /// board must fingerprint the same as the board that went in. Otherwise
    /// every pour would leave the fills marked stale the instant it finished.
    func testPouringDoesNotChangeTheSignature() {
        let board = makeBoard()
        let poured = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)

        XCTAssertFalse(poured.planes.contains { $0.fragments.isEmpty },
                       "precondition: the pour must have produced fills to ignore")
        XCTAssertEqual(signature(board), signature(poured))
    }

    /// Copper the pour clips around.
    func testMovingATrackInvalidatesTheFills() {
        var board = makeBoard()
        board.tracks[0].to = p(6 * mm, 0)
        XCTAssertNotEqual(signature(makeBoard()), signature(board))
    }

    func testAddingAViaInvalidatesTheFills() {
        var board = makeBoard()
        board.vias = [HorizontalMarker(id: "v", position: p(mm, 0), size: 600_000, layer: nil)]
        XCTAssertNotEqual(signature(makeBoard()), signature(board))
    }

    func testMovingAPadInvalidatesTheFills() {
        var board = makeBoard()
        board.packagePads = [square("pkg/pad/a", cx: 9 * mm, cy: 8 * mm, half: 500_000, net: "gnd")]
        XCTAssertNotEqual(signature(makeBoard()), signature(board))
    }

    func testAKeepoutInvalidatesTheFills() {
        var board = makeBoard()
        board.keepouts = [HorizontalKeepout(
            id: "k1",
            polygonID: "k1-poly",
            polygon: square("k1-poly", cx: 0, cy: 0, half: mm, layer: 0),
            keepoutClass: "",
            allCopperLayers: true,
            exposedCopperOnly: false,
            copperPatchTypes: []
        )]
        XCTAssertNotEqual(signature(makeBoard()), signature(board))
    }

    /// A plane's own definition — priority decides which tier pours first, so it
    /// changes the result even though no copper moved.
    func testChangingAPlaneDefinitionInvalidatesTheFills() {
        var board = makeBoard()
        board.planes[0].priority = 3
        XCTAssertNotEqual(signature(makeBoard()), signature(board))

        var widened = makeBoard()
        widened.planes[0].minWidth = 500_000
        XCTAssertNotEqual(signature(makeBoard()), signature(widened))
    }

    /// Clearances come from the rules, so a rule edit changes the fill without
    /// touching a single object on the board.
    func testChangingRulesInvalidatesTheFills() {
        var board = makeBoard()
        board.rules.planeRules = [HorizontalRulePlane(json: ["enabled": true, "order": 1])]
        XCTAssertNotEqual(signature(makeBoard()), signature(board))
    }

    /// Things the pour never reads must not claim the fills are out of date, or
    /// the control cries wolf and gets ignored.
    func testCosmeticEditsDoNotInvalidateTheFills() {
        var board = makeBoard()
        board.dimensions = [HorizontalDimension(
            id: "d1", p0: p(0, 0), p1: p(mm, 0),
            labelDistance: 0, labelSize: 1_500_000, mode: .horizontal)]
        XCTAssertEqual(signature(makeBoard()), signature(board), "a dimension is not copper")
    }
}
