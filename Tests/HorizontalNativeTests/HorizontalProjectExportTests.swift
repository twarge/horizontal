import Foundation
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// File ▸ Export… copies the project as a package or as a Horizon project
/// folder, its `.hprj` named after the copy, and a package save names the
/// package's `.hprj` after the package.
final class HorizontalProjectExportTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A new project saved as `Evan.horizontal`, still holding `Untitled.hprj`.
    private func savedPackage(in folder: URL) throws -> (URL, HorizontalProject, HorizontalProjectArchive) {
        let package = folder.appendingPathComponent("Evan.horizontal")
        try HorizontalProjectArchive.newProject().write(to: package)
        let archive = try HorizontalProjectArchive.snapshot(from: package)
        XCTAssertEqual(archive.packageProjectFileName(), "Untitled.hprj", "precondition")
        return (package, try HorizontalProject.load(from: package), archive)
    }

    private func hprjFiles(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { $0.hasSuffix(".hprj") }.sorted()
    }

    func testAHorizonFolderHoldsAnHprjNamedAfterItAndTheFilesItNames() throws {
        let folder = try temporaryFolder()
        let (_, project, archive) = try savedPackage(in: folder)
        XCTAssertEqual(HorizontalProjectExport.defaultFormat(for: project), .horizonFolder, "a package exports to a folder first")
        XCTAssertEqual(HorizontalProjectExport.suggestedName(for: project), "Evan")

        let chosen = folder.appendingPathComponent("Evan Horizon")
        let written = try HorizontalProjectExport.export(archive, of: project, as: .horizonFolder, to: chosen, isReadOnly: false)
        XCTAssertEqual(written, chosen)
        XCTAssertEqual(try hprjFiles(in: written), ["Evan Horizon.hprj"])
        let opened = try HorizontalProject.load(from: written.appendingPathComponent("Evan Horizon.hprj"))
        XCTAssertEqual(opened.board?.uuid, project.board?.uuid, "Horizon's way in opens the same board")
        XCTAssertEqual(opened.schematics.count, project.schematics.count)
    }

    func testAPackageTakesHorizontalAndItsHprjTakesItsName() throws {
        let folder = try temporaryFolder()
        let (_, project, archive) = try savedPackage(in: folder)
        let written = try HorizontalProjectExport.export(archive, of: project, as: .package, to: folder.appendingPathComponent("Copy"), isReadOnly: false)
        XCTAssertEqual(written.lastPathComponent, "Copy.horizontal")
        XCTAssertEqual(try hprjFiles(in: written), ["Copy.hprj"])
        XCTAssertEqual(try HorizontalProject.load(from: written).board?.uuid, project.board?.uuid)

        XCTAssertEqual(HorizontalProjectExport.destination(for: folder.appendingPathComponent("A.horizontal"), format: .horizonFolder).lastPathComponent, "A")
        XCTAssertEqual(HorizontalProjectExport.destination(for: folder.appendingPathComponent("A.horizontal"), format: .package).lastPathComponent, "A.horizontal")
    }

    func testAnExportIntoAFolderKeepsWhatElseIsThere() throws {
        let folder = try temporaryFolder()
        let (_, project, archive) = try savedPackage(in: folder)
        let target = folder.appendingPathComponent("Evan Horizon")
        let notes = target.appendingPathComponent("Fabrication/notes.txt")
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: notes)
        try Data("stale".utf8).write(to: target.appendingPathComponent("board.json"))

        try HorizontalProjectExport.export(archive, of: project, as: .horizonFolder, to: target, isReadOnly: false)
        XCTAssertEqual(try Data(contentsOf: notes), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("board.json")), archive.regularFileData(relativePath: "board.json"))

        XCTAssertThrowsError(try HorizontalProjectExport.export(archive, of: project, as: .horizonFolder, to: target, isReadOnly: true)) { error in
            XCTAssertEqual(error as? HorizontalProjectExport.ExportError, .readOnlyOverwrite("Evan Horizon"))
        }
        XCTAssertNoThrow(try HorizontalProjectExport.export(archive, of: project, as: .horizonFolder,
                                                            to: folder.appendingPathComponent("New"), isReadOnly: true),
                         "read-only still writes where nothing is")
    }

    func testAnExportOntoTheProjectItselfIsRefused() throws {
        let folder = try temporaryFolder()
        let (package, project, archive) = try savedPackage(in: folder)
        XCTAssertThrowsError(try HorizontalProjectExport.export(archive, of: project, as: .package, to: package, isReadOnly: false)) { error in
            XCTAssertEqual(error as? HorizontalProjectExport.ExportError, .ontoItself("Evan.horizontal"))
        }
        XCTAssertEqual(try hprjFiles(in: package), ["Untitled.hprj"], "untouched")
    }

    /// The save over a package on disk writes the `.hprj` under the
    /// package's name, and the document holds that copy without an edit: a
    /// copy taken before still shares its storage.
    func testASaveOverAPackageNamesItsHprjAfterThePackage() throws {
        let folder = try temporaryFolder()
        let (package, _, archive) = try savedPackage(in: folder)
        var document = HorizontalProjectDocument()
        document.archive = archive
        let before = document

        let written = document.packageArchive(writing: archive, over: try FileWrapper(url: package))
        XCTAssertEqual(written.packageProjectFileName(), "Evan.hprj")
        XCTAssertEqual(document.archive.packageProjectFileName(), "Evan.hprj", "the document holds what the save wrote")
        XCTAssertTrue(document.hasSameArchive(as: before), "and was not edited to get there")

        let first = HorizontalProjectDocument().packageArchive(writing: archive, over: nil)
        XCTAssertEqual(first.packageProjectFileName(), "Untitled.hprj", "a first save has no package to take a name from")
    }
}
