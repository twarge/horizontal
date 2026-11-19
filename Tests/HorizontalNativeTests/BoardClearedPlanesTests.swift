import XCTest
@testable import HorizontalNative

/// Clear All Planes leaves the planes unpoured until Update All Planes: the
/// board says they were cleared, which is what stops the pour that follows an
/// edit, and only a pour's fills taken in end it.
final class BoardClearedPlanesTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private let net = "net-a"

    private func square(around center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half),
        ]
    }

    private func plane(_ id: String, priority: Int = 0) -> HorizontalPlane {
        var plane = HorizontalPlane(
            id: id, netID: net, polygonID: "poly-\(id)", layer: top,
            priority: priority, fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: []
        )
        plane.fallbackPolygon = HorizontalPolygon(
            id: "poly-\(id)", vertices: square(around: HorizontalPoint(x: 5 * mm, y: 0), half: 12 * mm), layer: top, netID: net
        )
        plane.fromRules = false
        return plane
    }

    /// A board with an outline, a pad of the planes' net for their fills to
    /// reach (a fill that reaches none is an orphan, and dropped), and the
    /// planes given, not yet poured.
    private func board(planes: [HorizontalPlane]) -> HorizontalBoard {
        var board = HorizontalGerberExportFixture.board()
        board.polygons = [HorizontalPolygon(
            id: "outline", vertices: square(around: HorizontalPoint(x: 5 * mm, y: 0), half: 15 * mm),
            layer: HorizontalBoardLayers.outline
        )]
        board.packagePads = [
            HorizontalPolygon(id: "pkg-a/pad/p1/shape/s", vertices: square(around: .zero, half: 400_000), layer: top, netID: net),
        ]
        board.packagePadPositions = ["pkg-a/p1": .zero]
        board.planes = planes
        return board
    }

    private func poured(_ planes: [HorizontalPlane]) -> HorizontalBoard {
        HorizontalBoardPlaneUpdater.updateAllPlanes(in: board(planes: planes))
    }

    private func result(for board: HorizontalBoard, byQ: Bool) -> HorizontalPlanePourResult {
        HorizontalPlanePourResult(
            fills: HorizontalPlaneFills(inputs: HorizontalBoardPlaneInputs.signature(of: board), fragmentsByPlaneID: [:], airwires: []),
            pouredPlaneIDs: [], planesFileData: nil, triangles: [:], fragmentKeys: [],
            isManual: byQ, registersUndo: byQ
        )
    }

    func testClearingEmptiesEveryFillAndSaysSo() {
        var board = poured([plane("p1"), plane("p2", priority: 1)])
        XCTAssertFalse(board.planes[0].fragments.isEmpty, "precondition: something was poured")
        XCTAssertFalse(board.planeFillsCleared)
        let inputs = HorizontalBoardPlaneInputs.signature(of: board)

        board.clearPlaneFills()

        XCTAssertTrue(board.planes.allSatisfy { $0.fragments.isEmpty })
        XCTAssertTrue(board.planeFillsCleared)
        XCTAssertEqual(HorizontalBoardPlaneInputs.signature(of: board), inputs,
                       "clearing is no change to what a pour reads: by itself it leaves nothing out of date")
    }

    /// With Update Planes Automatically on, planes that were never poured are
    /// poured by the next edit too, so there is something to clear.
    func testThereIsSomethingToClearUntilThePlanesAreMarkedCleared() {
        XCTAssertFalse(board(planes: []).canClearPlaneFills, "no planes, nothing to clear")

        var unpoured = board(planes: [plane("p1")])
        XCTAssertTrue(unpoured.canClearPlaneFills, "unpoured planes can still be kept from pouring")
        unpoured.clearPlaneFills()
        XCTAssertFalse(unpoured.canClearPlaneFills, "cleared already")

        XCTAssertTrue(poured([plane("p1")]).canClearPlaneFills)
    }

    /// The report: with the planes cleared, changing a net poured them again.
    /// A document asks the board before it takes a pour, and a cleared one
    /// takes only what Update All Planes asked for.
    func testAClearedBoardTakesOnlyThePourUpdateAllPlanesAskedFor() {
        var board = poured([plane("p1")])
        XCTAssertTrue(board.takesPlaneFills(of: result(for: board, byQ: false)), "a board not cleared takes the pour after an edit")

        board.clearPlaneFills()
        XCTAssertFalse(board.takesPlaneFills(of: result(for: board, byQ: false)),
                       "a pour on its way when the planes were cleared must not fill them again")
        XCTAssertTrue(board.takesPlaneFills(of: result(for: board, byQ: true)), "Q pours them again")
    }

    func testTakingAPourEndsTheClear() {
        let filled = poured([plane("p1")])
        var board = filled
        board.clearPlaneFills()

        board.takePlaneFills(HorizontalPlaneFills(
            inputs: HorizontalBoardPlaneInputs.signature(of: board),
            fragmentsByPlaneID: ["p1": filled.planes[0].fragments], airwires: board.airwires
        ))

        XCTAssertEqual(board.planes[0].fragments, filled.planes[0].fragments)
        XCTAssertFalse(board.planeFillsCleared, "poured again, the next edit pours as it did before")
    }

    func testPouringAClearedBoardHandsBackOneThatIsNotCleared() {
        var board = poured([plane("p1")])
        board.clearPlaneFills()

        let again = HorizontalBoardPlaneUpdater.pour(in: board, cache: HorizontalPlanePourCache())

        XCTAssertTrue(again.isComplete)
        XCTAssertFalse(again.board.planes[0].fragments.isEmpty)
        XCTAssertFalse(again.board.planeFillsCleared)
    }

    /// A change on a sheet reads the board back from the archive, whose
    /// planes file still has the fills that were cleared in memory.
    func testABoardReadBackWhileThePlanesAreClearedIsClearedToo() {
        let onDisk = poured([plane("p1"), plane("p2", priority: 1)])
        var memory = onDisk
        memory.planes.removeLast()
        memory.clearPlaneFills()

        var readBack = onDisk
        readBack.carryPlaneFills(from: memory)

        XCTAssertTrue(readBack.planes.allSatisfy { $0.fragments.isEmpty }, "a plane the memory board lacks is cleared with the rest")
        XCTAssertTrue(readBack.planeFillsCleared, "and the board read back stays unpoured through the edits that follow")
    }

    func testABoardReadBackFromOneThatIsNotClearedIsNotCleared() {
        let memory = poured([plane("p1")])
        var readBack = board(planes: [plane("p1")])
        readBack.carryPlaneFills(from: memory)

        XCTAssertEqual(readBack.planes[0].fragments, memory.planes[0].fragments)
        XCTAssertFalse(readBack.planeFillsCleared)
    }
}
