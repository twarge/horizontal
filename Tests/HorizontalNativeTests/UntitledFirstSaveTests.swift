import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A new document is loaded from a copy of its template in a temporary
/// folder until its first save, which moves the open project to the saved
/// files rather than reading them back into a new workspace.
final class UntitledFirstSaveTests: XCTestCase {
    private func temporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The template with a part in its project pool, so the project names a
    /// file there too.
    private func writtenProject(at url: URL) throws {
        try HorizontalProjectArchive.newProject().write(to: url)
        let poolURL = url.appendingPathComponent("pool")
        let unit = HorizontalPoolItemFactory.newUnit()
        let entity = HorizontalPoolItemFactory.newEntity(for: unit)
        let package = HorizontalPoolItemFactory.newPackage()
        let part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        _ = try HorizontalPoolItemFactory.write(.unit(unit), to: poolURL.appendingPathComponent("units/cache/\(unit.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.entity(entity), to: poolURL.appendingPathComponent("entities/cache/\(entity.uuid).json"))
        _ = try HorizontalPoolItemFactory.write(.package(package), to: poolURL.appendingPathComponent("packages/cache/\(package.uuid)/package.json"))
        _ = try HorizontalPoolItemFactory.write(.part(part), to: poolURL.appendingPathComponent("parts/cache/\(part.uuid).json"))
    }

    private func paths(_ project: HorizontalProject) -> [String] {
        let files = [project.url, project.projectFileURL, project.baseURL]
            + [project.board?.url, project.schematic?.url].compactMap { $0 }
            + project.schematics.map(\.schematic.url)
            + project.poolParts.compactMap(\.fileURL)
        return files.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }

    /// The project moved to where a save wrote its files names each file
    /// where loading it from there would.
    func testAMovedProjectNamesTheFilesWhereTheSaveWroteThem() throws {
        let untitled = try temporaryFolder("untitled").appendingPathComponent("Untitled.horizontal")
        let saved = try temporaryFolder("saved").appendingPathComponent("Saved.horizontal")
        try writtenProject(at: untitled)
        var project = try HorizontalProject.load(from: untitled)
        XCTAssertEqual(project.poolParts.count, 1)
        try HorizontalProjectArchive.completeProject(from: untitled).write(to: saved)

        project.move(to: saved)

        XCTAssertEqual(paths(project), paths(try HorizontalProject.load(from: saved)))
        XCTAssertEqual(project.url, saved)
        let untitledPath = untitled.resolvingSymlinksInPath().path
        XCTAssertFalse(paths(project).contains { $0.hasPrefix(untitledPath) }, "\(paths(project))")
    }

    /// The temporary folder is /var/folders/… to FileManager and
    /// /private/var/folders/… once its link is followed; a file under either
    /// spelling moves.
    func testBothSpellingsOfATemporaryFolderMove() throws {
        let folder = try temporaryFolder("spelling")
        guard folder.path.hasPrefix("/var/") else { throw XCTSkip("The temporary folder is not under /var here") }
        let old = folder.appendingPathComponent("Untitled.horizontal")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("pool"), withIntermediateDirectories: true)
        let linked = URL(fileURLWithPath: "/private" + old.path)
        let new = URL(fileURLWithPath: "/Users/someone/Saved.horizontal")

        XCTAssertEqual(HorizontalProject.file(linked.appendingPathComponent("pool"), movedFrom: old, to: new).path,
                       "/Users/someone/Saved.horizontal/pool")
        XCTAssertEqual(HorizontalProject.file(old.appendingPathComponent("pool"), movedFrom: linked, to: new).path,
                       "/Users/someone/Saved.horizontal/pool")
        XCTAssertEqual(HorizontalProject.file(old, movedFrom: old, to: new), new)
        // Beside the project, not in it: a sibling that only shares the name's
        // beginning, and the folder above.
        let sibling = folder.appendingPathComponent("Untitled.horizontal-models/model.step")
        XCTAssertEqual(HorizontalProject.file(sibling, movedFrom: old, to: new), sibling)
        XCTAssertEqual(HorizontalProject.file(folder, movedFrom: old, to: new), folder)
    }
}

/// The real workspace, mounted, through a first save: the live channel
/// follows the project to its saved files, edits land there, and an undo
/// back past the save keeps it there.
@MainActor
final class UntitledFirstSaveWorkspaceTests: XCTestCase {
    private final class DocumentState: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var projectURL: URL
        init(_ archive: HorizontalProjectArchive, projectURL: URL) {
            self.projectURL = projectURL
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var state: DocumentState
        var project: HorizontalProject
        @State var panes: Set<HorizontalPane> = [.board, .schematic]
        @State var nets = Set<String>()
        @State var highlightedNets = Set<String>()
        @State var components = Set<String>()
        @State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, projectURL: state.projectURL, document: $state.document, visiblePanes: $panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }

