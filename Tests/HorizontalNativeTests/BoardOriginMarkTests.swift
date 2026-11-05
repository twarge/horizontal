import XCTest
@testable import HorizontalNative

/// The board shows its origin mark as the schematic does: the sided layer
/// views (placement, routing, silkscreen, each side) keep it on with the rest
/// of the view furniture. They used to switch it off, and since a board opens
/// on one of them and the rail offers nothing else, the board's origin never
/// showed.
final class BoardOriginMarkTests: XCTestCase {
    func testSidedLayerViewsShowTheOrigin() {
        let sided = HorizontalBoardLayerPreset.allCases.filter { preset in
            [.top, .bottom].contains { preset.resolved(for: $0).side != nil }
        }
        XCTAssertFalse(sided.isEmpty)

        for preset in sided {
            for side in [HorizontalBoardSide.top, .bottom] {
                var options = BoardDisplayOptions()
                options.origin = false
                options.applyLayerPreset(preset.resolved(for: side))
                XCTAssertTrue(options.origin, "\(preset.rawValue) on the \(side.rawValue) must show the origin")
                XCTAssertTrue(options.grid, "\(preset.rawValue) on the \(side.rawValue) must show the grid")
            }
        }
    }

    /// The schematic shows its origin from the start, and so does a board.
    func testTheOriginShowsByDefaultOnBothCanvases() {
        XCTAssertTrue(BoardDisplayOptions().origin)
        XCTAssertTrue(SchematicDisplayOptions().origin)
    }

    /// The clean view is the one that leaves the furniture out, on both.
    func testTheCleanViewStillHidesTheOrigin() {
        var board = BoardDisplayOptions()
        board.applyLayerPreset(.clean)
        XCTAssertFalse(board.origin)

        var schematic = SchematicDisplayOptions()
        schematic.cleanView()
        XCTAssertFalse(schematic.origin)
    }
}
