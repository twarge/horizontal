#if os(macOS)
import AppKit
import XCTest
@testable import HorizontalNative

/// Saving an open document on demand. SwiftUI's `DocumentGroup` gives no API
/// for this, so the document is found through `NSDocumentController` and
/// written through its own pipeline. The part worth testing is that the
/// lookup finds the right document from a path that may not be spelled the
/// way the document spells it, and that the write and the edited flag behave.
@MainActor
final class HorizontalDocumentSavingTests: XCTestCase {
    /// The smallest document that really writes: enough for `writeSafely` to
    /// run the same path a real save runs.
    private final class TestDocument: NSDocument {
        var contents = Data("first".utf8)
        var writes = 0

        override func data(ofType typeName: String) throws -> Data {
            writes += 1
            return contents
        }

        override func read(from data: Data, ofType typeName: String) throws {
            contents = data
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-saving-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
    }

    private func openDocument(at url: URL) throws -> TestDocument {
        try Data("first".utf8).write(to: url)
        let document = TestDocument()
        document.fileURL = url
        document.fileType = "public.data"
        NSDocumentController.shared.addDocument(document)
        addTeardownBlock { @MainActor in NSDocumentController.shared.removeDocument(document) }
        return document
    }

    func testTheDocumentIsFoundByPathHoweverItIsSpelled() throws {
        let url = root.appendingPathComponent("Project.horizontal")
        let document = try openDocument(at: url)

        XCTAssertIdentical(HorizontalDocumentSaving.document(for: url), document)
        // A path through a symlink, and one with a redundant component, are
        // the same document: an automation client rarely spells a path the
        // way the document does.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertIdentical(HorizontalDocumentSaving.document(for: link.appendingPathComponent("Project.horizontal")), document)
        XCTAssertIdentical(HorizontalDocumentSaving.document(for: root.appendingPathComponent("./Project.horizontal")), document)

        XCTAssertNil(HorizontalDocumentSaving.document(for: root.appendingPathComponent("Other.horizontal")))
    }

    func testSaveWritesOnlyWhatIsOutstandingAndClearsTheEditedFlag() throws {
        let url = root.appendingPathComponent("Project.horizontal")
        let document = try openDocument(at: url)

        // Nothing outstanding: the file is left alone rather than rewritten,
        // so a save does not churn a timestamp something may be watching.
        try HorizontalDocumentSaving.save(url: url)
        XCTAssertEqual(document.writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))

        document.contents = Data("second".utf8)
        document.updateChangeCount(.changeDone)
        XCTAssertTrue(HorizontalDocumentSaving.isEdited(url: url))

        try HorizontalDocumentSaving.save(url: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("second".utf8), "the document's own pipeline wrote the file")
        XCTAssertEqual(document.writes, 1)
        XCTAssertFalse(document.isDocumentEdited, "a saved document is no longer edited")
        XCTAssertFalse(HorizontalDocumentSaving.isEdited(url: url))
        // Left stale, this makes the app believe another program changed the
        // file under it the next time it writes.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(document.fileModificationDate?.timeIntervalSince1970 ?? 0, modified.timeIntervalSince1970, accuracy: 1)

        try HorizontalDocumentSaving.save(url: url)
        XCTAssertEqual(document.writes, 1, "a second save with nothing outstanding writes nothing")
    }

    func testSavingSomethingTheDocumentSystemDoesNotHaveIsNotFound() throws {
        let missing = root.appendingPathComponent("Never.horizontal")
        XCTAssertFalse(HorizontalDocumentSaving.isEdited(url: missing))
        XCTAssertThrowsError(try HorizontalDocumentSaving.save(url: missing)) { error in
            XCTAssertEqual((error as? HorizontalDispatchError)?.code, .notFound)
        }
    }
}
#endif
