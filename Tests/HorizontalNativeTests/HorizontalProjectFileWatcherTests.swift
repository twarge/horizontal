#if os(macOS)
import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The watcher on a real folder, through FSEvents (item 121): a change from
/// outside is reported once the folder settles; the document's own write is not.
@MainActor
final class HorizontalProjectFileWatcherTests: XCTestCase {
    private var reports = [(fingerprint: HorizontalProjectFingerprint, unsaved: Bool)]()

    func testAChangeFromOutsideIsReported() async throws {
        let project = try makeProject()
        let document = try openDocument(project.file)
        let watcher = makeWatcher(project.file, document: { document })
        watcher.start()
        defer { watcher.stop() }
        await watcher.baselineRead()

        try Data("{\"name\":\"Checked out\"}".utf8).write(to: project.root.appendingPathComponent("board.json"))
        try await waitForReport()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.unsaved, false)
    }

    func testTheDocumentsOwnWriteIsNotReported() async throws {
        let project = try makeProject()
        var document = try openDocument(project.file)
        let watcher = makeWatcher(project.file, document: { document })
        watcher.start()
        defer { watcher.stop() }
        await watcher.baselineRead()

        // What an autosave does: the document says what it writes, then writes it.
        var edited = document.archive
        try edited.replaceRegularFileData(relativePath: "board.json", with: Data("{\"name\":\"Edited here\"}".utf8))
        document.archive = edited
        NotificationCenter.default.post(name: HorizontalProjectDocument.didWriteNotification, object: edited)
        _ = try edited.projectFileWrapper()

        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(reports.isEmpty, "\(reports.count) report(s) for the document's own write")
    }

    func testFilesBesideTheProjectAreNotReported() async throws {
        let project = try makeProject()
        let document = try openDocument(project.file)
        let watcher = makeWatcher(project.file, document: { document })
        watcher.start()
        defer { watcher.stop() }
        await watcher.baselineRead()

        let exports = project.root.appendingPathComponent("Fabrication")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("G04*".utf8).write(to: exports.appendingPathComponent("board.gbr"))
        try Data("x".utf8).write(to: project.root.appendingPathComponent("pool/.DS_Store"))

        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(reports.isEmpty)
    }

    /// An edit arriving before the scheduled check looks first. The schedule
    /// here is far longer than the test, so Check Now is what reads the
    /// change however slowly the events or this test arrive: with the usual
    /// half second, a busy machine could run the scheduled check first, and
    /// Check Now then found the change again and reported it twice.
    func testCheckNowSeesAChangeTheScheduleHasNotYetRead() async throws {
        let project = try makeProject()
        let document = try openDocument(project.file)
        let watcher = makeWatcher(project.file, settleDelay: .seconds(600), document: { document })
        watcher.start()
        defer { watcher.stop() }
        await watcher.baselineRead()

        try Data("{\"name\":\"Pulled\"}".utf8).write(to: project.root.appendingPathComponent("board.json"))
        let deadline = Date().addingTimeInterval(3)
        while !watcher.hasUnreadChanges, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(watcher.checkNow())
        XCTAssertEqual(reports.count, 1)
    }

    // MARK: - Fixture

    private func makeWatcher(_ file: URL, settleDelay: Duration = HorizontalProjectFileWatcher.settleDelay,
                             document: @escaping () -> HorizontalProjectDocument) -> HorizontalProjectFileWatcher {
        HorizontalProjectFileWatcher(projectURL: file, handlers: .init(
            document: document,
            holdsCompleteArchive: { true },
            hasUnsavedChanges: { false },
            changedOnDisk: { [weak self] _, fingerprint, unsaved in self?.reports.append((fingerprint, unsaved)) }
        ), settleDelay: settleDelay)
    }

    private func openDocument(_ file: URL) throws -> HorizontalProjectDocument {
        var document = HorizontalProjectDocument()
        document.archive = try HorizontalProjectArchive.completeProject(from: file)
        return document
    }

    private func waitForReport() async throws {
        let deadline = Date().addingTimeInterval(5)
        while reports.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func makeProject() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-watch-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Test.hprj")
        func write(_ text: String, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("""
            {"uuid": "project", "blocks_filename": "blocks.json", "board_filename": "board.json",
             "planes_filename": "planes.json", "pool_directory": "pool"}
            """, "Test.hprj")
        try write("""
            {"top_block": "a", "blocks": {"a": {"block_filename": "top_block.json", "schematic_filename": "top_schematic.json"}}}
            """, "blocks.json")
        try write("{}", "top_block.json")
        try write("{\"sheets\":[]}", "top_schematic.json")
        try write("{\"name\":\"Board\"}", "board.json")
        try write("{}", "planes.json")
        try write("{\"name\":\"Part\"}", "pool/parts/part.json")
        return (root, file)
    }
}
#endif
