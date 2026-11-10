import XCTest
@testable import HorizontalNative

/// Edit ▸ Align and Edit ▸ Distribute on the board (`BoardAlignment`): what
/// each moves the objects by, what stays, and which objects take part.
final class BoardAlignAndDistributeTests: XCTestCase {
    private func box(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> HorizontalRect {
        HorizontalRect(points: [HorizontalPoint(x: minX, y: minY), HorizontalPoint(x: maxX, y: maxY)])
    }

    private var three: [BoardAlignItem<String>] {
        [
            BoardAlignItem(key: "a", bounds: box(0, 0, 10, 10)),
            BoardAlignItem(key: "b", bounds: box(30, 5, 50, 25)),
            BoardAlignItem(key: "c", bounds: box(100, -20, 104, -10)),
        ]
    }

    func testAlignLeftLinesUpTheLeftEdgesOnTheLeftmost() {
        let offsets = BoardAlignment.offsets(.left, items: three)
        XCTAssertNil(offsets["a"], "the leftmost is already there")
        XCTAssertEqual(offsets["b"], HorizontalPoint(x: -30, y: 0))
        XCTAssertEqual(offsets["c"], HorizontalPoint(x: -100, y: 0))
    }

    func testAlignRightTopAndBottomUseTheOutermostEdges() {
        let right = BoardAlignment.offsets(.right, items: three)
        XCTAssertEqual(right["a"], HorizontalPoint(x: 94, y: 0))
        XCTAssertEqual(right["b"], HorizontalPoint(x: 54, y: 0))
        XCTAssertNil(right["c"])

        let top = BoardAlignment.offsets(.top, items: three)
        XCTAssertEqual(top["a"], HorizontalPoint(x: 0, y: 15))
        XCTAssertNil(top["b"])
        XCTAssertEqual(top["c"], HorizontalPoint(x: 0, y: 35))

        let bottom = BoardAlignment.offsets(.bottom, items: three)
        XCTAssertEqual(bottom["a"], HorizontalPoint(x: 0, y: -20))
        XCTAssertEqual(bottom["b"], HorizontalPoint(x: 0, y: -25))
        XCTAssertNil(bottom["c"])
    }

    func testCenterAndMiddleLineUpTheCentresOnTheMiddleOfTheWhole() {
        // The whole spans x 0…104 and y −20…25: centre 52, middle 2.5.
        let center = BoardAlignment.offsets(.center, items: three)
        XCTAssertEqual(center["a"], HorizontalPoint(x: 47, y: 0))
        XCTAssertEqual(center["b"], HorizontalPoint(x: 12, y: 0))
        XCTAssertEqual(center["c"], HorizontalPoint(x: -50, y: 0))

        let middle = BoardAlignment.offsets(.middle, items: three)
        // Whole nanometres, as the file stores them: 2.5 − 5 = −2.5 rounds away.
        XCTAssertEqual(middle["a"], HorizontalPoint(x: 0, y: -3))
        XCTAssertEqual(middle["b"], HorizontalPoint(x: 0, y: -13))
        XCTAssertEqual(middle["c"], HorizontalPoint(x: 0, y: 18))
    }

    func testDistributeLeavesEqualGapsAndKeepsTheOutermostTwo() {
        // Span 0…104, boxes 10 + 20 + 4 wide: two gaps of 35.
        let offsets = BoardAlignment.offsets(.distributeHorizontally, items: three)
        XCTAssertNil(offsets["a"])
        XCTAssertNil(offsets["c"])
        XCTAssertEqual(offsets["b"], HorizontalPoint(x: 15, y: 0), "b's left edge goes to 10 + 35")

        let vertical = BoardAlignment.offsets(.distributeVertically, items: [
            BoardAlignItem(key: "low", bounds: box(0, 0, 1, 10)),
            BoardAlignItem(key: "high", bounds: box(0, 90, 1, 100)),
            BoardAlignItem(key: "mid", bounds: box(5, 20, 6, 30)),
            BoardAlignItem(key: "upper", bounds: box(5, 60, 6, 80)),
        ])
        // Span 100, boxes 10 + 10 + 20 + 10: three gaps of 50 / 3.
        XCTAssertEqual(vertical["mid"], HorizontalPoint(x: 0, y: 7), "to 10 + 16.67")
        XCTAssertEqual(vertical["upper"], HorizontalPoint(x: 0, y: -7), "from 60 to 36.67 + 16.67")
        XCTAssertNil(vertical["low"])
        XCTAssertNil(vertical["high"])
    }

    func testAFixedObjectStaysButStillSetsTheEdge() {
        var items = three
        items[2].isFixed = true
        let offsets = BoardAlignment.offsets(.right, items: items)
        XCTAssertEqual(offsets["a"], HorizontalPoint(x: 94, y: 0), "the others line up on the fixed one")
        XCTAssertNil(offsets["c"])

        items[2].bounds = box(-100, 0, -90, 1)
        let left = BoardAlignment.offsets(.left, items: items)
        XCTAssertNil(left["c"], "a fixed object never moves, even when it isn't the edge")
    }

    func testTooFewObjectsDoNothing() {
        XCTAssertTrue(BoardAlignment.offsets(.left, items: Array(three.prefix(1))).isEmpty)
        XCTAssertTrue(BoardAlignment.offsets(.distributeHorizontally, items: Array(three.prefix(2))).isEmpty)
    }

    func testLeftAndRightSwapWhenTheViewIsSeenFromBelow() {
        XCTAssertEqual(BoardAlignOperation.left.onBoard(viewMirrored: true), .right)
        XCTAssertEqual(BoardAlignOperation.right.onBoard(viewMirrored: true), .left)
        XCTAssertEqual(BoardAlignOperation.top.onBoard(viewMirrored: true), .top)
        XCTAssertEqual(BoardAlignOperation.left.onBoard(viewMirrored: false), .left)
    }

    func testOnlyPackagesViasHolesDecalsAndBoardTextsTakePart() throws {
        var board = HorizontalGerberExportFixture.board(
            tracks: [HorizontalSegment(id: "track", from: .zero, to: HorizontalPoint(x: 1, y: 0), width: 1, layer: HorizontalGerberExportFixture.top)],
            vias: [HorizontalMarker(id: "via", position: .zero, size: 600_000, holeSize: 300_000, layer: HorizontalGerberExportFixture.top)]
        )
        board.packages = [
            HorizontalPlacement(id: "PKG", position: .zero, angle: 0, mirrored: false, label: "R1"),
            HorizontalPlacement(id: "fixed", position: .zero, angle: 0, mirrored: false, label: "R2"),
        ]
        board.packages[1].fixed = true
        let refs = [
            HorizontalSelectableRef(id: "pkg", type: .boardPackage),
            HorizontalSelectableRef(id: "pkg", type: .boardPackage),
            HorizontalSelectableRef(id: "FIXED", type: .boardPackage),
            HorizontalSelectableRef(id: "no-such-package", type: .boardPackage),
            HorizontalSelectableRef(id: "track", type: .track),
            HorizontalSelectableRef(id: "via", type: .via, layer: HorizontalGerberExportFixture.top),
            HorizontalSelectableRef(id: "PKG/text/refdes", type: .text),
        ]
        let alignable = BoardAlignment.alignableRefs(refs, in: board)
        XCTAssertEqual(alignable, [refs[0], refs[2], refs[5]],
                       "each package once, the via; no track, nothing missing from the board, no package's own text")

        let items = BoardAlignment.items(for: refs, in: board) { _ in self.box(0, 0, 1, 1) }
        XCTAssertEqual(items.map { $0.isFixed }, [false, true, false], "a fixed package is marked to stay")
    }
}
