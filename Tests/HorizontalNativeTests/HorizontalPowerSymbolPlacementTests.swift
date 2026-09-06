import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The model half of the place-power-symbol tool: the artwork a placed
/// symbol gets, and how a placement reaches the schematic and block JSON.
final class HorizontalPowerSymbolPlacementTests: XCTestCase {
    private let mm = 1_000_000.0

    private func writtenTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-power-symbol-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }

    /// A template sheet with one power net "GND" (drawn as ground) and one
    /// power symbol on a junction at `position`.
    private func sheetWithPowerSymbol(at position: HorizontalPoint, style: String = "gnd", orientation: String? = nil) throws -> (sheet: HorizontalSchematicSheet, project: HorizontalProject, packageURL: URL) {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var sheet = try XCTUnwrap(project.schematic?.sheets.first)
        sheet.netDetails["net-gnd"] = HorizontalNetDetails(
            id: "net-gnd",
            name: "GND",
            netClassID: sheet.netClasses.first?.id,
            netClassName: sheet.netClasses.first?.name,
            isPower: true,
            powerSymbolStyle: style
        )
        sheet.junctions["junction-1"] = position
        sheet.junctionNetIDs["junction-1"] = "net-gnd"
        sheet.powerSymbols.append(HorizontalPowerSymbol(
            id: "power-1",
            junctionID: "junction-1",
            netID: "net-gnd",
            orientation: orientation ?? HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: style),
            mirrored: false
        ))
        sheet.rebakePowerSymbol(id: "power-1")
        return (sheet, project, packageURL)
    }

    func testGroundHangsDownFromItsJunctionAndDotsStandUp() throws {
        XCTAssertEqual(HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: "gnd"), "down")
        XCTAssertEqual(HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: "earth"), "down")
        XCTAssertEqual(HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: "dot"), "up")
        XCTAssertEqual(HorizontalSchematicSheet.defaultPowerSymbolOrientation(forStyle: "antenna"), "up")

        let position = HorizontalPoint(x: 10 * mm, y: 20 * mm)
        let ground = try sheetWithPowerSymbol(at: position).sheet
        let lines = ground.powerSymbolLines.filter { $0.id.hasPrefix("power-1/") }
        XCTAssertEqual(lines.count, 4, "stem, bar and two legs")
        let stem = try XCTUnwrap(lines.first { $0.id == "power-1/gnd/stem" })
        XCTAssertEqual(stem.from, position)
        XCTAssertEqual(stem.to.y, position.y - 1.25 * mm, accuracy: 1)
        XCTAssertEqual(stem.netID, "net-gnd")
        XCTAssertEqual(ground.powerSymbolTexts.first { $0.id.hasPrefix("power-1/") }?.text, "GND")

        let dot = try sheetWithPowerSymbol(at: position, style: "dot").sheet
        let dotStem = try XCTUnwrap(dot.powerSymbolLines.first { $0.id == "power-1/dot/stem" })
        XCTAssertEqual(dotStem.to.y, position.y + 1 * mm, accuracy: 1)
        XCTAssertEqual(dot.powerSymbolCircles.filter { $0.id.hasPrefix("power-1/") }.count, 1)
    }

    func testRebakingFollowsTheJunctionAndReplacesTheOldArtwork() throws {
        var (sheet, _, _) = try sheetWithPowerSymbol(at: HorizontalPoint(x: 0, y: 0))
        sheet.junctions["junction-1"] = HorizontalPoint(x: 5 * mm, y: 5 * mm)
        sheet.rebakePowerSymbol(id: "power-1")
        let lines = sheet.powerSymbolLines.filter { $0.id.hasPrefix("power-1/") }
        XCTAssertEqual(lines.count, 4, "the old artwork is gone")
        XCTAssertEqual(lines.first { $0.id == "power-1/gnd/stem" }?.from, HorizontalPoint(x: 5 * mm, y: 5 * mm))
        XCTAssertEqual(sheet.powerSymbolTexts.filter { $0.id.hasPrefix("power-1/") }.count, 1)

        // A net that hides the name draws no text.
        sheet.netDetails["net-gnd"]?.powerSymbolNameVisible = false
        sheet.rebakePowerSymbol(id: "power-1")
        XCTAssertTrue(sheet.powerSymbolTexts.filter { $0.id.hasPrefix("power-1/") }.isEmpty)
    }

    func testAPlacedSymbolItsJunctionAndItsNewPowerNetReachTheJSON() throws {
        let position = HorizontalPoint(x: 12.5 * mm, y: -7.5 * mm)
        let (sheet, project, packageURL) = try sheetWithPowerSymbol(at: position, orientation: "up")
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")

        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematicURL, in: project, to: &archive)

        let schematic = try json(in: archive, at: "top_schematic.json")
        let sheets = try XCTUnwrap(schematic["sheets"] as? [String: Any])
        let sheetJSON = try XCTUnwrap(sheets[sheet.id] as? [String: Any])
        let symbols = try XCTUnwrap(sheetJSON["power_symbols"] as? [String: Any])
        let symbol = try XCTUnwrap(symbols["power-1"] as? [String: Any], "a placed symbol is a new entry")
        XCTAssertEqual(symbol["junction"] as? String, "junction-1")
        XCTAssertEqual(symbol["net"] as? String, "net-gnd")
        XCTAssertEqual(symbol["orientation"] as? String, "up")
        XCTAssertEqual(symbol["mirror"] as? Bool, false)
        let junctions = try XCTUnwrap(sheetJSON["junctions"] as? [String: Any])
        let junction = try XCTUnwrap(junctions["junction-1"] as? [String: Any])
        XCTAssertEqual(junction["net"] as? String, "net-gnd")

        let block = try json(in: archive, at: "top_block.json")
        let nets = try XCTUnwrap(block["nets"] as? [String: Any])
        let net = try XCTUnwrap(nets["net-gnd"] as? [String: Any], "the power net is written to the block")
        XCTAssertEqual(net["name"] as? String, "GND")
        XCTAssertEqual(net["is_power"] as? Bool, true)
        XCTAssertEqual(net["power_symbol_style"] as? String, "gnd")

        // Loading it back draws the symbol again.
        try archive.write(to: packageURL)
        let reloaded = try HorizontalProject.load(from: packageURL)
        let reloadedSheet = try XCTUnwrap(reloaded.schematic?.sheets.first)
        XCTAssertEqual(reloadedSheet.powerSymbols.map(\.id), ["power-1"])
        XCTAssertEqual(reloadedSheet.powerSymbols.first?.orientation, "up")
        XCTAssertEqual(reloadedSheet.powerSymbolLines.filter { $0.id.hasPrefix("power-1/") }.count, 4)
        XCTAssertEqual(reloadedSheet.netDetails["net-gnd"]?.isPower, true)
    }

    private func json(in archive: HorizontalProjectArchive, at path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
