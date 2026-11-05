#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Tab on the schematic or the board asks the workspace for the other pane,
/// which gives it the keyboard or shows it in this one's place. The key goes
/// through the canvas's key monitor, as a real one does; mid-interaction it
/// is taken and does nothing, and a canvas the workspace gave no pane to
/// switch to leaves Tab to the window.
@MainActor
final class CanvasTabSwitchesPaneTests: XCTestCase {
    @MainActor private final class State {
        var actions: HorizontalCanvasCommandActions?
        var switches = 0
        let undo = UndoManager()
    }

    private struct Schematic: View {
        var state: State
        var switchesPanes: Bool
        @State private var sheet: HorizontalSchematicSheet
        @State private var viewport = CanvasViewport()
        init(state: State, sheet: HorizontalSchematicSheet, switchesPanes: Bool) {
            self.state = state
            self.switchesPanes = switchesPanes
            _sheet = SwiftUI.State(initialValue: sheet)
        }
        var body: some View {
            SchematicCanvasView(sheet: sheet, viewport: $viewport, displayOptions: SchematicDisplayOptions(), undoManager: state.undo,
                onSheetChange: { sheet = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                onSwitchPane: switchesPanes ? { state.switches += 1 } : nil)
        }
    }

    private struct Board: View {
        var state: State
        @State private var board: HorizontalBoard
        @State private var viewport = CanvasViewport()
        let toolSettings = HorizontalBoardToolSettings()
        init(state: State, board: HorizontalBoard) {
            self.state = state
            _board = SwiftUI.State(initialValue: board)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                onSwitchPane: { state.switches += 1 },
                toolSettings: toolSettings)
        }
    }

    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.symbols = [.init(id: "symbol", position: .zero, angle: 0, mirrored: false, label: "R1", componentID: "component")]
        sheet.symbolLines = [.init(id: "symbol/line/body", from: .init(x: -2_500_000, y: -1_000_000),
                                  to: .init(x: 2_500_000, y: 1_000_000), width: 0, layer: nil)]
        return sheet
    }

    private func board() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/tab.hprj"), uuid: "b", name: "tab",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
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

    /// Mounts `view` and returns a key sender, which says whether the canvas
    /// took the key.
    private func mount(_ view: some View, _ state: State) async throws -> (window: NSWindow, key: (UInt16, String) throws -> Bool) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: view
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
        let key: (UInt16, String) throws -> Bool = { code, characters in
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            return handle(event) == nil
        }
        return (window, key)
    }

    func testTabOnTheSchematicAsksForTheOtherPaneButNotMidMove() async throws {
        let state = State()
        let (window, key) = try await mount(Schematic(state: state, sheet: sheet(), switchesPanes: true), state)
        defer { window.close() }
        XCTAssertTrue(try key(48, "\t"))
        XCTAssertEqual(state.switches, 1)

        // An arrow starts a move of the selection; Tab is the canvas's then,
        // and the pane stays.
        state.actions?.selectComponents?(["component"])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        XCTAssertTrue(try key(126, "\u{f700}"))
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        XCTAssertTrue(try key(48, "\t"))
        XCTAssertEqual(state.switches, 1)

        XCTAssertTrue(try key(53, "\u{1b}"))
        let cancelled = await settle { state.actions?.canCancelInteraction == false }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(try key(48, "\t"))
        XCTAssertEqual(state.switches, 2)
    }

    /// A canvas with no area is one kept mounted in a hidden pane: it takes
    /// no key, though its pane had the keyboard when it was hidden.
    func testACanvasWithNoAreaTakesNoKeys() async throws {
        let state = State()
        let (window, key) = try await mount(Schematic(state: state, sheet: sheet(), switchesPanes: true).frame(width: 0), state)
        defer { window.close() }
        state.actions?.selectComponents?(["component"])
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        XCTAssertFalse(try key(48, "\t"))
        XCTAssertEqual(state.switches, 0)
        XCTAssertFalse(try key(126, "\u{f700}"), "No move starts")
        XCTAssertFalse(state.actions?.canCommitInteraction == true)
    }

    func testTabIsLeftToTheWindowWhereThereIsNoPaneToSwitchTo() async throws {
        let state = State()
        let (window, key) = try await mount(Schematic(state: state, sheet: sheet(), switchesPanes: false), state)
        defer { window.close() }
        XCTAssertFalse(try key(48, "\t"))
        XCTAssertEqual(state.switches, 0)
    }

    func testTabShowsTheOtherPaneInThisOnesPlaceOnlyWhenItIsNotOpen() {
        XCTAssertEqual(HorizontalPane.schematic.tabCounterpart, .board)
        XCTAssertEqual(HorizontalPane.board.tabCounterpart, .schematic)
        XCTAssertNil(HorizontalPane.threeD.tabCounterpart)
        // One open: the other takes its place.
        XCTAssertEqual(HorizontalPane.schematic.panesAfterTab(from: [.schematic]), [.board])
        XCTAssertEqual(HorizontalPane.board.panesAfterTab(from: [.board]), [.schematic])
        // Both open: Tab only moves the keyboard, so the panes stay.
        XCTAssertEqual(HorizontalPane.schematic.panesAfterTab(from: [.schematic, .board]), [.schematic, .board])
        XCTAssertEqual(HorizontalPane.board.panesAfterTab(from: [.schematic, .board, .threeD]), [.schematic, .board, .threeD])
        // The rest stay open beside it.
        XCTAssertEqual(HorizontalPane.schematic.panesAfterTab(from: [.library, .schematic, .threeD]), [.library, .board, .threeD])
        XCTAssertEqual(HorizontalPane.threeD.panesAfterTab(from: [.threeD]), [.threeD])
    }

    func testTabOnTheBoardAsksForTheOtherPane() async throws {
        let state = State()
        let (window, key) = try await mount(Board(state: state, board: board()), state)
        defer { window.close() }
        XCTAssertTrue(try key(48, "\t"))
        XCTAssertEqual(state.switches, 1)
    }
}
#endif
