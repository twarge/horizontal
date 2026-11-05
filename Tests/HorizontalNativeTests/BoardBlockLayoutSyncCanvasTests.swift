#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A mounted board canvas keeps a block's instances laid out alike: a part
/// moved in one instance moves in the other in the same commit, and one Undo
/// takes both back; with Keep Block Instances in Sync off, or U pressed
/// during the move, only the instance it was made in changes. The inspector
/// says which instance a part is in, and Select Instance selects it.
@MainActor
final class BoardBlockLayoutSyncCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var options = BoardDisplayOptions()
        @Published var command: HorizontalSelectionPropertyChangeCommand?
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let instances: HorizontalBoardBlockInstances
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, instances: HorizontalBoardBlockInstances) {
            self.board = board
            self.instances = instances
        }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: state.options, undoManager: state.undo,
                onBoardChange: { state.committed.append($0); state.board = $0 },
                blockInstances: state.instances,
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.command,
                toolSettings: state.toolSettings)
        }
    }

    private var fixture: BlockLayoutFixture!

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
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

    /// The fixture's board on a mounted canvas, I1's R2 selected; a key sender.
    private func mount() async throws -> (state: State, window: NSWindow, key: (UInt16, String) throws -> Void) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        fixture = try BlockLayoutFixture(instances: 2)
        let state = State(try fixture.board, instances: try XCTUnwrap(fixture.project.flattenedBlock).boardInstances)
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Pane(state: state)
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
            _ = handle(event)
        }
        XCTAssertEqual(state.actions?.selectComponents?([fixture.flat(fixture.instances[0], "R2")]), true)
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        return (state, window, key)
    }

    private func position(_ instance: Int, _ refdes: String, in board: HorizontalBoard?) -> HorizontalPoint? {
        board?.packages.first { $0.componentID?.lowercased() == fixture.flat(fixture.instances[instance], refdes) }?.position
    }

    /// Up, then Return: a keyboard move of the selection, committed.
    private func moveUp(_ state: State, key: (UInt16, String) throws -> Void, pressing extra: (() throws -> Void)? = nil) async throws {
        let before = state.committed.count
        try key(126, "\u{f700}")
        let moving = await settle { state.actions?.canCommitInteraction == true }
        XCTAssertTrue(moving)
        try extra?()
        try key(36, "\r")
        let committed = await settle { state.committed.count > before }
        XCTAssertTrue(committed)
    }

    func testAPartMovedInOneInstanceMovesInTheOtherAndOneUndoTakesBothBack() async throws {
        let (state, window, key) = try await mount()
        defer { window.close() }
        let start1 = try XCTUnwrap(position(0, "R2", in: state.board))
        let start2 = try XCTUnwrap(position(1, "R2", in: state.board))
        let other = try XCTUnwrap(position(1, "R1", in: state.board))
        try await moveUp(state, key: key)
        let moved1 = try XCTUnwrap(position(0, "R2", in: state.committed.last))
        let moved2 = try XCTUnwrap(position(1, "R2", in: state.committed.last))
        XCTAssertGreaterThan(moved1.y, start1.y)
        XCTAssertEqual(moved2.y - start2.y, moved1.y - start1.y, accuracy: 2, "the same edit in I2")
        XCTAssertEqual(moved2.x, start2.x, accuracy: 2)
        XCTAssertEqual(position(1, "R1", in: state.committed.last), other, "the rest of I2 stays")

        XCTAssertTrue(state.undo.canUndo)
        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        XCTAssertEqual(position(0, "R2", in: state.committed.last), start1)
        XCTAssertEqual(position(1, "R2", in: state.committed.last), start2, "one undo step for both")
    }

    func testWithTheSwitchOffOnlyTheInstanceEditedChanges() async throws {
        let (state, window, key) = try await mount()
        defer { window.close() }
        state.options.syncsBlockInstances = false
        let start2 = try XCTUnwrap(position(1, "R2", in: state.board))
        try await moveUp(state, key: key)
        XCTAssertEqual(position(1, "R2", in: state.committed.last), start2)
    }

    func testUDuringTheMoveMakesItThisInstancesAlone() async throws {
        let (state, window, key) = try await mount()
        defer { window.close() }
        let start2 = try XCTUnwrap(position(1, "R2", in: state.board))
        // U twice is U undone: the move reaches I2.
        try await moveUp(state, key: key) {
            try key(32, "u")
            try key(32, "u")
        }
        let synced = try XCTUnwrap(position(1, "R2", in: state.committed.last))
        XCTAssertGreaterThan(synced.y, start2.y)
        // U once: this one doesn't, and I1's R2 then differs from I2's, its own
        // from then on.
        try await moveUp(state, key: key) { try key(32, "u") }
        XCTAssertEqual(position(1, "R2", in: state.committed.last), synced)
        let match = HorizontalBlockLayoutMatch(board: try XCTUnwrap(state.committed.last), instances: state.instances)
        XCTAssertEqual(match.pair(from: fixture.path(0), to: fixture.path(1))?.differs, [fixture.components["R2"]!.lowercased()])
    }

    func testTheInspectorSaysWhichInstanceAndSelectInstanceSelectsIt() async throws {
        let (state, window, _) = try await mount()
        defer { window.close() }
        let described = await settle { state.details.groups.contains { $0.type == .boardPackage && !$0.summary.isEmpty } }
        XCTAssertTrue(described)
        let group = try XCTUnwrap(state.details.groups.first { $0.type == .boardPackage })
        XCTAssertEqual(group.summary.map { "\($0.label): \($0.value)" }, ["Block instance: I1 of Channel", "In sync with: I2"])
        XCTAssertEqual(group.actions.map(\.id), [HorizontalBlockInstanceSummary.selectActionID, HorizontalBlockInstanceSummary.copyLayoutActionID])

        let item = try XCTUnwrap(group.items.first)
        state.command = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: item.ref, type: .boardPackage, propertyID: HorizontalBlockInstanceSummary.selectActionID,
            value: .bool(true), applyToAll: true))
        let selected = await settle { state.details.groups.first { $0.type == .boardPackage }?.items.count == 3 }
        XCTAssertTrue(selected, "I1's three parts")
    }
}
#endif
