import SwiftUI
import XCTest
@testable import HorizontalNative

/// ⌘⇧+ and ⌘⇧−: a selected text a size bigger or smaller, 0.1 mm a step
/// below 1 mm and 0.25 mm from there up.
final class HorizontalTextSizeStepTests: XCTestCase {
    private let mm = 1_000_000.0

    private func up(_ size: Double) -> Double? { HorizontalTextSizeStep.stepped(size * mm, larger: true).map { $0 / mm } }
    private func down(_ size: Double) -> Double? { HorizontalTextSizeStep.stepped(size * mm, larger: false).map { $0 / mm } }

    func testStepsAreATenthOfAMillimetreBelowOneAndAQuarterFromOneUp() {
        XCTAssertEqual(up(0.5), 0.6)
        XCTAssertEqual(up(0.9), 1.0)
        XCTAssertEqual(up(1.0), 1.25)
        XCTAssertEqual(up(1.5), 1.75)
        XCTAssertEqual(up(2.5), 2.75)
        XCTAssertEqual(down(0.6), 0.5)
        XCTAssertEqual(down(1.0), 0.9)
        XCTAssertEqual(down(1.25), 1.0)
        XCTAssertEqual(down(2.5), 2.25)
    }

    func testASizeBetweenStepsGoesToTheNextOneInTheStepsDirection() {
        XCTAssertEqual(up(0.95), 1.0)
        XCTAssertEqual(up(0.55), 0.6)
        XCTAssertEqual(up(1.2), 1.25)
        XCTAssertEqual(down(1.2), 1.0)
        XCTAssertEqual(down(1.1), 1.0)
        XCTAssertEqual(down(1.3), 1.25)
        XCTAssertEqual(down(0.55), 0.5)
        XCTAssertEqual(up(0), 0.1)
    }

    func testAStepDownStopsAtATenthOfAMillimetre() {
        XCTAssertEqual(down(0.2), 0.1)
        XCTAssertEqual(down(0.15), 0.1)
        XCTAssertNil(down(0.1), "the smallest stays")
        XCTAssertNil(down(0.05), "below the smallest, it stays too")
        XCTAssertEqual(up(0.05), 0.1)
    }

    func testSizesAHairOffAStepCountAsOnItAndStepsAreWholeNanometres() {
        // A size typed in millimetres, or read from a file, may be a hair off.
        XCTAssertEqual(HorizontalTextSizeStep.stepped(999_999.7, larger: true), 1_250_000)
        XCTAssertEqual(HorizontalTextSizeStep.stepped(1_000_000.3, larger: false), 900_000)
        XCTAssertEqual(HorizontalTextSizeStep.stepped(0.3 * mm, larger: true), 400_000)
        XCTAssertEqual(HorizontalTextSizeStep.stepped(100_000.2, larger: false), nil)
        var size = 0.1 * mm
        for _ in 0..<20 {
            size = HorizontalTextSizeStep.stepped(size, larger: true)!
            XCTAssertEqual(size, size.rounded(), "\(size) is a whole nanometre")
        }
        XCTAssertEqual(size, 3.75 * mm)
        for _ in 0..<20 {
            size = HorizontalTextSizeStep.stepped(size, larger: false)!
        }
        XCTAssertEqual(size, 0.1 * mm, "down retraces up")
    }

    private func event(
        _ characters: String, typed: String? = nil, _ modifiers: HorizontalCanvasInputModifiers
    ) -> HorizontalCanvasKeyEvent {
        HorizontalCanvasKeyEvent(characters: characters, typedCharacters: typed ?? characters, modifiers: modifiers)
    }

    private func larger(_ event: HorizontalCanvasKeyEvent, supportsTrackVias: Bool = true) -> Bool? {
        switch HorizontalCanvasInputCore.command(event, supportsTrackVias: supportsTrackVias) {
        case .stepTextSize(let larger): larger
        default: nil
        }
    }

