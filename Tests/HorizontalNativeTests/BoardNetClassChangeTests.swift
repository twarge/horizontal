import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// A net put in another class, or a class renamed, is a change to what the
/// rules give it: the rules match by the board's nets as they are now, so a
/// track's width, a via's shape and a plane's settings follow the class.
final class BoardNetClassChangeTests: XCTestCase {
    private static let null = "00000000-0000-0000-0000-000000000000"
    fileprivate static let fast = "aaaaaaaa-0000-4000-8000-000000000001"
    fileprivate static let slow = "aaaaaaaa-0000-4000-8000-000000000002"
    private static let tented = HorizontalProjectArchive.horizonPoolTentedCircularVia
    private static let circular = HorizontalProjectArchive.horizonPoolCircularVia

    private static var all: JSONDictionary {
        ["mode": "all", "net": null, "net_class": null, "net_name_regex": ""]
    }

    private static func inClass(_ id: String) -> JSONDictionary {
        ["mode": "net_class", "net": null, "net_class": id, "net_name_regex": ""]
    }

    private static func widths(_ def: Int) -> JSONDictionary {
        ["0": ["min": 100_000, "max": 1_000_000, "def": def] as JSONDictionary]
    }

    /// The Fast class's rules first by order, then one for every net: a
    /// track 0.4 mm wide and a 0.8 mm via in Fast, 0.2 mm and 0.6 mm elsewhere,
    /// and a hatched plane in Fast.
    private static var rules: JSONDictionary {
        [
            "track_width": [
                "fast": ["enabled": true, "order": 0, "match": inClass(fast), "widths": widths(400_000)] as JSONDictionary,
                "rest": ["enabled": true, "order": 1, "match": all, "widths": widths(200_000)] as JSONDictionary,
            ] as JSONDictionary,
            "via": [
                "fast": ["enabled": true, "order": 0, "match": inClass(fast), "padstack": tented,
                         "parameter_set": ["via_diameter": 800_000, "hole_diameter": 400_000] as JSONDictionary] as JSONDictionary,
                "rest": ["enabled": true, "order": 1, "match": all, "padstack": tented,
                         "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000] as JSONDictionary] as JSONDictionary,
            ] as JSONDictionary,
            "plane": [
                "fast": ["enabled": true, "order": 0, "match": inClass(fast), "layer": 10000,
                         "settings": ["min_width": 300_000, "fill_style": "hatch"] as JSONDictionary] as JSONDictionary,
                "rest": ["enabled": true, "order": 1, "match": all, "layer": 10000,
                         "settings": ["min_width": 200_000, "fill_style": "solid"] as JSONDictionary] as JSONDictionary,
            ] as JSONDictionary,
        ]
    }

    private static func net(_ id: String, classID: String, className: String) -> HorizontalNetDetails {
        HorizontalNetDetails(id: id, name: id.uppercased(), netClassID: classID, netClassName: className)
    }

    private static func track(_ id: String, net: String, fromRules: Bool = true) -> HorizontalSegment {
        var track = HorizontalSegment(
            id: id, from: .zero, to: HorizontalPoint(x: 1_000_000, y: 0), width: 200_000,
            layer: HorizontalBoardLayers.topCopper, netID: net)
        track.widthFromRules = fromRules
        return track
    }

    /// A board with a track, a via and a plane on SIG that take their shape
    /// from the rules, a track on SIG of its own width, and a track on OTHER,
    /// both nets in the Slow class, with the rules applied.
    fileprivate static func board(_ rules: JSONDictionary = BoardNetClassChangeTests.rules) -> HorizontalBoard {
        let via = HorizontalMarker(
            id: "via", position: .zero, size: 600_000, holeSize: 300_000, layer: nil,
            connectedLayers: [0, -1, -2, -100], netID: "sig", padstackID: Self.circular, definitionID: nil,
            fromRules: true, parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000],
            topMaskExpansion: 100_000, bottomMaskExpansion: 100_000)
        var plane = HorizontalPlane(
            id: "plane", netID: "sig", polygonID: "poly", layer: HorizontalBoardLayers.topCopper, priority: 0,
            fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: [], fallbackPolygon: nil)
        plane.fromRules = true
        var board = HorizontalGerberExportFixture.board(
            tracks: [track("ruled", net: "sig"), track("own", net: "sig", fromRules: false), track("other", net: "other")],
            vias: [via], planes: [plane])
        board.netDetails = [
            "sig": net("sig", classID: Self.slow, className: "Slow"),
            "other": net("other", classID: Self.slow, className: "Slow"),
        ]
        board.takeRules(rules)
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        return board
    }

    private func width(_ id: String, in board: HorizontalBoard) -> Double? {
        board.tracks.first { $0.id == id }?.width
    }

    func testANetPutInAnotherClassTakesWhatTheRulesGiveThatClass() throws {
        var board = Self.board()
        XCTAssertEqual(width("ruled", in: board), 200_000)
        XCTAssertEqual(board.vias.first?.size, 600_000)
        XCTAssertEqual(board.planes.first?.fillStyle, "solid")

        // As the selection inspector's Net class sets it.
        board.netDetails["sig"]?.netClassID = Self.fast
        board.netDetails["sig"]?.netClassName = "Fast"
        let changes = HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)

        XCTAssertEqual(changes, HorizontalBoardRuleApplication.Changes(tracks: ["ruled"], vias: ["via"], planes: ["plane"]))
        XCTAssertEqual(width("ruled", in: board), 400_000, "the Fast rule's width")
        XCTAssertEqual(width("own", in: board), 200_000, "a width of its own stays")
        XCTAssertEqual(width("other", in: board), 200_000, "a net still in Slow keeps its rule")
        let via = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(via.size, 800_000)
        XCTAssertEqual(via.holeSize, 400_000)
        XCTAssertEqual(board.viaHoles.first { $0.id == "via/hole" }?.diameter, 400_000, "the drill follows")
        XCTAssertEqual(board.planes.first?.fillStyle, "hatch")
        XCTAssertEqual(board.planes.first?.settings.minWidth, 300_000)

