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

    /// The information panel's title-block edit. Older Horizon files, Billo
    /// among them, keep their own copy of the project title in the schematic,
    /// once for the whole schematic and once per sheet, and a copy wins on the
    /// sheets it covers. Changing the block alone left every title block
    /// saying the old name while the board said the new one; the copies change
    /// with it, and the reload redraws both.
    func testATitleBlockEditReachesTheSheetsAndTheBoard() throws {
        let packageURL = try writtenTemplate()
        let session = HorizontalDispatchSession()
        let entry = try session.open(url: packageURL)
        var frame = HorizontalPoolItemFactory.newFrame().json()
        frame["texts"] = [UUID().uuidString.lowercased(): [
            "text": "$project_title R$rev", "size": 2_000_000, "width": 0,
            "origin": "baseline", "font": "simplex",
            "placement": ["angle": 0, "mirror": false, "shift": [10_000_000, 10_000_000]]
        ] as JSONDictionary]
        let frameID = try XCTUnwrap(frame.string("uuid"))
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": entry.handle, "expected_revision": entry.revision, "operation_id": UUID().uuidString,
            "pool_items": [frame],
            "ops": [["op": "add_sheet", "name": "Power", "frame": frameID],
                    ["op": "add_sheet", "name": "Analog"],
                    ["op": "set_project_meta", "values": ["project_title": "Roxanne", "rev": "1B"]],
                    ["op": "place_board_text", "text": "$project_title", "layer": 20, "x_mm": 0, "y_mm": 0]]
        ]], in: session)
        XCTAssertNil(response["error"], "\(response)")

        // The copies an older file keeps: the schematic's own, and Analog's.
        let schematicURL = packageURL.appendingPathComponent("top_schematic.json")
        var schematic = try JSONHelper.loadDictionary(from: schematicURL)
        schematic["title_block_values"] = ["project_title": "Roxanne"]
        var sheets = try XCTUnwrap(schematic["sheets"] as? JSONDictionary)
        let analog = try XCTUnwrap(sheets.first { ($0.value as? JSONDictionary)?.string("name") == "Analog" }?.key)
        var sheet = try XCTUnwrap(sheets[analog] as? JSONDictionary)
        sheet["title_block_values"] = ["project_title": "Roxanne"]
        sheets[analog] = sheet
        schematic["sheets"] = sheets
        try JSONSerialization.data(withJSONObject: schematic, options: [.sortedKeys]).write(to: schematicURL)

        func drawn(_ project: HorizontalProject) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: (project.schematic?.sheets ?? [])
                .filter { !$0.frameTexts.isEmpty }
                .map { ($0.name, $0.frameTexts.map(\.text)) })
        }
        let project = try HorizontalProject.load(from: packageURL)
        XCTAssertEqual(drawn(project), ["Power": ["Roxanne R1B"], "Analog": ["Roxanne R1B"]])

        // What the panel used to do: the block alone. The copies win.
        var blockOnly = try HorizontalProjectArchive.completeProject(from: packageURL)
        var stale = try JSONHelper.loadDictionary(from: XCTUnwrap(blockOnly.regularFileData(relativePath: "top_block.json")))
        stale["project_meta"] = ["project_title": "Billo", "rev": "1B"]
        try blockOnly.replaceRegularFileData(relativePath: "top_block.json", with: JSONSerialization.data(withJSONObject: stale))
        XCTAssertEqual(drawn(try HorizontalProject.loadSnapshot(of: blockOnly)), ["Power": ["Roxanne R1B"], "Analog": ["Roxanne R1B"]])

        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        let changed = try HorizontalProjectJSONApplicator.apply(
            titleBlockChanges: HorizontalTitleBlockChanges(key: "project_title", value: " Billo "), in: project, to: &archive)
        XCTAssertEqual(changed, ["project_title"])
        let reloaded = try HorizontalProject.loadSnapshot(of: archive)
        XCTAssertEqual(drawn(reloaded), ["Power": ["Billo R1B"], "Analog": ["Billo R1B"]])
        XCTAssertEqual(reloaded.board?.texts.map(\.text), ["Billo"])
        XCTAssertEqual(reloaded.projectMeta["project_title"], "Billo")

        // Blank removes a key everywhere it is; a copy is never added to.
        try HorizontalProjectJSONApplicator.apply(titleBlockChanges: HorizontalTitleBlockChanges(key: "rev", value: ""),
                                                  in: reloaded, to: &archive)
        let block = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_block.json")))
        XCTAssertEqual(block.dictionary("project_meta") as? [String: String], ["project_title": "Billo"])
        let copies = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        XCTAssertEqual(copies.dictionary("title_block_values") as? [String: String], ["project_title": "Billo"])
        XCTAssertEqual(try HorizontalProjectJSONApplicator.apply(
            titleBlockChanges: HorizontalTitleBlockChanges(key: "project_title", value: "Billo"), in: reloaded, to: &archive), [],
            "an unchanged value changes nothing, so the app records no undo step for it")
    }

    /// The information panel has a field for every title-block key. It used to
    /// skip a key whose value an earlier field already showed, so on Billo,
    /// whose name and title were both "Roxanne", the name had no field at all
    /// and renaming the title left it behind.
    func testEveryTitleBlockKeyHasItsOwnField() {
        let rows = ProjectMetadataRow.rows(for: ["project_title": "Roxanne", "project_name": "Roxanne", "rev": "1B",
                                                 "author": "Roxanne", "custom_note": "x", "blank": " "])
        XCTAssertEqual(rows.map(\.key), ["project_title", "project_name", "rev", "author", "date", "license", "custom_note"])
        XCTAssertEqual(rows.first { $0.key == "project_name" }?.value, "Roxanne")
        XCTAssertEqual(rows.first { $0.key == "date" }?.value, "", "the usual keys show even when empty")
        XCTAssertEqual(rows.last?.title, "Custom Note")
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