    private func settle(until predicate: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func liveEntry(at url: URL) -> HorizontalDispatchProjectEntry? {
        HorizontalDispatchSession.shared.openEntries.first {
            $0.live != nil && $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
        }
    }

    private func placeText(_ text: String, in entry: HorizontalDispatchProjectEntry, undo: UndoManager) -> JSONDictionary {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": entry.handle, "expected_revision": entry.revision, "operation_id": UUID().uuidString,
            "ops": [["op": "place_board_text", "text": text, "layer": 0, "x_mm": 1, "y_mm": 1]]
        ]])
    }

    private func boardTexts(_ state: DocumentState) throws -> [String] {
        let data = try XCTUnwrap(state.document.archive.regularFileData(relativePath: "board.json"))
        let board = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        return (board["texts"] as? [String: JSONDictionary] ?? [:]).values.compactMap { $0["text"] as? String }.sorted()
    }

    func testTheFirstSaveMovesTheOpenProjectToItsFiles() async throws {
        _ = NSApplication.shared
        let untitledFolder = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-\(UUID().uuidString)")
        let savedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: untitledFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: untitledFolder)
            try? FileManager.default.removeItem(at: savedFolder)
        }
        let untitled = untitledFolder.appendingPathComponent("Untitled.horizontal")
        let saved = savedFolder.appendingPathComponent("Saved.horizontal")
        let archive = HorizontalProjectArchive.newProject()
        try archive.write(to: untitled)
        let state = DocumentState(archive, projectURL: untitled)
        let project = try HorizontalProject.load(from: untitled)

        let defaults = UserDefaults(suiteName: "untitled-first-save-\(UUID().uuidString)")!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let undo = UndoManager()
        undo.groupsByEvent = false
        // The document the save gives a URL. Found by the untitled one's URL
        // here, so that its edits go on the undo stack the saved one keeps.
        let registeredDocument = NSDocument()
        registeredDocument.fileURL = untitled
        registeredDocument.undoManager = undo
        NSDocumentController.shared.addDocument(registeredDocument)
        defer { NSDocumentController.shared.removeDocument(registeredDocument) }
        let hosted = NSHostingView(rootView: Workspace(state: state, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        let opened = await settle { self.liveEntry(at: untitled) != nil }
        XCTAssertTrue(opened, "The untitled document is served live")
        let before = try XCTUnwrap(liveEntry(at: untitled))
        let beforeEdit = placeText("BEFORE", in: before, undo: undo)
        XCTAssertNil(beforeEdit["error"], "\(beforeEdit)")

        // The save: the files written where the user chose, and the document
        // at that URL.
        try state.document.archive.write(to: saved)
        registeredDocument.fileURL = saved
        state.projectURL = saved

        let moved = await settle { self.liveEntry(at: saved) != nil && self.liveEntry(at: untitled) == nil }
        XCTAssertTrue(moved, "The live channel follows the project to its saved files")
        let after = try XCTUnwrap(liveEntry(at: saved))
        let movedProject = try XCTUnwrap(after.live?.currentProject())
        let savedPath = saved.resolvingSymlinksInPath().path
        for url in [movedProject.url, movedProject.baseURL, movedProject.projectFileURL, movedProject.board?.url, movedProject.schematic?.url] {
            XCTAssertTrue(try XCTUnwrap(url).resolvingSymlinksInPath().path.hasPrefix(savedPath), "\(String(describing: url))")
        }
        XCTAssertEqual(try boardTexts(state), ["BEFORE"], "The design is the one shown, not read again")

        let afterEdit = placeText("AFTER", in: after, undo: undo)
        XCTAssertNil(afterEdit["error"], "\(afterEdit)")
        XCTAssertEqual(try boardTexts(state), ["AFTER", "BEFORE"])

        // Back past the save: the design from before it, the files from after.
        undo.undo()
        undo.undo()
        XCTAssertEqual(try boardTexts(state), [])
        let undone = try XCTUnwrap(liveEntry(at: saved)?.live?.currentProject())
        XCTAssertEqual(undone.url.resolvingSymlinksInPath(), saved.resolvingSymlinksInPath())
        XCTAssertTrue(try XCTUnwrap(undone.board?.url).resolvingSymlinksInPath().path.hasPrefix(savedPath))
        HorizontalDispatchSession.shared.syncLiveEntries()
        let again = placeText("AGAIN", in: try XCTUnwrap(liveEntry(at: saved)), undo: undo)
        XCTAssertNil(again["error"], "\(again)")
        XCTAssertEqual(try boardTexts(state), ["AGAIN"])
    }
}
