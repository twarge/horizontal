#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The board canvas's two ways to take a via's pinned net off.
///
/// Clear Net, in the right-click menu and the Design menu, takes it off
/// every selected via that holds one, not only the one the inspector shows.
/// Let Vias Follow Their Tracks… finds the vias pinned to the net their pads
/// already give them, says how many there are and how many are conflicts,
/// and takes the pin off those alone once the user confirms. Each is one
/// undoable edit, and a save writes the vias as Horizon writes a via that
/// holds no net.
@MainActor
final class BoardClearNetAndLetViasFollowTheirTracksTests: XCTestCase {
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

    // MARK: - Clear Net

    /// Clear Net takes the pin off every selected via, the stitching one
    /// too (the user chose them all), and undo puts every pin back.
    func testClearNetTakesThePinOffEverySelectedViaAndUndoPutsThemBack() async throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", true))
                         + [PinnedViaFixture.via(50, 30, "+3V3", pinned: true)])
        let board = try fixture.board
        XCTAssertEqual(pinned(board).count, 3)
        let state = State(board, poolURL: poolURL)
        let window = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.canClearViaNets, false, "nothing selected")

        state.actions?.dispatch(.selectAll)
        let ready = await settle { state.actions?.canClearViaNets == true }
        XCTAssertTrue(ready, "the selection holds pinned vias")
        let after = try await commit(state) { state.actions?.dispatch(.clearViaNets) }
        XCTAssertTrue(pinned(after).isEmpty, "every selected via, not only one")
        let rail = try fixture.net("+3V3")
        let routed = after.vias.filter { abs($0.position.y - 20_000_000) < 1 }
        XCTAssertEqual(routed.count, 2)
        XCTAssertTrue(routed.allSatisfy { $0.netID?.lowercased() == rail }, "the routed ones take their tracks' net")
        XCTAssertEqual(state.undo.undoActionName, "Clear Net")
        let spent = await settle { state.actions?.canClearViaNets == false && state.actions?.canLetViasFollowTracks == false }
        XCTAssertTrue(spent, "no pin is left to clear")

        state.undo.undo()
        let undone = await settle { self.pinned(state.committed.last ?? after).count == 3 }
        XCTAssertTrue(undone, "undo puts all three pins back")
    }

    /// The right-click's Clear Net acts on the selection the clicked via or
    /// track is part of, and on the clicked via alone where it isn't; it is
    /// offered only where that holds a pinned via.
    func testTheRightClicksClearNetIsOfferedWhereTheSelectionHoldsAPinnedVia() throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", false)))
        let board = try fixture.board
        let pinnedVia = try XCTUnwrap(board.vias.first { $0.netSetID != nil })
        let freeVia = try XCTUnwrap(board.vias.first { $0.netSetID == nil })
        let track = try XCTUnwrap(board.tracks.first)
        let pinnedRef = HorizontalSelectableRef(id: pinnedVia.id, type: .via)
        let freeRef = HorizontalSelectableRef(id: freeVia.id, type: .via)
        let trackRef = HorizontalSelectableRef(id: track.id, type: .track)
        func title(_ ref: HorizontalSelectableRef, _ selection: [HorizontalSelectableRef]) -> String? {
            guard case .command(let title, .clearViaNets)? = BoardViaNetCommands.menuEntry(for: ref, selection: selection, in: board) else {
                return nil
            }
            return title
        }
        XCTAssertEqual(title(pinnedRef, []), "Clear Net")
        XCTAssertNil(title(freeRef, []), "a via its tracks give a net has nothing to clear")
        XCTAssertEqual(title(freeRef, [freeRef, pinnedRef, trackRef]), "Clear Net", "the selection it is part of has one")
        XCTAssertEqual(title(trackRef, [trackRef, pinnedRef]), "Clear Net")
        XCTAssertNil(title(trackRef, [pinnedRef]), "a track outside the selection is the menu's alone")
        XCTAssertEqual(BoardViaNetCommands.pinnedVias(among: BoardViaNetCommands.menuRefs(for: freeRef, selection: [freeRef, pinnedRef]),
                                                      in: board).map(\.id), [pinnedVia.id])
    }

    // MARK: - Let Vias Follow Their Tracks…

    /// Asked for, it says what it found before changing anything; confirmed,
    /// it takes the pin off the two vias their pads give +3V3 and leaves
    /// the conflict and the stitching via pinned, as one undoable edit. The
    /// save writes no net_set on the two.
    func testLetViasFollowTheirTracksAsksFirstThenUnpinsOnlyTheViasThatFollowAsOneUndo() async throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", true), up: (30, 20, "+3V3", true)))
        try fixture.edit([
            PinnedViaFixture.track(from: "R1", pad: "2", to: 15, 0),
            PinnedViaFixture.via(15, 0, "+3V3", pinned: true),
            PinnedViaFixture.via(50, 30, "+3V3", pinned: true),
        ])
        let board = try fixture.board
        let all = pinned(board)
        XCTAssertEqual(all.count, 4)
        let state = State(board, poolURL: poolURL)
        let window = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.canLetViasFollowTracks, true)

        state.actions?.dispatch(.letViasFollowTracks)
        let asked = await settle { state.actions?.pinnedViaReview != nil }
        XCTAssertTrue(asked, "it asks first")
        XCTAssertTrue(state.committed.isEmpty, "and changes nothing yet")
        let review = try XCTUnwrap(state.actions?.pinnedViaReview)
        XCTAssertEqual(review.count(.follows), 2)
        XCTAssertEqual(review.count(.conflict), 1)
        XCTAssertEqual(review.count(.stitching), 1)
        XCTAssertEqual(BoardViaNetCommands.confirmTitle(review), "Unpin 2 Vias")
        let message = BoardViaNetCommands.message(review) { id in board.netDetails[id]?.name ?? id }
        XCTAssertTrue(message.contains("2 vias of the 4"), message)
        XCTAssertTrue(message.contains("(15.00, 0.00) mm pinned to +3V3 on +5V copper"), message)
        XCTAssertTrue(message.contains("1 via stands alone"), message)

        let after = try await commit(state) { state.actions?.confirmLetViasFollowTracks?() }
        let following = Set(review.following.map { $0.id.lowercased() })
        XCTAssertEqual(pinned(after), all.subtracting(following), "the conflict and the stitching via keep their pins")
        XCTAssertEqual(state.undo.undoActionName, "Let Vias Follow Their Tracks")
        let closed = await settle { state.actions?.pinnedViaReview == nil }
        XCTAssertTrue(closed)

        try fixture.commit(after)
        for (id, entry) in try fixture.viaEntries() {
            XCTAssertEqual(entry["net_set"] == nil, following.contains(id.lowercased()), "net_set written only where held: \(id)")
        }

        state.undo.undo()
        let undone = await settle { self.pinned(state.committed.last ?? after) == all }
        XCTAssertTrue(undone, "one undo puts both pins back")
    }

    /// With no via that can follow, it says why and changes nothing.
    func testLetViasFollowTheirTracksWithNothingToUnpinChangesNothing() async throws {
        try fixture.edit([PinnedViaFixture.via(50, 30, "+3V3", pinned: true)])
        let state = State(try fixture.board, poolURL: poolURL)
        let window = try await mount(state)
        defer { window.close() }

        state.actions?.dispatch(.letViasFollowTracks)
        let asked = await settle { state.actions?.pinnedViaReview != nil }
        XCTAssertTrue(asked)
        let review = try XCTUnwrap(state.actions?.pinnedViaReview)
        XCTAssertNil(BoardViaNetCommands.confirmTitle(review), "only OK")
        state.actions?.confirmLetViasFollowTracks?()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(state.committed.isEmpty)
    }

    /// A board with no pinned via doesn't offer it.
    func testABoardWithNoPinnedViaDoesNotOfferIt() async throws {
        try fixture.edit(PinnedViaFixture.route(down: (20, 20, "+3V3", false), up: (30, 20, "+3V3", false)))
        let state = State(try fixture.board, poolURL: poolURL)
        let window = try await mount(state)
        defer { window.close() }
        XCTAssertEqual(state.actions?.canLetViasFollowTracks, false)
    }
}
#endif
