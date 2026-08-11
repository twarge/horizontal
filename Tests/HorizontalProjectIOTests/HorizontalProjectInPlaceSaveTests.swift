import Foundation
import HorizontalProjectIO
import XCTest

/// Saving a project opened from a bare Horizon `.hprj`.
///
/// `completeProject(from:)` gathers a `.hprj` and every sibling it references
/// into ONE directory-rooted archive, so the project can also be saved as a
/// `.horizontal` package. Handing that directory to the document writer for the
/// original `.hprj` URL replaced the user's project FILE with a FOLDER of the
/// same name — Horizon's format is a JSON file with siblings beside it, never a
/// bundle. These tests pin the file-shaped save path.
final class HorizontalProjectInPlaceSaveTests: XCTestCase {
    // MARK: - Fixture

    /// A minimal but realistic project: `.hprj` + blocks/schematic/board/pool.
    private func makeProject(named name: String = "Round Trip") throws -> (root: URL, projectFile: URL) {
        let root = try temporaryDirectory().appendingPathComponent("Project Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let projectFile = root.appendingPathComponent("\(name).hprj")
        try write(
            """
            {
              "uuid": "project",
              "name": "\(name)",
              "blocks_filename": "blocks.json",
              "board_filename": "board.json",
              "planes_filename": "planes.json",
              "pool_directory": "pool"
            }
            """,
            to: projectFile
        )
        try write(
            """
            {
              "top_block": "block-a",
              "blocks": {
                "block-a": {
                  "block_filename": "top_block.json",
                  "schematic_filename": "top_schematic.json",
                  "symbol_filename": "top_symbol.json"
                }
              }
            }
            """,
            to: root.appendingPathComponent("blocks.json")
        )
        try write("{\"project_meta\":{\"project_title\":\"\(name)\"}}", to: root.appendingPathComponent("top_block.json"))
        try write("{\"name\":\"Top\",\"sheets\":[]}", to: root.appendingPathComponent("top_schematic.json"))
        try write("{\"name\":\"Top Symbol\"}", to: root.appendingPathComponent("top_symbol.json"))
        try write("{\"name\":\"Board\",\"included_boards\":{},\"board_panels\":{}}", to: root.appendingPathComponent("board.json"))
        try write("{\"fragments\":[]}", to: root.appendingPathComponent("planes.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pool/packages"), withIntermediateDirectories: true)
        try write("{\"name\":\"Package\"}", to: root.appendingPathComponent("pool/packages/pkg.json"))

        return (root, projectFile)
    }

    // MARK: - The regression

    func testProjectFileWrapperIsAFileNotADirectory() throws {
        let (_, projectFile) = try makeProject()
        let archive = try HorizontalProjectArchive.completeProject(from: projectFile)

        // The gathered archive IS a directory — that's what feeds the .horizontal
        // package — which is exactly why the file-shaped path has to exist.
        XCTAssertTrue(archive.directoryCount > 0)

        let wrapper = try archive.projectFileWrapper()

        XCTAssertTrue(wrapper.isRegularFile, "a .hprj must be saved as a FILE, never a folder")
        XCTAssertFalse(wrapper.isDirectory)
        XCTAssertEqual(wrapper.preferredFilename, "Round Trip.hprj")
    }

    func testProjectFileWrapperCarriesTheProjectJSON() throws {
        let (_, projectFile) = try makeProject()
        let archive = try HorizontalProjectArchive.completeProject(from: projectFile)

        let wrapper = try archive.projectFileWrapper()
        let contents = try XCTUnwrap(wrapper.regularFileContents)

        XCTAssertEqual(contents, try Data(contentsOf: projectFile))
    }

    // MARK: - In-place writeback

    func testEditedSiblingIsWrittenBackToItsOriginalLocation() throws {
        let (root, projectFile) = try makeProject()
        var archive = try HorizontalProjectArchive.completeProject(from: projectFile)

        let editedBoard = Data("{\"name\":\"Board\",\"included_boards\":{},\"board_panels\":{},\"edited\":true}".utf8)
        try archive.replaceRegularFileData(relativePath: "board.json", with: editedBoard)

        let written = try archive.writeInPlace()

        XCTAssertTrue(written.contains("board.json"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("board.json")), editedBoard)
        // The project stays a folder of loose files — no bundle, nothing moved.
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFile.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue, ".hprj must remain a regular file")
    }

