#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A package's drills and keepouts are parts of the package: the board picks
/// and moves only the whole package, as Horizon does. Its pad drills were
/// selectable as board holes of their own, so a click on one took the drill
/// (the smallest thing there) and a move or a delete took it off its pad.
@MainActor
final class BoardPackagePartSelectionTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.source, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let start = HorizontalPoint(x: 10_000_000, y: 10_000_000)

    private func square(_ id: String, at center: HorizontalPoint, half: Double, layer: Int) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [
            .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
            .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
        ], layer: layer, netID: nil)
    }

    private func keepout(_ id: String, at center: HorizontalPoint) -> HorizontalKeepout {
        HorizontalKeepout(
            id: id, polygonID: id, polygon: square(id, at: center, half: 200_000, layer: HorizontalBoardLayers.topCopper),
            keepoutClass: "", allCopperLayers: false, exposedCopperOnly: false, copperPatchTypes: [])
    }

    /// A through-hole part `pkg` with a drill in its pad and a keepout under
    /// it, beside a free mounting hole and a free keepout.
    private func board() -> HorizontalBoard {
        let away = HorizontalPoint(x: start.x + 5_000_000, y: start.y)
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/package-parts.hprj"), uuid: "b", name: "package parts",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [],
            keepouts: [keepout("pkg/keepout/k", at: start), keepout("k", at: away)],
            dimensions: [], decals: [],
            holes: [HorizontalHole(id: "h", position: HorizontalPoint(x: away.x, y: away.y + 2_000_000), diameter: 1_000_000, plated: false)],
            vias: [], viaHoles: [],
            packages: [HorizontalPlacement(id: "pkg", position: start, angle: 0, mirrored: false, label: "J1", componentID: "component")],
            packagePads: [square("pkg/pad/a", at: start, half: 500_000, layer: HorizontalBoardLayers.topCopper)],
            packageHoles: [HorizontalHole(id: "pkg/pad/a/hole", position: start, diameter: 600_000, plated: true)],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func selected(_ type: HorizontalObjectType, in details: HorizontalSelectionDetailState) -> Set<String> {
        Set(details.groups.filter { $0.type == type }.flatMap(\.items).map(\.ref.id))
    }

    /// Select All picks from what a click can pick: the package and the free
    /// hole and keepout, and none of the package's own parts.
    func testSelectAllTakesThePackageWholeAndNotItsDrillOrKeepout() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State(board())
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

        state.actions?.dispatch(.selectAll)
        let published = await settle { !self.selected(.boardPackage, in: state.details).isEmpty }
        XCTAssertTrue(published, "the selection reaches the sidebar")

        XCTAssertEqual(selected(.boardPackage, in: state.details), ["pkg"])
        XCTAssertEqual(selected(.boardHole, in: state.details), ["h"], "the pad's drill is the package's, not a hole of its own")
        XCTAssertEqual(selected(.keepout, in: state.details), ["k"], "and so is its keepout")
    }
}
#endif
