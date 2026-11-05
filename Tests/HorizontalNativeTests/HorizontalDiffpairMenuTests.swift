import Foundation
import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import HorizontalNative

/// The canvases' right-click Set Differential Pair, for a selection of two
/// nets on either of them, and Clear Differential Pair, on a paired net: the
/// entries the menu offers, and the edits the commands make on a mounted
/// board and schematic, the selection left as it was.
@MainActor
final class HorizontalDiffpairMenuTests: XCTestCase {
    private let rx = "11111111-1111-4111-8111-111111111111"
    private let rxn = "22222222-2222-4222-8222-222222222222"
    private let tx = "33333333-3333-4333-8333-333333333333"
    private let txn = "44444444-4444-4444-8444-444444444444"
    private let gnd = "55555555-5555-4555-8555-555555555555"

    private var details: [String: HorizontalNetDetails] {
        [rx: HorizontalNetDetails(id: rx, name: "RX-"),
         rxn: HorizontalNetDetails(id: rxn, name: "RX+"),
         tx: HorizontalNetDetails(id: tx, name: "TX+", diffpairID: txn, isDiffpairPrimary: true),
         txn: HorizontalNetDetails(id: txn, name: "TX-", diffpairID: tx),
         gnd: HorizontalNetDetails(id: gnd, name: "GND", isPower: true)]
    }

    private func titles(_ entries: [HorizontalTargetItemMenuEntry]) -> [String] {
        entries.map { entry in
            if case .command(let title, _) = entry { return title }
            return "?"
        }
    }

