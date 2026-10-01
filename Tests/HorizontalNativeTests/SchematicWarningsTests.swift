import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

final class SchematicWarningsTests: XCTestCase {
    private func sheet() -> HorizontalSchematicSheet {
        HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
    }
    private func messages(_ sheet: HorizontalSchematicSheet) -> Set<String> {
        Set(HorizontalSchematicWarnings.evaluate(sheet).flatMap(\.messages))
    }
    private func net(_ id: String, name: String, power: Bool = false) -> HorizontalNetDetails {
        .init(id: id, name: name, netClassID: nil, netClassName: nil, isPower: power)
    }

    func testConnectedWireEndpointIsNotAPinOnLineWarningButCrossingWireIs() {
        var sheet = sheet()
        sheet.symbolPins = [.init(id: "s/pin/p", from: .zero, to: .init(x: 100, y: 0), width: 0, layer: nil, netID: "n")]
        sheet.netLines = [.init(id: "wire", from: .zero, to: .init(x: -100, y: 0), width: 0, layer: nil, netID: "n",
                               schematicFrom: .pin("s/p"), schematicTo: .junction("j"))]
        XCTAssertFalse(messages(sheet).contains("Pin on line"))
        XCTAssertFalse(messages(sheet).contains("Pin connected to net: n"))
        sheet.netLines[0].from = .init(x: 100, y: 0)
        sheet.netLines[0].schematicFrom = .junction("other")
        XCTAssertTrue(messages(sheet).contains("Pin on line"))
        XCTAssertTrue(messages(sheet).contains("Pin connected to net: n"))
    }

    func testPinLabelZeroWireWarningsDisappearAfterMovingLabel() {
        var sheet = sheet()
        sheet.junctions = ["j": .zero]
        sheet.netLabels = [.init(id: "label", text: "N", position: .zero, size: 100, orientation: "left", netID: "n", junctionID: "j")]
        sheet.symbolPins = [.init(id: "s/pin/p", from: .zero, to: .init(x: 100, y: 0), width: 0, layer: nil, netID: "n")]
        sheet.netLines = [.init(id: "wire", from: .zero, to: .zero, width: 0, layer: nil, netID: "n",
                               schematicFrom: .pin("s/p"), schematicTo: .junction("j"))]
        XCTAssertEqual(messages(sheet), ["Pin on junction", "Zero length line"])
        SchematicMovePlanner.movePinLabels(at: .zero, by: .init(x: -100, y: 0), selected: [.init(id: "label", type: .netLabel)], sheet: &sheet)
        XCTAssertTrue(messages(sheet).isEmpty)
    }

    func testPinDecorationsDoNotProduceDuplicatePinWarnings() {
        var sheet = sheet()
        sheet.symbolPins = [.init(id: "s/pin/p", from: .zero, to: .init(x: 100, y: 0), width: 0, layer: nil),
                            .init(id: "s/pin-decoration/p", from: .zero, to: .init(x: 50, y: 0), width: 0, layer: nil)]
        XCTAssertTrue(messages(sheet).isEmpty)
        sheet.symbolPins.append(.init(id: "other/pin/p", from: .zero, to: .init(x: -100, y: 0), width: 0, layer: nil))
        XCTAssertTrue(messages(sheet).contains("Pin on pin"))
    }

