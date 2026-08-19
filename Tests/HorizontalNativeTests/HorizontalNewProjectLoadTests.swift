import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Loading the new-document template through the real project loader.
///
/// The template's job is to be a project the full pipeline accepts silently: a
/// board, a schematic with one sheet, a default net class, and not a single
/// diagnostic. A diagnostic on a brand-new document would greet every File >
/// New with a warning about a project the user hasn't touched yet.
final class HorizontalNewProjectLoadTests: XCTestCase {
    func testTemplateLoadsCleanlyWithBoardAndSchematic() throws {
        let packageURL = try writtenTemplate()

        let project = try HorizontalProject.load(from: packageURL)

        XCTAssertEqual(project.diagnostics.map(\.message), [])
        XCTAssertNotNil(project.board)
        XCTAssertNotNil(project.schematic)
        XCTAssertEqual(project.schematic?.sheets.count, 1)
        XCTAssertEqual(project.schematic?.sheets.first?.name, "Sheet 1")
        XCTAssertEqual(project.schematic?.netClasses.map(\.name), ["Default"])
        XCTAssertTrue(project.poolParts.isEmpty)
    }

    func testTemplateBoardHasTheStockTwoLayerStackup() throws {
        let packageURL = try writtenTemplate()

        let board = try XCTUnwrap(HorizontalProject.load(from: packageURL).board)

        XCTAssertEqual(board.stackupLayers.map(\.layer), [0, -100])
        XCTAssertEqual(board.stackupLayers.map(\.copperThickness), [35_000, 35_000])
        XCTAssertTrue(board.tracks.isEmpty)
        XCTAssertTrue(board.packages.isEmpty)
    }

    func testTemplateCanvasesGetTheEmptyContentRegion() throws {
        // An empty document must never hand the canvases empty bounds: the fit
        // renders at one nanometer per pixel and the input transforms map every
        // click to the origin, so a brand-new project looked frozen.
        let packageURL = try writtenTemplate()

        let project = try HorizontalProject.load(from: packageURL)

        XCTAssertEqual(project.board?.bounds, .emptyContentCanvasRegion)
        XCTAssertEqual(project.schematic?.sheets.first?.bounds, .emptyContentCanvasRegion)
    }

    func testBlockEditsApplyToATemplateProject() throws {
        // The block-level patchers throw when `nets` / `components` are absent
        // instead of creating them, so the template must ship both — otherwise
        // the first rename or net-class assignment on a new document fails.
        let packageURL = try writtenTemplate()
        let project = try HorizontalProject.load(from: packageURL)
        var archive = try HorizontalProjectArchive.completeProject(from: packageURL)
        let blockURL = try XCTUnwrap(
            project.blockFilename.map { project.baseURL.appendingPathComponent($0) }
        )

        XCTAssertNoThrow(
            try HorizontalProjectJSONApplicator.apply(
                netClassID: "some-class",
                forNetID: "some-net",
                blockURL: blockURL,
                in: project,
                to: &archive
            )
        )
        XCTAssertNoThrow(
            try HorizontalProjectJSONApplicator.apply(
                componentRefdes: "R1",
                forComponentID: "some-component",
                blockURL: blockURL,
                in: project,
                to: &archive
            )
        )
    }

    // MARK: - Helpers

    private func writtenTemplate() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-new-project-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        return packageURL
    }
}
