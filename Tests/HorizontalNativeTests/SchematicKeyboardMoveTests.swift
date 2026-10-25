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
    /// R on a symbol, with or without the pointer resting on the canvas, and
    /// what was committed: in a move made with up (then Enter), or at rest.
    private func upTurnEnter(restingPointer: Bool, moving: Bool = true) async throws -> HorizontalSchematicSheet {
        let state = State(fixture())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            XCTAssertNil(handle(event))
        }
        state.actions?.selectComponents?(["component"])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        if moving {
            try key(126, "\u{f700}")
            let started = await settle { state.actions?.canCommitInteraction == true }
            XCTAssertTrue(started)
        }
        if restingPointer {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 650, y: 450), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            _ = handle(event)
        }
        try key(15, "r")
        if moving {
            try key(36, "\r")
        }
        let committed = await settle { state.committed != nil }
        XCTAssertTrue(committed)
        return try XCTUnwrap(state.committed)
    }

    /// E on a part whose two pins swap ends, each with a label on it (a
    /// junction at the pin's end and a wire of no length, as Billo's U13 has).
    /// The labels go with their pins and flip to read away from the part.
    /// Before, the first pin's junction merged on arrival with the one still
    /// waiting to leave, wiring the two nets together, and the labels kept
    /// pointing back across the part.
    func testEFlipsAPartWhosePinsSwapEndsWithTheirLabels() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        let left = HorizontalPoint(x: -2_500_000, y: 0), right = HorizontalPoint(x: 2_500_000, y: 0)
        sheet.symbols = [.init(id: "symbol", position: .zero, angle: 0, mirrored: false, label: "U1", componentID: "component")]
        sheet.symbolLines = [.init(id: "symbol/line/body", from: .init(x: -1_250_000, y: -1_250_000),
                                  to: .init(x: 1_250_000, y: 1_250_000), width: 0, layer: nil)]
        sheet.symbolPins = [
            .init(id: "symbol/pin/a", from: left, to: .init(x: -1_250_000, y: 0), width: 0, layer: nil, netID: "na"),
            .init(id: "symbol/pin/b", from: right, to: .init(x: 1_250_000, y: 0), width: 0, layer: nil, netID: "nb"),
        ]
        sheet.netDetails = ["na": .init(id: "na", name: "A", netClassID: nil, netClassName: nil, isPower: false),
                            "nb": .init(id: "nb", name: "B", netClassID: nil, netClassName: nil, isPower: false)]
        sheet.junctions = ["ja": left, "jb": right]
        sheet.junctionNetIDs = ["ja": "na", "jb": "nb"]
        sheet.netLines = [
            .init(id: "wa", from: left, to: left, width: 0, layer: nil, netID: "na", schematicFrom: .pin("symbol/a"), schematicTo: .junction("ja")),
            .init(id: "wb", from: right, to: right, width: 0, layer: nil, netID: "nb", schematicFrom: .pin("symbol/b"), schematicTo: .junction("jb")),
        ]
        sheet.netLabels = [
            .init(id: "la", text: "A", position: left, size: 1_500_000, orientation: "left", netID: "na", junctionID: "ja"),
            .init(id: "lb", text: "B", position: right, size: 1_500_000, orientation: "right", netID: "nb", junctionID: "jb"),
        ]
        let state = State(sheet)
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        state.actions?.selectComponents?(["component"])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        state.actions?.dispatch(.mirrorSelection)
        let committed = await settle { state.committed != nil }
        XCTAssertTrue(committed)
        let flipped = try XCTUnwrap(state.committed)

        XCTAssertEqual(flipped.symbols.first?.position, .zero, "flipped in place")
        XCTAssertEqual(flipped.symbols.first?.mirrored, true)
        XCTAssertEqual(flipped.junctions.count, 2, "the two nets' junctions stay apart")
        XCTAssertEqual(flipped.junctions["ja"], right)
        XCTAssertEqual(flipped.junctions["jb"], left)
        let labels = Dictionary(uniqueKeysWithValues: flipped.netLabels.map { ($0.id, $0) })
        XCTAssertEqual(labels["la"]?.position, right)
        XCTAssertEqual(labels["la"]?.orientation, "right", "reading away from the part")
        XCTAssertEqual(labels["la"]?.junctionID, "ja")
        XCTAssertEqual(labels["lb"]?.position, left)
        XCTAssertEqual(labels["lb"]?.orientation, "left")
        XCTAssertEqual(labels["lb"]?.junctionID, "jb")
        // The wires may be rewritten as they heal, so each is found by its ends.
        func wire(_ pin: String, _ junction: String) -> HorizontalSegment? {
            let ends: Set<HorizontalSchematicEndpoint> = [.pin(pin), .junction(junction)]
            return flipped.netLines.first { line in
                Set([line.schematicFrom, line.schematicTo].compactMap { $0 }) == ends
            }
        }
        XCTAssertEqual(flipped.netLines.count, 2)
        XCTAssertEqual(wire("symbol/a", "ja").map { [$0.from, $0.to] }, [right, right])
        XCTAssertEqual(wire("symbol/b", "jb").map { [$0.from, $0.to] }, [left, left])
    }

    /// R on a symbol at rest turns it about its own centre, wherever the
    /// pointer rests on the canvas (124). Before, it turned about the pointer.
    func testRAtRestTurnsTheSymbolInPlaceWhereverThePointerRests() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let sheet = try await upTurnEnter(restingPointer: true, moving: false)
        let symbol = try XCTUnwrap(sheet.symbols.first)
        XCTAssertNotEqual(symbol.angle, 0, "R turned the symbol")
        XCTAssertEqual(symbol.position, .zero, "in place, about its own centre")
    }

    /// A move made with the arrow keys turns about what it moves, wherever the
    /// pointer rests on the canvas (123). Before, R turned the symbol about the
    /// pointer and threw it across the sheet.
    func testRDuringAKeyboardMoveTurnsAboutTheSelectionNotThePointer() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let aloneSheet = try await upTurnEnter(restingPointer: false)
        let pointedSheet = try await upTurnEnter(restingPointer: true)
        let alone = try XCTUnwrap(aloneSheet.symbols.first)
        let pointed = try XCTUnwrap(pointedSheet.symbols.first)
        XCTAssertNotEqual(alone.angle, 0, "R turned the symbol")
        XCTAssertEqual(pointed.angle, alone.angle)
        XCTAssertEqual(pointed.position, alone.position, "the resting pointer is not the pivot")
        XCTAssertLessThan(abs(alone.position.x) + abs(alone.position.y - 1_250_000), 5_000_000,
                          "turned about the symbol, near where the up key took it")
    }

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
        monitor.onMoveSelectionByGrid = { direction, steps in moves.append(direction * steps) }
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
        XCTAssertNil(handle(try event(123, "\u{f702}", modifiers: .shift)), "Shift-arrow moves eight grid steps")
        XCTAssertEqual(moves.last, .init(x: -8, y: 0))
        let unhandled = try event(0, "?")
        XCTAssertTrue(handle(unhandled) === unhandled)
        let modifiedArrow = try event(126, "\u{f700}", modifiers: .command)
        XCTAssertTrue(handle(modifiedArrow) === modifiedArrow)
        let textView = NSTextView(frame: monitor.bounds)
        monitor.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        let textArrow = try event(124, "\u{f703}")
        XCTAssertTrue(handle(textArrow) === textArrow, "Text fields retain normal cursor movement")
        XCTAssertEqual(moves.count, 6)
    }

    /// Billo, 2026-10-13: during a placement, typing "tps62172" or Delete in a
    /// pane's search field went to the canvas, as rotate, layer and delete.
    func testFocusedTextFieldKeepsEveryKeyDuringAnInteraction() throws {
        _ = NSApplication.shared
        let monitor = TrackpadCanvasMonitor.MonitorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = monitor
        defer { window.close() }
        let handle = monitor.makeEventHandler()
        var commands = 0
        monitor.onCommand = { _ in commands += 1 }
        var focusRequests = 0
        monitor.onRequestKeyboardFocus = { focusRequests += 1 }
        func event(_ code: UInt16, _ characters: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let textView = NSTextView(frame: monitor.bounds)
        monitor.addSubview(textView)

        // An interaction that starts while the field has focus takes it, so R rotates.
        XCTAssertTrue(window.makeFirstResponder(textView))
        monitor.handlesInteractionKeys = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.firstResponder === monitor)
        XCTAssertEqual(focusRequests, 1)
        XCTAssertNil(handle(try event(15, "r")))
        XCTAssertEqual(commands, 1)

        // Clicked back into the field, the field gets everything.
        XCTAssertTrue(window.makeFirstResponder(textView))
        for (code, characters) in [(UInt16(17), "t"), (35, "p"), (1, "s"), (22, "6"), (15, "r"),
                                   (51, "\u{7f}"), (53, "\u{1b}"), (36, "\r")] {
            let typed = try event(code, characters)
            XCTAssertTrue(handle(typed) === typed, "\(characters.debugDescription) belongs to the text field")
        }
        XCTAssertEqual(commands, 1)
        XCTAssertEqual(focusRequests, 1, "only the start of an interaction moves the focus")
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