    func testTheKeysAreKnownByWhatTheyType() {
        for supportsTrackVias in [true, false] {
            // US: ⌘⇧= types +, ⌘⇧− types _.
            XCTAssertEqual(larger(event("+", [.command, .shift]), supportsTrackVias: supportsTrackVias), true)
            XCTAssertEqual(larger(event("_", [.command, .shift]), supportsTrackVias: supportsTrackVias), false)
            // UIKit leaves Shift out of charactersIgnoringModifiers, and
            // ⌘⇧= counts as it is, should Shift be left out of what it types.
            XCTAssertEqual(larger(event("=", typed: "+", [.command, .shift]), supportsTrackVias: supportsTrackVias), true)
            XCTAssertEqual(larger(event("=", [.command, .shift]), supportsTrackVias: supportsTrackVias), true)
            XCTAssertEqual(larger(event("-", typed: "_", [.command, .shift]), supportsTrackVias: supportsTrackVias), false)
            // The keypad's + and −, and a German keyboard's + key, typing +
            // with no Shift.
            XCTAssertEqual(larger(event("-", [.command, .shift]), supportsTrackVias: supportsTrackVias), false)
            XCTAssertEqual(larger(event("+", [.command]), supportsTrackVias: supportsTrackVias), true)
        }
        // ⌘= and ⌘− alone, a German ⌘⇧+ (which types *), with Option or
        // Control, or without ⌘, are not these.
        XCTAssertNil(larger(event("=", [.command])))
        XCTAssertNil(larger(event("-", [.command])))
        XCTAssertNil(larger(event("*", [.command, .shift])))
        XCTAssertNil(larger(event("+", [.command, .shift, .option])))
        XCTAssertNil(larger(event("_", [.command, .shift, .control])))
        XCTAssertNil(larger(event("-", [.shift])))
        if case .selectMore(stopsAtVias: false) = HorizontalCanvasInputCore.command(event("+", [.shift]), supportsTrackVias: true) {
        } else {
            XCTFail("+ alone is still Select More")
        }
    }
}

#if os(macOS)
import AppKit

private extension UndoManager {
    /// Grouped by hand: under XCTest the run loop closes no event's group,
    /// so every step would fall in one.
    static func byPress() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }
}

