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
