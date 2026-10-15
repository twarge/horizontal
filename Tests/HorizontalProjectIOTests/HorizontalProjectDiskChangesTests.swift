import Foundation
import HorizontalProjectIO
import XCTest

/// Telling a change something else made to an open project's files — a git
/// checkout, a pull — from the document's own autosaves (item 121).
final class HorizontalProjectDiskChangesTests: XCTestCase {
    func testAnAutosaveOfTheDocumentIsInStep() throws {
        let project = try makeProject()
        var document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try document.replaceRegularFileData(relativePath: "board.json", with: Data("{\"name\":\"Edited\"}".utf8))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)),
                       .documentAhead, "before the autosave, the files are as they were and the document is ahead")

        detector.recordWrite(.init(archive: document))
        _ = try document.projectFileWrapper()
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .inStep)
    }

    func testACheckoutUnderTheDocumentIsAChangeOnDisk() throws {
        let project = try makeProject()
        let document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try write("{\"name\":\"From another branch\"}", to: project.root.appendingPathComponent("board.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .changedOnDisk)
    }

    func testAPartAddedByAPullIsAChangeOnDisk() throws {
        let project = try makeProject()
        let document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try write("{\"name\":\"New\"}", to: project.root.appendingPathComponent("pool/parts/new.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .changedOnDisk)
    }

    /// An autosave of edit A lands, then edit B arrives before the check: the
    /// files hold A, which is neither the document (B) nor the baseline.
    func testAnAutosaveOvertakenByANewerEditIsTheDocumentsOwn() throws {
        let project = try makeProject()
        var document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try document.replaceRegularFileData(relativePath: "board.json", with: Data("{\"name\":\"A\"}".utf8))
        detector.recordWrite(.init(archive: document))
        _ = try document.projectFileWrapper()
        try document.replaceRegularFileData(relativePath: "board.json", with: Data("{\"name\":\"B\"}".utf8))

        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .documentAhead)
        // A change after that is still seen.
        try write("{\"name\":\"Pulled\"}", to: project.root.appendingPathComponent("top_block.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .changedOnDisk)
    }

    /// Replace in the Pools pane: the part is cached into the project pool,
    /// on disk and in the document, and the edit that uses it waits for the
    /// autosave. The files then hold the new part and the old block, neither
    /// the document nor the baseline as a whole, and the user was asked
    /// whether to reload (131). File by file, each holds a version the
    /// document knows.
    func testAPartTheAppCachesBeforeTheAutosaveIsTheDocumentsOwn() throws {
        let project = try makeProject()
        var document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        let part = "{\"name\":\"Cached\"}", manifest = "{\"files\":{}}"
        try write(part, to: project.root.appendingPathComponent("pool/parts/cached.json"))
        try write(manifest, to: project.root.appendingPathComponent("pool/.horizontal/pool-cache.json"))
        try document.replaceRegularFileData(relativePath: "pool/parts/cached.json", with: Data(part.utf8))
        try document.replaceRegularFileData(relativePath: "pool/.horizontal/pool-cache.json", with: Data(manifest.utf8))
        try document.replaceRegularFileData(relativePath: "top_block.json", with: Data("{\"name\":\"Uses the part\"}".utf8))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)),
                       .documentAhead, "the cached part is the document's, and its edit is still to be written")

        // The autosave catches the files up.
        detector.recordWrite(.init(archive: document))
        _ = try document.projectFileWrapper()
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .inStep)

        // A cached file changed from outside is still a change.
        try write("{\"name\":\"Pulled over it\"}", to: project.root.appendingPathComponent("pool/parts/cached.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .changedOnDisk)
    }

    func testFinderAndGitDroppingsAreNotChanges() throws {
        let project = try makeProject()
        let document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try write("x", to: project.root.appendingPathComponent("pool/.DS_Store"))
        try write("x", to: project.root.appendingPathComponent("pool/pool.db"))
        try write("x", to: project.root.appendingPathComponent("pool/parts/._new.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: .init(archive: document)), .inStep)

        for path in [".git/index", "pool/.DS_Store", "pool/pool.db-journal", "board.json.sb-1a2b-Xy",
                     ".horizontal-transactions/abc/journal.json", "top_block.json.bak"] {
            XCTAssertTrue(HorizontalProjectFingerprint.ignores(path), path)
        }
        for path in ["board.json", "pool/.horizontal/pool-cache.json", ".gitignore", "pool/parts/x.json"] {
            XCTAssertFalse(HorizontalProjectFingerprint.ignores(path), path)
        }
    }

    /// The user chose to keep their version over a change on disk: that same
    /// state is not reported again, a later change is.
    func testAcceptedChangesAreNotReportedAgain() throws {
        let project = try makeProject()
        let document = try HorizontalProjectArchive.completeProject(from: project.file)
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))

        try write("{\"name\":\"Theirs\"}", to: project.root.appendingPathComponent("board.json"))
        let theirs = try fingerprint(of: project.file)
        XCTAssertEqual(detector.classify(disk: theirs, document: .init(archive: document)), .changedOnDisk)
        detector.accept(theirs)
        XCTAssertEqual(detector.classify(disk: theirs, document: .init(archive: document)), .documentAhead)
    }

    /// A document opened read-only holds no complete copy to compare with; the
    /// baseline alone tells a change.
    func testWithoutADocumentCopyTheBaselineDecides() throws {
        let project = try makeProject()
        var detector = HorizontalProjectChangeDetector(baseline: try fingerprint(of: project.file))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: nil), .inStep)
        try write("{\"name\":\"Changed\"}", to: project.root.appendingPathComponent("board.json"))
        XCTAssertEqual(detector.classify(disk: try fingerprint(of: project.file), document: nil), .changedOnDisk)
    }

    func testOnlyPathsTheProjectReadsAreTracked() throws {
        let project = try makeProject()
        let archive = try HorizontalProjectArchive.completeProject(from: project.file)
        XCTAssertTrue(archive.tracks(relativePath: "board.json"))
        XCTAssertTrue(archive.tracks(relativePath: "pool/parts/new.json"), "a new file in the pool is part of the project")
        XCTAssertTrue(archive.tracks(relativePath: ""), "the folder itself: rescan")
        XCTAssertFalse(archive.tracks(relativePath: "Fabrication/board.gbr"), "exports beside the project are not")
        XCTAssertFalse(archive.tracks(relativePath: "README.md"))
        XCTAssertFalse(archive.tracks(relativePath: ".git/index"))

        let package = HorizontalProjectArchive(root: .directory(["project.hprj": .regularFile(Data())]))
        XCTAssertTrue(package.tracks(relativePath: "anything/inside.json"), "everything in a package is the project")
    }

    // MARK: - Fixture

    private func makeProject() throws -> (root: URL, file: URL) {
        let root = try temporaryDirectory().appendingPathComponent("Project")
        let file = root.appendingPathComponent("Test.hprj")
        try write("""
            {"uuid": "project", "blocks_filename": "blocks.json", "board_filename": "board.json",
             "planes_filename": "planes.json", "pool_directory": "pool"}
            """, to: file)
        try write("""
            {"top_block": "a", "blocks": {"a": {"block_filename": "top_block.json", "schematic_filename": "top_schematic.json"}}}
            """, to: root.appendingPathComponent("blocks.json"))
        try write("{}", to: root.appendingPathComponent("top_block.json"))
        try write("{\"sheets\":[]}", to: root.appendingPathComponent("top_schematic.json"))
        try write("{\"name\":\"Board\"}", to: root.appendingPathComponent("board.json"))
        try write("{}", to: root.appendingPathComponent("planes.json"))
        try write("{\"name\":\"Part\"}", to: root.appendingPathComponent("pool/parts/part.json"))
        try write("notes", to: root.appendingPathComponent("README.md"))
        return (root, file)
    }

    private func fingerprint(of file: URL) throws -> HorizontalProjectFingerprint {
        HorizontalProjectFingerprint(archive: try HorizontalProjectArchive.completeProject(from: file))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }
}
