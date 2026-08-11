#if os(macOS)
import Foundation
import XCTest
@testable import HorizontalNative

/// The sandbox gate for opening a bare Horizon `.hprj`.
///
/// Opening one from Finder or the open panel grants access to that single file,
/// while its board / blocks / schematic / pool are SIBLINGS. Because
/// `HorizontalProject.load` records an unreadable sibling as a non-fatal
/// diagnostic and carries on, a missing grant used to surface as a project
/// window whose panes were all silently empty. These tests pin the check that
/// makes the open refuse instead.
@MainActor
final class HorizontalProjectFolderAccessTests: XCTestCase {
    func testUnreadableFolderReportsNoAccess() {
        // A folder that cannot be listed is exactly what a revoked or
        // never-granted sandbox scope looks like — it must report no access so
        // the document refuses rather than opening blank.
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Project.hprj")

        XCTAssertFalse(HorizontalFolderAccessStore.hasProjectFolderAccess(for: url))
    }

    func testReadableFolderReportsAccess() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let projectFile = folder.appendingPathComponent("Project.hprj")
        try Data("{}".utf8).write(to: projectFile)

        XCTAssertTrue(HorizontalFolderAccessStore.hasProjectFolderAccess(for: projectFile))
    }

    func testFilesInsideAHorizontalPackageAlwaysReportAccess() {
        // A .horizontal package is granted as a unit, so its contents must never
        // be gated — even for a path that doesn't exist, which proves the check
        // short-circuits before probing the filesystem.
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Sample.horizontal/Sample.hprj")

        XCTAssertTrue(HorizontalFolderAccessStore.hasProjectFolderAccess(for: url))
    }

    func testMessageNamesBothTheProjectAndTheFolderToGrant() {
        // "Grant access to a folder" is useless without saying which folder
        // macOS will ask about, so both names have to appear.
        let url = URL(fileURLWithPath: "/tmp/Randi Short Horizon/Randi Short.hprj")

        let message = HorizontalFolderAccessStore.projectFolderAccessMessage(for: url)

        XCTAssertTrue(message.contains("Randi Short.hprj"), "should name the project")
        XCTAssertTrue(message.contains("Randi Short Horizon"), "should name the folder to grant")
        XCTAssertTrue(message.contains("Grant Access"), "should point at the recovery action")
    }
}
#endif
