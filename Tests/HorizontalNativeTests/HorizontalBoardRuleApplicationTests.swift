import Foundation
import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// The board's rules kept applied (`HorizontalBoardRuleApplication`): what
/// takes its shape from them — a track's width, a via's padstack and size, a
/// plane's settings — takes it again whenever they or the board change, as
/// Horizon's Apply gives it, and what has a shape of its own keeps it.
final class HorizontalBoardRuleApplicationTests: XCTestCase {
    private static var all: JSONDictionary {
        ["mode": "all", "net": "00000000-0000-0000-0000-000000000000",
         "net_class": "00000000-0000-0000-0000-000000000000", "net_name_regex": ""]
    }
    private static let circular = HorizontalProjectArchive.horizonPoolCircularVia
    private static let tented = HorizontalProjectArchive.horizonPoolTentedCircularVia

    private static func viaRules(padstack: String = tented, diameter: Int = 600_000, hole: Int = 300_000) -> JSONDictionary {
        ["via": ["r": [
            "enabled": true, "order": 0, "match": all, "padstack": padstack,
            "parameter_set": ["via_diameter": diameter, "hole_diameter": hole] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary]
    }

    private func via(_ id: String, fromRules: Bool, net: String? = "gnd", definition: String? = nil) -> HorizontalMarker {
        HorizontalMarker(
            id: id, position: .zero, size: 450_000, holeSize: 200_000, layer: nil,
            connectedLayers: [0, -1, -2, -100], netID: net, padstackID: Self.circular, definitionID: definition,
            fromRules: fromRules, parameterSet: ["via_diameter": 450_000, "hole_diameter": 200_000],
            topMaskExpansion: 100_000, bottomMaskExpansion: 100_000)
    }

    func testViasFromTheRulesTakeTheirRulesShape() throws {
        var board = HorizontalGerberExportFixture.board(vias: [
            via("ruled", fromRules: true),
            via("own", fromRules: false),
            via("netless", fromRules: true, net: nil),
        ])
        board.takeRules(Self.viaRules())

        let changes = HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(changes.vias, ["ruled"])
        let ruled = try XCTUnwrap(board.vias.first { $0.id == "ruled" })
        XCTAssertEqual(ruled.padstackID, Self.tented)
        XCTAssertEqual(ruled.size, 600_000)
        XCTAssertEqual(ruled.holeSize, 300_000)
        XCTAssertEqual(ruled.parameterSet, ["via_diameter": 600_000, "hole_diameter": 300_000])
        XCTAssertNil(ruled.topMaskExpansion, "the tented via opens no mask")
        XCTAssertNil(ruled.bottomMaskExpansion)
        XCTAssertEqual(board.viaHoles.first { $0.id == "ruled/hole" }?.diameter, 300_000, "the drill follows")

        let own = try XCTUnwrap(board.vias.first { $0.id == "own" })
        XCTAssertEqual(own.size, 450_000, "a via of its own shape keeps it")
        XCTAssertEqual(own.padstackID, Self.circular)
        XCTAssertEqual(board.vias.first { $0.id == "netless" }?.size, 450_000, "Horizon leaves a via on no net")

        XCTAssertTrue(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).isEmpty, "applied, they change nothing")
    }

    func testAViaRuleNamingNoPadstackThePoolHasChangesNothing() {
        var board = HorizontalGerberExportFixture.board(vias: [via("ruled", fromRules: true)])
        // As a padstack id being typed into the rules is, until it is whole.
        board.takeRules(Self.viaRules(padstack: "3c4a52fe"))
        XCTAssertTrue(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).isEmpty)
        XCTAssertEqual(board.vias.first?.size, 450_000)
    }

    func testAViaFromADefinitionTakesItsShapeAndSpan() throws {
        var board = HorizontalGerberExportFixture.board(vias: [via("defined", fromRules: false, definition: "d1")])
        board.takeRules(["via_definitions": ["via_definitions": ["d1": [
            "name": "Blind", "padstack": Self.circular,
            "parameters": ["via_diameter": 700_000, "hole_diameter": 350_000] as JSONDictionary,
            "span": ["start": 0, "end": -1] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary] as JSONDictionary])

        XCTAssertEqual(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).vias, ["defined"])
        let defined = try XCTUnwrap(board.vias.first)
        XCTAssertEqual(defined.size, 700_000)
        XCTAssertEqual(defined.holeSize, 350_000)
        XCTAssertEqual(defined.connectedLayers, [0, -1], "the definition's span")
        XCTAssertNotNil(defined.topMaskExpansion, "the circular via opens the mask")

        // The span goes into the file as Via::serialize writes it, and a
        // through one comes out of it.
        let entry = HorizontalProjectJSONApplicator.viaJSONEntry(defined, existing: ["junction": "j"])
        XCTAssertEqual(entry["span"] as? JSONDictionary as NSDictionary?, ["start": 0, "end": -1] as NSDictionary)
        var through = defined
        through.span = .through
        XCTAssertNil(HorizontalProjectJSONApplicator.viaJSONEntry(through, existing: ["span": ["start": 0, "end": -1]])["span"])
        XCTAssertTrue(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).isEmpty)
    }

