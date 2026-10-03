import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The persistence half of the navigator's sheet rename / reorder commands.
final class HorizontalSheetEditingTests: XCTestCase {
    func testRenamingASheetPatchesTheSchematicJSON() throws {
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")
        let sheetID = try XCTUnwrap(project.schematic?.sheets.first?.id)

        try HorizontalProjectJSONApplicator.apply(
            sheetName: "Power Supply",
            forSheetID: sheetID,
            schematicURL: schematicURL,
            in: project,
            to: &archive
        )

        let sheets = try sheetsJSON(in: archive)
        XCTAssertEqual((sheets[sheetID] as? [String: Any])?["name"] as? String, "Power Supply")
    }

    func testReorderingSheetsRewritesTheirIndices() throws {
        let packageURL = try writtenTemplate()
        // Grow the template to two sheets so there is an order to change.
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")
        var schematicJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: schematicURL)) as? [String: Any]
        )
        var sheets = try XCTUnwrap(schematicJSON["sheets"] as? [String: Any])
        let firstID = try XCTUnwrap(sheets.keys.first)
        let secondID = "00000000-0000-0000-0000-00000000000b"
        sheets[secondID] = ["name": "Sheet 2", "index": 2]
        schematicJSON["sheets"] = sheets
        try JSONSerialization.data(withJSONObject: schematicJSON).write(to: schematicURL)

        let project = try HorizontalProject.load(from: packageURL)
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)

        try HorizontalProjectJSONApplicator.apply(
            sheetOrder: [secondID, firstID],
            schematicURL: schematicURL,
            in: project,
            to: &archive
        )

        let patched = try sheetsJSON(in: archive)
        XCTAssertEqual((patched[secondID] as? [String: Any])?["index"] as? Int, 1)
        XCTAssertEqual((patched[firstID] as? [String: Any])?["index"] as? Int, 2)
    }

    /// The page number, page count and title are baked into the title block,
    /// and page numbers into net labels' off-sheet references, when the project
    /// loads. Reordering or renaming in the navigator patches the archive and
    /// reloads it, so the drawing says the new numbers — patching the sheet
    /// model alone left the old ones showing.
    func testReloadedSheetsRedrawTheirNumbersAndTitles() throws {
        let packageURL = try writtenTemplate()
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: packageURL)
        var frame = HorizontalPoolItemFactory.newFrame().json()
        frame["texts"] = [UUID().uuidString.lowercased(): [
            "text": "$sheet_title $sheet_idx/$sheet_total", "size": 2_000_000, "width": 0,
            "origin": "baseline", "font": "simplex",
            "placement": ["angle": 0, "mirror": false, "shift": [10_000_000, 10_000_000]]
        ] as JSONDictionary]
        let frameID = try XCTUnwrap(frame.string("uuid"))
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": entry.handle, "expected_revision": entry.revision, "operation_id": UUID().uuidString,
            "pool_items": [frame],
            "ops": [["op": "add_sheet", "name": "Power", "frame": frameID],
                    ["op": "add_sheet", "name": "Analog"],
                    ["op": "ensure_net", "name": "VIN"],
                    ["op": "place_net_label", "net": "VIN", "sheet": "Power", "x_mm": 10, "y_mm": 10],
                    ["op": "place_net_label", "net": "VIN", "sheet": "Analog", "x_mm": 10, "y_mm": 10]]
        ]], in: session)
        XCTAssertNil(response["error"], "\(response)")

        func drawn(_ project: HorizontalProject, _ name: String) throws -> (title: [String], label: String?) {
            let sheet = try XCTUnwrap(project.schematic?.sheets.first { $0.name == name })
            return (sheet.frameTexts.map(\.text), sheet.netLabels.first?.text)
        }
        let project = try HorizontalProject.load(from: packageURL)
        XCTAssertEqual(try drawn(project, "Analog").title, ["Analog 3/3"])
        XCTAssertEqual(try drawn(project, "Power").label, "VIN [3]")

        let ids = try XCTUnwrap(project.schematic?.sheets.sorted { $0.index < $1.index }.map(\.id))
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        try HorizontalProjectJSONApplicator.apply(sheetOrder: [ids[2], ids[0], ids[1]], schematicURL: schematicURL,
                                                  in: project, to: &archive)
        try HorizontalProjectJSONApplicator.apply(sheetName: "Analog Front End", forSheetID: ids[2],
                                                  schematicURL: schematicURL, in: project, to: &archive)
        let reloaded = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertEqual(try drawn(reloaded, "Analog Front End").title, ["Analog Front End 1/3"])
        XCTAssertEqual(try drawn(reloaded, "Power").title, ["Power 3/3"])
        XCTAssertEqual(try drawn(reloaded, "Power").label, "VIN [1]")
    }

    // MARK: - Helpers

    private func sheetsJSON(in archive: HorizontalProjectArchive) throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["sheets"] as? [String: Any])
    }

    private func writtenTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-sheet-editing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }
}
