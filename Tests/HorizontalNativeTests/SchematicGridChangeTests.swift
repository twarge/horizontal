#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A sheet's grid changed in the pane, on a schematic canvas that has a sheet
/// of its own already, as it has after any edit. The pane's grid settings
/// change the sheet it holds; the canvas went on stepping the arrow keys (and
/// snapping) by its own sheet's old grid, and its next commit put the old
/// grid back. The board canvas did the same (BoardGridChangeTests).
@MainActor
final class SchematicGridChangeTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var sheet: HorizontalSchematicSheet
        var committed: [HorizontalSchematicSheet] = []
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        init(_ sheet: HorizontalSchematicSheet) { self.sheet = sheet }
    }

    /// The pane's part: it hands the canvas the sheet it holds, and takes the
    /// canvas's commits back into it.
    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(sheet: state.sheet, viewport: $viewport, displayOptions: SchematicDisplayOptions(),
                undoManager: state.undo,
                onSheetChange: { state.committed.append($0); state.sheet = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 })
        }
    }

    private func grid(_ spacing: Double) -> HorizontalGridSettings {
        HorizontalGridSettings(name: "", mode: "square", spacing: HorizontalPoint(x: spacing, y: spacing), origin: .zero)
    }

    private func fixture() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.symbols = [.init(id: "symbol", position: .zero, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        sheet.symbolLines = [.init(id: "symbol/line/body", from: .init(x: -2_500_000, y: -1_000_000),
                                  to: .init(x: 2_500_000, y: 1_000_000), width: 0, layer: nil)]
        return sheet
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    private func mount(_ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Void) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let key: (UInt16, String) throws -> Void = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        return (window, key)
    }

    /// Moves R1 up a step with the keyboard, commits, and gives how far it went.
    private func moveTheSymbolUp(_ state: State, key: (UInt16, String) throws -> Void) async throws -> Double {
        let before = try XCTUnwrap(state.sheet.symbols.first?.position)
        let commits = state.committed.count
        _ = state.actions?.selectComponents?(["component"])   // false once it is the selection already
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.commitInteraction)
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        let after = try XCTUnwrap(state.committed.last?.symbols.first?.position)
        XCTAssertEqual(after.x, before.x)
        return abs(after.y - before.y)
    }

    func testAGridChangedAfterAnEditStepsTheArrowKeysAndStays() async throws {
        let state = State(fixture())
        let (window, key) = try await mount(state)
        defer { window.close() }

        // An edit first, after which the canvas draws from a sheet of its own.
        let first = try await moveTheSymbolUp(state, key: key)
        XCTAssertEqual(first, 1_250_000, accuracy: 1)

        // The pane's grid settings change the sheet it holds.
        state.sheet.grid = grid(2_500_000)
        try? await Task.sleep(for: .milliseconds(100))
        let second = try await moveTheSymbolUp(state, key: key)
        XCTAssertEqual(second, 2_500_000, accuracy: 1, "the arrow keys step by the new grid")
        XCTAssertEqual(state.committed.last?.grid.spacing.x, 2_500_000, "and the edit keeps it")
    }
}
#endif
