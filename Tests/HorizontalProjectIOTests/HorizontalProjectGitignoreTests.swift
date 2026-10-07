import Foundation
import HorizontalProjectIO
import XCTest

/// Horizon's project `.gitignore`: written with a new project, and checked and
/// fixed when one opens (`Project::create`, `gitignore_needs_fixing`,
/// `fix_gitignore`).
final class HorizontalProjectGitignoreTests: XCTestCase {
    func testANewProjectCarriesHorizonsLines() throws {
        let archive = HorizontalProjectArchive.newProject()
        let data = try XCTUnwrap(archive.regularFileData(relativePath: ".gitignore"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "pool/*.db\npool/*.db-*\n*.imp_meta\n*.autosave\n*.bak\n")
        XCTAssertFalse(archive.gitignoreNeedsFixing)
    }

    func testMissingLinesAreAppendedOnceAndTrimmedLinesCount() throws {
        var archive = HorizontalProjectArchive.newProject()
        try archive.replaceRegularFileData(relativePath: ".gitignore", with: Data("build/\n  *.bak  \npool/*.db".utf8))
        XCTAssertTrue(archive.gitignoreNeedsFixing)
        XCTAssertTrue(try archive.fixGitignore())
        let fixed = String(decoding: try XCTUnwrap(archive.regularFileData(relativePath: ".gitignore")), as: UTF8.self)
        XCTAssertEqual(fixed, "build/\n  *.bak  \npool/*.db\npool/*.db-*\n*.imp_meta\n*.autosave\n")
        XCTAssertFalse(archive.gitignoreNeedsFixing)
        XCTAssertFalse(try archive.fixGitignore())
    }

    func testAProjectWithoutAGitignoreIsLeftAlone() throws {
        let archive = HorizontalProjectArchive(root: .directory(["Board.hprj": .regularFile(Data("{}".utf8))]))
        XCTAssertEqual(archive.gitignoreRelativePath, ".gitignore")
        XCTAssertFalse(archive.gitignoreNeedsFixing)
    }

    func testTheGitignoreIsTheOneBesideANestedProjectFile() throws {
        var archive = HorizontalProjectArchive(root: .directory([
            ".gitignore": .regularFile(Data("other\n".utf8)),
            "Billo Horizon": .directory([
                "Billo.hprj": .regularFile(Data("{}".utf8)),
                ".gitignore": .regularFile(HorizontalProjectGitignore.data)
            ])
        ]))
        XCTAssertEqual(archive.gitignoreRelativePath, "Billo Horizon/.gitignore")
        XCTAssertFalse(archive.gitignoreNeedsFixing)
        XCTAssertFalse(try archive.fixGitignore())
        XCTAssertEqual(archive.regularFileData(relativePath: ".gitignore"), Data("other\n".utf8))
    }

    func testAWrittenPackageKeepsItsGitignore() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitignore-\(UUID().uuidString).horizontal")
        defer { try? FileManager.default.removeItem(at: url) }
        try HorizontalProjectArchive.newProject().write(to: url)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(".gitignore")), HorizontalProjectGitignore.data)
    }

    /// A `.hprj` opens as a manifest-built archive; its `.gitignore` comes along
    /// so it can be checked, and a fix saves in place.
    func testAnHprjProjectBringsItsGitignoreAndAFixSavesInPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitignore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try HorizontalProjectArchive.newProject(named: "Board").write(to: folder)
        try Data("pool/*.db\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))

        var archive = try HorizontalProjectArchive.completeProject(from: folder.appendingPathComponent("Board.hprj"))
        XCTAssertEqual(archive.gitignoreRelativePath, ".gitignore")
        XCTAssertTrue(archive.gitignoreNeedsFixing)
        XCTAssertTrue(try archive.fixGitignore())
        XCTAssertEqual(try archive.writeInPlace(), [".gitignore"])
        XCTAssertEqual(String(decoding: try Data(contentsOf: folder.appendingPathComponent(".gitignore")), as: UTF8.self),
                       "pool/*.db\npool/*.db-*\n*.imp_meta\n*.autosave\n*.bak\n")
    }
}
