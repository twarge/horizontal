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
                "pool/pool.json",
                "top_block.json",
                "top_schematic.json",
                "top_symbol.json",
                "Untitled.hprj"
            ]
        )
        XCTAssertEqual(archive.suggestedFilename, "Untitled.horizontal")
        XCTAssertNil(archive.manifest)
    }

    /// A new project carries Horizon's project pool: `pool/pool.json` with
    /// the project-pool uuid, named by the project file as `pool_directory`,
    /// so parts placed from a library have somewhere to be cached and
    /// Horizon itself can open the project.
    func testNewProjectHasAProjectPool() throws {
        let pool = HorizontalProjectPoolTemplate(
            includedPoolUUIDs: ["8fdb6a1f-7d4b-4a80-9b0c-7d22ab0d8f7a"],
            defaultViaUUID: "1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c",
            defaultFrameUUID: nil
        )
        let archive = HorizontalProjectArchive.newProject(pool: pool)
        let project = try projectJSON(from: archive)
        XCTAssertEqual(project["pool_directory"] as? String, "pool")

        let data = try XCTUnwrap(archive.regularFileData(relativePath: "pool/pool.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "pool")
        XCTAssertEqual(json["uuid"] as? String, HorizontalProjectArchive.projectPoolUUID)
        XCTAssertEqual(json["name"] as? String, "Project pool")
        XCTAssertEqual(json["pools_included"] as? [String], ["8fdb6a1f-7d4b-4a80-9b0c-7d22ab0d8f7a"])
        XCTAssertEqual(json["default_via"] as? String, "1c4d3f0a-8e7b-4a6e-9c3d-2b1a0f9e8d7c")
        // Horizon parses every uuid it reads, so an unset default is the null uuid, not an empty string.
        XCTAssertEqual(json["default_frame"] as? String, HorizontalProjectArchive.nullUUID)

        let bare = try XCTUnwrap(JSONSerialization.jsonObject(with: HorizontalProjectArchive.projectPoolData()) as? [String: Any])
        XCTAssertEqual(bare["pools_included"] as? [String], [])
        XCTAssertEqual(bare["default_via"] as? String, HorizontalProjectArchive.nullUUID)
    }

    /// A layer's substrate is the dielectric below it, so the bottom copper
    /// has none; Horizon's own new board writes it that way.
    func testBottomCopperHasNoSubstrate() throws {
        let archive = HorizontalProjectArchive.newProject()
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stackup = try XCTUnwrap(json["stackup"] as? [String: Any])
        let top = try XCTUnwrap(stackup["0"] as? [String: Any])
        let bottom = try XCTUnwrap(stackup["-100"] as? [String: Any])
        XCTAssertEqual(top["substrate_thickness"] as? Int, 1_600_000)
        XCTAssertEqual(bottom["substrate_thickness"] as? Int, 0)
        XCTAssertEqual(bottom["thickness"] as? Int, 35_000)
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
                "pool",
                "top_block.json",
                "top_schematic.json",
                "top_symbol.json",
                "Untitled.hprj"
            ]
        )
        XCTAssertEqual(manifest.poolDirectoryURL, packageURL.appendingPathComponent("pool").standardizedFileURL)
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
