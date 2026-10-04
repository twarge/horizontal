#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class SchematicKeyboardMoveTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalSchematicSheet
        var committed: HorizontalSchematicSheet?
        var actions: HorizontalCanvasCommandActions?
        var flushLayout: (() -> Void)?
        var displayOptions = SchematicDisplayOptions()
        var revealNetsAfterSelection = false
        let undo = UndoManager()
        init(_ sheet: HorizontalSchematicSheet) { source = sheet }
    }

    private struct Canvas: View {
        var state: State
        @State private var sheet: HorizontalSchematicSheet
        @State private var actions: HorizontalCanvasCommandActions?
        @State private var details = HorizontalSelectionDetailState.empty
        @State private var selectedComponents: Set<String> = []
        @State private var selectedNets: Set<String> = []
        @State private var viewport = CanvasViewport()
        @State private var displayOptions: SchematicDisplayOptions
        init(state: State) {
            self.state = state
            _sheet = SwiftUI.State(initialValue: state.source)
            _displayOptions = SwiftUI.State(initialValue: state.displayOptions)
        }
        var body: some View {
            let _ = (actions, details, selectedComponents, selectedNets)
            SchematicCanvasView(sheet: sheet, viewport: $viewport, displayOptions: displayOptions, undoManager: state.undo,
                onSelectedNetChange: { selectedNets = $0 },
                onSelectedComponentChange: { selectedComponents = $0; actions?.selectComponents?($0) },
                onSheetChange: { state.committed = $0; sheet = $0; state.flushLayout?() },
                onSelectionDetailsChange: {
                    details = $0
                    if state.revealNetsAfterSelection && $0.hasSelection { displayOptions.nets = true }
                },
                onCanvasCommandActionsChange: { state.actions = $0; actions = $0 })
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func assertSettles(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await settle(predicate)
        XCTAssertTrue(result, file: file, line: line)
    }

    private func fixture() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.symbols = [.init(id: "symbol", position: .zero, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        sheet.symbolLines = [.init(id: "symbol/line/body", from: .init(x: -2_500_000, y: -1_000_000),
                                  to: .init(x: 2_500_000, y: 1_000_000), width: 0, layer: nil)]
        sheet.symbolPins = [.init(id: "symbol/pin/a", from: .init(x: -3_750_000, y: 0),
                                 to: .init(x: -2_500_000, y: 0), width: 0, layer: nil)]
        sheet.netLines = [.init(id: "wire", from: .init(x: -3_750_000, y: 0),
                               to: .init(x: -6_250_000, y: 0), width: 0, layer: nil)]
        return sheet
    }

    private func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal overlay" { return renderer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    func testUpEnterDownEnterKeepsEachPreviewAndReturnsToStartingPosition() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(fixture())
        let original = state.source
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        hosted.frame = container.bounds
        hosted.autoresizingMask = [.width, .height]
        container.addSubview(hosted)
        window.contentView = container
        // The document window can lay out synchronously while publishing the
        // edited sheet, before the canvas's own state update has settled.
        state.flushLayout = { [weak hosted, weak window] in
            hosted?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.renderer(in: hosted)?.presentedContentKey != nil }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let monitor = try XCTUnwrap(monitor(in: hosted))
        let handle = monitor.makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        let before = renderer.residentLineEndpoints(compositeGroup: 4)
        XCTAssertFalse(before.isEmpty)
        state.actions?.selectComponents?(["component"])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        let delta = HorizontalPoint(x: 0, y: 1_250_000)
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        let previewed = await settle { renderer.residentLineEndpoints(compositeGroup: 4).first?.from != before.first?.from }
        XCTAssertTrue(previewed)
        let preview = renderer.residentLineEndpoints(compositeGroup: 4)
        XCTAssertEqual(preview.count, before.count)
        for (original, moved) in zip(before, preview) {
            XCTAssertEqual(moved.from.x, original.from.x, accuracy: 2)
            XCTAssertEqual(moved.from.y, original.from.y + 1_250_000, accuracy: 2)
            XCTAssertEqual(moved.to.x, original.to.x, accuracy: 2)
            XCTAssertEqual(moved.to.y, original.to.y + 1_250_000, accuracy: 2)
        }
        let previewKey = renderer.presentedContentKey
        try key(36, "\r")
        let committed = await settle { state.committed != nil }
        XCTAssertTrue(committed)
        let sheet = try XCTUnwrap(state.committed)
        XCTAssertEqual(sheet.symbols[0].position, original.symbols[0].position + delta)
        XCTAssertEqual(sheet.symbolLines[0].from, original.symbolLines[0].from + delta)
        XCTAssertEqual(sheet.symbolPins[0].from, original.symbolPins[0].from + delta)
        XCTAssertEqual(sheet.netLines[0].from, original.netLines[0].from + delta)
        XCTAssertEqual(sheet.netLines[0].to, original.netLines[0].to)
        let redrawn = await settle { renderer.presentedContentKey != previewKey }
        XCTAssertTrue(redrawn)
        try await Task.sleep(for: .milliseconds(200))
        let after = renderer.residentLineEndpoints(compositeGroup: 4)
        XCTAssertEqual(after.count, preview.count)
        for (placed, previewed) in zip(after, preview) {
            XCTAssertEqual(placed.from.x, previewed.from.x, accuracy: 2)
            XCTAssertEqual(placed.from.y, previewed.from.y, accuracy: 2)
            XCTAssertEqual(placed.to.x, previewed.to.x, accuracy: 2)
            XCTAssertEqual(placed.to.y, previewed.to.y, accuracy: 2)
        }

        state.committed = nil
        try key(125, "\u{f701}")
        let movingDown = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(movingDown)
        try await Task.sleep(for: .milliseconds(200))
        let downPreview = renderer.residentLineEndpoints(compositeGroup: 4)
        XCTAssertEqual(downPreview.count, before.count)
        for (moved, initial) in zip(downPreview, before) {
            XCTAssertEqual(moved.from.x, initial.from.x, accuracy: 2, "Down preview")
            XCTAssertEqual(moved.from.y, initial.from.y, accuracy: 2, "Down preview")
            XCTAssertEqual(moved.to.x, initial.to.x, accuracy: 2, "Down preview")
            XCTAssertEqual(moved.to.y, initial.to.y, accuracy: 2, "Down preview")
        }
        try key(36, "\r")
        let committedDown = await settle { state.committed != nil }
        XCTAssertTrue(committedDown)
        let restored = try XCTUnwrap(state.committed)
        XCTAssertEqual(restored.symbols[0].position, original.symbols[0].position)
        XCTAssertEqual(restored.symbolLines[0].from, original.symbolLines[0].from)
        XCTAssertEqual(restored.symbolPins[0].from, original.symbolPins[0].from)
        try await Task.sleep(for: .milliseconds(200))
        let final = renderer.residentLineEndpoints(compositeGroup: 4)
        XCTAssertEqual(final.count, downPreview.count)
        for (placed, previewed) in zip(final, downPreview) {
            XCTAssertEqual(placed.from.x, previewed.from.x, accuracy: 2, "Second Enter")
            XCTAssertEqual(placed.from.y, previewed.from.y, accuracy: 2, "Second Enter")
            XCTAssertEqual(placed.to.x, previewed.to.x, accuracy: 2, "Second Enter")
            XCTAssertEqual(placed.to.y, previewed.to.y, accuracy: 2, "Second Enter")
        }
    }

    /// Horizon writes "layer": 0 on every sheet text, and a text's ref carried
    /// it while the Metal scene filed the text's strokes without one, so a
    /// dragged text stayed put until the move committed. One text here stores
    /// a layer and one, as MCP's place_text wrote it, does not.
    func testTextsFollowTheMovePreviewWhetherOrNotTheyStoreALayer() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.texts = [
            .init(id: "with-layer", text: "Amplifier", position: .init(x: 0, y: 0), size: 1_500_000, layer: 0),
            .init(id: "no-layer", text: "Note", position: .init(x: 0, y: -5_000_000), size: 1_500_000, layer: nil),
        ]
        let state = State(sheet)
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        await assertSettles { state.actions != nil && self.renderer(in: hosted)?.presentedContentKey != nil }
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let before = renderer.residentLineEndpoints(compositeGroup: 0)
        XCTAssertFalse(before.isEmpty)
        state.actions?.dispatch(.selectAll)
        await assertSettles { state.actions?.canMoveSelection == true }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{f700}",
            charactersIgnoringModifiers: "\u{f700}", isARepeat: false, keyCode: 126))
        XCTAssertNil(handle(event))
        await assertSettles { state.actions?.canCommitInteraction == true }
        // Settle on the whole preview, not on any change: before the fix the
        // text without a layer moved and the one with a layer did not.
        func shifted(_ lines: [(from: SIMD2<Float>, to: SIMD2<Float>)]) -> Bool {
            guard lines.count == before.count else { return false }
            let step: Float = 1_250_000
            for (original, moved) in zip(before, lines) {
                let across = abs(moved.from.x - original.from.x)
                let fromUp = abs(moved.from.y - original.from.y - step)
                let toUp = abs(moved.to.y - original.to.y - step)
                if across >= 2 || fromUp >= 2 || toUp >= 2 { return false }
            }
            return true
        }
        await assertSettles { shifted(renderer.residentLineEndpoints(compositeGroup: 0)) }
    }

    func testKeyMonitorConsumesHandledArrowsAndPassesThroughTextEditing() throws {
        _ = NSApplication.shared
        let monitor = TrackpadCanvasMonitor.MonitorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = monitor
        defer { window.close() }
        let handle = monitor.makeEventHandler()
        var moves: [HorizontalPoint] = []
        monitor.onMoveSelectionByGrid = { direction, fine in moves.append(direction * (fine ? 0.1 : 1)) }
        func event(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        for (code, characters) in [(UInt16(126), "\u{f700}"), (125, "\u{f701}"), (123, "\u{f702}"), (124, "\u{f703}")] {
            XCTAssertNil(handle(try event(code, characters)), "A handled arrow must not reach AppKit and beep")
        }
        XCTAssertEqual(moves, [.init(x: 0, y: 1), .init(x: 0, y: -1), .init(x: -1, y: 0), .init(x: 1, y: 0)])
        XCTAssertNil(handle(try event(126, "\u{f700}", modifiers: .option)))
        XCTAssertEqual(moves.last, .init(x: 0, y: 0.1))
        let unhandled = try event(0, "?")
        XCTAssertTrue(handle(unhandled) === unhandled)
        let modifiedArrow = try event(126, "\u{f700}", modifiers: .command)
        XCTAssertTrue(handle(modifiedArrow) === modifiedArrow)
        let textView = NSTextView(frame: monitor.bounds)
        monitor.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        let textArrow = try event(124, "\u{f703}")
        XCTAssertTrue(handle(textArrow) === textArrow, "Text fields retain normal cursor movement")
        XCTAssertEqual(moves.count, 5)
    }

    func testPinLabelPreviewExtendsWireAndCommitUndoAndCancelPreservePin() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        var sheet = fixture()
        let anchor = sheet.symbolPins[0].from
        sheet.symbolPins[0].netID = "net"
        sheet.junctions = ["label-junction": anchor]
        sheet.junctionNetIDs = ["label-junction": "net"]
        sheet.netLabels = [.init(id: "label", text: "SIGNAL", position: anchor, size: 1_000_000,
                                orientation: "left", netID: "net", junctionID: "label-junction")]
        sheet.netLines = [.init(id: "wire", from: anchor, to: anchor, width: 0, layer: nil, netID: "net",
                               schematicFrom: .pin("symbol/a"), schematicTo: .junction("label-junction"))]
        let state = State(sheet)
        state.undo.groupsByEvent = false
        state.displayOptions.symbols = false
        state.displayOptions.junctions = false
        state.displayOptions.nets = false
        state.revealNetsAfterSelection = true
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        await assertSettles { state.actions != nil && self.renderer(in: hosted)?.presentedContentKey != nil }
        state.actions?.dispatch(.selectAll)
        await assertSettles { state.actions?.canMoveSelection == true }
        let renderer = try XCTUnwrap(renderer(in: hosted))
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        try key(126, "\u{f700}")
        let destination = anchor + HorizontalPoint(x: 0, y: 1_250_000)
        await assertSettles {
            guard let wire = renderer.residentLineEndpoints(compositeGroup: 5).first else { return false }
            return abs(Double(wire.from.y) - anchor.y) < 2 && abs(Double(wire.to.y) - destination.y) < 2
        }
        state.undo.beginUndoGrouping()
        try key(36, "\r")
        state.undo.endUndoGrouping()
        await assertSettles { state.committed?.netLabels.first?.position == destination }
        XCTAssertEqual(state.committed?.symbolPins, sheet.symbolPins)
        XCTAssertEqual(state.committed?.netLines.first?.from, anchor)
        XCTAssertEqual(state.committed?.netLines.first?.to, destination)
        XCTAssertTrue(state.undo.canUndo)
        state.undo.undo()
        await assertSettles { state.committed?.netLabels.first?.position == anchor }
        XCTAssertEqual(state.committed?.netLines.first?.length, 0)
        XCTAssertEqual(state.committed?.symbolPins, sheet.symbolPins)
        state.committed = nil
        try key(126, "\u{f700}")
        await assertSettles { state.actions?.canCancelInteraction == true }
        state.actions?.dispatch(.cancelInteraction)
        await assertSettles { state.actions?.canCancelInteraction == false }
        XCTAssertNil(state.committed, "Cancel must not publish a sheet edit")
        await assertSettles {
            guard let wire = renderer.residentLineEndpoints(compositeGroup: 5).first else { return false }
            return abs(Double(wire.from.y) - anchor.y) < 2 && abs(Double(wire.to.y) - anchor.y) < 2
        }
    }
}
#endif
