#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The selection sidebar's All toggles, pressed where they read "All", as
/// the sidebar lays them out: with several tracks selected, All on Width from
/// then Rules gives every one the track width rule's width, and Custom then
/// makes every one's width its own again. A Rules / Custom row is no wider
/// than the sidebar, so no row's All stands past the list's edge, where a
/// click doesn't reach it.
@MainActor
final class SelectionSidebarApplyToAllTests: XCTestCase {
    /// The workspace's sidebar width (`ProjectWorkspaceView`).
    private static let sidebarWidth: CGFloat = 340
    private static let ruleWidth = 250_000.0

    @MainActor private final class State {
        /// What the canvas last reported selected.
        var details = HorizontalSelectionDetailState.empty
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let source: HorizontalBoard
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let routeInspector = HorizontalRouteInspectorModel()
        init(_ board: HorizontalBoard) { source = board }
    }

    /// The board canvas and the selection sidebar beside it, as the
    /// workspace has them: the canvas reports its selection to the sidebar,
    /// and the sidebar's changes go back to it as commands.
    private struct Workspace: View {
        let state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        @SwiftUI.State private var details = HorizontalSelectionDetailState.empty
        @SwiftUI.State private var change: HorizontalSelectionPropertyChangeCommand?
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            HStack(spacing: 0) {
                BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                    onBoardChange: { state.committed.append($0); board = $0 },
                    onSelectionDetailsChange: { details = $0; state.details = $0 },
                    onCanvasCommandActionsChange: { state.actions = $0 },
                    selectionPropertyChangeCommand: change,
                    toolSettings: state.toolSettings)
                SelectionSidebarView(
                    sections: details.hasSelection ? [SelectionSidebarSection(pane: .board, state: details)] : [],
                    netSegmentSelection: nil,
                    routeInspector: state.routeInspector,
                    toolSettings: state.toolSettings,
                    safeAreaInsets: EdgeInsets(),
                    foregroundColor: .primary,
                    backgroundColor: .clear,
                    isReadOnly: false,
                    onChange: { change, _ in self.change = HorizontalSelectionPropertyChangeCommand(change: change) },
                    onNetSegmentSelectionCommand: { _ in },
                    onRouteInspectorCommand: { _ in }
                )
                .frame(width: SelectionSidebarApplyToAllTests.sidebarWidth)
            }
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func mount<Content: View>(_ content: Content, width: CGFloat) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: content
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (window, hosted)
    }

    // MARK: - Finding and pressing the sidebar's controls

    /// The sidebar list's rows, each by its frame in the window, where a
    /// click reaches what it shows, with the frames of the views drawn in it
    /// that have none of their own: its controls, AppKit's (the pager, the
    /// pickers, the fields) and the rings of SwiftUI's own (the All toggles).
    private func listRows(in window: NSWindow) -> [(cell: NSRect, controls: [NSRect])] {
        var rows = [(cell: NSRect, controls: [NSRect])]()
        func leaves(of view: NSView) -> [NSRect] {
            guard !view.isHidden else {
                return []
            }
            if view.subviews.isEmpty {
                let frame = view.convert(view.bounds, to: nil)
                return frame.width > 0 && frame.height > 0 ? [frame] : []
            }
            return view.subviews.flatMap(leaves)
        }
        func walk(_ view: NSView) {
            if let table = view as? NSTableView {
                for row in 0..<table.numberOfRows {
                    if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                        rows.append((cell.convert(cell.bounds, to: nil), leaves(of: cell)))
                    }
                }
                return
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView {
            walk(content)
        }
        return rows
    }

    /// The control at the trailing end of `control`'s line, or of the line
    /// above it where the row puts its picker under its label (the window's
    /// y runs up): the row's All toggle.
    private func trailingControl(besides control: NSView, in window: NSWindow) -> NSRect? {
        let picker = control.convert(control.bounds, to: nil)
        return listRows(in: window)
            .flatMap(\.controls)
            .filter { $0.minX >= picker.maxX && $0.midY >= picker.minY && $0.midY <= picker.maxY + 30 }
            .min { abs($0.midY - picker.midY) < abs($1.midY - picker.midY) }
    }

    private func segmentedControl(_ titles: [String], in window: NSWindow) -> NSSegmentedControl? {
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl,
               (0..<control.segmentCount).map({ control.label(forSegment: $0) ?? "" }) == titles {
                return control
            }
            for subview in view.subviews {
                if let found = find(subview) {
                    return found
                }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// A click where the user clicks, at `point` in the window: the mouse
    /// up waits in the queue for a control that tracks the mouse, as
    /// `HorizontalRulesCheckAutomaticallyTests` clicks.
    private func click(_ point: NSPoint, in window: NSWindow) async throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(up)
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func assertEveryControlStandsInsideItsRow(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let rows = listRows(in: window)
        XCTAssertFalse(rows.isEmpty, "the sidebar lists the selection", file: file, line: line)
        for row in rows {
            for control in row.controls {
                XCTAssertTrue(control.minX >= row.cell.minX - 0.5 && control.maxX <= row.cell.maxX + 0.5,
                              "a control at \(control) stands inside its sidebar row \(row.cell)", file: file, line: line)
            }
        }
    }

    // MARK: - Tests

    private func track(_ id: String, y: Double, width: Double) -> HorizontalSegment {
        var track = HorizontalSegment(
            id: id, from: HorizontalPoint(x: 0, y: y), to: HorizontalPoint(x: 5_000_000, y: y),
            width: width, layer: HorizontalBoardLayers.topCopper, netID: "gnd")
        track.widthFromRules = false
        return track
    }

    func testAllOnWidthFromGivesEverySelectedTrackTheRulesWidthAndCustomMakesItTheirOwnAgain() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = HorizontalGerberExportFixture.board(tracks: [
            track("a", y: 0, width: 300_000),
            track("b", y: 2_000_000, width: 400_000),
            track("c", y: 4_000_000, width: 500_000),
        ])
        board.takeRules(BoardWidthFromRulesTests.rules(def: Int(Self.ruleWidth)))
        let state = State(board)
        let (window, _) = mount(Workspace(state: state), width: 500 + Self.sidebarWidth)
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.groups.first { $0.type == .track }?.items.count == 3 }
        XCTAssertTrue(selected, "the three tracks are selected")
        let shown = await settle { self.segmentedControl(["Rules", "Custom"], in: window) != nil }
        XCTAssertTrue(shown, "the sidebar shows Width from")
        let picker = try XCTUnwrap(segmentedControl(["Rules", "Custom"], in: window))
        assertEveryControlStandsInsideItsRow(in: window)
        let all = try XCTUnwrap(trailingControl(besides: picker, in: window), "Width from has an All toggle")

        // All, pressed where it reads "All", sends what the track shown has to
        // every selected one: Custom, which they have.
        let beforeAll = state.committed.count
        state.undo.beginUndoGrouping()
        try await click(NSPoint(x: all.midX, y: all.midY), in: window)
        let pressed = await settle { state.committed.count > beforeAll }
        state.undo.endUndoGrouping()
        XCTAssertTrue(pressed, "the click on All at \(all) reaches it")

        func pick(_ segment: Int) async -> HorizontalBoard? {
            let before = state.committed.count
            guard let picker = segmentedControl(["Rules", "Custom"], in: window) else {
                return nil
            }
            state.undo.beginUndoGrouping()
            picker.selectedSegment = segment
            _ = picker.sendAction(picker.action, to: picker.target)
            _ = await settle { state.committed.count > before }
            state.undo.endUndoGrouping()
            return state.committed.count > before ? state.committed.last : nil
        }

        let ruledBoard = await pick(0)
        let ruled = try XCTUnwrap(ruledBoard, "Rules commits an edit")
        XCTAssertEqual(ruled.tracks.count, 3)
        for track in ruled.tracks {
            XCTAssertTrue(track.widthFromRules, "\(track.id) takes its width from the rules")
            XCTAssertEqual(track.width, Self.ruleWidth, "\(track.id) has the rule's width")
        }

        let customBoard = await pick(1)
        let custom = try XCTUnwrap(customBoard, "Custom commits an edit")
        for track in custom.tracks {
            XCTAssertFalse(track.widthFromRules, "\(track.id)'s width is its own again")
            XCTAssertEqual(track.width, Self.ruleWidth, "\(track.id) keeps the width it had")
        }
    }

    /// A via's Shape from, on a board with via definitions, has three
    /// choices, too wide beside its label and All in the sidebar: they go
    /// under the label, and its All stays on the label's line, in reach.
    func testShapeFromWithThreeChoicesGoesUnderItsLabelWithItsAllInReach() async throws {
        let sources = [
            HorizontalSelectionPropertyOption(id: "rules", title: "Rules"),
            HorizontalSelectionPropertyOption(id: "definition", title: "Definition"),
            HorizontalSelectionPropertyOption(id: "local", title: "Custom"),
        ]
        let items = ["v1", "v2"].map { id in
            HorizontalSelectionDetailItem(
                ref: HorizontalSelectableRef(id: id, type: .via), title: "Via", subtitle: "", details: [],
                properties: [
                    HorizontalSelectionProperty(id: "name", label: "Net", editor: .readOnly, value: .readOnly("GND")),
                    HorizontalSelectionProperty(id: "locked", label: "Locked", editor: .bool, value: .bool(false)),
                    HorizontalSelectionProperty(id: "viaSource", label: "Shape from", editor: .segmented(sources),
                                                value: .choice("rules")),
                    HorizontalSelectionProperty(id: "diameter", label: "Diameter", editor: .length, value: .length(600_000)),
                ])
        }
        let details = HorizontalSelectionDetailState(hovered: nil, groups: [
            HorizontalSelectionDetailGroup(type: .via, title: "Via", pluralTitle: "Vias", items: items),
        ])
        var changes = [HorizontalSelectionPropertyChange]()
        let routeInspector = HorizontalRouteInspectorModel()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sidebar = SelectionSidebarView(
            sections: [SelectionSidebarSection(pane: .board, state: details)],
            netSegmentSelection: nil,
            routeInspector: routeInspector,
            toolSettings: toolSettings,
            safeAreaInsets: EdgeInsets(),
            foregroundColor: .primary,
            backgroundColor: .clear,
            isReadOnly: false,
            onChange: { change, _ in changes.append(change) },
            onNetSegmentSelectionCommand: { _ in },
            onRouteInspectorCommand: { _ in }
        )
        .frame(width: Self.sidebarWidth)
        let (window, _) = mount(sidebar, width: Self.sidebarWidth)
        defer { window.close() }
        let shown = await settle { self.segmentedControl(["Rules", "Definition", "Custom"], in: window) != nil }
        XCTAssertTrue(shown, "the sidebar shows Shape from")
        let picker = try XCTUnwrap(segmentedControl(["Rules", "Definition", "Custom"], in: window))
        assertEveryControlStandsInsideItsRow(in: window)

        let all = try XCTUnwrap(trailingControl(besides: picker, in: window), "Shape from has an All toggle")
        let pickerFrame = picker.convert(picker.bounds, to: nil)
        XCTAssertGreaterThan(all.minY, pickerFrame.maxY - 0.5, "All is on the label's line, above the choices")

        try await click(NSPoint(x: all.midX, y: all.midY), in: window)
        let pressed = await settle { !changes.isEmpty }
        XCTAssertTrue(pressed, "the click on All at \(all) reaches it")
        XCTAssertEqual(changes.last?.propertyID, "viaSource")
        XCTAssertEqual(changes.last?.applyToAll, true, "All sends the via shown's Shape from to every selected via")

        picker.selectedSegment = 2
        _ = picker.sendAction(picker.action, to: picker.target)
        let picked = await settle { changes.count == 2 }
        XCTAssertTrue(picked)
        XCTAssertEqual(changes.last?.value, .choice("local"))
        XCTAssertEqual(changes.last?.applyToAll, true, "and Custom then goes to every one")
    }
}
#endif
