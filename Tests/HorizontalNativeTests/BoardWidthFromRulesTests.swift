import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A track's width is the track width rules' or its own, as Horizon's
/// `width_from_rules` says: read and written with the board, applied from the
/// rules window, and chosen in the selection inspector. And a junction
/// deleted takes what ends on it.
final class BoardWidthFromRulesTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper

    static func rules(def: Int) -> JSONDictionary {
        let all: JSONDictionary = ["mode": "all", "net": "00000000-0000-0000-0000-000000000000",
                                   "net_class": "00000000-0000-0000-0000-000000000000", "net_name_regex": ""]
        return ["track_width": ["all": [
            "enabled": true, "order": 0, "match": all,
            "widths": ["0": ["min": 100_000, "max": 1_000_000, "def": def]] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary]
    }

    private func track(_ id: String, width: Double, fromRules: Bool, net: String? = "gnd", layer: Int? = nil) -> HorizontalSegment {
        var track = HorizontalSegment(
            id: id, from: .zero, to: HorizontalPoint(x: 1_000_000, y: 0), width: width, layer: layer ?? top, netID: net)
        track.widthFromRules = fromRules
        return track
    }

    func testApplyingTheTrackWidthRulesGivesTheirWidthToTracksThatTakeIt() {
        var board = HorizontalGerberExportFixture.board(tracks: [
            track("ruled", width: 300_000, fromRules: true),
            track("own", width: 300_000, fromRules: false),
            track("netless", width: 300_000, fromRules: true, net: nil),
            track("already", width: 250_000, fromRules: true),
            // Top copper is the only layer the rule states; Horizon gives the
            // others RuleTrackWidth's 0.2 mm.
            track("bottom", width: 300_000, fromRules: true, layer: bottom),
        ])
        board.takeRules(Self.rules(def: 250_000))
        let changed = HorizontalTrackWidthRules.apply(to: &board)
        XCTAssertEqual(Set(changed), ["ruled", "bottom"])
        let widths = Dictionary(uniqueKeysWithValues: board.tracks.map { ($0.id, $0.width) })
        XCTAssertEqual(widths["ruled"], 250_000)
        XCTAssertEqual(widths["own"], 300_000)
        XCTAssertEqual(widths["netless"], 300_000, "Horizon leaves a track on no net")
        XCTAssertEqual(widths["bottom"], 200_000)

        // With no rule taking the net, Horizon would make it 0 wide; it is left.
        var unruled = HorizontalGerberExportFixture.board(tracks: [track("ruled", width: 300_000, fromRules: true)])
        unruled.takeRules([:])
        XCTAssertTrue(HorizontalTrackWidthRules.apply(to: &unruled).isEmpty)
    }

    func testTheFlagIsSavedWithTheTrack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("width-from-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: url)
        var archive = try HorizontalProjectArchive.completeProject(from: url)
        var project = try HorizontalProject.load(from: url)

        func save(_ board: HorizontalBoard) throws -> HorizontalBoard {
            try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
            var reloaded = try HorizontalProject.loadSnapshot(of: archive)
            reloaded.rebaseURLs(onto: project)
            project = reloaded
            return try XCTUnwrap(project.board)
        }

        var board = try XCTUnwrap(project.board)
        board.junctions = ["j1": .zero, "j2": HorizontalPoint(x: 1_000_000, y: 0), "j3": HorizontalPoint(x: 2_000_000, y: 0)]
        var ruled = track("ruled", width: 250_000, fromRules: true, net: nil)
        ruled.fromJunctionID = "j1"
        ruled.toJunctionID = "j2"
        var own = track("own", width: 300_000, fromRules: false, net: nil)
        own.from = HorizontalPoint(x: 1_000_000, y: 0)
        own.to = HorizontalPoint(x: 2_000_000, y: 0)
        own.fromJunctionID = "j2"
        own.toJunctionID = "j3"
        board.tracks = [ruled, own]

        var saved = try save(board)
        func flag(_ id: String, in board: HorizontalBoard) -> Bool? {
            board.tracks.first { $0.id == id }?.widthFromRules
        }
        XCTAssertEqual(flag("ruled", in: saved), true)
        XCTAssertEqual(flag("own", in: saved), false)

        // Changed on a track the file already has.
        let index = try XCTUnwrap(saved.tracks.firstIndex { $0.id == "ruled" })
        saved.tracks[index].widthFromRules = false
        saved = try save(saved)
        XCTAssertEqual(flag("ruled", in: saved), false)
    }

    func testADeletedJunctionTakesWhatEndsOnIt() {
        var board = HorizontalGerberExportFixture.board()
        let point = HorizontalPoint(x: 1_000_000, y: 0)
        board.junctions = ["j": point, "other": .zero, "far": HorizontalPoint(x: 2_000_000, y: 0),
                           "below": point]
        var named = track("named", width: 200_000, fromRules: false)
        named.fromJunctionID = "other"
        named.toJunctionID = "j"
        // An end that names no junction, at the point, on the junction's layer.
        var unnamed = track("unnamed", width: 200_000, fromRules: false)
        unnamed.from = point
        unnamed.to = HorizontalPoint(x: 2_000_000, y: 0)
        unnamed.toJunctionID = "far"
        // The bottom layer's track ends on a junction of its own at the point.
        var below = track("below", width: 200_000, fromRules: false, layer: bottom)
        below.toJunctionID = "below"
        below.to = point
        var elsewhere = track("elsewhere", width: 200_000, fromRules: false)
        elsewhere.fromJunctionID = "other"
        elsewhere.toJunctionID = "far"
        board.tracks = [named, unnamed, below, elsewhere]
        board.lines = [HorizontalSegment(id: "line", from: point, to: .zero, width: 100_000, layer: HorizontalBoardLayers.topSilkscreen)]

        let refs = board.refsEnding(onJunction: "J")
        XCTAssertEqual(Set(refs.map(\.id)), ["named", "unnamed", "line"])
        XCTAssertTrue(refs.contains(HorizontalSelectableRef(id: "line", type: .boardLine)))
        XCTAssertTrue(board.refsEnding(onJunction: "missing").isEmpty)
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// The selection inspector's Width from: Rules gives a track the rule's width
/// and the flag; a width typed in makes it the track's own.
@MainActor
final class BoardWidthSourceInspectorTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let source: HorizontalBoard
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard) { source = board }
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
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testWidthFromRulesAndATypedWidth() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var track = HorizontalSegment(
            id: "t", from: .zero, to: HorizontalPoint(x: 5_000_000, y: 0), width: 300_000,
            layer: HorizontalBoardLayers.topCopper, netID: "gnd")
        track.widthFromRules = false
        var board = HorizontalGerberExportFixture.board(tracks: [track])
        board.takeRules(BoardWidthFromRulesTests.rules(def: 250_000))
        let state = State(board)

        _ = NSApplication.shared
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

        let ref = HorizontalSelectableRef(id: "t", type: .track)
        func send(_ propertyID: String, _ value: HorizontalSelectionPropertyValue) async -> HorizontalSegment? {
            let before = state.committed.count
            state.undo.beginUndoGrouping()
            state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
                ref: ref, type: .track, propertyID: propertyID, value: value, applyToAll: false))
            _ = await settle { state.committed.count > before }
            state.undo.endUndoGrouping()
            return state.committed.last?.tracks.first { $0.id == "t" }
        }

        let ruledTrack = await send("widthSource", .choice("rules"))
        let ruled = try XCTUnwrap(ruledTrack)
        XCTAssertTrue(ruled.widthFromRules)
        XCTAssertEqual(ruled.width, 250_000, "the rule's width")

        let typedTrack = await send("width", .length(400_000))
        let typed = try XCTUnwrap(typedTrack)
        XCTAssertFalse(typed.widthFromRules, "a width typed in is the track's own")
        XCTAssertEqual(typed.width, 400_000)
    }
}
#endif
