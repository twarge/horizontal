import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

final class SchematicPinLabelTests: XCTestCase {
    private let anchor = HorizontalPoint(x: 0, y: 0)
    private let destination = HorizontalPoint(x: -2_500_000, y: 1_250_000)
    private let selection = [HorizontalSelectableRef(id: "label", type: .netLabel)]

    private func sheet(zeroWire: Bool = true, reversed: Bool = false) -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.junctions = ["label-junction": anchor]
        sheet.junctionNetIDs = ["label-junction": "net"]
        sheet.netLabels = [.init(id: "label", text: "SIGNAL", position: anchor, size: 1_000_000,
                                orientation: "left", netID: "net", junctionID: "label-junction")]
        sheet.symbolPins = [.init(id: "symbol/pin/a", from: anchor, to: .init(x: 1_250_000, y: 0),
                                 width: 0, layer: nil, netID: "net")]
        if zeroWire {
            sheet.netLines = [.init(id: "wire", from: anchor, to: anchor, width: 0, layer: nil, netID: "net",
                                   schematicFrom: reversed ? .junction("label-junction") : .pin("symbol/a"),
                                   schematicTo: reversed ? .pin("symbol/a") : .junction("label-junction"))]
        }
        return sheet
    }

    func testMovesOnlyJunctionEndOfZeroWireInEitherDirection() throws {
        for reversed in [false, true] {
            var sheet = sheet(reversed: reversed)
            let pins = sheet.symbolPins
            SchematicMovePlanner.preparePinLabels(selected: selection, fixedPointKeys: [HorizontalCanvasModeSupport.pointKey(anchor)], sheet: &sheet)
            SchematicMovePlanner.movePinLabels(at: anchor, by: destination, selected: selection, sheet: &sheet)
            XCTAssertEqual(sheet.netLabels[0].position, destination)
            XCTAssertEqual(sheet.junctions["label-junction"], destination)
            XCTAssertEqual(sheet.symbolPins, pins)
            XCTAssertEqual(sheet.netLines.count, 1)
            XCTAssertEqual(sheet.netLines[0].from, reversed ? destination : anchor)
            XCTAssertEqual(sheet.netLines[0].to, reversed ? anchor : destination)
            XCTAssertEqual(sheet.netLines[0].netID, "net")
        }
    }

    func testMissingWireIsRepresentedByAZeroLengthPinToJunctionWire() {
        var sheet = sheet(zeroWire: false)
        SchematicMovePlanner.preparePinLabels(selected: selection, fixedPointKeys: [HorizontalCanvasModeSupport.pointKey(anchor)], sheet: &sheet)
        XCTAssertEqual(sheet.netLines.count, 1)
        XCTAssertEqual(sheet.netLines[0].length, 0)
        XCTAssertEqual(sheet.netLines[0].schematicFrom, .pin("symbol/a"))
        XCTAssertEqual(sheet.netLines[0].schematicTo, .junction("label-junction"))
        SchematicMovePlanner.movePinLabels(at: anchor, by: destination, selected: selection, sheet: &sheet)
        XCTAssertEqual(sheet.netLines[0].from, anchor)
        XCTAssertEqual(sheet.netLines[0].to, destination)
    }

    func testMovingOneLabelDoesNotMoveAnUnselectedLabelSharingItsJunction() {
        var sheet = sheet()
        var other = sheet.netLabels[0]
        other.id = "other"
        sheet.netLabels.append(other)
        SchematicMovePlanner.preparePinLabels(selected: selection, fixedPointKeys: [HorizontalCanvasModeSupport.pointKey(anchor)], sheet: &sheet)
        SchematicMovePlanner.movePinLabels(at: anchor, by: destination, selected: selection, sheet: &sheet)
        XCTAssertEqual(sheet.netLabels[0].position, destination)
        XCTAssertEqual(sheet.netLabels[1].position, anchor)
        XCTAssertEqual(sheet.junctions["label-junction"], anchor)
        XCTAssertEqual(sheet.netLines[0].length, 0)
        XCTAssertEqual(sheet.netLines.count, 2)
    }

    func testPinEndpointAndMovedLabelSurviveSavingAndReloading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pin-label-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        var archive = HorizontalProjectArchive.newProject()
        func put(_ path: String, _ json: JSONDictionary) throws {
            try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
        }
        var schematic = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))) as? JSONDictionary)
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        schematic["sheets"] = [sheetID: [
            "name": "Sheet", "index": 1,
            "symbols": ["symbol": ["symbol": "part-symbol", "component": "component", "gate": "gate",
                                    "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]],
            "junctions": ["label-junction": ["position": [0, 0], "net": "net"]],
            "net_labels": ["label": ["junction": "label-junction", "last_net": "net", "orientation": "left", "size": 1_000_000]],
            "net_lines": ["wire": ["from": ["pin": "symbol/a"], "to": ["junc": "label-junction"]]],
        ]]
        try put("top_schematic.json", schematic)
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))) as? JSONDictionary)
        block["nets"] = ["net": ["name": "SIGNAL"]]
        block["components"] = ["component": ["refdes": "R1", "value": "", "connections": ["gate/a": ["net": "net"]]]]
        try put("top_block.json", block)
        try put("pool/symbols/cache/part-symbol.json", ["uuid": "part-symbol", "unit": "unit", "pins": [
            "a": ["position": [0, 0], "length": 1_250_000, "orientation": "left", "name_visible": false, "pad_visible": false],
        ]])
        try put("pool/units/cache/unit.json", ["uuid": "unit", "pins": ["a": ["primary_name": "1"]]])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try archive.write(to: url)
        let project = try HorizontalProject.load(from: url)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        XCTAssertEqual(sheet.netLines.first?.schematicFrom, .pin("symbol/a"))
        // A no-op save must not replace a coincident pin endpoint with the junction.
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        var reloaded = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertEqual(reloaded.schematic?.sheets.first?.netLines.first?.schematicFrom, .pin("symbol/a"))
        SchematicMovePlanner.preparePinLabels(selected: selection, fixedPointKeys: [HorizontalCanvasModeSupport.pointKey(anchor)], sheet: &sheet)
        SchematicMovePlanner.movePinLabels(at: anchor, by: destination, selected: selection, sheet: &sheet)
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        reloaded = try HorizontalProject.loadSnapshot(of: archive)
        let saved = try XCTUnwrap(reloaded.schematic?.sheets.first)
        XCTAssertEqual(saved.netLabels.first?.position, destination)
        XCTAssertEqual(saved.netLines.first?.from, anchor)
        XCTAssertEqual(saved.netLines.first?.to, destination)
        XCTAssertEqual(saved.netLines.first?.schematicFrom, .pin("symbol/a"))
        XCTAssertEqual(saved.netLines.first?.netID, "net")
        XCTAssertFalse(HorizontalSchematicWarnings.evaluate(saved).flatMap(\.messages).contains("Zero length line"))
    }
}
