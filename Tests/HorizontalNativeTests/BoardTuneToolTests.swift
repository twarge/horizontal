import Foundation
import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import HorizontalNative

/// The tune tool on the board canvas: a click on a straight track starts the
/// meander there, the cursor stretches it, the preview is the board with the
/// meander laid under ids that don't change, the inspector and the hint say
/// where it stands, and the canvas arms and ends the tool.
@MainActor
final class BoardTuneToolTests: XCTestCase {
    private let mm = 1_000_000.0
    private let net = "aaaaaaaa-0000-4000-8000-000000000001"

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    private func board() -> HorizontalBoard {
        let bounds = HorizontalRect(points: [.zero, p(40, 20)])
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/tune-tool.hprj"), uuid: "b", name: "tune tool",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:],
            netDetails: [net: HorizontalNetDetails(id: net, name: "CLK")],
            tracks: [HorizontalSegment(id: "t", from: p(5, 10), to: p(35, 10), width: 200_000, layer: 0, netID: net)],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
    }

    func testAClickStartsTheTuneAndTheCursorStretchesIt() throws {
        var state = BoardTuneState(board: board())
        let settings = HorizontalMeander.Settings()
        XCTAssertFalse(state.start(at: p(20, 15), reach: 100_000, target: 34 * mm, settings: settings), "no track there")
        XCTAssertNotNil(state.refusal)
        XCTAssertTrue(state.hint.contains("no straight track"), state.hint)

        XCTAssertTrue(state.start(at: HorizontalPoint(x: 6 * mm + 0.4, y: 10 * mm + 20_000), reach: 100_000,
                                  target: 34 * mm, settings: settings))
        XCTAssertEqual(state.trackID, "t")
        XCTAssertEqual(state.anchor, p(6, 10), "on the track, in whole nanometres")
        XCTAssertFalse(state.result?.hasCells ?? true, "the cursor hasn't moved along it yet")

        state.move(to: p(34, 11), target: 34 * mm, settings: settings)
        let result = try XCTUnwrap(state.result)
        XCTAssertEqual(result.status, .reached)
        XCTAssertTrue(result.plan.cells.allSatisfy { $0.side == 1 }, "the cursor's side")
        XCTAssertTrue(state.hint.contains("click lays it"), state.hint)

        let inspector = state.inspectorState(target: 34 * mm, source: .reference)
        XCTAssertEqual(inspector.netName, "CLK")
        XCTAssertEqual(inspector.netLength ?? 0, 30 * mm, accuracy: 1e-6)
        XCTAssertEqual(inspector.tunedLength ?? 0, 34 * mm, accuracy: 2)
        XCTAssertEqual(inspector.cells, result.plan.cells.count)
        XCTAssertFalse(inspector.isShort)

        // The preview is the board with it laid, under ids that stay put.
        let preview = state.preview(of: board())
        XCTAssertNil(preview.tracks.first { $0.id == "t" })
        XCTAssertTrue(preview.tracks.allSatisfy { $0.id.hasPrefix(BoardTuneState.previewIDPrefix) })
        XCTAssertEqual(state.preview(of: board()).tracks, preview.tracks)
        XCTAssertEqual(HorizontalTrackLength.routedLength(ofNet: net, in: preview.tracks), result.tunedLength, accuracy: 1e-3)
        let signature = try XCTUnwrap(state.previewSignature)
        state.move(to: p(30, 11), target: 34 * mm, settings: settings)
        XCTAssertEqual(state.previewSignature?.hash, signature.hash, "the same cells, the same preview")
        state.move(to: p(34, 9), target: 34 * mm, settings: settings)
        XCTAssertNotEqual(state.previewSignature?.hash, signature.hash, "the other side is another meander")

        // A target it can't reach in the stretch says how much is missing.
        state.move(to: p(8, 11), target: 34 * mm, settings: settings)
        guard case .short = state.result?.status else { return XCTFail("\(String(describing: state.result?.status))") }
        XCTAssertTrue(state.inspectorState(target: 34 * mm, source: .typed).isShort)

        state.restart()
        XCTAssertFalse(state.hasStarted)
        XCTAssertNil(state.previewSignature)
        XCTAssertEqual(state.preview(of: board()).tracks.map(\.id), ["t"])
    }

    func testNoTargetLaysNothing() {
        var state = BoardTuneState(board: board())
        state.start(at: p(6, 10), reach: 100_000, target: nil, settings: HorizontalMeander.Settings())
        state.move(to: p(34, 11), target: nil, settings: HorizontalMeander.Settings())
        XCTAssertNil(state.result)
        XCTAssertTrue(state.hint.contains("no target"), state.hint)
        XCTAssertEqual(state.inspectorState(target: nil, source: .none).targetSource, .none)
    }

    #if os(macOS)
    @MainActor private final class Host: ObservableObject {
        @Published var board: HorizontalBoard
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let routeInspector = HorizontalRouteInspectorModel()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Pane: View {
        @ObservedObject var host: Host
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: host.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: host.undo,
                onBoardChange: { host.board = $0 },
                tuningReferenceLength: 34_000_000,
                onCanvasCommandActionsChange: { host.actions = $0 },
                routeInspector: host.routeInspector,
                toolSettings: host.toolSettings)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// Design ▸ Tune Track arms the tool on a board canvas: the inspector
    /// takes it, with the window's reference for the target, and Esc ends it.
    func testTheCanvasArmsAndEndsTheTool() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let host = Host(board())
        let hosted = NSHostingView(rootView: Pane(host: host)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        let mounted = await settle { host.actions != nil }
        XCTAssertTrue(mounted)
        XCTAssertEqual(host.actions?.canTuneTrack, true)
        host.actions?.dispatch(.tuneTrack)
        let armed = await settle { host.routeInspector.tune != nil && host.actions?.canCancelInteraction == true }
        XCTAssertTrue(armed)
        XCTAssertTrue(host.routeInspector.isRouting, "the host shows the inspector as for a route")
        XCTAssertEqual(host.routeInspector.tune?.target, 34_000_000)
        XCTAssertEqual(host.routeInspector.tune?.targetSource, .reference)

        host.actions?.dispatch(.cancelInteraction)
        let ended = await settle { host.routeInspector.tune == nil && host.actions?.canCancelInteraction == false }
        XCTAssertTrue(ended)
        XCTAssertFalse(host.routeInspector.isRouting)
    }
    #endif
}
