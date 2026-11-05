#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// H on a package smashed already selects its smashed refdes, where it did
/// nothing, the package having nothing left to smash.
@MainActor
final class BoardSmashSelectsRefdesTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private let silk = HorizontalBoardLayers.topSilkscreen

    private func text(_ id: String, _ drawn: String, stored: String, at x: Double, fromSmash: Bool) -> HorizontalText {
        HorizontalText(id: id, text: drawn, position: HorizontalPoint(x: x * mm, y: 2 * mm), size: mm, layer: silk,
                       fromSmash: fromSmash, placeholder: HorizontalTextPlaceholder(stored: stored, drawn: drawn))
    }

    /// R1, smashed, its refdes and value board texts of its own; with
    /// `unsmashed`, R2 beside it, drawing its own $RD.
    private func board(unsmashed: Bool) -> HorizontalBoard {
        var packages = [HorizontalPlacement(id: "pa", position: HorizontalPoint(x: 0, y: 0), angle: 0, mirrored: false,
                                            label: "R1", componentID: "ca", smashed: true)]
        var texts = [text("pa/text/rd", "R1", stored: "$RD", at: 0, fromSmash: true),
                     text("pa/text/val", "10k", stored: "$VALUE", at: 0.5, fromSmash: true)]
        if unsmashed {
            packages.append(HorizontalPlacement(id: "pb", position: HorizontalPoint(x: 10 * mm, y: 0), angle: 0, mirrored: false,
                                                label: "R2", componentID: "cb"))
            texts.append(text("pb/text/rd", "R2", stored: "$RD", at: 10, fromSmash: false))
        }
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/smash-refdes.hprj"), uuid: "b", name: "smash refdes",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [],
            junctions: [:], junctionNetIDs: [:], netDetails: [:], tracks: [],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: packages,
            packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: texts, texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitor(in view: NSView) -> TrackpadCanvasMonitor.MonitorView? {
        if let view = view as? TrackpadCanvasMonitor.MonitorView { return view }
        return view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    /// Mounts the canvas, selects everything and presses H.
    private func pressHOnEverything(_ state: State) async throws -> NSWindow {
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

        state.actions?.dispatch(.selectAll)
        let all = await settle { Set(state.details.groups.map(\.type)) == [.boardPackage, .text] }
        XCTAssertTrue(all, "\(state.details.groups.map(\.type))")

        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        XCTAssertNil(handle(event), "the canvas takes H")
        return window
    }

    private func selectedIDs(_ state: State) -> [String] {
        state.details.groups.flatMap { $0.items.map(\.ref.id) }.sorted()
    }

    func testHOnASmashedPackageSelectsItsRefdes() async throws {
        let state = State(board(unsmashed: false))
        let window = try await pressHOnEverything(state)
        defer { window.close() }

        let refdes = await settle { self.selectedIDs(state) == ["pa/text/rd"] }
        XCTAssertTrue(refdes, "the refdes alone, not the package or its value: \(selectedIDs(state))")
        XCTAssertEqual(state.committed.count, 0, "nothing changed")
        XCTAssertFalse(state.undo.canUndo, "and there is nothing to undo")
    }

    /// With a package not smashed yet beside it, H smashes that one and
    /// selects the texts the smash made, with the other's refdes.
    func testHSmashesTheOthersAndSelectsTheirTextsWithTheRefdes() async throws {
        let state = State(board(unsmashed: true))
        let window = try await pressHOnEverything(state)
        defer { window.close() }

        let committed = await settle { state.committed.count == 1 }
        XCTAssertTrue(committed)
        let board = try XCTUnwrap(state.committed.last)
        XCTAssertEqual(board.packages.map(\.smashed), [true, true])
        let made = try XCTUnwrap(board.packageTexts.first { $0.fromSmash && $0.id.hasPrefix("pb/text/") })
        let selected = await settle { self.selectedIDs(state) == [made.id, "pa/text/rd"].sorted() }
        XCTAssertTrue(selected, "\(selectedIDs(state))")
    }

    func testRefdesIsWhatTheTextStores() {
        func stored(_ text: String) -> HorizontalText {
            HorizontalText(id: "t", text: "R1", position: .zero, size: mm, layer: silk, fromSmash: true,
                           placeholder: HorizontalTextPlaceholder(stored: text, drawn: "R1"))
        }
        for text in ["$RD", "$REFDES", "$REF", "${RD}", "$rd", "Part $RD"] {
            XCTAssertTrue(HorizontalSmash.isRefdes(stored(text)), text)
        }
        for text in ["$VALUE", "$VAL", "$RDX", "RD", "$project_title"] {
            XCTAssertFalse(HorizontalSmash.isRefdes(stored(text)), text)
        }
        XCTAssertFalse(HorizontalSmash.isRefdes(HorizontalText(id: "t", text: "R1", position: .zero, size: mm, layer: silk)),
                       "a text typed as R1 is a text")
    }
}
#endif
