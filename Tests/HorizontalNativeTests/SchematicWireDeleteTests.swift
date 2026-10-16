import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Deleting a wire takes a pin off its net when it was the last wire ending
/// on it, as Horizon's `Schematic::delete_net_line` does.
final class SchematicWireDeleteTests: XCTestCase {
    /// One symbol whose pin `a` is wired to a junction on net "net", with a
    /// second wire to another junction when `wires` is 2.
    private func project(wires: Int) throws -> (project: HorizontalProject, archive: HorizontalProjectArchive) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wire-delete-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")
        var archive = HorizontalProjectArchive.newProject()
        func put(_ path: String, _ json: JSONDictionary) throws {
            try archive.replaceRegularFileData(relativePath: path, with: JSONSerialization.data(withJSONObject: json))
        }
        var schematic = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))) as? JSONDictionary)
        let sheetID = try XCTUnwrap(schematic.dictionaryMap("sheets").keys.first)
        var netLines: JSONDictionary = ["wire": ["from": ["pin": "symbol/a"], "to": ["junc": "left"]]]
        if wires == 2 {
            netLines["other"] = ["from": ["pin": "symbol/a"], "to": ["junc": "down"]]
        }
        schematic["sheets"] = [sheetID: [
            "name": "Sheet", "index": 1,
            "symbols": ["symbol": ["symbol": "part-symbol", "component": "component", "gate": "gate",
                                    "placement": ["shift": [0, 0], "angle": 0, "mirror": false]]],
            "junctions": ["left": ["position": [-2_500_000, 0], "net": "net"],
                          "down": ["position": [0, -2_500_000], "net": "net"]],
            "net_lines": netLines,
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
        return (try HorizontalProject.load(from: url), archive)
    }

    private func connectorIDs(_ sheet: HorizontalSchematicSheet) -> [String] {
        sheet.symbolPins.map { $0.id.lowercased() }.filter { $0.hasPrefix("symbol/pin-connector/a") }
    }

    private func blockConnections(_ archive: HorizontalProjectArchive) throws -> JSONDictionary {
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))) as? JSONDictionary)
        return block.dictionaryMap("components")["component"]?.dictionaryMap("connections") ?? [:]
    }

    func testDeletingThePinsOnlyWireLeavesItUnconnectedAndSavesThat() throws {
        let fixture = try project(wires: 1)
        let project = fixture.project
        var archive = fixture.archive
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        XCTAssertTrue(connectorIDs(sheet).isEmpty, "a connected pin draws no connector mark")

        let before = sheet.netLines
        sheet.netLines.removeAll { $0.id.lowercased() == "wire" }
        sheet.disconnectPinsLeftWithoutWires(netLinesBefore: before)

        XCTAssertNil(sheet.componentInfo["component"]?.connections["gate/a"])
        XCTAssertEqual(sheet.removedConnections, ["component": ["gate/a"]])
        XCTAssertEqual(connectorIDs(sheet).count, 4, "the open box of an unconnected pin")
        XCTAssertNil(sheet.symbolPins.first { $0.id.lowercased() == "symbol/pin/a" }?.netID)
        XCTAssertFalse(HorizontalSchematicWarnings.evaluate(sheet).flatMap(\.messages).contains { $0.hasPrefix("Pin connected to net") })

        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        XCTAssertNil(try blockConnections(archive)["gate/a"])
        let reloaded = try XCTUnwrap(HorizontalProject.loadSnapshot(of: archive).schematic?.sheets.first)
        XCTAssertEqual(connectorIDs(reloaded).count, 4)
    }

    func testAPinWithAnotherWireStaysOnItsNet() throws {
        let (project, archive) = try project(wires: 2)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let before = sheet.netLines
        sheet.netLines.removeAll { $0.id.lowercased() == "wire" }
        sheet.disconnectPinsLeftWithoutWires(netLinesBefore: before)

        XCTAssertEqual(sheet.componentInfo["component"]?.connections["gate/a"]?.netID, "net")
        XCTAssertTrue(sheet.removedConnections.isEmpty)
        XCTAssertTrue(connectorIDs(sheet).isEmpty)
        var saved = archive
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &saved)
        XCTAssertEqual(try blockConnections(saved)["gate/a"].flatMap { ($0 as? JSONDictionary)?.string("net") }, "net")
    }

    func testAPinConnectedAgainBeforeSavingKeepsItsConnection() throws {
        var (project, archive) = try project(wires: 1)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let before = sheet.netLines
        sheet.netLines.removeAll { $0.id.lowercased() == "wire" }
        sheet.disconnectPinsLeftWithoutWires(netLinesBefore: before)
        // Drawn to again before the save: the connection is back.
        sheet.netLines = before
        sheet.componentInfo["component"]?.connections["gate/a"] = .connected("net")

        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: project.schematic!.url, in: project, to: &archive)
        XCTAssertEqual(try blockConnections(archive)["gate/a"].flatMap { ($0 as? JSONDictionary)?.string("net") }, "net")
        project = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertTrue(connectorIDs(try XCTUnwrap(project.schematic?.sheets.first)).isEmpty)
    }
}
