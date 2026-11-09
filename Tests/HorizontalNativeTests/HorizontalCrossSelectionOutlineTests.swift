import Foundation
import XCTest
@testable import HorizontalNative

/// The blue box round a part another view selected sits where that part's
/// selection box does: along its outline, pushed out as far, a few points
/// whatever the zoom, rather than a fixed distance in millimetres that looked
/// wider or tighter than the selection box as the view zoomed.
final class HorizontalCrossSelectionOutlineTests: XCTestCase {
    private let mm = 1_000_000.0

    func testTheBlueBoxIsTheSelectionBoxsOutlinePushedOutAsFar() throws {
        let rgba = { (value: Float) in HorizontalMetalRGBA(red: value, green: value, blue: value, alpha: 1) }
        for type in [HorizontalObjectType.boardPackage, .schematicSymbol] {
            let ref = HorizontalSelectableRef(id: "part", type: type)
            let corners = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 4 * mm, y: 0),
                           HorizontalPoint(x: 4 * mm, y: 2 * mm), HorizontalPoint(x: 0, y: 2 * mm)]
            let selectable = HorizontalSelectable.bounds(
                ref: ref, points: corners, fallbackCenter: HorizontalPoint(x: 2 * mm, y: mm), fallbackSize: mm
            )
            let style = HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: rgba(0.1), selectedInnerColor: rgba(0.2), selectedHandleInnerColor: rgba(0.3),
                hoverOuterColor: rgba(0.4), hoverInnerColor: rgba(0.5), handleShape: .diamond
            )
            let selection = HorizontalCanvasModeSupport.metalSelectionOverlay(
                selectablesForRef: { $0 == ref ? [selectable] : [] },
                selectedRefs: [ref], hoveredRef: nil, style: style
            ).lines.filter { $0.color == style.selectedOuterColor }
            let blue = HorizontalCanvasModeSupport.crossSelectionLines(for: [selectable]).lines

            XCTAssertEqual(blue.count, 4, "\(type): a closed box")
            XCTAssertEqual(blue.map(\.from), selection.map(\.from), "\(type): along the selection box's outline")
            XCTAssertEqual(blue.map(\.to), selection.map(\.to))
            XCTAssertEqual(blue.map { $0.normalOffset }, selection.map { $0.normalOffset }, "\(type): pushed out as far")
            XCTAssertEqual(blue.first?.normalOffset, -HorizontalSelectable.selectionOutlineScreenMargin)
            XCTAssertEqual(blue.first?.dashLength, 0, "solid, where the selection box is dashed")
        }
    }
}
