#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Pin Net, in a via's right-click menu and as the Design menu's Pin Via
/// Net, pins the net the via's copper gives it onto the via, which then
/// holds it itself as a stitching via does: it keeps the net when its
/// tracks go.
///
/// It is offered where the via clicked, or the selection it is part of, has
/// a via on a net it does not hold. It changes no net, is one undoable
/// edit, and a save writes the pin as Horizon writes a via's `net_set`. The
/// board is `PinnedViaFixture`'s: R1's pad 1 routed to R2's through two
/// vias, on +3V3.
@MainActor
final class BoardPinNetOnAViaTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var source: HorizontalBoard
        let poolURL: URL
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, poolURL: URL) {
            source = board
            self.poolURL = poolURL
        }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings,
                poolURL: state.poolURL)
        }
    }

    private var fixture: PinnedViaFixture!

    override func setUpWithError() throws {
        fixture = try PinnedViaFixture()
    }

    override func tearDown() {
        fixture?.remove()
        super.tearDown()
    }

    private var poolURL: URL {
        fixture.project.baseURL.appendingPathComponent(fixture.project.poolDirectory ?? "pool", isDirectory: true)
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    private func mount(_ state: State) async throws -> NSWindow {
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
        return window
    }

    /// `body` as one undo group, and the board it commits.
    private func commit(_ state: State, _ body: () -> Void) async throws -> HorizontalBoard {
        let commits = state.committed.count
        state.undo.beginUndoGrouping()
        body()
        state.undo.endUndoGrouping()
        let committed = await settle { state.committed.count == commits + 1 }
        XCTAssertTrue(committed)
        return try XCTUnwrap(state.committed.last)
    }

    private func pinned(_ board: HorizontalBoard) -> Set<String> {
        Set(board.vias.filter { $0.netSetID != nil }.map { $0.id.lowercased() })
    }

    private func via(_ board: HorizontalBoard, at x: Double, _ y: Double) throws -> HorizontalMarker {
        let point = HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
        return try XCTUnwrap(board.vias.first { $0.position == point }, "no via at (\(x), \(y))")
    }

    private func ref(_ via: HorizontalMarker) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: via.id, type: .via)
    }

    // MARK: - Where it is offered

    /// Pin Net is a via's: on one its copper gives a net and that does not
    /// hold it, alone or in the selection the clicked via is part of. A via
    /// that holds its net has Clear Net instead, and one on no net Set Net….
    func testPinNetIsOfferedOnAViaItsCopperGivesANetItDoesNotHold() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", false), up: (30, 20, "+3V3", true))
                         + [PinnedViaFixture.via(50, 30, "+3V3", pinned: true)])
        var board = try fixture.board
        // The stitching via let go of its net: it stands alone, on none.
        XCTAssertTrue(BoardSetNet.clearNet(on: [ref(try via(board, at: 50, 30))], in: &board))
        board = HorizontalBoardConnectivity.recompute(board)
        let free = try via(board, at: 20, 20), held = try via(board, at: 30, 20), bare = try via(board, at: 50, 30)
        XCTAssertNotNil(free.netID)
        XCTAssertNil(free.netSetID)
        XCTAssertNotNil(held.netSetID)
        XCTAssertNil(bare.netID)
        let track = try XCTUnwrap(board.tracks.first)
        let trackRef = HorizontalSelectableRef(id: track.id, type: .track)

        func title(_ ref: HorizontalSelectableRef, _ selection: [HorizontalSelectableRef]) -> String? {
            guard case .command(let title, .pinViaNets)? = BoardViaNetCommands.pinMenuEntry(for: ref, selection: selection, in: board) else {
                return nil
            }
            return title
        }
        XCTAssertEqual(title(ref(free), []), "Pin Net")
        XCTAssertNil(title(ref(held), []), "it holds its net already")
        XCTAssertNil(title(ref(bare), []), "it has no net to pin")
        XCTAssertEqual(title(ref(held), [ref(held), ref(free), trackRef]), "Pin Net", "the selection it is part of has one to pin")
        XCTAssertEqual(title(ref(free), [ref(held)]), "Pin Net", "outside the selection, the clicked via alone")
        XCTAssertNil(title(ref(held), [ref(free)]), "outside the selection, the clicked via alone, which is pinned")
        XCTAssertNil(title(trackRef, [trackRef, ref(free)]), "a via's menu, not a track's")

        XCTAssertEqual(BoardViaNetCommands.pinnableVias(among: [ref(held), ref(free), ref(bare), trackRef, ref(free)], in: board).map(\.id),
                       [free.id], "once each, and only the one to pin")
        XCTAssertEqual(BoardViaNetCommands.commandSignature([ref(free)], in: board) & 4, 4, "the commands are republished for it")
        XCTAssertEqual(BoardViaNetCommands.commandSignature([ref(held)], in: board) & 4, 0)
    }

    // MARK: - What it does

    /// The via holds the net it had; no net changes. Saved, it is written
    /// with the pin and the other via without. With the tracks gone the
    /// pinned via keeps +3V3 and the other is on no net.
    func testPinNetPinsTheNetTheViaHasWhichItKeepsWhenItsTracksGo() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", false), up: (30, 20, "+3V3", false)))
        var board = try fixture.board
        let rail = try fixture.net("+3V3")
        let down = try via(board, at: 20, 20), up = try via(board, at: 30, 20)
        XCTAssertEqual(down.netID?.lowercased(), rail)
        XCTAssertTrue(pinned(board).isEmpty)

        XCTAssertTrue(BoardViaNetCommands.pinNets(on: [ref(down)], in: &board))
        XCTAssertEqual(pinned(board), [down.id.lowercased()], "the one asked for")
        XCTAssertEqual(try via(board, at: 20, 20).netSetID?.lowercased(), rail)
        XCTAssertFalse(BoardViaNetCommands.pinNets(on: [ref(down)], in: &board), "it is pinned already")
        let resolved = HorizontalBoardConnectivity.recompute(board)
        XCTAssertEqual(Set(resolved.vias.compactMap { $0.netID?.lowercased() }), [rail], "no net changed")
        XCTAssertTrue(resolved.tracks.allSatisfy { $0.netID?.lowercased() == rail })

        try fixture.commit(board)
        let entries = try fixture.viaEntries()
        XCTAssertEqual(entries.first { $0.key.lowercased() == down.id.lowercased() }?.value.string("net_set")?.lowercased(), rail)
        XCTAssertNil(entries.first { $0.key.lowercased() == up.id.lowercased() }?.value["net_set"], "the other via holds none")

        var bare = try fixture.board
        bare.tracks.removeAll()
        bare = HorizontalBoardConnectivity.recompute(bare)
        XCTAssertEqual(try via(bare, at: 20, 20).netID?.lowercased(), rail, "pinned, it keeps its net")
        XCTAssertNil(try via(bare, at: 30, 20).netID, "the other went with its tracks")
    }

    /// On the canvas it pins every selected via that has a net to pin, as
    /// one edit Undo takes back, and then has nothing left to offer.
    func testPinNetPinsEverySelectedViaWithANetAsOneUndoableEdit() async throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", false), up: (30, 20, "+3V3", false))
                         + [PinnedViaFixture.via(50, 30, "+3V3", pinned: true)])
        let board = try fixture.board
        XCTAssertEqual(pinned(board).count, 1, "the stitching via alone")
        let state = State(board, poolURL: poolURL)
        let window = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.canPinViaNets, false, "nothing selected")

        state.actions?.dispatch(.selectAll)
        let ready = await settle { state.actions?.canPinViaNets == true }
        XCTAssertTrue(ready, "the selection has vias to pin")
        let after = try await commit(state) { state.actions?.dispatch(.pinViaNets) }
        XCTAssertEqual(pinned(after).count, 3, "both routed vias, and the one pinned before")
        let rail = try fixture.net("+3V3")
        XCTAssertTrue(after.vias.allSatisfy { $0.netSetID?.lowercased() == rail && $0.netID?.lowercased() == rail })
        XCTAssertEqual(state.undo.undoActionName, "Pin Net")
        let spent = await settle { state.actions?.canPinViaNets == false && state.actions?.canClearViaNets == true }
        XCTAssertTrue(spent, "nothing is left to pin, and every one can be cleared")

        state.undo.undo()
        let undone = await settle { self.pinned(state.committed.last ?? after).count == 1 }
        XCTAssertTrue(undone, "undo takes both pins off again")
    }
}
#endif
