#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A canvas says which boards it made and which it put back: a commit is
/// always an edit, an undo or a redo may leave its host nothing to write.
@MainActor
final class BoardCanvasPutsABoardBackTests: XCTestCase {
    func testUndoAndRedoPublishTheirBoardsAsPutBack() async throws {
        let canvas = ManyPackageCanvas(ManyPackageBoard.board(packages: 4, columns: 2, padPairs: 1))
        canvas.hearsRestores = true
        try await canvas.mount()
        defer { canvas.close() }
        await canvas.selectComponents(1)

        // Up, which starts the move a grid step on, and Return, which commits it.
        try canvas.key(126, "\u{f700}")
        let moving = await canvas.settle { canvas.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        try canvas.key(36, "\r")
        let committed = await canvas.settle { !canvas.committed.isEmpty }
        XCTAssertTrue(committed)
        XCTAssertEqual(canvas.committed.count, 1)
        XCTAssertEqual(canvas.restored.count, 0, "a commit is an edit")
        let moved = try XCTUnwrap(canvas.committed.last?.packages.first?.position)
        XCTAssertNotEqual(moved, canvas.source.packages.first?.position)

        canvas.undo.undo()
        XCTAssertEqual(canvas.committed.count, 1)
        XCTAssertEqual(canvas.restored.count, 1, "an undo puts a board back")
        XCTAssertEqual(canvas.restored.last?.packages.first?.position, canvas.source.packages.first?.position)

        canvas.undo.redo()
        XCTAssertEqual(canvas.committed.count, 1)
        XCTAssertEqual(canvas.restored.count, 2, "and so does a redo")
        XCTAssertEqual(canvas.restored.last?.packages.first?.position, moved)
    }
}

/// In the workspace a canvas commit leaves the board's file to be written
/// behind it (`HorizontalBoardFileWrite`). Whatever reads the document's
/// archive still finds the edit there, the live channel too, and an undo and
/// a redo put the file back and forth with the board.
@MainActor
final class BoardCommitWritesItsFileBehindTests: XCTestCase {
    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.board]
        @Published var request = 0
        let shared = HorizontalSharedProject()
        let undo = UndoManager()
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var spot: Spot
        @ObservedObject var shared: HorizontalSharedProject
        var project: HorizontalProject
        var body: some View {
            ProjectWorkspaceView(project: project, document: $spot.document, visiblePanes: $spot.panes,
                                 selectedNetIDs: $shared.selectedNetIDs, highlightedNetIDs: $shared.highlightedNetIDs,
                                 selectedComponentIDs: $shared.selectedComponentIDs,
                                 highlightedComponentIDs: $shared.highlightedComponentIDs,
                                 spotlightRequest: $spot.request,
                                 sharedProject: shared, undoManagerOverride: spot.undo)
        }
    }

    private func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitors(in view: NSView) -> [TrackpadCanvasMonitor.MonitorView] {
        (view as? TrackpadCanvasMonitor.MonitorView).map { [$0] } ?? view.subviews.flatMap { monitors(in: $0) }
    }

    /// Mouse events at a point in a canvas monitor's coordinates (top left).
    private func click(_ types: [NSEvent.EventType], at point: CGPoint, in monitor: TrackpadCanvasMonitor.MonitorView, window: NSWindow) async throws {
        let inWindow = monitor.convert(NSPoint(x: point.x, y: monitor.bounds.height - point.y), to: nil)
        for type in types {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            NSApplication.shared.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    /// The components the board file in `archive` has packages for.
    private func placedComponents(in archive: HorizontalProjectArchive) throws -> Set<String> {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let board = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        return Set(board.dictionaryMap("packages").values.compactMap { ($0["component"] as? String)?.lowercased() })
    }

    func testACommitIsInTheFileWhenTheArchiveIsReadAndUndoPutsTheFileBack() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let fixture = try BlockLayoutFixture(instances: 1, placeParts: false)
        let root = fixture.root
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let instance = try XCTUnwrap(fixture.instances.first)
        try fixture.apply([["op": "place_component", "component": fixture.flat(instance, "R1"), "x_mm": 0, "y_mm": 0]])
        let r1 = fixture.flat(instance, "R1").lowercased()
        let r2 = try XCTUnwrap(try fixture.board.unplacedObjects.first?.componentID).lowercased()
        let spot = Spot(fixture.archive)
        let opened = spot.document
        XCTAssertEqual(try placedComponents(in: spot.document.archive), [r1], "precondition")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Workspace(spot: spot, shared: spot.shared, project: fixture.project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        let up = await settle(timeout: 15) { spot.shared.project != nil && self.monitors(in: hosted).contains { !$0.overlayFrames.isEmpty } }
        XCTAssertTrue(up, "the workspace, with its column of parts to place")
        func live() -> HorizontalLiveDocument? {
            HorizontalDispatchSession.shared.openEntries.first { $0.live != nil && $0.url.resolvingSymlinksInPath() == fixture.url.resolvingSymlinksInPath() }?.live
        }
        XCTAssertTrue(spot.document.hasSameArchive(as: opened), "opening it edited nothing")

        // On the canvas: pick R2 in the column, and Return drops it on the board.
        window.makeKeyAndOrderFront(nil)
        let monitor = try XCTUnwrap(monitors(in: hosted).first { !$0.overlayFrames.isEmpty })
        let column = try XCTUnwrap(monitor.overlayFrames.first)
        try await click([.mouseMoved, .leftMouseDown, .leftMouseUp], at: CGPoint(x: column.midX, y: column.minY + 48), in: monitor, window: window)
        let picked = await settle { spot.shared.selectedComponentIDs.map { $0.lowercased() } == [r2] }
        XCTAssertTrue(picked, "R2 picked: \(spot.shared.selectedComponentIDs)")
        try await click([.mouseMoved], at: CGPoint(x: monitor.bounds.width * 0.7, y: monitor.bounds.height * 0.5), in: monitor, window: window)
        NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        )))
        let placed = await settle {
            live()?.currentProject().board?.packages.contains { $0.componentID?.lowercased() == r2 } == true
        }
        XCTAssertTrue(placed, "R2 is on the board")

        // The commit was an assignment to the document, and the board's
        // file is written behind it with nobody asking for the archive.
        XCTAssertFalse(spot.document.hasSameArchive(as: opened))
        let written = await settle { !spot.document.hasDeferredEdit }
        XCTAssertTrue(written)
        XCTAssertEqual(try placedComponents(in: spot.document.settledArchive), [r1, r2])
        XCTAssertEqual(try placedComponents(in: spot.document.archive), [r1, r2])
        let current = try XCTUnwrap(live())
        XCTAssertEqual(current.archive(), spot.document.archive, "the live channel reads the same files")
        XCTAssertEqual(try placedComponents(in: opened.archive), [r1], "and a copy from before does not have it")

        // Undo takes R2 off the board and out of the file; Redo puts it back
        // in both.
        spot.undo.undo()
        let undone = await settle {
            live()?.currentProject().board?.packages.contains { $0.componentID?.lowercased() == r2 } == false
        }
        XCTAssertTrue(undone, "R2 is off the board again")
        XCTAssertEqual(try placedComponents(in: spot.document.archive), [r1])
        spot.undo.redo()
        let redone = await settle {
            live()?.currentProject().board?.packages.contains { $0.componentID?.lowercased() == r2 } == true
        }
        XCTAssertTrue(redone, "and on it once more")
        XCTAssertEqual(try placedComponents(in: spot.document.archive), [r1, r2])
        XCTAssertFalse(spot.document.hasDeferredEdit, "a board put back is written at once")
    }
}
#endif