    func testPlanesFromTheRulesTakeTheirSettings() throws {
        func plane(_ id: String, fromRules: Bool) -> HorizontalPlane {
            var plane = HorizontalPlane(
                id: id, netID: "gnd", polygonID: "poly-\(id)", layer: HorizontalBoardLayers.topCopper, priority: 0,
                fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: [], fallbackPolygon: nil)
            plane.fromRules = fromRules
            return plane
        }
        var board = HorizontalGerberExportFixture.board()
        board.planes = [plane("ruled", fromRules: true), plane("own", fromRules: false)]
        board.takeRules(["plane": ["p": [
            "enabled": true, "order": 0, "match": Self.all, "layer": 10000,
            "settings": ["min_width": 300_000, "fill_style": "hatch", "keep_orphans": true] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary])

        XCTAssertEqual(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).planes, ["ruled"])
        let ruled = try XCTUnwrap(board.planes.first { $0.id == "ruled" })
        XCTAssertEqual(ruled.settings.minWidth, 300_000)
        XCTAssertEqual(ruled.settings.fillStyle, .hatch)
        XCTAssertEqual(ruled.minWidth, 300_000, "the mirrored fields follow")
        XCTAssertEqual(ruled.fillStyle, "hatch")
        XCTAssertTrue(ruled.keepOrphans)
        XCTAssertEqual(board.planes.first { $0.id == "own" }?.settings.minWidth, 200_000)
        XCTAssertTrue(HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil).isEmpty)
    }

    func testTracksAreAppliedWithTheRest() {
        var track = HorizontalSegment(
            id: "t", from: .zero, to: HorizontalPoint(x: 1_000_000, y: 0), width: 300_000,
            layer: HorizontalBoardLayers.topCopper, netID: "gnd")
        track.widthFromRules = true
        var board = HorizontalGerberExportFixture.board(tracks: [track], vias: [via("ruled", fromRules: true)])
        var rules = BoardWidthFromRulesTests.rules(def: 250_000)
        rules.merge(Self.viaRules()) { _, new in new }
        board.takeRules(rules)
        let changes = HorizontalBoardRuleApplication.apply(to: &board, poolURL: nil)
        XCTAssertEqual(changes.tracks, ["t"])
        XCTAssertEqual(changes.vias, ["ruled"])
        XCTAssertEqual(changes.summary, "1 track and 1 via")
        XCTAssertEqual(board.tracks.first?.width, 250_000)
    }

    func testTheSummarySaysWhatChanged() {
        XCTAssertNil(HorizontalBoardRuleApplication.Changes().summary)
        let changes = HorizontalBoardRuleApplication.Changes(tracks: ["a", "b"], vias: ["c"], planes: ["d", "e"])
        XCTAssertEqual(changes.summary, "2 tracks, 1 via and 2 planes")
        XCTAssertEqual(HorizontalBoardRuleApplication.Changes(planes: ["d"]).summary, "1 plane")
    }