/// A mounted board canvas and a mounted schematic canvas take ⌘⇧+ and ⌘⇧−
/// as a step of the selected texts' size, each from its own, one undo step
/// a press, with Edit ▸ Increase and Decrease Text Size enabled only while a
/// text is selected.
@MainActor
final class HorizontalTextSizeStepCanvasTests: XCTestCase {
    private let mm = 1_000_000.0

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    private func window(hosting view: some View) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: view
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (window, hosted)
    }

    /// ⌘⇧= (+) or ⌘⇧− (_) on a US keyboard, to the canvas's key monitor,
    /// in an undo group of its own, as the app's event loop gives a key.
    private func press(larger: Bool, in hosted: NSView, window: NSWindow, undo: UndoManager) throws {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let characters = larger ? "+" : "_"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: larger ? 24 : 27))
        XCTAssertNil(handle(event), "the canvas takes ⌘⇧\(characters)")
    }

    // MARK: Board

    @MainActor private final class BoardState {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager.byPress()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct BoardCanvas: View {
        var state: BoardState
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: BoardState) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    /// A part with its refdes smashed, a text of the board's own and a
    /// dimension.
    private func board() -> HorizontalBoard {
        let silk = HorizontalBoardLayers.topSilkscreen
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/text-size-canvas.hprj"), uuid: "b", name: "text size canvas",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.topCopper, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.bottomCopper, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [],
            dimensions: [HorizontalDimension(id: "dim", p0: HorizontalPoint(x: 0, y: -10 * mm), p1: HorizontalPoint(x: 20 * mm, y: -10 * mm),
                                             labelDistance: 2 * mm, labelSize: 1.2 * mm, mode: .horizontal)],
            decals: [], holes: [], vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: HorizontalPoint(x: 10 * mm, y: 10 * mm), angle: 0, mirrored: false,
                                           label: "R1", componentID: "c1")],
            packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [],
            packageTexts: [HorizontalText(id: "pkg/text/rd", text: "R1", position: HorizontalPoint(x: 10 * mm, y: 12 * mm),
                                          size: 1 * mm, layer: silk, fromSmash: true)],
            texts: [HorizontalText(id: "note", text: "NOTE", position: HorizontalPoint(x: 0, y: 0), size: 0.9 * mm, layer: silk)],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func sizes(_ board: HorizontalBoard?) -> [Double]? {
        guard let board else { return nil }
        let texts = board.texts + board.packageTexts
        guard let note = texts.first(where: { $0.id == "note" }), let refdes = texts.first(where: { $0.id == "pkg/text/rd" }),
              let dimension = board.dimensions.first else { return nil }
        return [note.size, refdes.size, dimension.labelSize].map { $0 / mm }
    }

    func testTheBoardStepsEverySelectedTextFromItsOwnSize() async throws {
        let state = BoardState(board())
        let (window, hosted) = window(hosting: BoardCanvas(state: state))
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(state.actions?.canStepTextSize, false, "no text selected")

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canStepTextSize == true }
        XCTAssertTrue(selected)

        try press(larger: true, in: hosted, window: window, undo: state.undo)
        let grown = await settle { sizes(state.committed.last) == [1.0, 1.25, 1.25] }
        XCTAssertTrue(grown, "\(String(describing: sizes(state.committed.last)))")

        try press(larger: false, in: hosted, window: window, undo: state.undo)
        let shrunk = await settle { sizes(state.committed.last) == [0.9, 1.0, 1.0] }
        XCTAssertTrue(shrunk, "\(String(describing: sizes(state.committed.last)))")

        // The menu item does the same.
        state.undo.beginUndoGrouping()
        state.actions?.dispatch(.stepTextSize(larger: false))
        state.undo.endUndoGrouping()
        let again = await settle { sizes(state.committed.last) == [0.8, 0.9, 0.9] }
        XCTAssertTrue(again, "\(String(describing: sizes(state.committed.last)))")

        // One undo step a press.
        XCTAssertEqual(state.undo.undoActionName, "Decrease Text Size")
        state.undo.undo()
        let undone = await settle { sizes(state.committed.last) == [0.9, 1.0, 1.0] }
        XCTAssertTrue(undone, "\(String(describing: sizes(state.committed.last)))")
        state.undo.undo()
        state.undo.undo()
        let original = await settle { sizes(state.committed.last) == [0.9, 1.0, 1.2] }
        XCTAssertTrue(original, "\(String(describing: sizes(state.committed.last)))")
    }

    // MARK: Schematic

    @MainActor private final class SheetState {
        var source: HorizontalSchematicSheet
        var committed: [HorizontalSchematicSheet] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager.byPress()
        init(_ sheet: HorizontalSchematicSheet) { source = sheet }
    }

    private struct SheetCanvas: View {
        var state: SheetState
        @SwiftUI.State private var sheet: HorizontalSchematicSheet
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: SheetState) {
            self.state = state
            _sheet = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            SchematicCanvasView(sheet: sheet, viewport: $viewport, displayOptions: SchematicDisplayOptions(), undoManager: state.undo,
                onSheetChange: { state.committed.append($0); sheet = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 })
        }
    }

    /// A text, a net label and a bus label.
    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.texts = [HorizontalText(id: "note", text: "NOTE", position: .zero, size: 1.5 * mm, layer: nil)]
        sheet.netLabels = [HorizontalSchematicNetLabel(id: "label", text: "SDA", position: HorizontalPoint(x: 10 * mm, y: 0),
                                                       size: 2.5 * mm, orientation: "right")]
        sheet.busLabels = [HorizontalBusLabel(id: "bus", text: "D[0..7]", position: HorizontalPoint(x: 0, y: 10 * mm),
                                              size: 1 * mm, orientation: "right")]
        return sheet
    }

    private func sizes(_ sheet: HorizontalSchematicSheet?) -> [Double]? {
        guard let sheet, let text = sheet.texts.first, let label = sheet.netLabels.first, let bus = sheet.busLabels.first else {
            return nil
        }
        return [text.size, label.size, bus.size].map { $0 / mm }
    }

    func testTheSchematicStepsTextsAndLabels() async throws {
        let state = SheetState(sheet())
        let (window, hosted) = window(hosting: SheetCanvas(state: state))
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.monitor(in: hosted) != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(state.actions?.canStepTextSize, false, "no text selected")

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canStepTextSize == true }
        XCTAssertTrue(selected)

        try press(larger: true, in: hosted, window: window, undo: state.undo)
        let grown = await settle { sizes(state.committed.last) == [1.75, 2.75, 1.25] }
        XCTAssertTrue(grown, "\(String(describing: sizes(state.committed.last)))")
        try press(larger: true, in: hosted, window: window, undo: state.undo)
        let grownAgain = await settle { sizes(state.committed.last) == [2.0, 3.0, 1.5] }
        XCTAssertTrue(grownAgain, "\(String(describing: sizes(state.committed.last)))")

        try press(larger: false, in: hosted, window: window, undo: state.undo)
        let shrunk = await settle { sizes(state.committed.last) == [1.75, 2.75, 1.25] }
        XCTAssertTrue(shrunk, "\(String(describing: sizes(state.committed.last)))")

        XCTAssertEqual(state.undo.undoActionName, "Decrease Text Size")
        state.undo.undo()
        let undone = await settle { sizes(state.committed.last) == [2.0, 3.0, 1.5] }
        XCTAssertTrue(undone, "one press undone: \(String(describing: sizes(state.committed.last)))")
        state.undo.undo()
        state.undo.undo()
        let original = await settle { sizes(state.committed.last) == [1.5, 2.5, 1.0] }
        XCTAssertTrue(original, "\(String(describing: sizes(state.committed.last)))")
    }
}
#endif