        // And back, as Undo puts it.
        board.netDetails["sig"] = Self.net("sig", classID: Self.slow, className: "Slow")
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(width("ruled", in: board), 200_000)
        XCTAssertEqual(board.vias.first?.size, 600_000)
        XCTAssertEqual(board.planes.first?.fillStyle, "solid")
    }

    func testTheRulesReadTheBoardsNetsEverywhereTheyAreAsked() {
        var board = Self.board()
        board.netDetails["sig"]?.netClassID = Self.fast
        // The route inspector, the router and the checks ask the rules
        // themselves, not the application.
        XCTAssertEqual(board.rules.trackWidth(net: "sig", layer: 0)?.rule.id, "fast")
        XCTAssertEqual(board.rules.trackWidth(net: "other", layer: 0)?.rule.id, "rest")
        XCTAssertEqual(board.rules.via(net: "sig")?.id, "fast")
        XCTAssertEqual(board.rules.netDetails, board.netDetails)
    }

    func testAClassRenamedTakesTheRuleThatMatchesItsNewName() {
        var rules = Self.rules
        rules["track_width"] = [
            "named": ["enabled": true, "order": 0,
                      "match": ["mode": "net_class_regex", "net": Self.null, "net_class": Self.null,
                                "net_name_regex": "", "net_class_regex": "Fast.*"] as JSONDictionary,
                      "widths": Self.widths(400_000)] as JSONDictionary,
            "rest": ["enabled": true, "order": 1, "match": Self.all, "widths": Self.widths(200_000)] as JSONDictionary,
        ] as JSONDictionary
        var board = Self.board(rules)
        XCTAssertEqual(width("ruled", in: board), 200_000)

        for id in board.netDetails.keys {
            board.netDetails[id]?.netClassName = "Faster"
        }
        HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(width("ruled", in: board), 400_000)
        XCTAssertEqual(width("other", in: board), 400_000)
    }

    func testABoardTakingAnothersRulesTakesTheClassesTheyMatchBy() {
        // The canvas's board, from before the document's had SIG put in Fast.
        var canvas = Self.board()
        var document = canvas
        document.netDetails["sig"]?.netClassID = Self.fast
        document.netDetails["sig"]?.netClassName = "Fast"

        canvas.takeRules(of: document)
        XCTAssertEqual(canvas.netDetails["sig"]?.netClassID, Self.fast)
        XCTAssertEqual(canvas.rules.netDetails, canvas.netDetails)
        HorizontalBoardRuleApplication.apply(to: &canvas, poolURL: nil)
        XCTAssertEqual(width("ruled", in: canvas), 400_000)
    }

    /// The board above with its via pinned to SIG and the ruled track
    /// starting on it, so the canvas's connectivity pass, which gives copper
    /// the net of what it reaches, leaves both on SIG.
    fileprivate static func pinnedBoard() -> HorizontalBoard {
        var board = Self.board()
        board.tracks.removeAll { $0.id != "ruled" }
        for index in board.vias.indices {
            board.vias[index].netSetID = "sig"
        }
        return board
    }

    fileprivate static let classes = [HorizontalNetClass(id: fast, name: "Fast"), HorizontalNetClass(id: slow, name: "Slow")]
}

#if os(macOS)
import AppKit
import SwiftUI

/// The selection inspector's Net class, on the board: the track it is set on
/// takes the class's width at once, with the via and the plane on its net,
/// and Undo gives them back what they had.
@MainActor
final class BoardNetClassInspectorTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var committed: [HorizontalBoard] = []
        var classChanges: [String?] = []
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
            BoardCanvasView(board: board, netClasses: BoardNetClassChangeTests.classes, viewport: $viewport,
                displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onNetClassChange: { _, classID in state.classChanges.append(classID) },
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

    func testATracksNetClassChangesItsWidthAndUndoPutsItBack() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(BoardNetClassChangeTests.pinnedBoard())
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

        let before = state.committed.count
        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: HorizontalSelectableRef(id: "ruled", type: .track), type: .track, propertyID: "netClass",
            value: .choice(BoardNetClassChangeTests.fast), applyToAll: false))
        let changed = await settle { state.committed.count > before }
        state.undo.endUndoGrouping()
        XCTAssertTrue(changed)

        let classed = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(classed.netDetails["sig"]?.netClassName, "Fast")
        XCTAssertEqual(classed.tracks.first?.netID, "sig")
        XCTAssertEqual(classed.tracks.first?.width, 400_000, "the Fast rule's width")
        XCTAssertEqual(classed.vias.first?.size, 800_000)
        XCTAssertEqual(classed.planes.first?.fillStyle, "hatch")
        XCTAssertEqual(state.classChanges, [BoardNetClassChangeTests.fast], "the document is told, for the block")

        let undone = state.committed.count
        state.undo.undo()
        let restoredInTime = await settle { state.committed.count > undone }
        XCTAssertTrue(restoredInTime)
        let restored = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(restored.netDetails["sig"]?.netClassName, "Slow")
        XCTAssertEqual(restored.tracks.first?.width, 200_000)
        XCTAssertEqual(restored.vias.first?.size, 600_000)
        XCTAssertEqual(restored.planes.first?.fillStyle, "solid")
        XCTAssertEqual(state.classChanges.last ?? nil, BoardNetClassChangeTests.slow)
    }
}
#endif