    func testTwoSelectedNetsOfferSetAndAPairedNetOffersClear() throws {
        let all: (String) -> Bool = { _ in true }
        // Two free nets selected: Set, on an object of either.
        for net in [rx, rxn.uppercased()] {
            let entries = HorizontalDiffpairProperty.menuEntries(for: net, selectedNetIDs: [rx, rxn], in: details, canEdit: all)
            XCTAssertEqual(titles(entries), ["Set Differential Pair"])
            guard case .command(_, .setDiffpair(let nets)) = try XCTUnwrap(entries.first) else { return XCTFail() }
            XCTAssertEqual(Set(nets), [rx, rxn])
            // RX+ sorts before RX-, so it is the primary.
            let edit = try XCTUnwrap(HorizontalDiffpairProperty.pairing(of: Set(nets), in: details))
            XCTAssertEqual(edit.ops.first?.string("net"), rxn)
            XCTAssertEqual(edit.actionName, "Set Differential Pair")
        }
        XCTAssertEqual(titles(HorizontalDiffpairProperty.menuEntries(for: tx, selectedNetIDs: [rx, rxn], in: details, canEdit: all)),
                       ["Clear Differential Pair"], "a third net, paired: Clear for it, no Set")
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: rx, selectedNetIDs: [rx], in: details, canEdit: all).count, 0,
                       "one net selected")
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: rx, selectedNetIDs: [rx, rxn, tx], in: details, canEdit: all).count, 0,
                       "three nets selected")

        // A paired net: Clear for its own net; the pair selected is no new pair.
        let paired = HorizontalDiffpairProperty.menuEntries(for: txn, selectedNetIDs: [tx, txn], in: details, canEdit: all)
        XCTAssertEqual(titles(paired), ["Clear Differential Pair"])
        guard case .command(_, .clearDiffpair(let net)) = try XCTUnwrap(paired.first) else { return XCTFail() }
        XCTAssertEqual(net, txn)
        XCTAssertEqual(HorizontalDiffpairProperty.clearing(of: [net], in: details)?.actionName, "Clear Differential Pair")

        // A free net with one paired to another selected can't pair; the paired one can clear.
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: rx, selectedNetIDs: [rx, tx], in: details, canEdit: all).count, 0)
        XCTAssertEqual(titles(HorizontalDiffpairProperty.menuEntries(for: tx, selectedNetIDs: [rx, tx], in: details, canEdit: all)),
                       ["Clear Differential Pair"])

        // A power net, no net, and nets the canvas can't edit offer nothing.
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: gnd, selectedNetIDs: [gnd, rx], in: details, canEdit: all).count, 0)
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: nil, selectedNetIDs: [rx, rxn], in: details, canEdit: all).count, 0)
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: rx, selectedNetIDs: [rx, rxn], in: details,
                                                              canEdit: { $0 != rxn }).count, 0)
        XCTAssertEqual(HorizontalDiffpairProperty.menuEntries(for: tx, selectedNetIDs: [tx], in: details,
                                                              canEdit: { $0 != tx }).count, 0)
    }

    #if os(macOS)
    private let mm = 1_000_000.0

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func mount<Content: View>(_ content: Content) -> NSWindow {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: content
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return window
    }

    @MainActor private final class Host: ObservableObject {
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var edits = [(ops: [JSONDictionary], actionName: String)]()
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private struct BoardPane: View {
        var board: HorizontalBoard
        @ObservedObject var host: Host
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: host.undo,
                onEditDiffpair: HorizontalDiffpairEditing(canEdit: { _ in true }, apply: { host.edits.append(($0, $1)) }),
                onSelectionDetailsChange: { host.details = $0 },
                onCanvasCommandActionsChange: { host.actions = $0 },
                toolSettings: host.toolSettings)
        }
    }

    private func board() -> HorizontalBoard {
        let top = HorizontalBoardLayers.topCopper
        let bounds = HorizontalRect(points: [.zero, HorizontalPoint(x: 20 * mm, y: 10 * mm)])
        func track(_ id: String, _ y: Double, _ net: String) -> HorizontalSegment {
            HorizontalSegment(id: id, from: HorizontalPoint(x: 5 * mm, y: y * mm), to: HorizontalPoint(x: 15 * mm, y: y * mm),
                              width: 150_000, layer: top, netID: net)
        }
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/diffpair-menu.hprj"), uuid: "b", name: "diffpair menu",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: details,
            tracks: [track("t-rx", 2, rx), track("t-rxn", 2.3, rxn)],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: bounds, bounds: bounds
        )
    }

    /// On the board, Set Differential Pair pairs the two nets it names and
    /// Clear Differential Pair clears the one, as project edits, and the
    /// two tracks selected stay selected.
    func testTheBoardsCommandsEditTheNetsTheyName() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let host = Host()
        let window = mount(BoardPane(board: board(), host: host))
        defer { window.close() }
        let mounted = await settle { host.actions != nil }
        XCTAssertTrue(mounted)
        host.actions?.dispatch(.selectAll)
        func selected() -> Int { host.details.groups.first { $0.type == .track }?.items.count ?? 0 }
        let both = await settle { selected() == 2 }
        XCTAssertTrue(both)

        host.actions?.dispatch(.setDiffpair([rx, rxn]))
        let paired = await settle { host.edits.count == 1 }
        XCTAssertTrue(paired)
        XCTAssertEqual(host.edits.first?.actionName, "Set Differential Pair")
        XCTAssertEqual(host.edits.first?.ops.first?.string("op"), "set_diffpair")
        XCTAssertEqual(host.edits.first?.ops.first?.string("net"), rxn, "RX+ the primary")
        XCTAssertEqual(host.edits.first?.ops.first?.string("partner"), rx)
        XCTAssertEqual(selected(), 2, "the selection stays")

        host.actions?.dispatch(.clearDiffpair(txn))
        let cleared = await settle { host.edits.count == 2 }
        XCTAssertTrue(cleared)
        XCTAssertEqual(host.edits.last?.actionName, "Clear Differential Pair")
        XCTAssertEqual(host.edits.last?.ops.first?.string("op"), "clear_diffpair")
        XCTAssertEqual(host.edits.last?.ops.first?.string("net"), txn)

        // Nets that can't pair make no edit.
        host.actions?.dispatch(.setDiffpair([rx, tx]))
        host.actions?.dispatch(.clearDiffpair(rx))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(host.edits.count, 2)
    }

    private struct SchematicPane: View {
        var sheet: HorizontalSchematicSheet
        @ObservedObject var host: Host
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(sheet: sheet, viewport: $viewport, undoManager: host.undo,
                onApplyProjectEdit: { host.edits.append(($0, $1)) },
                onSelectionDetailsChange: { host.details = $0 },
                onCanvasCommandActionsChange: { host.actions = $0 })
        }
    }

    private func sheet() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.netDetails = details
        func wire(_ id: String, _ y: Double, _ net: String) -> HorizontalSegment {
            HorizontalSegment(id: id, from: HorizontalPoint(x: 0, y: y * mm), to: HorizontalPoint(x: 10 * mm, y: y * mm),
                              width: 0, layer: nil, netID: net)
        }
        sheet.netLines = [wire("w-rx", 0, rx), wire("w-rxn", 2.5, rxn), wire("w-tx", 5, tx)]
        return sheet
    }

    /// On the schematic too, through its project edit, the selection kept.
    func testTheSchematicsCommandsEditTheNetsTheyName() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let host = Host()
        let window = mount(SchematicPane(sheet: sheet(), host: host))
        defer { window.close() }
        let mounted = await settle { host.actions != nil }
        XCTAssertTrue(mounted)
        host.actions?.dispatch(.selectAll)
        func selected() -> Int { host.details.groups.flatMap(\.items).count }
        let all = await settle { selected() == 3 }
        XCTAssertTrue(all, "\(host.details.groups.map(\.title))")

        host.actions?.dispatch(.setDiffpair([rx, rxn]))
        let paired = await settle { host.edits.count == 1 }
        XCTAssertTrue(paired)
        XCTAssertEqual(host.edits.first?.actionName, "Set Differential Pair")
        XCTAssertEqual(host.edits.first?.ops.first?.string("net"), rxn)
        XCTAssertEqual(host.edits.first?.ops.first?.string("partner"), rx)

        host.actions?.dispatch(.clearDiffpair(tx))
        let cleared = await settle { host.edits.count == 2 }
        XCTAssertTrue(cleared)
        XCTAssertEqual(host.edits.last?.actionName, "Clear Differential Pair")
        XCTAssertEqual(host.edits.last?.ops.first?.string("net"), tx)
        XCTAssertEqual(selected(), 3, "the selection stays")
    }
    #endif
}
