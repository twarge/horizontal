import Foundation
import HorizontalProjectIO
import XCTest

final class HorizontalProjectArchiveTests: XCTestCase {
    func testDirectorySnapshotRoundTripsWithoutContentLoss() throws {
        let root = try temporaryDirectory().appendingPathComponent("Sample.horizontal")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("{}", to: root.appendingPathComponent("Sample.hprj"))
        try write("hidden", to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pool/parts"), withIntermediateDirectories: true)
        try write("{\"name\":\"R1\"}", to: root.appendingPathComponent("pool/parts/resistor.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pool/empty"), withIntermediateDirectories: true)

        let archive = try HorizontalProjectArchive.snapshot(from: root)
        let writtenURL = try temporaryDirectory().appendingPathComponent("Written.horizontal")
        try archive.write(to: writtenURL)
        let writtenArchive = try HorizontalProjectArchive.snapshot(from: writtenURL)

        XCTAssertEqual(writtenArchive.root, archive.root)
        XCTAssertEqual(archive.regularFileData(relativePath: ".hidden"), Data("hidden".utf8))
    }

    func testCompleteProjectArchiveIncludesProjectGraphAndPool() throws {
        let root = try temporaryDirectory().appendingPathComponent("Project Source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(
            """
            {
              "uuid": "project",
              "name": "Round Trip",
              "blocks_filename": "blocks.json",
              "board_filename": "board.json",
              "planes_filename": "planes.json",
              "pool_directory": "pool"
            }
            """,
            to: root.appendingPathComponent("Round Trip.hprj")
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
        try write("{\"project_meta\":{\"project_title\":\"Round Trip\"}}", to: root.appendingPathComponent("top_block.json"))
        try write("{\"name\":\"Top\",\"sheets\":[]}", to: root.appendingPathComponent("top_schematic.json"))
        try write("{\"name\":\"Top Symbol\"}", to: root.appendingPathComponent("top_symbol.json"))
        try write("{\"name\":\"Board\",\"included_boards\":{},\"board_panels\":{}}", to: root.appendingPathComponent("board.json"))
        try write("{\"fragments\":[]}", to: root.appendingPathComponent("planes.json"))
        try write("not referenced", to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pool/packages"), withIntermediateDirectories: true)
        try write("{\"name\":\"Package\"}", to: root.appendingPathComponent("pool/packages/pkg.json"))

        let archive = try HorizontalProjectArchive.completeProject(from: root.appendingPathComponent("Round Trip.hprj"))

        XCTAssertNotNil(archive.regularFileData(relativePath: "Round Trip.hprj"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "blocks.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "top_block.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "top_schematic.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "top_symbol.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "board.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "planes.json"))
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/packages/pkg.json"))
        XCTAssertNil(archive.regularFileData(relativePath: "notes.txt"))

        let writtenURL = try temporaryDirectory().appendingPathComponent("Round Trip.horizontal")
        try archive.write(to: writtenURL)
        let writtenArchive = try HorizontalProjectArchive.snapshot(from: writtenURL)
        XCTAssertEqual(writtenArchive.root, archive.root)
    }

    func testReplacingRegularFileDataPreservesSiblingFiles() throws {
        let root = try temporaryDirectory().appendingPathComponent("Sample.horizontal")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try write("{\"old\":true}", to: root.appendingPathComponent("board.json"))
        try write("keep", to: root.appendingPathComponent("nested/notes.txt"))

        var archive = try HorizontalProjectArchive.snapshot(from: root)
        try archive.replaceRegularFileData(relativePath: "board.json", with: Data("{\"new\":true}".utf8))

        XCTAssertEqual(archive.regularFileData(relativePath: "board.json"), Data("{\"new\":true}".utf8))
        XCTAssertEqual(archive.regularFileData(relativePath: "nested/notes.txt"), Data("keep".utf8))
    }

    /// A pool cleanup removes files from the archive; saving in place deletes
    /// exactly those, with the directories the archive no longer has, and an
    /// earlier archive (undo) writes them back.
    func testRemovedFilesAreDeletedOnSaveAndAnEarlierArchiveRestoresThem() throws {
        let root = try temporaryDirectory().appendingPathComponent("Cleanup")
        try write("{\"uuid\":\"project\",\"name\":\"Cleanup\",\"pool_directory\":\"pool\"}",
                  to: root.appendingPathComponent("Cleanup.hprj"))
        try write("{\"type\":\"pool\"}", to: root.appendingPathComponent("pool/pool.json"))
        try write("{\"type\":\"part\"}", to: root.appendingPathComponent("pool/parts/cache/used.json"))
        try write("{\"type\":\"part\"}", to: root.appendingPathComponent("pool/parts/cache/unused.json"))
        try write("{\"type\":\"package\"}", to: root.appendingPathComponent("pool/packages/cache/pkg/package.json"))
        try write("{\"type\":\"padstack\"}", to: root.appendingPathComponent("pool/packages/cache/pkg/padstacks/pad.json"))
        try write("{\"type\":\"package\"}", to: root.appendingPathComponent("pool/packages/cache/other/package.json"))

        let original = try HorizontalProjectArchive.completeProject(from: root.appendingPathComponent("Cleanup.hprj"))
        var cleaned = original
        for path in ["pool/parts/cache/unused.json", "pool/packages/cache/pkg/package.json", "pool/packages/cache/pkg/padstacks/pad.json"] {
            try cleaned.removeRegularFile(relativePath: path)
        }
        XCTAssertThrowsError(try cleaned.removeRegularFile(relativePath: "pool/parts/cache/missing.json"))
        XCTAssertThrowsError(try cleaned.removeRegularFile(relativePath: "pool/packages/cache/other"), "only regular files")
        XCTAssertNil(cleaned.regularFileData(relativePath: "pool/parts/cache/unused.json"))
        XCTAssertNotNil(cleaned.regularFileData(relativePath: "pool/parts/cache/used.json"))
        XCTAssertEqual(cleaned.removedRelativePaths.count, 3)

        let changed = try cleaned.writeInPlace()
        XCTAssertEqual(changed, ["pool/packages/cache/pkg/package.json", "pool/packages/cache/pkg/padstacks/pad.json", "pool/parts/cache/unused.json"])
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("pool/parts/cache/unused.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("pool/packages/cache/pkg").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("pool/packages/cache/other/package.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("pool/parts/cache/used.json").path))
        XCTAssertEqual(try cleaned.writeInPlace(), [], "nothing left to delete")

        // Undo: the earlier archive still holds the files and writes them back.
        XCTAssertEqual(Set(try original.writeInPlace()), ["pool/packages/cache/pkg/package.json", "pool/packages/cache/pkg/padstacks/pad.json", "pool/parts/cache/unused.json"])
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("pool/packages/cache/pkg/padstacks/pad.json").path))

        // Writing a removed file again takes it off the list.
        try cleaned.replaceRegularFileData(relativePath: "pool/parts/cache/unused.json", with: Data("{}".utf8))
        XCTAssertFalse(cleaned.removedRelativePaths.contains("pool/parts/cache/unused.json"))
    }

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
