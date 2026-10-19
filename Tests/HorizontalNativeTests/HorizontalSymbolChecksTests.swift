import Foundation
import XCTest
@testable import HorizontalNative

/// Upstream's symbol rules check (`SymbolRules::check_symbol`), and the app's
/// own rule that a pin pointing up or down keeps its name horizontal.
final class HorizontalSymbolChecksTests: XCTestCase {
    private let mm = 1_000_000.0

    /// A 5 × 2.5 mm box with a pin out of each side, its refdes and value
    /// 1.25 mm clear of it: everything upstream asks of a symbol.
    private func boxSymbol() -> (symbol: HorizontalPoolSymbol, unit: HorizontalPoolUnit) {
        var symbol = HorizontalPoolSymbol(uuid: UUID().uuidString.lowercased(), name: "Box", unitID: "unit")
        let corners = [(-5.0, 2.5), (5.0, 2.5), (5.0, -2.5), (-5.0, -2.5)]
        for (index, corner) in corners.enumerated() {
            symbol.drawing.junctions["j\(index)"] = HorizontalPoint(x: corner.0 * mm, y: corner.1 * mm)
        }
        for index in 0..<4 {
            symbol.drawing.lines["l\(index)"] = HorizontalPoolLine(id: "l\(index)", from: "j\(index)", to: "j\((index + 1) % 4)")
        }
        symbol.drawing.texts["r"] = HorizontalPoolText(id: "r", text: "$REFDES",
            placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: 3.75 * mm), angle: 0, mirrored: false))
        symbol.drawing.texts["v"] = HorizontalPoolText(id: "v", text: "$VALUE",
            placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: -3.75 * mm), angle: 0, mirrored: false))
        let placed: [(String, Double, Double, HorizontalPinOrientation)] = [
            ("A", -5, 0, .left), ("B", 5, 0, .right), ("C", 0, 2.5, .up), ("D", 0, -2.5, .down)
        ]
        var unitPins = [String: HorizontalUnitPin]()
        for (name, x, y, orientation) in placed {
            symbol.pins[name] = HorizontalSymbolPin(id: name, position: HorizontalPoint(x: x * mm, y: y * mm), orientation: orientation,
                                                    nameOrientation: [.up, .down].contains(orientation) ? .horizontal : .inLine)
            unitPins[name] = HorizontalUnitPin(id: name, primaryName: "Pin \(name)")
        }
        return (symbol, HorizontalPoolUnit(uuid: "unit", name: "Unit", pins: unitPins))
    }

    func testAWellDrawnBoxSymbolPasses() {
        let (symbol, unit) = boxSymbol()
        XCTAssertEqual(symbol.validationIssues(unit: unit), [])
    }

    func testTextsMustBeSymmetricAndClearOfTheBox() {
        var (symbol, unit) = boxSymbol()
        symbol.drawing.texts["v"]?.placement.shift = HorizontalPoint(x: 1.25 * mm, y: -5 * mm)
        symbol.drawing.texts["r"]?.size = 2 * mm
        let messages = symbol.validationIssues(unit: unit).map(\.message)
        XCTAssertTrue(messages.contains("Refdes and value text should be at same X position"), "\(messages)")
        XCTAssertTrue(messages.contains("Refdes and value text should be at mirrored Y position"))
        XCTAssertTrue(messages.contains("Value should be 1.25mm below symbol box"))
        XCTAssertTrue(messages.contains("Refdes text must have 0 line width and 1.5mm size"))
        // Upside down, and one too many.
        symbol.drawing.texts["v"]?.placement.shift = HorizontalPoint(x: 0, y: 3.75 * mm)
        symbol.drawing.texts["r"]?.placement.shift = HorizontalPoint(x: 0, y: -3.75 * mm)
        XCTAssertTrue(symbol.validationIssues(unit: unit).map(\.message).contains("Refdes should be above value"))
        symbol.drawing.texts["r2"] = HorizontalPoolText(id: "r2", text: "$REFDES", placement: .identity)
        XCTAssertTrue(symbol.validationIssues(unit: unit).map(\.message).contains("Symbol has 2 reference designators, need 1"))
    }

    func testPinsLieOnTheirRectangleOnGridApartAndPointingOut() {
        var (symbol, unit) = boxSymbol()
        symbol.pins["A"]?.position = HorizontalPoint(x: -2.5 * mm, y: 0)        // inside the rectangle
        symbol.pins["B"]?.orientation = .left                                   // pointing in
        symbol.pins["C"]?.position = HorizontalPoint(x: 0.5 * mm, y: 2.5 * mm)  // off the 1.25 mm grid
        symbol.pins["D"]?.position = HorizontalPoint(x: 5 * mm, y: 0)           // on top of B
        unit.pins["E"] = HorizontalUnitPin(id: "E", primaryName: "Pin E")      // never placed
        let issues = symbol.validationIssues(unit: unit)
        let messages = issues.map(\.message)
        XCTAssertTrue(messages.contains("Pin Pin A is not on bounding box"), "\(messages)")
        XCTAssertTrue(messages.contains("Pin Pin B has improper orientation"))
        XCTAssertTrue(messages.contains("Pin Pin C is off-grid, residual: 0.5 mm, 0 mm"))
        XCTAssertTrue(messages.contains("Overlapping pins: Pin B, Pin D"))
        XCTAssertTrue(messages.contains("Pin Pin E is not placed"))
        XCTAssertEqual(issues.first { $0.message == "Pin Pin A is not on bounding box" }?.location, HorizontalPoint(x: -2.5 * mm, y: 0))
        XCTAssertEqual(issues.first { $0.message.hasPrefix("Pin Pin E") }?.level, .failure)
    }

    func testAVerticalPinKeepsItsNameHorizontal() {
        var (symbol, unit) = boxSymbol()
        symbol.pins["C"]?.nameOrientation = .inLine
        symbol.pins["D"]?.nameOrientation = .perpendicular
        let messages = symbol.validationIssues(unit: unit).map(\.message)
        XCTAssertTrue(messages.contains("Pin Pin C points up; its name should be horizontal"), "\(messages)")
        XCTAssertTrue(messages.contains("Pin Pin D points down; its name should be horizontal"))
        // A hidden name draws nothing to read.
        symbol.pins["C"]?.nameVisible = false
        XCTAssertFalse(symbol.validationIssues(unit: unit).map(\.message).contains { $0.hasPrefix("Pin Pin C points") })
    }

    func testALooseJunctionIsReportedAndPinsGoByUuidWithoutTheUnit() {
        var (symbol, _) = boxSymbol()
        symbol.drawing.junctions["loose"] = HorizontalPoint(x: 1.25 * mm, y: 1.25 * mm)
        symbol.pins["B"]?.orientation = .up
        let messages = symbol.validationIssues(unit: nil).map(\.message)
        XCTAssertTrue(messages.contains("Junction has no connections"), "\(messages)")
        XCTAssertTrue(messages.contains("Pin B has improper orientation"))
        XCTAssertFalse(messages.contains { $0.hasSuffix("is not placed") })
    }
}
