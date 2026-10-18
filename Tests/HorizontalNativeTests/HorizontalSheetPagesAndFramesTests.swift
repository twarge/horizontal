import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The navigator's sheet edits: New Sheet, Delete Sheet, and a frame taken
/// from a pool the project draws from, cached into the project pool with the
/// edit that uses it.
final class HorizontalSheetPagesAndFramesTests: XCTestCase {
    private var root: URL!
    private var packageURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-editing-\(UUID().uuidString)", isDirectory: true)
        packageURL = root.appendingPathComponent("Project.horizontal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try HorizontalProjectArchive.newProject().write(to: packageURL)
    }

    override func tearDownWithError() throws {
        unsetenv("HORIZONTAL_POOLS")
        try? FileManager.default.removeItem(at: root)
        HorizontalPoolLibrary.invalidateCache()
    }

    private func sheetsJSON(_ archive: HorizontalProjectArchive) throws -> [String: JSONDictionary] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json"))
        return try JSONHelper.loadDictionary(from: data).dictionaryMap("sheets")
    }

    func testNewSheetFollowsTheLastPageAndAnEmptyOneCanBeDeleted() throws {
        var archive = try HorizontalProjectArchive.snapshot(from: packageURL)
        let project = try HorizontalProject.load(from: packageURL)
        let schematicURL = try XCTUnwrap(project.schematics.first?.schematic.url ?? project.schematic?.url)
        let frameID = UUID().uuidString.lowercased()
        let first = try XCTUnwrap(try sheetsJSON(archive).keys.first)
        try HorizontalProjectJSONApplicator.apply(sheetFrame: frameID, forSheetID: first, schematicURL: schematicURL, in: project, to: &archive)

        let second = try HorizontalProjectJSONApplicator.addSheet(schematicURL: schematicURL, in: project, to: &archive)
        let third = try HorizontalProjectJSONApplicator.addSheet(schematicURL: schematicURL, in: project, to: &archive)
        var sheets = try sheetsJSON(archive)
        XCTAssertEqual(sheets[second]?.string("name"), "Sheet 2")
        XCTAssertEqual(sheets[third]?.string("name"), "Sheet 3")
        XCTAssertEqual(sheets[third]?.int("index"), 3)
        XCTAssertEqual(sheets[third]?.string("frame"), frameID, "a new page takes the last page's frame")
        for key in HorizontalSchematic.sheetCollectionKeys {
            XCTAssertNotNil(sheets[third]?[key] as? JSONDictionary, "\(key) is there, empty")
        }
        XCTAssertEqual(try HorizontalProject.loadSnapshot(of: archive).schematic?.sheets.map(\.name), ["Sheet 1", "Sheet 2", "Sheet 3"])

        // A name a page already has is passed over.
        try HorizontalProjectJSONApplicator.apply(sheetName: "Sheet 4", forSheetID: third, schematicURL: schematicURL, in: project, to: &archive)
        let fourth = try HorizontalProjectJSONApplicator.addSheet(schematicURL: schematicURL, in: project, to: &archive)
        XCTAssertEqual(try sheetsJSON(archive)[fourth]?.string("name"), "Sheet 5")

        // A page with a symbol on it stays.
        var schematic = try JSONHelper.loadDictionary(from: try XCTUnwrap(archive.regularFileData(relativePath: "top_schematic.json")))
        var pages = schematic.dictionaryMap("sheets")
        pages[first]?["symbols"] = [UUID().uuidString.lowercased(): ["component": UUID().uuidString.lowercased()]]
        schematic["sheets"] = pages
        try archive.replaceRegularFileData(relativePath: "top_schematic.json", with: try HorizontalHorizonJSONWriter.data(schematic))
        XCTAssertThrowsError(try HorizontalProjectJSONApplicator.removeSheet(first, schematicURL: schematicURL, in: project, to: &archive)) {
            XCTAssertTrue($0.localizedDescription.contains("1 symbol"), $0.localizedDescription)
        }

        // An empty one goes, and the pages after it close up.
        try HorizontalProjectJSONApplicator.removeSheet(second, schematicURL: schematicURL, in: project, to: &archive)
        sheets = try sheetsJSON(archive)
        XCTAssertNil(sheets[second])
        XCTAssertEqual(sheets[first]?.int("index"), 1)
        XCTAssertEqual(sheets[third]?.int("index"), 2)
        XCTAssertEqual(sheets[fourth]?.int("index"), 3)

        // The last page never goes.
        XCTAssertEqual(HorizontalProjectJSONApplicator.sheetDeletionRefusal([:], pageCount: 1), "A schematic keeps at least one sheet.")
        XCTAssertNil(HorizontalProjectJSONApplicator.sheetDeletionRefusal(["symbols": [String: Any](), "block_symbols": [String: Any]()], pageCount: 2))
        XCTAssertNotNil(HorizontalProjectJSONApplicator.sheetDeletionRefusal(["block_symbols": ["b": [String: Any]()]], pageCount: 2))
    }

    func testAFrameFromABasePoolIsCachedWithTheEditThatUsesIt() throws {
        // A base pool the project doesn't include, holding a frame.
        let basePool = root.appendingPathComponent("Stock Pool", isDirectory: true)
        try FileManager.default.createDirectory(at: basePool.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["type": "pool", "uuid": UUID().uuidString.lowercased(), "name": "Stock", "version": 1,
                                                    "pools_included": [String]()])
            .write(to: basePool.appendingPathComponent("pool.json"))
        var frame = HorizontalPoolItemFactory.newFrame()
        frame.name = "A3 Landscape"
        try HorizontalHorizonJSONWriter.data(frame.json()).write(to: basePool.appendingPathComponent("frames/a3.json"))
        setenv("HORIZONTAL_POOLS", basePool.path, 1)
        HorizontalPoolLibrary.invalidateCache()

        let project = try HorizontalProject.load(from: packageURL)
        let poolURL = packageURL.appendingPathComponent("pool", isDirectory: true)
        let offered = try XCTUnwrap(HorizontalSchematic.basePoolFrames(poolURL: poolURL).first { $0.id == frame.uuid })
        XCTAssertEqual(offered.name, "A3 Landscape")
        XCTAssertEqual(offered.source?.poolName, "Stock")
        XCTAssertTrue(project.schematic?.availableFrames.isEmpty ?? true, "the project pool has no frame yet")

        var archive = try HorizontalProjectArchive.snapshot(from: packageURL)
        let schematicURL = try XCTUnwrap(project.schematics.first?.schematic.url ?? project.schematic?.url)
        let sheet = try XCTUnwrap(try sheetsJSON(archive).keys.first)
        try HorizontalProjectJSONApplicator.cacheFrame(try XCTUnwrap(offered.source), in: project, to: &archive)
        try HorizontalProjectJSONApplicator.apply(sheetFrame: offered.id, forSheetID: sheet, schematicURL: schematicURL, in: project, to: &archive)

        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/frames/cache/\(frame.uuid).json"), "cached where a sheet's frame is drawn from")
        XCTAssertFalse(FileManager.default.fileExists(atPath: poolURL.appendingPathComponent("frames/cache/\(frame.uuid).json").path),
                       "in the archive, not written past the document")
        XCTAssertNotNil(archive.regularFileData(relativePath: "pool/\(HorizontalPoolCacheProvenance.path)"), "with where it came from")
        let loaded = try XCTUnwrap(try HorizontalProject.loadSnapshot(of: archive).schematic)
        XCTAssertEqual(loaded.availableFrames.map(\.id), [frame.uuid])
        XCTAssertFalse(try XCTUnwrap(loaded.sheets.first).frameLines.isEmpty, "the frame is drawn")
    }
}