    func testUnchangedFilesAreNotRewritten() throws {
        let (root, projectFile) = try makeProject()
        var archive = try HorizontalProjectArchive.completeProject(from: projectFile)
        try archive.replaceRegularFileData(relativePath: "board.json", with: Data("{\"edited\":true}".utf8))

        let written = try archive.writeInPlace()

        // Only the edited file is touched: a one-board edit must not rewrite (and
        // re-timestamp) the whole pool.
        XCTAssertEqual(written, ["board.json"])
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("pool/packages/pkg.json")),
            Data("{\"name\":\"Package\"}".utf8)
        )
    }

    func testProjectFileWrapperSkipsTheProjectFileItselfWhenWritingSiblings() throws {
        // The document writer places the returned wrapper AT the project URL, so
        // writeInPlace must not also write it (double write, and it would defeat
        // the writer's atomic replace).
        let (_, projectFile) = try makeProject()
        var archive = try HorizontalProjectArchive.completeProject(from: projectFile)
        try archive.replaceRegularFileData(
            relativePath: "Round Trip.hprj",
            with: Data("{\"uuid\":\"project\",\"name\":\"Renamed\"}".utf8)
        )

        _ = try archive.projectFileWrapper()

        // Untouched on disk: only the returned wrapper carries the new bytes.
        XCTAssertEqual(
            try Data(contentsOf: projectFile),
            Data("""
            {
              "uuid": "project",
              "name": "Round Trip",
              "blocks_filename": "blocks.json",
              "board_filename": "board.json",
              "planes_filename": "planes.json",
              "pool_directory": "pool"
            }
            """.utf8)
        )
    }

    func testWriteInPlaceCreatesMissingIntermediateDirectories() throws {
        let (root, projectFile) = try makeProject()
        var archive = try HorizontalProjectArchive.completeProject(from: projectFile)
        try FileManager.default.removeItem(at: root.appendingPathComponent("pool"))
        try archive.replaceRegularFileData(
            relativePath: "pool/packages/pkg.json",
            with: Data("{\"name\":\"Restored\"}".utf8)
        )

        try archive.writeInPlace()

        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("pool/packages/pkg.json")),
            Data("{\"name\":\"Restored\"}".utf8)
        )
    }

    // MARK: - Guards

    func testDirectoryArchiveWithoutAManifestRefusesToSaveAsAFile() throws {
        // A .horizontal package snapshot has no manifest, so there are no original
        // locations to write back to. It must fail loudly rather than silently
        // dropping the siblings.
        let packageRoot = try temporaryDirectory().appendingPathComponent("Sample.horizontal")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try write("{}", to: packageRoot.appendingPathComponent("Sample.hprj"))

        let archive = try HorizontalProjectArchive.snapshot(from: packageRoot)
        XCTAssertNil(archive.manifest)

        XCTAssertThrowsError(try archive.projectFileWrapper()) { error in
            XCTAssertEqual(error as? HorizontalProjectArchiveError, .missingManifest)
        }
    }

    func testSingleFileArchiveSavesAsAFileUnchanged() throws {
        // Opened read-only (or built from raw data): never expanded, so it should
        // pass straight through as a regular file.
        let archive = HorizontalProjectArchive(
            regularFileData: Data("{\"uuid\":\"project\"}".utf8),
            suggestedFilename: "Bare.hprj"
        )

        let wrapper = try archive.projectFileWrapper()

        XCTAssertTrue(wrapper.isRegularFile)
        XCTAssertEqual(wrapper.regularFileContents, Data("{\"uuid\":\"project\"}".utf8))
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }
}
