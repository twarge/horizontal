import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A net label's Off-sheet references row: on, the label lists the other
/// sheets its net is labelled on, as Horizon draws `SIG [2]`; off, the name
/// alone. The change is one place_net_label on the label, so one undo step.
final class SchematicNetLabelOffsheetRefsTests: XCTestCase {
    func testTurningOffSheetReferencesOffDropsTheOtherSheetsFromTheLabel() throws {
        let fixture = try SchematicProjectEditFixture(testCase: self)
        try fixture.placeResistors(["R1"])
        try fixture.apply([
            ["op": "add_sheet", "name": "Second"],
            ["op": "terminate_pin", "component": "R1", "pin": "1", "kind": "label", "net": "SIG", "create_net": true],
            ["op": "place_net_label", "net": "SIG", "sheet": "Second", "x_mm": 40, "y_mm": 40],
        ])
        let first = try fixture.sheet
        let label = try XCTUnwrap(first.netLabels.first)
        XCTAssertTrue(label.showsOffsheetRefs)
        XCTAssertEqual(label.text, "SIG [2]")
        XCTAssertEqual(HorizontalNetLabelOffsheetProperty.property(for: label, editable: true).value, .bool(true))
        XCTAssertNil(HorizontalNetLabelOffsheetProperty.edit(shown: true, labels: [label]), "already shown")

        let edit = try XCTUnwrap(HorizontalNetLabelOffsheetProperty.edit(shown: false, labels: [label]))
        XCTAssertEqual(edit.ops.count, 1, "one op, one undo step")
        XCTAssertEqual(edit.actionName, "Hide Off-sheet References")
        try fixture.apply(edit.ops)

        let after = try XCTUnwrap(try fixture.sheet.netLabels.first { $0.id == label.id })
        XCTAssertFalse(after.showsOffsheetRefs)
        XCTAssertEqual(after.text, "SIG")
        let item = try XCTUnwrap(try fixture.sheetJSON().dictionaryMap("net_labels").first { $0.key.lowercased() == label.id.lowercased() }?.value)
        XCTAssertEqual(item.bool("offsheet_refs"), false)
    }
}
