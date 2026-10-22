import XCTest
@testable import HorizontalNative

/// Find in the navigator matches what a sheet draws, not only its name:
/// components by refdes, value, MPN, manufacturer and description.
final class HorizontalNavigatorComponentSearchTests: XCTestCase {
    private func symbol(_ id: String, component: String, refdes: String, value: String, mpn: String?,
                        manufacturer: String? = nil, description: String? = nil, x: Double = 0) -> HorizontalPlacement {
        var details = HorizontalComponentDetails(componentID: component, refdes: refdes, value: value, partID: nil)
        details.mpn = mpn
        details.manufacturer = manufacturer
        details.description = description
        return HorizontalPlacement(id: id, position: HorizontalPoint(x: x, y: 0), angle: 0, mirrored: false,
                                   label: refdes, componentID: component, componentDetails: details)
    }

    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Power", gridSpacing: 1_250_000)
        sheet.symbols = [
            symbol("s1", component: "C-R10", refdes: "R10", value: "10k", mpn: "RC0402FR-0710KL", manufacturer: "Yageo", x: 1),
            symbol("s2", component: "C-R2", refdes: "R2", value: "4k7", mpn: "RC0402FR-074K7L", manufacturer: "Yageo", x: 2),
            symbol("s3a", component: "C-U1", refdes: "U1", value: "OPA2328", mpn: "OPA2328DGKR", description: "Dual op amp", x: 3),
            symbol("s3b", component: "C-U1", refdes: "U1", value: "OPA2328", mpn: "OPA2328DGKR", description: "Dual op amp", x: 4),
            symbol("s4", component: "C-C1", refdes: "C1", value: "GRM155R71C104KA88D", mpn: "GRM155R71C104KA88D", manufacturer: "Murata", x: 5),
        ]
        return sheet
    }

    func testAnMPNFindsItsComponentsInRefdesOrder() {
        let matches = HorizontalNavigatorComponentSearch.matches(on: sheet(), tokens: HorizontalNavigatorComponentSearch.tokens("rc0402"))
        XCTAssertEqual(matches.map(\.refdes), ["R2", "R10"], "refdes in natural order")
        XCTAssertEqual(matches.first?.detail, "4k7 · RC0402FR-074K7L")
        XCTAssertEqual(matches.first?.componentID, "c-r2")
    }

    func testEveryWordHasToMatchAndAComponentIsListedOnce() {
        let sheet = sheet()
        XCTAssertEqual(HorizontalNavigatorComponentSearch.matches(on: sheet, tokens: ["yageo", "10k"]).map(\.refdes), ["R10"])
        let opAmps = HorizontalNavigatorComponentSearch.matches(on: sheet, tokens: ["op", "amp"])
        XCTAssertEqual(opAmps.map(\.refdes), ["U1"], "two gates, one row")
        XCTAssertEqual(opAmps.first?.position, HorizontalPoint(x: 3, y: 0), "its first symbol")
        XCTAssertEqual(HorizontalNavigatorComponentSearch.matches(on: sheet, tokens: ["U1"].map { $0.lowercased() }).map(\.refdes), ["U1"])
        XCTAssertTrue(HorizontalNavigatorComponentSearch.matches(on: sheet, tokens: []).isEmpty)
    }

    func testAValueThatIsTheMPNIsShownOnce() {
        let matches = HorizontalNavigatorComponentSearch.matches(on: sheet(), tokens: ["murata"])
        XCTAssertEqual(matches.first?.detail, "GRM155R71C104KA88D")
    }

    /// The navigator marks the sheets that draw a selected part, as it marks
    /// those that draw a highlighted net.
    func testASheetDrawingASelectedPartIsMarked() {
        let sheet = sheet()
        XCTAssertTrue(sheet.containsAnyComponent(["c-u1"]), "one of its gates is on the sheet")
        XCTAssertTrue(sheet.containsAnyComponent(["elsewhere", "c-r2"]))
        XCTAssertFalse(sheet.containsAnyComponent(["elsewhere"]))
        XCTAssertFalse(sheet.containsAnyComponent([]))
    }

    func testWordsSplitOnSpacesAndCommasWithoutCase() {
        XCTAssertEqual(HorizontalNavigatorComponentSearch.tokens(" R1, OPA2328  x"), ["r1", "opa2328", "x"])
    }
}
