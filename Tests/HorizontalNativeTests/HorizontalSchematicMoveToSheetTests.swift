import Foundation
import XCTest
@testable import HorizontalNative

/// The canvas's side of Move to Other Sheet: which selected refs the op can
/// carry, under the ids the sheet's JSON stores them by, and the refs its
/// reply names on the other sheet.
final class HorizontalSchematicMoveToSheetTests: XCTestCase {
    func testSelectedRefsBecomeTheIdsTheSheetStoresThemUnder() {
        let refs = [
            HorizontalSelectableRef(id: "S1", type: .schematicSymbol),
            HorizontalSelectableRef(id: "s1", type: .schematicSymbol),
            HorizontalSelectableRef(id: "sheet/line/L1", type: .drawingLine),
            HorizontalSelectableRef(id: "sheet/arc/A1", type: .drawingArc),
            HorizontalSelectableRef(id: "W1", type: .lineNet),
            HorizontalSelectableRef(id: "S1/P1", type: .symbolPin),
            HorizontalSelectableRef(id: "B1/block-text/T", type: .text),
            HorizontalSelectableRef(id: "T1", type: .text),
            HorizontalSelectableRef(id: "line/L2", type: .drawingLine)
        ]
        XCTAssertEqual(HorizontalSchematicMoveToSheet.items(for: refs), ["S1", "L1", "A1", "W1", "T1"],
                       "a pin, a block symbol's text and a malformed line id are left out, and a repeat is listed once")
    }

    func testTheReplyNamesRefsTheCanvasSelects() {
        let refs = HorizontalSchematicMoveToSheet.refs(moved: ["symbols": ["s1"], "lines": ["l1"], "arcs": ["a1"],
                                                                "junctions": ["j1"], "pictures": ["p1"]])
        XCTAssertEqual(Set(refs), [HorizontalSelectableRef(id: "s1", type: .schematicSymbol),
                                   HorizontalSelectableRef(id: "sheet/line/l1", type: .drawingLine),
                                   HorizontalSelectableRef(id: "sheet/arc/a1", type: .drawingArc),
                                   HorizontalSelectableRef(id: "j1", type: .junction)],
                       "a picture moves but isn't something the canvas selects")
        XCTAssertEqual(HorizontalSchematicMoveToSheet.items(for: refs).sorted(), ["a1", "j1", "l1", "s1"])
    }
}
