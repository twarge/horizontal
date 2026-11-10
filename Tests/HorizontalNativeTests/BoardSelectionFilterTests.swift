import XCTest
@testable import HorizontalNative

/// The board's selection filter (`BoardSelectionFilter`): which objects it
/// lets a pick take, and that a filtered object doesn't hide the one under
/// it from a click.
final class BoardSelectionFilterTests: XCTestCase {
    private func ref(_ type: HorizontalObjectType, _ id: String = "x") -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: type)
    }

    func testByDefaultEverythingIsPicked() {
        let filter = BoardSelectionFilter()
        XCTAssertFalse(filter.isFiltering)
        for type in [HorizontalObjectType.boardPackage, .track, .via, .polygonEdge, .text, .boardHole, .dimension] {
            XCTAssertTrue(filter.admits(ref(type)))
        }
    }

    func testAKindSwitchedOffIsLeftOutWithAllItsParts() {
        var filter = BoardSelectionFilter()
        filter.set(.polygons, admitted: false)
        filter.set(.packages, admitted: false)
        XCTAssertFalse(filter.admits(ref(.polygonEdge)))
        XCTAssertFalse(filter.admits(ref(.polygonVertex)))
        XCTAssertFalse(filter.admits(ref(.polygonArcCenter)))
        XCTAssertFalse(filter.admits(ref(.boardPackage)))
        XCTAssertFalse(filter.admits(ref(.pad)), "a package's pads go with it")
        XCTAssertTrue(filter.admits(ref(.track)))
        XCTAssertTrue(filter.admits(ref(.schematicSymbol)), "nothing of the schematic's is the board filter's")

        filter.set(.packages, admitted: true)
        XCTAssertTrue(filter.admits(ref(.boardPackage)))
        XCTAssertEqual(filter.excluded, [.polygons])
    }

    func testOnlyPicksOneKind() {
        var filter = BoardSelectionFilter()
        filter.only(.vias)
        XCTAssertTrue(filter.admits(ref(.via)))
        for kind in BoardSelectionKind.allCases where kind != .vias {
            XCTAssertFalse(filter.admits(kind), "\(kind) is off")
        }
        XCTAssertFalse(filter.admits(ref(.track)))
        XCTAssertFalse(filter.admits(ref(.junction)))
    }

    func testEveryBoardObjectTypeHasAKind() {
        let boardTypes: [HorizontalObjectType] = [
            .boardPackage, .pad, .track, .via, .junction, .polygonEdge, .polygonVertex, .polygonArcCenter, .plane,
            .keepout, .text, .boardHole, .boardLine, .boardArc, .dimension, .boardDecal, .boardNetTie, .connectionLine,
            .boardPanel,
        ]
        for type in boardTypes {
            XCTAssertNotNil(BoardSelectionKind(type), "\(type)")
        }
        XCTAssertEqual(Set(boardTypes.compactMap(BoardSelectionKind.init)), Set(BoardSelectionKind.allCases),
                       "and every kind offered stands for something")
    }

    func testAClickPassesOverAFilteredObjectToTheOneUnderIt() {
        // A small via on a large polygon edge's box: the via, the smaller,
        // wins a plain click; with vias filtered the click takes the edge.
        let point = HorizontalPoint(x: 0, y: 0)
        let via = HorizontalSelectable.bounds(
            ref: ref(.via, "via"),
            points: [HorizontalPoint(x: -300_000, y: -300_000), HorizontalPoint(x: 300_000, y: 300_000)],
            fallbackCenter: point, fallbackSize: 600_000
        )
        let text = HorizontalSelectable.bounds(
            ref: ref(.text, "text"),
            points: [HorizontalPoint(x: -5_000_000, y: -2_000_000), HorizontalPoint(x: 5_000_000, y: 2_000_000)],
            fallbackCenter: point, fallbackSize: 10_000_000
        )
        let scene = HorizontalCanvasSelectableScene(selectables: [via, text])
        XCTAssertEqual(scene.hitSelectable(at: point, worldUnitsPerPoint: 1_000)?.id, "via")

        var filter = BoardSelectionFilter()
        filter.set(.vias, admitted: false)
        XCTAssertEqual(scene.hitSelectable(at: point, worldUnitsPerPoint: 1_000, admits: filter.admits)?.id, "text")
        filter.set(.texts, admitted: false)
        XCTAssertNil(scene.hitSelectable(at: point, worldUnitsPerPoint: 1_000, admits: filter.admits))
    }

    func testTheFilterTravelsWithTheSelectionToolSettings() {
        var settings = HorizontalSelectionToolSettings()
        XCTAssertFalse(settings.boardFilter.isFiltering)
        settings.boardFilter.only(.packages)
        XCTAssertNotEqual(settings, HorizontalSelectionToolSettings(), "a change to the filter is a change to the settings")
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// The filter on the board canvas: Select All takes only the kinds it lets
/// through.
@MainActor
final class BoardSelectionFilterCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var actions: HorizontalCanvasCommandActions?
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        let board: HorizontalBoard
        let settings: HorizontalSelectionToolSettings
        let toolSettings = HorizontalBoardToolSettings()
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(),
                selectionToolSettings: settings,
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: toolSettings)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// Two parts and a track between them.
    private func fixture() -> HorizontalBoard {
        let a = HorizontalPoint(x: 10_000_000, y: 10_000_000), b = HorizontalPoint(x: 20_000_000, y: 10_000_000)
        func pad(_ id: String, at c: HorizontalPoint) -> HorizontalPolygon {
            HorizontalPolygon(id: id, vertices: [
                .init(x: c.x - 300_000, y: c.y - 300_000), .init(x: c.x + 300_000, y: c.y - 300_000),
                .init(x: c.x + 300_000, y: c.y + 300_000), .init(x: c.x - 300_000, y: c.y + 300_000),
            ], layer: HorizontalBoardLayers.topCopper, netID: nil)
        }
        var board = HorizontalGerberExportFixture.board(tracks: [
            HorizontalSegment(id: "track", from: a, to: b, width: 200_000, layer: HorizontalBoardLayers.topCopper),
        ])
        board.packages = [
            HorizontalPlacement(id: "a", position: a, angle: 0, mirrored: false, label: "R1", componentID: "ca"),
            HorizontalPlacement(id: "b", position: b, angle: 0, mirrored: false, label: "R2", componentID: "cb"),
        ]
        board.packagePads = [pad("a/pad/1", at: a), pad("b/pad/1", at: b)]
        board.packagePadPositions = ["a/1": a, "b/1": b]
        return board
    }

    /// How many parts Select All leaves selected, by what Align offers.
    private func partsSelectedBySelectAll(with filter: BoardSelectionFilter) async throws -> Int {
        let state = State()
        var settings = HorizontalSelectionToolSettings()
        settings.boardFilter = filter
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state, board: fixture(), settings: settings)
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
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canCopySelection == true }
        XCTAssertTrue(selected, "Select All selected something")
        _ = await settle { (state.actions?.alignableSelectionCount ?? 0) > 0 }
        return state.actions?.alignableSelectionCount ?? 0
    }

    func testSelectAllTakesOnlyTheKindsTheFilterLetsThrough() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let unfiltered = try await partsSelectedBySelectAll(with: BoardSelectionFilter())
        XCTAssertEqual(unfiltered, 2, "both parts, unfiltered")

        var tracksOnly = BoardSelectionFilter()
        tracksOnly.only(.tracks)
        let filtered = try await partsSelectedBySelectAll(with: tracksOnly)
        XCTAssertEqual(filtered, 0, "the track alone, no part")
    }
}
#endif
