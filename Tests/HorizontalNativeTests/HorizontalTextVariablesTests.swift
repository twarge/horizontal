import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// `$project_title`, `$rev` and the rest typed into a text drew as typed
/// until the design was read again, which drew the values; an edit now draws
/// them at once, through the resolver the loaders draw with, and still saves
/// the text as typed.
final class HorizontalTextVariablesTests: XCTestCase {
    private let meta = HorizontalTextVariables.project(["project_title": "Board A", "rev": "2A", "author": ""])

    func testKeysResolveAsHorizonReadsThem() {
        XCTAssertEqual(meta.resolve("$project_title"), "Board A")
        XCTAssertEqual(meta.resolve("Rev $rev."), "Rev 2A.")
        XCTAssertEqual(meta.resolve("${rev}B"), "2AB", "a braced key ends at its brace")
        XCTAssertEqual(meta.resolve("$REV"), "2A", "all uppercase too")
        XCTAssertEqual(meta.resolve("$project_title/$rev"), "Board A/2A")
        XCTAssertEqual(meta.resolve("by $author"), "by ", "a key with an empty value draws nothing")
    }

    func testWhatNamesNoKeyStaysAsWritten() {
        XCTAssertEqual(meta.resolve("$revision"), "$revision", "a key is the whole name, not a prefix of it")
        XCTAssertEqual(meta.resolve("$rev_2"), "$rev_2")
        XCTAssertEqual(meta.resolve("${nothing}"), "${nothing}")
        XCTAssertEqual(meta.resolve("${rev"), "${rev", "never closed")
        XCTAssertEqual(meta.resolve("5 $ each"), "5 $ each")
        XCTAssertEqual(meta.resolve("ends in $"), "ends in $")
        XCTAssertEqual(meta.resolve("$$rev"), "$2A")
        XCTAssertEqual(HorizontalTextVariables().resolve("$rev"), "$rev")
    }

    func testAComponentsKeysAndCustomValueOnTopOfTheDesigns() {
        let symbol = meta.merging(HorizontalSchematic.symbolTextVariables(
            refdes: "R1", value: "10k", details: nil, customValue: nil))
        XCTAssertEqual(symbol.resolve("$REFDES $VALUE $rev"), "R1 10k 2A")
        let custom = meta.merging(HorizontalSchematic.symbolTextVariables(
            refdes: "R1", value: "10k", details: nil, customValue: "${value} 1%"))
        XCTAssertEqual(custom.resolve("$VALUE"), "10k 1%", "$VALUE alone draws the custom value")
        XCTAssertEqual(custom.resolve("$VALUE ohm"), "10k ohm", "anywhere else, the value")
    }

    func testStoredTextDrawsResolvedAndSavesAsTyped() {
        var text = HorizontalText(id: "t", text: "", position: .zero, size: 1_000_000, layer: 20)
        text.setStoredText("$project_title rev $rev", variables: meta)
        XCTAssertEqual(text.text, "Board A rev 2A")
        XCTAssertEqual(text.fileText, "$project_title rev $rev")
        XCTAssertEqual(text.editableText, "$project_title rev $rev")

        text.setStoredText("Plain", variables: meta)
        XCTAssertEqual(text.text, "Plain")
        XCTAssertNil(text.placeholder, "nothing to keep for a text that draws what it stores")
        XCTAssertEqual(text.fileText, "Plain")
    }

    func testTheMenuListsTheUsualKeysThenTheRest() {
        let items = HorizontalTextVariables.project(["zeta": "z", "rev": "2A", "alpha": "a", "empty_one": " "]).metadataItems
        XCTAssertEqual(items.map(\.code), ["$project_title", "$project_name", "$rev", "$author", "$date", "$license", "$alpha", "$zeta"])
        XCTAssertEqual(items.first { $0.key == "rev" }?.value, "2A")
        XCTAssertEqual(items.first { $0.key == "rev" }?.title, "Revision")
        XCTAssertEqual(HorizontalTextVariables().metadataItems, [], "no design, no menu: a pool editor's")
        XCTAssertEqual(HorizontalTextVariables.component(refdes: "R1", value: "1k").metadataItems, [])
    }

    /// The edit, the file and the reload agree: a text drawing "$rev" as the
    /// revision right after it is typed draws it after a reload, and the file
    /// keeps "$rev", on the board and on a sheet.
    func testAnEditDrawsWhatTheReloadDraws() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-variables-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var archive = try HorizontalProjectArchive.completeProject(from: root)
        var project = try HorizontalProject.loadSnapshot(of: archive)
        try HorizontalProjectJSONApplicator.apply(
            titleBlockChanges: HorizontalTitleBlockChanges(key: "project_title", value: "Board A"), in: project, to: &archive)
        project = try HorizontalProject.loadSnapshot(of: archive)
        try HorizontalProjectJSONApplicator.apply(
            titleBlockChanges: HorizontalTitleBlockChanges(key: "rev", value: "2A"), in: project, to: &archive)
        project = try HorizontalProject.loadSnapshot(of: archive)

        var board = try XCTUnwrap(project.board)
        var boardText = HorizontalText(id: "b0a2a1d6-0000-4000-8000-000000000001", text: "", position: .zero,
                                       size: 1_000_000, layer: 20)
        boardText.setStoredText("$project_title rev $rev", variables: board.textVariables(forTextID: boardText.id))
        XCTAssertEqual(boardText.text, "Board A rev 2A", "drawn as it is committed")
        board.texts.append(boardText)
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)

        let schematic = try XCTUnwrap(project.schematic)
        var sheet = try XCTUnwrap(schematic.sheets.first)
        var sheetText = HorizontalText(id: "b0a2a1d6-0000-4000-8000-000000000002", text: "", position: .zero,
                                       size: 1_500_000, layer: nil)
        sheetText.setStoredText("Rev ${rev}", variables: sheet.textVariables(forTextID: sheetText.id))
        XCTAssertEqual(sheetText.text, "Rev 2A")
        sheet.texts.append(sheetText)
        try HorizontalProjectJSONApplicator.apply(schematicSheet: sheet, schematicURL: schematic.url, in: project, to: &archive)

        let reloaded = try HorizontalProject.loadSnapshot(of: archive)
        let reloadedBoardText = try XCTUnwrap(reloaded.board?.texts.first { $0.id == boardText.id })
        XCTAssertEqual(reloadedBoardText.text, "Board A rev 2A")
        XCTAssertEqual(reloadedBoardText.editableText, "$project_title rev $rev")
        let reloadedSheetText = try XCTUnwrap(reloaded.schematic?.sheets.first?.texts.first { $0.id == sheetText.id })
        XCTAssertEqual(reloadedSheetText.text, "Rev 2A")
        XCTAssertEqual(reloadedSheetText.editableText, "Rev ${rev}")

        let boardJSON = try JSONHelper.loadDictionary(from: XCTUnwrap(archive.regularFileData(relativePath: "board.json")))
        XCTAssertEqual(boardJSON.dictionaryMap("texts")[boardText.id]?.string("text"), "$project_title rev $rev",
                       "the file keeps what was typed")
        XCTAssertEqual(reloaded.board?.textVariables.metadataItems.first { $0.key == "rev" }?.value, "2A")
        XCTAssertEqual(reloaded.schematic?.sheets.first?.textVariables.metadataItems.first { $0.key == "project_title" }?.value,
                       "Board A")
    }
}
