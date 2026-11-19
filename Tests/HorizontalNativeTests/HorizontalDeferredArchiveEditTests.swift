import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// An edit to the document's archive left to be made when the archive is
/// next read (`deferArchiveEdit`): made once, by whichever thread asks first,
/// superseded by one deferred after it, and an assignment like any other to
/// the document's copies.
final class HorizontalDeferredArchiveEditTests: XCTestCase {
    private struct Failed: Error {}

    /// How often an edit ran, and where.
    private final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var onMain = false
        func add() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            onMain = onMain || Thread.isMainThread
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        var ranOnMainThread: Bool {
            lock.lock()
            defer { lock.unlock() }
            return onMain
        }
    }

    private func expandedArchive() -> HorizontalProjectArchive {
        HorizontalProjectArchive(root: .directory([
            "Project.hprj": .regularFile(Data("project".utf8)),
            "board.json": .regularFile(Data("board".utf8))
        ]), suggestedFilename: "Project.horizontal")
    }

    private func document() -> HorizontalProjectDocument {
        var document = HorizontalProjectDocument()
        document.archive = expandedArchive()
        return document
    }

    private func board(_ archive: HorizontalProjectArchive) -> String? {
        archive.regularFileData(relativePath: "board.json").map { String(decoding: $0, as: UTF8.self) }
    }

    private func writing(_ text: String, _ runs: Runs? = nil) -> HorizontalProjectDocument.DeferredArchiveEdit {
        { archive in
            runs?.add()
            try archive.replaceRegularFileData(relativePath: "board.json", with: Data(text.utf8))
        }
    }

    func testADeferredEditIsMadeWhenTheArchiveIsRead() {
        var document = document()
        let runs = Runs()
        document.deferArchiveEdit(writing("moved", runs))

        XCTAssertTrue(document.hasDeferredEdit)
        XCTAssertEqual(board(document.settledArchive), "board", "the archive as last written")
        XCTAssertEqual(runs.value, 0, "and asking for that makes nothing")

        XCTAssertEqual(board(document.archive), "moved")
        XCTAssertFalse(document.hasDeferredEdit)
        XCTAssertEqual(board(document.archive), "moved")
        XCTAssertEqual(board(document.settledArchive), "moved")
        XCTAssertEqual(runs.value, 1, "made once")
    }

    func testAnEditDeferredAfterAnotherTakesItsPlace() throws {
        var document = document()
        let first = Runs()
        document.deferArchiveEdit { archive in
            first.add()
            try archive.replaceRegularFileData(relativePath: "left-behind.json", with: Data("first".utf8))
        }
        document.deferArchiveEdit(writing("second"))

        XCTAssertEqual(board(document.archive), "second")
        XCTAssertEqual(first.value, 0, "the edit it superseded was never made")
        XCTAssertNil(document.archive.regularFileData(relativePath: "left-behind.json"))

        // One made already is what the next is made in.
        document.deferArchiveEdit { archive in
            try archive.replaceRegularFileData(relativePath: "kept.json", with: Data("third".utf8))
        }
        XCTAssertEqual(board(document.archive), "second")
        XCTAssertNotNil(document.archive.regularFileData(relativePath: "kept.json"))
    }

    func testCopiesTakenBeforeAndAfterKeepTheirOwnArchives() {
        var document = document()
        let before = document
        let runs = Runs()
        document.deferArchiveEdit(writing("moved", runs))
        let undoSnapshot = document
        document.deferArchiveEdit(writing("moved again"))

        XCTAssertFalse(before.hasSameArchive(as: document), "deferring is an assignment: the storage is replaced")
        XCTAssertEqual(board(before.archive), "board")
        XCTAssertEqual(board(document.archive), "moved again")
        XCTAssertEqual(runs.value, 0, "a copy on the undo stack is not written until it is read")
        XCTAssertEqual(board(undoSnapshot.archive), "moved", "and then holds the edit it was taken with")
        XCTAssertEqual(runs.value, 1)
    }

    func testAnEditThatThrowsLeavesTheArchiveAndIsReported() async {
        var document = document()
        document.deferArchiveEdit { archive in
            try archive.replaceRegularFileData(relativePath: "board.json", with: Data("half made".utf8))
            throw Failed()
        }

        let error = await document.writeDeferredEdit()

        XCTAssertTrue(error is Failed, "\(String(describing: error))")
        XCTAssertFalse(document.hasDeferredEdit)
        XCTAssertEqual(document.archive, expandedArchive(), "none of it is kept")
        let again = await document.writeDeferredEdit()
        XCTAssertTrue(again is Failed, "the failure stays with the archive it was made for")
    }

    @MainActor
    func testTheWriteBehindIsMadeOffTheMainThread() async {
        var document = document()
        let runs = Runs()
        document.deferArchiveEdit(writing("moved", runs))

        let error = await document.writeDeferredEdit()

        XCTAssertNil(error)
        XCTAssertFalse(document.hasDeferredEdit)
        XCTAssertFalse(runs.ranOnMainThread)
        XCTAssertEqual(board(document.archive), "moved")
        XCTAssertEqual(runs.value, 1, "reading it afterwards makes nothing more")
    }

    func testManyReadersAtOnceMakeTheEditOnce() {
        var document = document()
        let runs = Runs()
        document.deferArchiveEdit { archive in
            runs.add()
            Thread.sleep(forTimeInterval: 0.02)
            try archive.replaceRegularFileData(relativePath: "board.json", with: Data("moved".utf8))
        }
        let shared = document
        let read = Runs()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if shared.archive.regularFileData(relativePath: "board.json") == Data("moved".utf8) {
                read.add()
            }
        }

        XCTAssertEqual(runs.value, 1)
        XCTAssertEqual(read.value, 16, "and every reader has it")
    }

    func testTheSettledArchiveDoesNotWaitForAWriteUnderWay() {
        var document = document()
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        document.deferArchiveEdit { archive in
            started.signal()
            finish.wait()
            try archive.replaceRegularFileData(relativePath: "board.json", with: Data("moved".utf8))
        }
        let shared = document
        let written = expectation(description: "the write, on another thread")
        DispatchQueue.global().async {
            _ = shared.archive
            written.fulfill()
        }
        started.wait()

        // The write is under way and will not finish until it is told to.
        XCTAssertEqual(board(document.settledArchive), "board")
        XCTAssertTrue(document.hasDeferredEdit)

        finish.signal()
        wait(for: [written], timeout: 10)
        XCTAssertEqual(board(document.settledArchive), "moved")
    }

    func testAnEditDeferredWhileLoadingIsNotOverwritten() {
        var document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        let loadingDocument = document
        let edited = HorizontalProjectArchive(regularFileData: Data("edited project".utf8))
        document.deferArchiveEdit { $0 = edited }

        XCTAssertFalse(document.completeLoading(with: expandedArchive(), from: loadingDocument))
        XCTAssertEqual(document.archive, edited)
    }

    /// As an edit made before a load began is replaced by what was loaded.
    func testLoadedFilesReplaceAnEditDeferredBeforeTheLoadBegan() {
        var document = HorizontalProjectDocument(rawProjectData: Data("project".utf8))
        let runs = Runs()
        document.deferArchiveEdit { archive in
            runs.add()
            archive = HorizontalProjectArchive(regularFileData: Data("edited project".utf8))
        }
        let loadingDocument = document

        XCTAssertTrue(document.completeLoading(with: expandedArchive(), from: loadingDocument))
        XCTAssertFalse(document.hasDeferredEdit)
        XCTAssertEqual(document.archive, expandedArchive())
        XCTAssertEqual(runs.value, 0)
    }

    /// A save reads the archive, which makes the edit, and names the `.hprj`
    /// after the package in the document it was taken from.
    func testASaveWritesADeferredEditAndNamesTheProjectFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-save-\(UUID().uuidString)")
        let package = folder.appendingPathComponent("Evan.horizontal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try HorizontalProjectArchive.newProject().write(to: package)
        var document = HorizontalProjectDocument()
        document.archive = try HorizontalProjectArchive.completeProject(from: package)
        XCTAssertEqual(document.archive.packageProjectFileName(), "Untitled.hprj", "precondition")
        document.deferArchiveEdit(writing("moved"))
        let before = document

        let written = document.packageArchive(writing: document.archive, over: try FileWrapper(url: package))

        XCTAssertEqual(board(written), "moved")
        XCTAssertEqual(written.packageProjectFileName(), "Evan.hprj")
        XCTAssertEqual(document.archive.packageProjectFileName(), "Evan.hprj")
        XCTAssertEqual(board(document.archive), "moved")
        XCTAssertTrue(document.hasSameArchive(as: before), "and was not edited to get there")
    }
}
