import AppKit
import MetalKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Mount the real workspace and issue live edits. Export renders and document
/// stand-ins cannot detect a canvas that keeps displaying an old scene.
@MainActor
final class HorizontalLiveCanvasTests: XCTestCase {
    private final class DocumentState: ObservableObject {
        @Published var document: HorizontalProjectDocument
        init(_ archive: HorizontalProjectArchive) {
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
            ProjectWorkspaceView(project: project, document: $state.document, visiblePanes: $panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }

    private func settle(until predicate: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func renderers(in view: NSView) -> [HorizontalMetalBackdropView.Renderer] {
        var result = [HorizontalMetalBackdropView.Renderer]()
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal overlay" {
            XCTAssertFalse(metal.isOpaque, "A layered Metal canvas must not occlude its sibling renderers")
            result.append(renderer)
        }
        return result + view.subviews.flatMap { renderers(in: $0) }
    }

    func testDocumentURLAliasKeepsWorkspaceIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        try Data().write(to: directory.appendingPathComponent("board.hprj"))
        XCTAssertEqual(ProjectDocumentView.documentIdentity(alias.appendingPathComponent("board.hprj")),
                       ProjectDocumentView.documentIdentity(directory.appendingPathComponent("board.hprj")))
        XCTAssertNotEqual(ProjectDocumentView.documentIdentity(directory.appendingPathComponent("a.hprj")),
                          ProjectDocumentView.documentIdentity(directory.appendingPathComponent("b.hprj")))
    }

    func testLiveEditsAndUndoReachBothMountedCanvases() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for canvas presentation") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-canvas-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = HorizontalDispatchSession()
        let entry = try disk.open(url: root)
        let seeded = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": entry.handle, "expected_revision": entry.revision, "operation_id": "seed",
            "ops": [["op": "place_board_text", "text": "BOARD", "layer": 0, "x_mm": 1, "y_mm": 1],
                    ["op": "place_text", "text": "SHEET", "x_mm": 1, "y_mm": 1]]
        ]], in: disk)
        XCTAssertNil(seeded["error"], "\(seeded)")
        let changes = try XCTUnwrap(seeded.dictionary("result")).dictionaryArray("changes")
        let boardText = try XCTUnwrap(changes.first?.string("id"))
        let sheetText = try XCTUnwrap(changes.last?.string("text_id"))
        let state = DocumentState(try HorizontalProjectArchive.snapshot(from: root))
        let project = try HorizontalProject.load(from: root)
        let defaults = UserDefaults(suiteName: "live-canvas-\(UUID().uuidString)")!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let registeredDocument = NSDocument()
        registeredDocument.fileURL = root
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
        let mounted = await settle { self.renderers(in: hosted).filter { $0.presentedContentKey != nil }.count >= 2 }
        XCTAssertTrue(mounted, "Both real canvases must submit a frame")
        guard mounted else { return }
        let live = try XCTUnwrap(HorizontalDispatchSession.shared.openEntries.first { $0.live != nil && $0.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() })
        let canvases = renderers(in: hosted)
        let initial = canvases.map { $0.presentedContentKey }
        undo.beginUndoGrouping()
        let result = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "apply", "params": [
            "handle": live.handle, "expected_revision": live.revision, "operation_id": "live-move",
            "ops": [["op": "place_board_text", "id": boardText, "x_mm": 10, "y_mm": 2],
                    ["op": "place_text", "id": sheetText, "x_mm": 10, "y_mm": 2]]
        ]])
        undo.endUndoGrouping()
        XCTAssertNil(result["error"], "\(result)")
        let refreshed = await settle { zip(canvases, initial).allSatisfy { $0.presentedContentKey != $1 } }
        XCTAssertTrue(refreshed, "Same-count edits must reach every existing canvas without reopening")
        XCTAssertEqual(renderers(in: hosted).map(ObjectIdentifier.init), canvases.map(ObjectIdentifier.init), "Refresh must preserve canvas identity")
        let editedKeys = canvases.map { $0.presentedContentKey }
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        let undone = await settle { zip(canvases, editedKeys).allSatisfy { $0.presentedContentKey != $1 } }
        XCTAssertTrue(undone, "Undo must redraw both canvases")
        let undoKeys = canvases.map { $0.presentedContentKey }
        undo.redo()
        let redone = await settle { zip(canvases, undoKeys).allSatisfy { $0.presentedContentKey != $1 } }
        XCTAssertTrue(redone, "Redo must redraw both canvases")
        // The drawing caches are now warm. Hide and restore the window
        // around a second edit, as when an MCP client is in the foreground.
        let redoKeys = canvases.map { $0.presentedContentKey }
        window.orderOut(nil)
        HorizontalDispatchSession.shared.syncLiveEntries()
        undo.beginUndoGrouping()
        let background = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 3, "method": "apply", "params": [
            "handle": live.handle, "expected_revision": live.revision, "operation_id": "background-move",
            "ops": [["op": "place_board_text", "id": boardText, "x_mm": 20, "y_mm": 3],
                    ["op": "place_text", "id": sheetText, "x_mm": 20, "y_mm": 3]]
        ]])
        undo.endUndoGrouping()
        XCTAssertNil(background["error"], "\(background)")
        window.orderFront(nil)
        let foregrounded = await settle { zip(canvases, redoKeys).allSatisfy { $0.presentedContentKey != $1 } }
        XCTAssertTrue(foregrounded, "Returning to the window must present the current document")
    }
}
