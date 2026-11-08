import Foundation
import HorizontalProjectIO
import XCTest

/// A package's `.hprj` takes the package's name, and an export writes into a
/// folder without taking away what else is there.
final class HorizontalProjectFileNameTests: XCTestCase {
    private func names(_ archive: HorizontalProjectArchive) -> [String] {
        archive.regularFilePaths.filter { $0.hasSuffix(".hprj") }
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hprj-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testANewProjectsHprjTakesThePackagesName() throws {
        let untitled = HorizontalProjectArchive.newProject()
        XCTAssertEqual(names(untitled), ["Untitled.hprj"])
        XCTAssertEqual(untitled.packageProjectFileName(), "Untitled.hprj")

        let saved = untitled.renamingProjectFile(toMatchPackageNamed: "Evan.horizontal")
        XCTAssertEqual(names(saved), ["Evan.hprj"])
        XCTAssertEqual(saved.regularFileData(relativePath: "Evan.hprj"), untitled.regularFileData(relativePath: "Untitled.hprj"),
                       "the same project, under the package's name")
        XCTAssertEqual(saved.regularFilePaths.count, untitled.regularFilePaths.count, "nothing else moves")
        XCTAssertEqual(saved.renamingProjectFile(toMatchPackageNamed: "Evan.horizontal"), saved, "a second save changes nothing")
        XCTAssertEqual(untitled.renamingProjectFile(toMatchPackageNamed: "Evan").packageProjectFileName(), "Evan.hprj",
                       "a folder's name, without an extension, names it the same way")
    }

    func testANameThatOnlyDiffersInCaseOrIsTakenOrAmbiguousIsLeftAlone() throws {
        let untitled = HorizontalProjectArchive.newProject()
        XCTAssertEqual(untitled.renamingProjectFile(toMatchPackageNamed: "untitled.horizontal"), untitled, "opening already picks it")

        var taken = untitled
        try taken.replaceRegularFileData(relativePath: "evan.hprj/notes.txt", with: Data())
        XCTAssertEqual(taken.renamingProjectFile(toMatchPackageNamed: "Evan.horizontal"), taken, "a folder already has the name")
        var two = untitled
        try two.replaceRegularFileData(relativePath: "Other.hprj", with: Data("{}".utf8))
        XCTAssertEqual(two.renamingProjectFile(toMatchPackageNamed: "Evan.horizontal"), two,
                       "of two projects, renaming one could change which one opens")
        XCTAssertEqual(two.packageProjectFileName(packageName: "Other"), "Other.hprj", "the one named like the package")
        XCTAssertEqual(two.packageProjectFileName(), "Other.hprj", "else the first by name")

        let file = HorizontalProjectArchive(regularFileData: Data("{}".utf8), suggestedFilename: "Evan.hprj")
        XCTAssertEqual(file.renamingProjectFile(toMatchPackageNamed: "Other.horizontal"), file, "a single file is no package")
        XCTAssertNil(file.packageProjectFileName())
        XCTAssertEqual(untitled.renamingProjectFile(toMatchPackageNamed: " .horizontal"), untitled, "a name with nothing in it")
        XCTAssertEqual(HorizontalProjectArchive.projectFileName(forPackageNamed: "A/B: C.horizontal"), "A-B- C.hprj")
    }

    func testTheManifestNamesTheRenamedFile() throws {
        // A project gathered from its .hprj says where its files came from.
        let folder = try temporaryFolder().appendingPathComponent("Untitled")
        try HorizontalProjectArchive.newProject().write(to: folder)
        let gathered = try HorizontalProjectArchive.completeProject(from: folder.appendingPathComponent("Untitled.hprj"))
        XCTAssertEqual(gathered.manifest?.projectFileURL.lastPathComponent, "Untitled.hprj")

        let renamed = gathered.renamingProjectFile(toMatchPackageNamed: "Evan.horizontal")
        let manifest = try XCTUnwrap(renamed.manifest)
        XCTAssertEqual(manifest.projectFileURL.lastPathComponent, "Evan.hprj")
        XCTAssertTrue(manifest.relativePaths.contains("Evan.hprj"))
        XCTAssertFalse(manifest.relativePaths.contains("Untitled.hprj"))
    }

    func testWritingIntoAFolderReplacesTheProjectsFilesAndKeepsTheRest() throws {
        let folder = try temporaryFolder().appendingPathComponent("Evan Horizon")
        let fabrication = folder.appendingPathComponent("Fabrication/gerbers.zip")
        try FileManager.default.createDirectory(at: fabrication.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("gerbers".utf8).write(to: fabrication)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("board.json"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: folder.appendingPathComponent("top_block.json"))

        let archive = HorizontalProjectArchive.newProject().renamingProjectFile(toMatchPackageNamed: "Evan Horizon")
        try archive.writeContents(into: folder)

        XCTAssertEqual(try Data(contentsOf: fabrication), Data("gerbers".utf8), "what the project doesn't hold stays")
        for path in archive.regularFilePaths {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), archive.regularFileData(relativePath: path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Evan Horizon.hprj").path))
        XCTAssertThrowsError(try HorizontalProjectArchive(regularFileData: Data()).writeContents(into: folder), "a single file is no folder")
    }
}
