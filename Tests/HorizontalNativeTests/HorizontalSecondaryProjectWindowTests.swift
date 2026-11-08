#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A project's other window (⌥⌘N) shows the same project as its project
/// window and edits it: an edit in either is in both, the selection is
/// shared, and only the project window serves the live channel.
@MainActor
final class HorizontalSecondaryProjectWindowTests: XCTestCase {
    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.board]
        @Published var secondaryPanes: Set<HorizontalPane> = [.board]
        @Published var request = 0
        let shared = HorizontalSharedProject()
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var spot: Spot
        @ObservedObject var shared: HorizontalSharedProject
        var project: HorizontalProject
        var secondary: Bool
        let undo = UndoManager()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $spot.document,
                                 visiblePanes: secondary ? $spot.secondaryPanes : $spot.panes,
                                 selectedNetIDs: $shared.selectedNetIDs, highlightedNetIDs: $shared.highlightedNetIDs,
                                 selectedComponentIDs: $shared.selectedComponentIDs,
                                 highlightedComponentIDs: $shared.highlightedComponentIDs,
                                 spotlightRequest: $spot.request,
                                 sharedProject: shared, isSecondaryWindow: secondary,
                                 undoManagerOverride: secondary ? undo : nil)
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

    private func mount(_ view: some View, defaults: UserDefaults, x: CGFloat) -> (NSWindow, NSView) {
        let hosted = NSHostingView(rootView: view.environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: x, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        return (window, hosted)
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

    func testAnEditInEitherWindowIsInBothAndTheSelectionIsShared() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let fixture = try BlockLayoutFixture(instances: 1, placeParts: false)
        let instance = try XCTUnwrap(fixture.instances.first)
        try fixture.apply([["op": "place_component", "component": fixture.flat(instance, "R1"), "x_mm": 0, "y_mm": 0]])
        XCTAssertEqual(try fixture.board.unplacedObjects.map(\.label), ["R2", "R3"])
        let r2 = try XCTUnwrap(try fixture.board.unplacedObjects.first?.componentID)
        let spot = Spot(fixture.archive)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        _ = NSApplication.shared
        let (_, primaryView) = mount(Workspace(spot: spot, shared: spot.shared, project: fixture.project, secondary: false), defaults: defaults, x: 0)
        let primaryUp = await settle(timeout: 15) { spot.shared.project != nil && self.monitors(in: primaryView).contains { !$0.overlayFrames.isEmpty } }
        XCTAssertTrue(primaryUp, "the project window, sharing its project")
        let (secondaryWindow, secondaryView) = mount(
            Workspace(spot: spot, shared: spot.shared, project: try XCTUnwrap(spot.shared.project), secondary: true),
            defaults: defaults, x: 1010
        )
        let secondaryUp = await settle(timeout: 15) { self.monitors(in: secondaryView).contains { !$0.overlayFrames.isEmpty } }
        XCTAssertTrue(secondaryUp, "the other window, with the same unplaced column")

        func live() -> HorizontalLiveDocument? {
            HorizontalDispatchSession.shared.openEntries.first { $0.live != nil && $0.url.resolvingSymlinksInPath() == fixture.url.resolvingSymlinksInPath() }?.live
        }
        let served = HorizontalDispatchSession.shared.openEntries.filter {
            $0.live != nil && $0.url.resolvingSymlinksInPath() == fixture.url.resolvingSymlinksInPath()
        }
        XCTAssertEqual(served.count, 1, "the project window alone serves the live channel")

        // In the other window: pick R2 in the column and drop it on the board.
        secondaryWindow.makeKeyAndOrderFront(nil)
        let monitor = try XCTUnwrap(monitors(in: secondaryView).first { !$0.overlayFrames.isEmpty })
        let column = try XCTUnwrap(monitor.overlayFrames.first)
        try await click([.mouseMoved, .leftMouseDown, .leftMouseUp], at: CGPoint(x: column.midX, y: column.minY + 48), in: monitor, window: secondaryWindow)
        let selected = await settle { spot.shared.selectedComponentIDs.map { $0.lowercased() } == [r2.lowercased()] }
        XCTAssertTrue(selected, "R2, picked in the other window, is the shared selection: \(spot.shared.selectedComponentIDs)")
        // Over the board, then Return, which places it where the cursor is.
        let drop = CGPoint(x: monitor.bounds.width * 0.7, y: monitor.bounds.height * 0.5)
        try await click([.mouseMoved], at: drop, in: monitor, window: secondaryWindow)
        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: secondaryWindow.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        NSApplication.shared.sendEvent(returnKey)
        let followed = await settle {
            live()?.currentProject().board?.packages.contains { $0.componentID?.lowercased() == r2.lowercased() } == true
        }
        XCTAssertTrue(followed, "the project window has R2 placed in the other window")

        // In the project window, through its live channel: place R3.
        let current = try XCTUnwrap(live())
        let edited = try HorizontalCanvasProjectEdit.archive(
            applying: [["op": "place_component", "component": fixture.flat(instance, "R3"), "x_mm": 10, "y_mm": 0]],
            to: current.archive(), in: current.currentProject()
        )
        try current.applyArchive(edited.archive, "Place R3")
        let gone = await settle { self.monitors(in: secondaryView).allSatisfy { $0.overlayFrames.isEmpty } }
        XCTAssertTrue(gone, "the other window has R3 placed too, and no part left to place")
        XCTAssertEqual(spot.shared.project?.board?.packages.count, 3)
    }

    func testOneTurnsChangesReachTheOtherWindowsOnce() async throws {
        let shared = HorizontalSharedProject()
        let fixture = try BlockLayoutFixture(instances: 1, placeParts: false)
        var heard = 0
        let listening = shared.projectChanges.sink { heard += 1 }
        defer { listening.cancel() }
        let window = UUID()
        shared.publish(fixture.project, from: window)
        shared.publish(fixture.project, from: window)
        XCTAssertEqual(heard, 0, "not until the turn is over")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard, 1)
        XCTAssertEqual(shared.writer, window)
        XCTAssertEqual(shared.nextWindowNumber(), 2)
        XCTAssertEqual(shared.nextWindowNumber(), 3)
    }
}
#endif
