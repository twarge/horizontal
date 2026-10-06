import XCTest
@testable import HorizontalNative

/// A package dropped onto the board joins the scene already built: its
/// primitives are appended batch by batch, and the batches it redraws whole
/// (the airwires) are replaced.
final class BoardMetalElementBucketsMergeTests: XCTestCase {
    private func line(_ x: Double, owner: String? = nil) -> (HorizontalMetalLinePrimitive, HorizontalSelectableRef?) {
        (
            HorizontalMetalLinePrimitive(
                from: HorizontalPoint(x: x, y: 0),
                to: HorizontalPoint(x: x, y: 1),
                color: HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1)
            ),
            owner.map { HorizontalSelectableRef(id: $0, type: .boardPackage) }
        )
    }

    /// A batch left out of the list would be dropped from every merged scene.
    func testEveryBatchTakesPartInAMerge() {
        XCTAssertEqual(BoardMetalElementBuckets.batchKeyPaths.count, BoardMetalElementBuckets().namedBatches().count)
    }

    func testAMergeAppendsTheAdditionAndReplacesWhatItRedraws() {
        let scene = BoardMetalElementBuckets()
        let (oldPad, oldPadOwner) = line(1, owner: "old")
        scene.pads.appendLine(oldPad, owner: oldPadOwner)
        scene.connectionLines.appendLine(line(2).0)

        let addition = BoardMetalElementBuckets()
        let (newPad, newPadOwner) = line(3, owner: "new")
        addition.pads.appendLine(newPad, owner: newPadOwner)
        addition.connectionLines.appendLine(line(4).0)
        addition.connectionLines.appendLine(line(5).0)

        let merged = scene.merged(adding: addition, replacing: [\.connectionLines])

        XCTAssertEqual(merged.pads.lines, [oldPad, newPad])
        XCTAssertEqual(merged.pads.lineOwners, [oldPadOwner, newPadOwner])
        XCTAssertEqual(merged.pads.lineLabelSizes.count, 2)
        XCTAssertEqual(merged.connectionLines.lines.map(\.from.x), [4, 5], "the airwires come from the addition alone")
        XCTAssertEqual(scene.pads.lines, [oldPad], "the scene merged into is left as it was")
    }

    /// A scene says which airwires it draws (field notes item 29), and a merge
    /// keeps that true: replaced with the batch it redraws, appended otherwise.
    func testAMergeCarriesTheAirwiresItsBatchesDraw() {
        func airwire(_ id: String) -> HorizontalSegment {
            HorizontalSegment(id: id, from: .zero, to: HorizontalPoint(x: 1, y: 1), width: 0, layer: nil)
        }
        let scene = BoardMetalElementBuckets()
        scene.airwires = [airwire("old")]
        let addition = BoardMetalElementBuckets()
        addition.airwires = [airwire("new")]

        XCTAssertEqual(scene.merged(adding: addition, replacing: [\.connectionLines]).airwires.map(\.id), ["new"])
        XCTAssertEqual(scene.merged(adding: addition, replacing: []).airwires.map(\.id), ["old", "new"])
    }
}
