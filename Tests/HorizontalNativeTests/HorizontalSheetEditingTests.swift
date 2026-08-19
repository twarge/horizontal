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
