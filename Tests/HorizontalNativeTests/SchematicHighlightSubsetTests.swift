import XCTest
@testable import HorizontalNative

/// A schematic highlight draws what it highlights again over the dimmed
/// sheet, as the sheet draws it, so it changes nothing it shows.
/// `SchematicHighlightSubset` is what it draws: the highlighted nets and the
/// highlighted components' symbols, and nothing else.
final class SchematicHighlightSubsetTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func wire(_ id: String, net: String?) -> HorizontalSegment {
        HorizontalSegment(id: id, from: p(0, 0), to: p(5_000_000, 0), width: 0, layer: nil, netID: net)
    }

    private func makeSheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.netLines = [wire("w-gnd", net: "GND"), wire("w-vcc", net: "VCC")]
        sheet.netLabels = [
            HorizontalSchematicNetLabel(id: "l-gnd", text: "GND", position: p(0, 0), size: 1_500_000, orientation: "right", netID: "GND"),
            HorizontalSchematicNetLabel(id: "l-vcc", text: "VCC", position: p(0, 0), size: 1_500_000, orientation: "right", netID: "VCC")
        ]
        sheet.junctions = ["J-GND": p(0, 0), "j-vcc": p(5_000_000, 0)]
        sheet.junctionNetIDs = ["j-gnd": "GND", "j-vcc": "VCC"]
        sheet.symbols = [
            HorizontalPlacement(id: "sym1", position: p(0, 0), angle: 0, mirrored: false, label: "U1", componentID: "U1-ID", smashedTextIDs: ["smashed-u1"]),
            HorizontalPlacement(id: "sym2", position: p(9_000_000, 0), angle: 0, mirrored: false, label: "R1", componentID: "r1-id")
        ]
        sheet.symbolLines = [
            HorizontalSegment(id: "sym1/line/body", from: p(0, 0), to: p(1, 1), width: 0, layer: nil),
            HorizontalSegment(id: "sym2/line/body", from: p(0, 0), to: p(1, 1), width: 0, layer: nil)
        ]
        sheet.symbolPins = [
            HorizontalSegment(id: "sym1/pin/a", from: p(0, 0), to: p(1, 0), width: 0, layer: nil, netID: "GND"),
            HorizontalSegment(id: "sym1/pin/b", from: p(0, 0), to: p(1, 0), width: 0, layer: nil, netID: "VCC"),
            HorizontalSegment(id: "sym2/pin/a", from: p(0, 0), to: p(1, 0), width: 0, layer: nil, netID: "GND"),
            HorizontalSegment(id: "sym2/pin/b", from: p(0, 0), to: p(1, 0), width: 0, layer: nil, netID: "VCC")
        ]
        sheet.texts = [
            HorizontalText(id: "smashed-u1", text: "U1", position: p(0, 0), size: 1_500_000, layer: nil),
            HorizontalText(id: "note", text: "note", position: p(0, 0), size: 1_500_000, layer: nil)
        ]
        sheet.frameLines = [wire("frame", net: nil)]
        return sheet
    }

    func testANetsHighlightIsItsWiringAndItsPins() {
        let subset = SchematicHighlightSubset.sheet(makeSheet(), netIDs: ["gnd"], componentIDs: [])
        XCTAssertEqual(subset.netLines.map(\.id), ["w-gnd"], "ids are matched lowercased")
        XCTAssertEqual(subset.netLabels.map(\.id), ["l-gnd"])
        XCTAssertEqual(Array(subset.junctions.keys), ["J-GND"], "a junction's net is found whatever its id's case")
        XCTAssertEqual(subset.symbolPins.map(\.id), ["sym1/pin/a", "sym2/pin/a"], "the pins on the net, not their symbols")
        XCTAssertTrue(subset.symbols.isEmpty)
        XCTAssertTrue(subset.symbolLines.isEmpty)
        XCTAssertTrue(subset.texts.isEmpty)
        XCTAssertTrue(subset.frameLines.isEmpty, "the frame is no part of a net")
    }

    func testAComponentsHighlightIsItsSymbolWhole() {
        let subset = SchematicHighlightSubset.sheet(makeSheet(), netIDs: [], componentIDs: ["u1-id"])
        XCTAssertEqual(subset.symbols.map(\.id), ["sym1"])
        XCTAssertEqual(subset.symbolLines.map(\.id), ["sym1/line/body"])
        XCTAssertEqual(subset.symbolPins.map(\.id), ["sym1/pin/a", "sym1/pin/b"], "every pin, whatever its net")
        XCTAssertEqual(subset.texts.map(\.id), ["smashed-u1"], "its smashed texts, which are the sheet's")
        XCTAssertTrue(subset.netLines.isEmpty)
        XCTAssertTrue(subset.junctions.isEmpty)
    }
}
