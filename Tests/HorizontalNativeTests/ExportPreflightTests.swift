import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Export All writes the board as designed and says what is wrong with it:
/// planes that Clear All Planes emptied are poured for the export, and the
/// rules checks run on what it wrote, their findings counted in its status.
final class ExportPreflightTests: XCTestCase {
    private func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-preflight-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A new document: two GND planes, poured, and nothing for the checks
    /// to find.
    private func newDocument() throws -> (project: HorizontalProject, archive: HorizontalProjectArchive) {
        let packageURL = try temporaryRoot("document").appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newPouredProject().write(to: packageURL)
        return (try HorizontalProject.load(from: packageURL), try HorizontalProjectArchive.completeProject(from: packageURL))
    }

    /// Export All of the Gerbers, unzipped: its status, and each file it
    /// wrote by name.
    private func exportedGerbers(
        of project: HorizontalProject, archive: HorizontalProjectArchive?
    ) async throws -> (status: HorizontalExportStatus, files: [String: Data]) {
        let target = try temporaryRoot("target")
        var settings = HorizontalExportSettings(project: project)
        settings.targetDirectory = target.path
        settings.gerber.zipOutput = false
        let status = await HorizontalExportPreflight.export(
            sections: [.gerber], settings: settings, project: project, archive: archive,
            schematicPDFPalette: .defaultPalette(kind: .schematic, mode: .light),
            boardPDFPalette: .defaultPalette(kind: .board, mode: .light),
            silkscreenClipping: nil
        )
        var files = [String: Data]()
        for name in try FileManager.default.contentsOfDirectory(atPath: target.path) {
            files[name] = try Data(contentsOf: target.appendingPathComponent(name))
        }
        return (status, files)
    }

    private func cleared(_ project: HorizontalProject) throws -> HorizontalProject {
        var project = project
        var board = try XCTUnwrap(project.board)
        XCTAssertTrue(board.planes.contains { !$0.fragments.isEmpty }, "precondition: the new document's planes are poured")
        board.clearPlaneFills()
        project.board = board
        return project
    }

    // MARK: - Cleared planes

    func testAnExportPoursThePlanesClearAllPlanesEmptied() throws {
        let document = try newDocument()
        let poured = try XCTUnwrap(document.project.board)

        let exported = try XCTUnwrap(HorizontalExportPreflight.pouringClearedPlanes(in: try cleared(document.project)).board)

        XCTAssertEqual(exported.planes.map(\.fragments), poured.planes.map(\.fragments), "the fills the board had before they were cleared")
        XCTAssertFalse(exported.planeFillsCleared)
        XCTAssertEqual(exported.airwires, poured.airwires, "and the rats' nest that goes with them")
    }

    func testAnExportLeavesABoardThatIsNotClearedAsItIs() throws {
        var project = try newDocument().project
        // Unpoured without having been cleared: the board as its files have
        // it, which is the export's to write and the checks' to report.
        project.board?.planes[0].fragments = []

        let exported = try XCTUnwrap(HorizontalExportPreflight.pouringClearedPlanes(in: project).board)

        XCTAssertEqual(exported.planes[0].fragments, [])
    }

    /// The reason for it: Gerbers of a board whose planes were cleared had
    /// no pours in them.
    func testGerbersOfABoardWithClearedPlanesHaveItsPours() async throws {
        let document = try newDocument()
        let asDesigned = try await exportedGerbers(of: document.project, archive: document.archive)
        XCTAssertEqual(asDesigned.status.kind, .success, asDesigned.status.message)

        let whileCleared = try await exportedGerbers(of: try cleared(document.project), archive: document.archive)

        XCTAssertEqual(whileCleared.status.kind, .success, whileCleared.status.message)
        XCTAssertFalse(asDesigned.files.isEmpty)
        XCTAssertEqual(whileCleared.files.keys.sorted(), asDesigned.files.keys.sorted())
        for (name, data) in asDesigned.files {
            XCTAssertEqual(whileCleared.files[name], data, "\(name) is the file the poured board gives")
        }
        XCTAssertNil(whileCleared.status.checks, "and the checks see the planes poured, as the files have them")
    }

    // MARK: - Checks

    func testTheChecksFindNothingInANewDocument() throws {
        let document = try newDocument()
        let summary = HorizontalExportPreflight.checks(of: document.project, archive: document.archive)
        XCTAssertEqual(summary, HorizontalExportCheckSummary())
        XCTAssertTrue(summary.isEmpty)
    }

    func testTheChecksCountWhatTheBoardChecksFind() throws {
        let document = try newDocument()
        var project = document.project
        let planes = try XCTUnwrap(project.board).planes.count
        for index in 0..<planes {
            project.board?.planes[index].fragments = []
        }

        let summary = HorizontalExportPreflight.checks(of: project, archive: document.archive)

        XCTAssertGreaterThanOrEqual(summary.errors, planes, "each plane with no fragments is an error")
        XCTAssertFalse(summary.isEmpty)
    }

    func testAnExportWithFindingsWritesItsFilesAndSaysWhatWasFound() async throws {
        let document = try newDocument()
        var project = document.project
        project.board?.planes[0].fragments = []
        let expected = HorizontalExportPreflight.checks(of: project, archive: document.archive)
        XCTAssertGreaterThan(expected.errors, 0, "precondition: an unpoured plane fails the checks")

        let exported = try await exportedGerbers(of: project, archive: document.archive)

        XCTAssertEqual(exported.status.kind, .success, "the warning does not hold the files back")
        XCTAssertFalse(exported.files.isEmpty)
        XCTAssertFalse(exported.status.outputs.isEmpty)
        XCTAssertEqual(exported.status.checks, expected)
    }

    func testAnExportThatFailsSaysWhyRatherThanWhatTheChecksFound() async throws {
        let document = try newDocument()
        var project = document.project
        project.board?.planes[0].fragments = []
        var settings = HorizontalExportSettings(project: project)
        // Under a file, where no directory can be made.
        let file = try temporaryRoot("blocked").appendingPathComponent("file")
        try Data().write(to: file)
        settings.targetDirectory = file.appendingPathComponent("out").path

        let status = await HorizontalExportPreflight.export(
            sections: [.gerber], settings: settings, project: project, archive: document.archive,
            schematicPDFPalette: .defaultPalette(kind: .schematic, mode: .light),
            boardPDFPalette: .defaultPalette(kind: .board, mode: .light),
            silkscreenClipping: nil
        )

        XCTAssertEqual(status.kind, .error)
        XCTAssertNil(status.checks)
    }

    func testTheSummarySaysHowManyOfEach() {
        XCTAssertEqual(HorizontalExportCheckSummary(errors: 1, warnings: 0).message, "The rules checks found 1 error.")
        XCTAssertEqual(HorizontalExportCheckSummary(errors: 0, warnings: 2).message, "The rules checks found 2 warnings.")
        XCTAssertEqual(HorizontalExportCheckSummary(errors: 3, warnings: 1).message, "The rules checks found 3 errors and 1 warning.")
    }
}
