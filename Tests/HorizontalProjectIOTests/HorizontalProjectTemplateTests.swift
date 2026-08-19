import Foundation
import HorizontalProjectIO
import XCTest

/// The new-document template behind File > New / Create Document.
///
/// A brand-new document used to be an empty regular file, which nothing could
/// load. These tests pin the replacement: a directory-rooted archive that is a
/// complete, discoverable Horizon project before it has ever touched disk.
final class HorizontalProjectTemplateTests: XCTestCase {
    func testTemplateContainsTheCanonicalProjectFiles() {
        let archive = HorizontalProjectArchive.newProject()

        XCTAssertEqual(
            archive.regularFilePaths,
            [
                "blocks.json",
                "board.json",
                "planes.json",
                "top_block.json",
                "top_schematic.json",
                "top_symbol.json",
                "Untitled.hprj"
            ]
        )
        XCTAssertEqual(archive.suggestedFilename, "Untitled.horizontal")
        XCTAssertNil(archive.manifest)
    }

    func testEveryTemplateFileIsAJSONObjectWithATrailingNewline() throws {
        let archive = HorizontalProjectArchive.newProject()

        for path in archive.regularFilePaths {
            let data = try XCTUnwrap(archive.regularFileData(relativePath: path))
            XCTAssertEqual(data.last, 0x0A, "\(path) should end with a newline like every saved file")
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertTrue(object is [String: Any], "\(path) should be a JSON object")
        }
    }

    func testManifestDiscoveryFindsEveryFileAndNothingMissing() throws {
        let root = try temporaryDirectory()
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)

        let manifest = try HorizontalProjectManifest.discover(
            from: packageURL.appendingPathComponent("Untitled.hprj")
        )

        XCTAssertEqual(
            manifest.relativePaths,
            [
                "blocks.json",
                "board.json",
                "planes.json",
                "top_block.json",
                "top_schematic.json",
                "top_symbol.json",
                "Untitled.hprj"
            ]
        )
        XCTAssertTrue(manifest.missingReferences.isEmpty)
        XCTAssertTrue(manifest.externalReferences.isEmpty)
    }

    func testTemplateRoundTripsThroughDiskUnchanged() throws {
        let root = try temporaryDirectory()
        let archive = HorizontalProjectArchive.newProject()
        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try archive.write(to: packageURL)

        let reread = try HorizontalProjectArchive.snapshot(from: packageURL)

        XCTAssertEqual(reread.root, archive.root)
    }

    func testEachTemplateGetsFreshIdentifiers() throws {
        let first = try projectJSON(from: HorizontalProjectArchive.newProject())
        let second = try projectJSON(from: HorizontalProjectArchive.newProject())

        let firstID = try XCTUnwrap(first["uuid"] as? String)
        let secondID = try XCTUnwrap(second["uuid"] as? String)
        XCTAssertNotEqual(firstID, secondID)
    }

    func testCustomNameShapesTheFilenamesAndSurvivesUnsafeCharacters() {
        let archive = HorizontalProjectArchive.newProject(named: "Amp: Rev/A")

        XCTAssertEqual(archive.suggestedFilename, "Amp- Rev-A.horizontal")
        XCTAssertNotNil(archive.regularFileData(relativePath: "Amp- Rev-A.hprj"))
    }

    // MARK: - Helpers

    private func projectJSON(from archive: HorizontalProjectArchive) throws -> [String: Any] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "Untitled.hprj"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-template-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
