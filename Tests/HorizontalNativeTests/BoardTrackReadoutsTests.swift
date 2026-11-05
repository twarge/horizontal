#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The board inspector's readouts for selected tracks, as a mounted board
/// canvas reports them: Horizon's track HUD (total length, the spacing of two
/// parallel tracks), the Measure buttons that fill the Length Tuning window,
/// and the Diff pair row on a paired net, whose edits go to the project edit.
@MainActor
final class BoardTrackReadoutsTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var command: HorizontalSelectionPropertyChangeCommand?
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var measured = [(tracks: Set<String>, allTracks: Bool)]()
        var edits = [(ops: [JSONDictionary], actionName: String)]()
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { self.board = board }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.board = $0 },
                onEditDiffpair: HorizontalDiffpairEditing(canEdit: { _ in true }, apply: { state.edits.append(($0, $1)) }),
                onMeasureTracks: { state.measured.append(($0, $1)) },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.command,
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private let tx = "11111111-1111-4111-8111-111111111111"
    private let txn = "22222222-2222-4222-8222-222222222222"

    /// A diff pair's two tracks, 10 mm long and 0.3 mm apart, centre to centre.
    private func board() -> HorizontalBoard {
        let top = HorizontalBoardLayers.topCopper
        let bounds = HorizontalRect(points: [.zero, HorizontalPoint(x: 20 * mm, y: 10 * mm)])
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/track-readouts.hprj"), uuid: "b", name: "track readouts",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:],
            netDetails: [tx: HorizontalNetDetails(id: tx, name: "TX+", diffpairID: txn, isDiffpairPrimary: true),
                         txn: HorizontalNetDetails(id: txn, name: "TX-", diffpairID: tx)],
            tracks: [
                HorizontalSegment(id: "t-p", from: HorizontalPoint(x: 5 * mm, y: 5 * mm), to: HorizontalPoint(x: 15 * mm, y: 5 * mm),
                                  width: 150_000, layer: top, netID: tx),
                HorizontalSegment(id: "t-n", from: HorizontalPoint(x: 5 * mm, y: 5.3 * mm), to: HorizontalPoint(x: 15 * mm, y: 5.3 * mm),
                                  width: 150_000, layer: top, netID: txn),
            ],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testSelectedTracksShowHorizonsHUDAndMeasure() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State(board())
        let hosted = NSHostingView(rootView: Pane(state: state)
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
        func tracks() -> HorizontalSelectionDetailGroup? { state.details.groups.first { $0.type == .track } }
        let selected = await settle { tracks()?.items.count == 2 }
        XCTAssertTrue(selected, "\(state.details.groups.map(\.title))")
        let group = try XCTUnwrap(tracks())
        let rows = Dictionary(uniqueKeysWithValues: group.summary.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Total length"], "20.000 mm")
        XCTAssertEqual(rows["Spacing"], "0.300 mm")
        XCTAssertEqual(rows["Gap"], "0.150 mm")
        XCTAssertEqual(rows["Nets"], "2")
        XCTAssertEqual(group.actions.map(\.title), ["Measure", "Measure All"])

        // A paired track's own Diff pair row, editable through the host.
        let primary = try XCTUnwrap(group.items.first { $0.ref.id == "t-p" })
        let row = try XCTUnwrap(primary.properties.first { $0.id == HorizontalDiffpairProperty.id })
        XCTAssertEqual(row.value, .choice(txn))
        XCTAssertTrue(row.isEditable)

        // Measure All: the selected tracks to the window, every track of their nets.
        state.command = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: primary.ref, type: .track, propertyID: HorizontalTrackSelectionSummary.measureAllActionID,
            value: .bool(true), applyToAll: true))
        let measuredAll = await settle { !state.measured.isEmpty }
        XCTAssertTrue(measuredAll)
        XCTAssertEqual(state.measured.first?.tracks, ["t-p", "t-n"])
        XCTAssertEqual(state.measured.first?.allTracks, true)

        // Choosing None clears the pair, as one project edit.
        state.command = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: primary.ref, type: .track, propertyID: HorizontalDiffpairProperty.id,
            value: .choice(HorizontalDiffpairProperty.noneID), applyToAll: false))
        let edited = await settle { !state.edits.isEmpty }
        XCTAssertTrue(edited)
        XCTAssertEqual(state.edits.first?.actionName, "Clear Diff Pair")
        XCTAssertEqual(state.edits.first?.ops.first?.string("op"), "clear_diffpair")
        XCTAssertEqual(state.edits.first?.ops.first?.string("net"), tx)
        XCTAssertEqual(state.board.tracks.count, 2, "the board itself is left to the project edit's reload")
    }

    func testTheTuningWindowShowsItsList() throws {
        let model = HorizontalLengthTuningModel()
        model.update(board: board())
        model.add(trackIDs: ["t-p", "t-n"], allTracks: false)
        let controller = HorizontalLengthTuningWindowController()
        controller.show(projectName: "Readouts", model: model)
        defer { controller.close() }
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(model.measurements.count, 2)
        XCTAssertEqual(model.measurements.map(\.length), [10 * mm, 10 * mm])
    }
}
#endif