    func testMissingLabelsAreCheckedPerConnectedSegmentAndPowerSymbolsCountAsLabels() {
        var sheet = sheet()
        sheet.netDetails = ["n": net("n", name: "VCC", power: true)]
        sheet.junctions = ["a": .zero, "b": .init(x: 100, y: 0), "c": .init(x: 200, y: 0)]
        sheet.junctionNetIDs = ["a": "n", "b": "n", "c": "n"]
        sheet.netLines = [.init(id: "wire", from: .zero, to: .init(x: 100, y: 0), width: 0, layer: nil, netID: "n",
                               schematicFrom: .junction("a"), schematicTo: .junction("b"))]
        sheet.powerSymbols = [.init(id: "power", junctionID: "a", netID: "n", orientation: "up", mirrored: false)]
        let warnings = HorizontalSchematicWarnings.evaluate(sheet)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.position, .init(x: 200, y: 0))
        XCTAssertEqual(Set(warnings.first?.messages ?? []), ["Label missing", "Power sym missing"])
    }

    func testStaleGroundWireMetadataDoesNotMakeReferenceNetAPowerSegment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-wire-\(UUID().uuidString).horizontal")
        defer { try? FileManager.default.removeItem(at: root) }
        var archive = HorizontalProjectArchive.newProject()
        var block = try HorizontalSchematicClipboardEditor.read("top_block.json", archive: archive)
        block["nets"] = ["gnd": ["name": "GND", "is_power": true],
                         "vref": ["name": "VREF 2V5", "is_power": false, "power_symbol_style": "gnd"]]
        try HorizontalSchematicClipboardEditor.write(block, path: "top_block.json", archive: &archive)
        var schematic = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
        let id = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        schematic["sheets"] = [id: [
            "name": "Sheet", "index": 1,
            "junctions": ["a": ["position": [0, 0], "net": "vref"],
                          "b": ["position": [2_000_000, 0]],
                          "c": ["position": [4_000_000, 0]],
                          "ground": ["position": [0, 0], "net": "gnd"]],
            "net_lines": ["wire": ["from": ["junc": "a"], "to": ["junc": "b"], "net": "gnd"],
                          "continuation": ["from": ["junc": "b"], "to": ["junc": "c"], "net": "gnd"]],
            "net_labels": ["label": ["junction": "a", "last_net": "vref", "size": 1_000_000]],
            "power_symbols": ["power": ["junction": "ground", "net": "gnd", "orientation": "down"]]
        ]]
        try HorizontalSchematicClipboardEditor.write(schematic, path: "top_schematic.json", archive: &archive)
        try archive.write(to: root)
        let baseline = try HorizontalProjectArchive.snapshot(from: root)
        let project = try HorizontalProject.load(from: root)
        let sheet = try XCTUnwrap(project.schematic?.sheets.first)
        XCTAssertEqual(sheet.netDetails["vref"]?.isPower, false)
        XCTAssertEqual(Set(sheet.netLines.compactMap(\.netID)), ["vref"])
        XCTAssertFalse(messages(sheet).contains("Power sym missing"))
        XCTAssertEqual(try HorizontalProjectArchive.snapshot(from: root), baseline, "Loading must not modify project files")
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        let saved = try HorizontalSchematicClipboardEditor.read("top_schematic.json", archive: archive)
        XCTAssertTrue(saved.dictionaryMap("sheets")[id]!.dictionaryMap("net_lines").values.allSatisfy { $0.string("net") == "vref" })
        let reloaded = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).schematic?.sheets.first)
        XCTAssertFalse(messages(reloaded).contains("Power sym missing"))
    }

    func testUnnamedDisconnectedNetAndDuplicateNamesWarn() {
        var sheet = sheet()
        sheet.netDetails = ["n": net("n", name: "")]
        sheet.junctions = ["a": .zero, "b": .init(x: 100, y: 0)]
        sheet.junctionNetIDs = ["a": "n", "b": "n"]
        XCTAssertTrue(messages(sheet).contains("Ambiguous nets"))
        sheet.netDetails = ["n": net("n", name: "Signal"), "other": net("other", name: " signal ")]
        XCTAssertTrue(messages(sheet).contains("Duplicate net name"))
    }

    func testGraphicLineArcAndNetTieWarnings() {
        var sheet = sheet()
        sheet.junctions = ["a": .zero, "b": .init(x: 100, y: 0)]
        sheet.junctionNetIDs = ["a": "n", "b": "n"]
        sheet.netLabels = [.init(id: "label", text: "N", position: .zero, size: 10, orientation: "left", netID: "n")]
        sheet.drawingLines = [.init(id: "graphic", from: .zero, to: .init(x: 0, y: 100), width: 0, layer: nil)]
        sheet.drawingArcs = [.init(id: "arc", from: .zero, to: .init(x: 0, y: 100), center: .init(x: 50, y: 50), width: 0, layer: nil)]
        sheet.netTies = [.init(id: "tie", from: .zero, to: .init(x: 100, y: 0), label: "", netIDs: ["n", "other"])]
        XCTAssertTrue(messages(sheet).contains("Graphic line connected to junction with net/bus"))
        XCTAssertTrue(messages(sheet).contains("Arc connected to junction with net/bus"))
        XCTAssertTrue(messages(sheet).contains("Net tie connected to incorrect net"))
        sheet.netTies[0].to = .zero
        XCTAssertTrue(messages(sheet).contains("Zero length net tie"))
    }

    func testPortLabelsOnOtherSheetsSatisfyPortWarning() {
        var sheet = sheet()
        sheet.netDetails = ["n": .init(id: "n", name: "SIGNAL", netClassID: nil, netClassName: nil, isPort: true)]
        sheet.junctions = ["j": .zero]
        sheet.junctionNetIDs = ["j": "n"]
        XCTAssertTrue(messages(sheet).contains("Need 'show port' net label"))
        var other = sheet
        other.id = "other"
        other.netLabels = [.init(id: "label", text: "SIGNAL", position: .zero, size: 10, orientation: "left", netID: "n", showsPort: true)]
        XCTAssertFalse(HorizontalSchematicWarnings.evaluate(sheet, allSheets: [sheet, other]).flatMap(\.messages).contains("Need 'show port' net label"))
    }

    func testBlockPortsAndBusRippersWarnAtTheirAnchors() {
        var sheet = sheet()
        sheet.blockSymbolPorts = [.init(id: "block/block-port/p", from: .zero, to: .init(x: 100, y: 0), width: 0, layer: nil, netID: "n")]
        sheet.junctions = ["bus-junction": .init(x: 200, y: 0)]
        sheet.warningContext.busRippers = ["r": .init(junctionID: "bus-junction", busID: "bus")]
        sheet.warningContext.missingPorts = ["block": ["OUT"]]
        XCTAssertTrue(messages(sheet).contains("Port connected to net: n"))
        XCTAssertTrue(messages(sheet).contains("Bus ripper connected to wrong net line"))
        XCTAssertTrue(messages(sheet).contains("Missing ports: OUT"))
        sheet.warningContext.junctionBusIDs["bus-junction"] = "bus"
        XCTAssertFalse(messages(sheet).contains("Bus ripper connected to wrong net line"))
    }
}
