#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A delete that takes only copper off the board takes it out of the scene
/// already built rather than building the whole board again, and the copper
/// it cut off from its net is drawn again: what the canvas draws afterwards
/// is what a canvas opened on the board it left draws.
@MainActor
final class BoardDeleteSceneSpliceTests: XCTestCase {
    @MainActor private final class Host: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var displayOptions: BoardDisplayOptions
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, displayOptions: BoardDisplayOptions) {
            self.board = board
            self.displayOptions = displayOptions
        }
    }

    private struct Canvas: View {
        @ObservedObject var host: Host
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: host.board, viewport: $viewport, displayOptions: host.displayOptions, undoManager: host.undo,
                onBoardChange: { host.committed.append($0); host.board = $0 },
                onCanvasCommandActionsChange: { host.actions = $0 },
                toolSettings: host.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper
    private func p(_ x: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: 10 * mm) }

    /// Fixed parts A and B, which a delete leaves; pad a1 on n and a chain
    /// of tracks from it along y = 10 mm through j1 and j2 to a via v at
    /// 30 mm; pad b1 on n at 40 mm, joined to nothing.
    private func board() -> HorizontalBoard {
        func pad(_ package: String, _ name: String, at center: HorizontalPoint) -> HorizontalPolygon {
            let half = 0.4 * mm
            return HorizontalPolygon(id: "\(package)/pad/\(name)/shape/s", vertices: [
                .init(x: center.x - half, y: center.y - half), .init(x: center.x + half, y: center.y - half),
                .init(x: center.x + half, y: center.y + half), .init(x: center.x - half, y: center.y + half),
            ], layer: top, netID: "n")
        }
        func track(_ id: String, _ from: Double, _ to: Double, _ fromJunction: String?, _ toJunction: String?) -> HorizontalSegment {
            HorizontalSegment(id: id, from: p(from), to: p(to), width: 250_000, layer: top, netID: "n",
                              fromJunctionID: fromJunction, toJunctionID: toJunction)
        }
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/delete-scene-splice.hprj"), uuid: "b", name: "delete scene splice",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: ["j1": p(10), "j2": p(20), "j3": p(30)], junctionNetIDs: [:],
            netDetails: ["n": HorizontalNetDetails(id: "n", name: "SIGNAL")],
            tracks: [track("t1", 0, 10, nil, "j1"), track("t2", 10, 20, "j1", "j2"), track("t3", 20, 30, "j2", "j3")],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [HorizontalMarker(id: "v", position: p(30), size: 600_000, holeSize: 300_000, layer: nil,
                                    connectedLayers: [top, HorizontalBoardLayers.bottomCopper], netID: "n")],
            viaHoles: [HorizontalHole(id: HorizontalBoard.viaHoleID(ofVia: "v"), position: p(30), diameter: 300_000,
                                      plated: true, netID: "n")],
            packages: [
                HorizontalPlacement(id: "pa", position: p(0), angle: 0, mirrored: false, label: "A", componentID: "ca", fixed: true),
                HorizontalPlacement(id: "pb", position: p(40), angle: 0, mirrored: false, label: "B", componentID: "cb", fixed: true),
            ],
            packagePads: [pad("pa", "a1", at: p(0)), pad("pb", "b1", at: p(40))],
            packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pa/a1": p(0), "pb/b1": p(40)]
        board = HorizontalBoardConnectivity.recompute(board)
        board.regenerateAirwires()
        return board
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

    private func layer(in view: NSView) -> HorizontalMetalCanvasLayer? {
        if let metal = view as? MTKView, let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           let layer = renderer.layer(labeled: "Metal overlay") { return layer }
        return view.subviews.lazy.compactMap { self.layer(in: $0) }.first
    }

    private func mount(_ host: Host) async -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(host: host)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { host.actions != nil && self.monitor(in: hosted) != nil && self.layer(in: hosted) != nil }
        XCTAssertTrue(mounted)
        return (window, hosted)
    }

    private struct Line: Hashable {
        var group: Int
        var from: SIMD2<Int>
        var to: SIMD2<Int>
    }

    /// Every line the scene holds, by composite group, ends rounded to 10 nm.
    private func scene(in view: NSView) -> [Line: Int] {
        guard let layer = layer(in: view) else {
            return [:]
        }
        var lines = [Line: Int]()
        for group in layer.compositedGroups {
            for line in layer.residentLineEndpoints(compositeGroup: group) {
                func rounded(_ point: SIMD2<Float>) -> SIMD2<Int> { SIMD2(Int((point.x / 10).rounded()), Int((point.y / 10).rounded())) }
                lines[Line(group: group, from: rounded(line.from), to: rounded(line.to)), default: 0] += 1
            }
        }
        return lines
    }

    /// With the vias hidden Select All takes the tracks and junctions but
    /// not the via, which the delete leaves on no net, to be drawn again.
    /// The scene the delete leaves is read before anything else changes: a
    /// change of what is shown that changes the layers built rebuilds it.
    func testASplicedDeleteDrawsWhatABuildOfTheBoardLeftDraws() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var options = BoardDisplayOptions()
        options.vias = false
        let host = Host(board(), displayOptions: options)
        XCTAssertEqual(host.board.vias.map(\.netID), ["n"])
        let (window, hosted) = await mount(host)
        defer { window.close() }
        let drawn = await settle { !self.scene(in: hosted).isEmpty }
        XCTAssertTrue(drawn)
        let before = scene(in: hosted)

        host.undo.beginUndoGrouping()
        host.actions?.dispatch(.selectAll)
        host.undo.endUndoGrouping()
        let selected = await settle { host.actions?.canDeleteSelection == true }
        XCTAssertTrue(selected)
        host.undo.beginUndoGrouping()
        host.actions?.dispatch(.deleteSelection)
        host.undo.endUndoGrouping()
        let committed = await settle { host.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(host.committed.last)
        XCTAssertEqual(board.tracks, [], "the tracks went")
        XCTAssertEqual(board.vias.map(\.id), ["v"], "the via, hidden, was not selected")
        XCTAssertEqual(board.vias.map(\.netID), [nil], "and is on no net now")
        XCTAssertEqual(board.packages.count, 2, "the fixed parts stayed")
        XCTAssertEqual(Set(board.junctions.keys), ["j3"], "the via holds its junction")

        let changed = await settle { self.scene(in: hosted) != before }
        XCTAssertTrue(changed, "the tracks left the scene")
        try? await Task.sleep(for: .milliseconds(300))
        let spliced = scene(in: hosted)

        let fresh = Host(board, displayOptions: options)
        let (freshWindow, freshHosted) = await mount(fresh)
        defer { freshWindow.close() }
        let built = await settle { !self.scene(in: freshHosted).isEmpty }
        XCTAssertTrue(built)
        try? await Task.sleep(for: .milliseconds(300))
        let rebuilt = scene(in: freshHosted)

        XCTAssertFalse(spliced.isEmpty)
        XCTAssertEqual(spliced.count, rebuilt.count, "as many distinct lines")
        XCTAssertEqual(spliced.filter { rebuilt[$0.key] != $0.value }.count, 0, "lines the spliced scene has that a build lacks")
        XCTAssertEqual(rebuilt.filter { spliced[$0.key] != $0.value }.count, 0, "lines a build has that the spliced scene lacks")
    }
}
#endif