    func testAChangeToTheParametersIsOneTheBoardReloadsFor() {
        let before: JSONDictionary = ["parameters": ["solder_mask_expansion": 100_000] as JSONDictionary]
        let after: JSONDictionary = ["parameters": ["solder_mask_expansion": 50_000] as JSONDictionary]
        XCTAssertTrue(HorizontalBoardRuleApplication.parametersChange(from: before, to: after))
        XCTAssertFalse(HorizontalBoardRuleApplication.parametersChange(from: before, to: before.merging(Self.viaRules()) { _, new in new }))
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// Choosing Rules in the selection inspector applies the rules to the item
/// at once, and an edit the rules shape — a track moved to another layer —
/// takes what they give it there.
@MainActor
final class BoardRuleSourceInspectorTests: XCTestCase {
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

    private func mount(_ board: HorizontalBoard) async throws -> (State, NSWindow) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
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
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        return (state, window)
    }

    private func send(
        _ state: State, ref: HorizontalSelectableRef, _ propertyID: String, _ value: HorizontalSelectionPropertyValue
    ) async -> HorizontalBoard? {
        let before = state.committed.count
        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: ref.type, propertyID: propertyID, value: value, applyToAll: false))
        _ = await settle { state.committed.count > before }
        state.undo.endUndoGrouping()
        return state.committed.count > before ? state.committed.last : nil
    }

    func testShapeFromRulesGivesTheViaItsRulesShape() async throws {
        var via = HorizontalMarker(
            id: "v", position: HorizontalPoint(x: 1_000_000, y: 1_000_000), size: 450_000, holeSize: 200_000, layer: nil,
            connectedLayers: [0, -1, -2, -100], netID: "gnd", netSetID: "gnd",
            padstackID: HorizontalProjectArchive.horizonPoolCircularVia, fromRules: false,
            parameterSet: ["via_diameter": 450_000, "hole_diameter": 200_000])
        via.topMaskExpansion = 100_000
        var board = HorizontalGerberExportFixture.board(vias: [via])
        board.takeRules(["via": ["r": [
            "enabled": true, "order": 0, "match": ["mode": "all"] as JSONDictionary,
            "padstack": HorizontalProjectArchive.horizonPoolTentedCircularVia,
            "parameter_set": ["via_diameter": 600_000, "hole_diameter": 300_000] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary])
        let (state, window) = try await mount(board)
        defer { window.close() }

        let committed = await send(state, ref: HorizontalSelectableRef(id: "v", type: .via), "viaSource", .choice("rules"))
        let ruled = try XCTUnwrap(committed?.vias.first)
        XCTAssertTrue(ruled.fromRules)
        XCTAssertEqual(ruled.padstackID, HorizontalProjectArchive.horizonPoolTentedCircularVia)
        XCTAssertEqual(ruled.size, 600_000, "the rule's diameter")
        XCTAssertEqual(ruled.holeSize, 300_000)
        XCTAssertEqual(committed?.viaHoles.first { $0.id == "v/hole" }?.diameter, 300_000)
    }

    func testSettingsFromRulesGivesThePlaneTheRulesAndASettingMakesItCustom() async throws {
        let polygon = HorizontalPolygon(
            id: "poly", vertices: [.zero, HorizontalPoint(x: 5_000_000, y: 0), HorizontalPoint(x: 5_000_000, y: 5_000_000)],
            layer: HorizontalBoardLayers.topCopper)
        var plane = HorizontalPlane(
            id: "plane", netID: "gnd", polygonID: "poly", layer: HorizontalBoardLayers.topCopper, priority: 0,
            fillStyle: "solid", minWidth: 200_000, keepOrphans: false, fragments: [], fallbackPolygon: polygon)
        plane.fromRules = false
        var board = HorizontalGerberExportFixture.board()
        board.planes = [plane]
        board.takeRules(["plane": ["p": [
            "enabled": true, "order": 0, "match": ["mode": "all"] as JSONDictionary, "layer": 10000,
            "settings": ["min_width": 300_000, "fill_style": "hatch"] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary])
        let (state, window) = try await mount(board)
        defer { window.close() }

        let ref = HorizontalSelectableRef(id: "plane", type: .plane, layer: HorizontalBoardLayers.topCopper)
        let ruledBoard = await send(state, ref: ref, "fromRules", .choice("rules"))
        let ruled = try XCTUnwrap(ruledBoard?.planes.first)
        XCTAssertTrue(ruled.fromRules)
        XCTAssertEqual(ruled.settings.minWidth, 300_000, "the rule's settings at once")
        XCTAssertEqual(ruled.settings.fillStyle, .hatch)

        let ownBoard = await send(state, ref: ref, "minWidth", .length(250_000))
        let own = try XCTUnwrap(ownBoard?.planes.first)
        XCTAssertFalse(own.fromRules, "a setting given the plane is its own")
        XCTAssertEqual(own.settings.minWidth, 250_000)
    }

    func testATrackMovedToAnotherLayerTakesTheWidthTheRulesGiveItThere() async throws {
        var track = HorizontalSegment(
            id: "t", from: .zero, to: HorizontalPoint(x: 5_000_000, y: 0), width: 250_000,
            layer: HorizontalBoardLayers.topCopper, netID: "gnd")
        track.widthFromRules = true
        // A via pinned to the net at its end keeps it on the net, as a pad would.
        let anchor = HorizontalMarker(
            id: "v", position: .zero, size: 450_000, holeSize: 200_000, layer: nil,
            connectedLayers: [0, -1, -2, -100], netID: "gnd", netSetID: "gnd",
            padstackID: HorizontalProjectArchive.horizonPoolCircularVia, fromRules: false)
        var board = HorizontalGerberExportFixture.board(tracks: [track], vias: [anchor])
        board.takeRules(["track_width": ["all": [
            "enabled": true, "order": 0, "match": ["mode": "all"] as JSONDictionary,
            "widths": [
                "0": ["min": 100_000, "max": 1_000_000, "def": 250_000],
                "-100": ["min": 100_000, "max": 1_000_000, "def": 400_000],
            ] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary])
        let (state, window) = try await mount(board)
        defer { window.close() }

        let moved = await send(state, ref: HorizontalSelectableRef(id: "t", type: .track), "layer",
                               .layer(HorizontalBoardLayers.bottomCopper))
        let bottom = try XCTUnwrap(moved?.tracks.first)
        XCTAssertEqual(bottom.layer, HorizontalBoardLayers.bottomCopper)
        XCTAssertEqual(bottom.width, 400_000, "the bottom copper's width from the rules")
    }
}
#endif
