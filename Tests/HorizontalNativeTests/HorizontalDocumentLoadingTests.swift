import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class HorizontalDocumentLoadingTests: XCTestCase {
    func testCompletingLoadDoesNotWriteThroughTheDocumentBinding() throws {
        var document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        var edits = 0
        let binding = Binding(
            get: { document },
            set: { document = $0; edits += 1 }
        )
        let loadingDocument = binding.wrappedValue
        let archive = expandedArchive()

        XCTAssertTrue(binding.wrappedValue.completeLoading(with: archive, from: loadingDocument))
        XCTAssertEqual(edits, 0, "Opening a project must not trigger DocumentGroup's edit/save pipeline")
        XCTAssertEqual(binding.wrappedValue.archive, archive)
        XCTAssertTrue(try binding.wrappedValue.archive.fileWrapper().isDirectory,
                      "Save As must still have the full project even before the first edit")

        // A real edit still uses the binding and leaves the loaded baseline
        // untouched, including nested mutations of the archive value.
        try binding.wrappedValue.archive.replaceRegularFileData(
            relativePath: "board.json", with: Data("edited board".utf8)
        )
        XCTAssertEqual(edits, 1)
        XCTAssertEqual(document.archive.regularFileData(relativePath: "board.json"), Data("edited board".utf8))
        XCTAssertEqual(loadingDocument.archive, archive)
    }

    func testAnEditMadeWhileLoadingIsNotOverwritten() {
        var document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        let loadingDocument = document
        let editedArchive = HorizontalProjectArchive(regularFileData: Data("edited project".utf8))
        document.archive = editedArchive

        XCTAssertFalse(document.completeLoading(with: expandedArchive(), from: loadingDocument))
        XCTAssertEqual(document.archive, editedArchive)
    }

    func testLoadingAnotherDocumentCannotReplaceThisOne() {
        let document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        let other = HorizontalProjectDocument(rawProjectData: Data("project".utf8))

        XCTAssertFalse(document.completeLoading(with: expandedArchive(), from: other))
        XCTAssertEqual(document.archive.root, .regularFile(Data("project".utf8)))
    }

    func testEditedCopiesAndUndoSnapshotsKeepIndependentArchives() throws {
        let document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        XCTAssertTrue(document.completeLoading(with: expandedArchive(), from: document))
        let originalArchive = document.archive
        var edited = document
        try edited.archive.replaceRegularFileData(relativePath: "board.json", with: Data("first edit".utf8))
        let undoSnapshot = edited
        try edited.archive.replaceRegularFileData(relativePath: "board.json", with: Data("second edit".utf8))

        XCTAssertEqual(document.archive, originalArchive)
        XCTAssertEqual(undoSnapshot.archive.regularFileData(relativePath: "board.json"), Data("first edit".utf8))
        XCTAssertEqual(edited.archive.regularFileData(relativePath: "board.json"), Data("second edit".utf8))
    }

    private func expandedArchive() -> HorizontalProjectArchive {
        HorizontalProjectArchive(root: .directory([
            "Project.hprj": .regularFile(Data("project".utf8)),
            "board.json": .regularFile(Data("board".utf8))
        ]), suggestedFilename: "Project.horizontal")
    }
}
