#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The board canvas feeds the route inspector while the track tool is in
/// use, and a route's width follows the track width rules: onto another
/// layer, through a change to the rules made without a reload, and back from
/// a custom width.
@MainActor
final class BoardRouteInspectorTests: XCTestCase {
    private static let top = HorizontalBoardLayers.topCopper
    private static let bottom = HorizontalBoardLayers.bottomCopper

    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var drawTrack: HorizontalDrawTrackCommand?
        @Published var widthCommand: HorizontalRouteWidthCommand?
        @Published var rulesRevision = 0
        @Published var layer = BoardRouteInspectorTests.top
        var actions: HorizontalCanvasCommandActions?
        let model = HorizontalRouteInspectorModel(interval: 0)
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(),
                onCanvasCommandActionsChange: { state.actions = $0 },
                drawTrackCommand: state.drawTrack,
                routeWidthCommand: state.widthCommand,
                routeInspector: state.model,
                rulesRevision: state.rulesRevision,
                toolSettings: state.toolSettings,
                drawingLayer: state.layer)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private static func rules(bottomWidth: Int) -> JSONDictionary {
        let all: JSONDictionary = ["mode": "all", "net": "00000000-0000-0000-0000-000000000000",
                                   "net_class": "00000000-0000-0000-0000-000000000000", "net_name_regex": ""]
        return ["track_width": ["all": [
            "enabled": true, "order": 0, "match": all,
            "widths": ["0": ["min": 100_000, "max": 1_000_000, "def": 150_000],
                       "-100": ["min": 100_000, "max": 1_000_000, "def": bottomWidth]] as JSONDictionary
        ] as JSONDictionary] as JSONDictionary]
    }

    func testTheRouteInspectorFollowsTheRouteAndTheRules() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = HorizontalGerberExportFixture.board()
        board.takeRules(Self.rules(bottomWidth: 250_000))
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

        // The tool starts: the inspector has the rule's width on top copper.
        state.drawTrack = HorizontalDrawTrackCommand()
        let started = await settle { state.model.state != nil }
        XCTAssertTrue(started)
        XCTAssertTrue(state.model.isRouting)
        var shown = try XCTUnwrap(state.model.state)
        XCTAssertEqual(shown.layer, Self.top)
        XCTAssertEqual(shown.width, 150_000)
        XCTAssertEqual(shown.widthSource, .rule(id: "all"))
        XCTAssertFalse(shown.hasStarted)

        // A route not yet started goes on the layer the pane picks, at that
        // layer's width.
        state.layer = Self.bottom
        let moved = await settle { state.model.state?.layer == Self.bottom }
        XCTAssertTrue(moved)
        XCTAssertEqual(state.model.state?.width, 250_000)

        // The rules change without a reload: the route takes the new width.
        var changed = state.board
        changed.takeRules(Self.rules(bottomWidth: 350_000))
        state.board = changed
        state.rulesRevision += 1
        let followed = await settle { state.model.state?.width == 350_000 }
        XCTAssertTrue(followed)

        // A custom width, then the rules again.
        state.toolSettings.explicitTrackWidth = 420_000
        let custom = await settle { state.model.state?.widthSource == .custom }
        XCTAssertTrue(custom)
        XCTAssertEqual(state.model.state?.width, 420_000)
        state.toolSettings.explicitTrackWidth = nil
        state.widthCommand = HorizontalRouteWidthCommand()
        let ruled = await settle { state.model.state?.widthSource == .rule(id: "all") }
        XCTAssertTrue(ruled)
        shown = try XCTUnwrap(state.model.state)
        XCTAssertEqual(shown.width, 350_000)
        XCTAssertEqual(shown.widthRule?.widths.def, 350_000)

        // A custom width typed while the rules' showed, then Define Rule, as
        // the host makes it: the rule's default becomes the custom width and
        // the route takes it from the rules.
        let typed = try XCTUnwrap(shown.command(typingWidth: 480_000))
        XCTAssertEqual(typed, .useCustomWidth(480_000))
        state.toolSettings.explicitTrackWidth = 480_000
        let typedCustom = await settle { state.model.state?.widthSource == .custom }
        XCTAssertTrue(typedCustom)
        let defineWidth = try XCTUnwrap(state.model.state?.defineWidthRule)
        var rulesJSON = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            defineWidth, to: Self.rules(bottomWidth: 350_000), copperLayers: [Self.top, Self.bottom]))
        changed = state.board
        changed.takeRules(rulesJSON)
        state.board = changed
        state.rulesRevision += 1
        state.toolSettings.explicitTrackWidth = nil
        state.widthCommand = HorizontalRouteWidthCommand()
        let defined = await settle { state.model.state?.widthSource == .rule(id: "all") }
        XCTAssertTrue(defined)
        shown = try XCTUnwrap(state.model.state)
        XCTAssertEqual(shown.width, 480_000)
        XCTAssertEqual(shown.widthRule?.widths.def, 480_000)
        XCTAssertNil(shown.defineWidthRule)

        // The via: the rules', then one of the tool's own size.
        XCTAssertEqual(shown.via.isCustom, false)
        XCTAssertNotNil(shown.via.rule, "the via rule the board is given at load")
        XCTAssertNil(shown.via.defineRule)
        state.toolSettings.viaDiameter = 650_000
        state.toolSettings.viaHoleDiameter = 300_000
        let ownVia = await settle { state.model.state?.via.isCustom == true }
        XCTAssertTrue(ownVia)
        XCTAssertEqual(state.model.state?.via.diameter, 650_000)
        XCTAssertEqual(state.model.state?.via.holeDiameter, 300_000)

        // Define Rule for the via: the via rule takes the size, and the via
        // comes from the rules at it.
        let defineVia = try XCTUnwrap(state.model.state?.via.defineRule)
        rulesJSON = try XCTUnwrap(HorizontalRouteRuleEditing.applying(
            defineVia, to: rulesJSON, copperLayers: [Self.top, Self.bottom]))
        changed = state.board
        changed.takeRules(rulesJSON)
        state.board = changed
        state.rulesRevision += 1
        state.toolSettings.setVia(diameter: nil, holeDiameter: nil)
        let ruledVia = await settle { state.model.state?.via.isCustom == false }
        XCTAssertTrue(ruledVia)
        XCTAssertEqual(state.model.state?.via.diameter, 650_000)
        XCTAssertEqual(state.model.state?.via.holeDiameter, 300_000)

        // Escape ends the tool, and the inspector with it.
        state.actions?.dispatch(.cancelInteraction)
        let ended = await settle { !state.model.isRouting }
        XCTAssertTrue(ended)
        XCTAssertNil(state.model.state)
    }
}
#endif
