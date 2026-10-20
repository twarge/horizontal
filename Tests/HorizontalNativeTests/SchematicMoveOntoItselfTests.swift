#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A move that takes one of the moving junctions to where another moving
/// junction starts. Merging the first there at once took in the second
/// before it moved away, wiring their nets together: on Avery, C1 and C2
/// moved down until their top pins reached their GND junctions drew GND on
/// the top pins in the preview, and a commit there would have joined P12V
/// to GND.
@MainActor
final class SchematicMoveOntoItselfTests: XCTestCase {
    @MainActor private final class State {
        var source: HorizontalSchematicSheet
        var committed: HorizontalSchematicSheet?
        var actions: HorizontalCanvasCommandActions?
        let undo = UndoManager()
        init(_ sheet: HorizontalSchematicSheet) { source = sheet }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var sheet: HorizontalSchematicSheet
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _sheet = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            SchematicCanvasView(sheet: sheet, viewport: $viewport, undoManager: state.undo,
                onSheetChange: { state.committed = $0; sheet = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 })
        }
    }

    /// A two-pin part with a junction 2.5 mm beyond each pin, P above on
    /// net P and G below on net G, wired to them.
    private func fixture() -> HorizontalSchematicSheet {
        var sheet = HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000)
        sheet.symbols = [.init(id: "symbol", position: .zero, angle: 0, mirrored: false, label: "C1", componentID: "component")]
        sheet.symbolLines = [.init(id: "symbol/line/body", from: .init(x: -1_250_000, y: -2_500_000),
                                   to: .init(x: 1_250_000, y: 2_500_000), width: 0, layer: nil)]
        sheet.symbolPins = [
            .init(id: "symbol/pin/top", from: .init(x: 0, y: 5_000_000), to: .init(x: 0, y: 2_500_000), width: 0, layer: nil, netID: "p"),
            .init(id: "symbol/pin/bottom", from: .init(x: 0, y: -5_000_000), to: .init(x: 0, y: -2_500_000), width: 0, layer: nil, netID: "g"),
        ]
        sheet.junctions = ["p": .init(x: 0, y: 7_500_000), "g": .init(x: 0, y: -7_500_000)]
        sheet.junctionNetIDs = ["p": "p", "g": "g"]
        sheet.netDetails = ["p": .init(id: "p", name: "P"), "g": .init(id: "g", name: "G")]
        sheet.netLines = [
            HorizontalSegment(id: "top", from: .init(x: 0, y: 5_000_000), to: .init(x: 0, y: 7_500_000), width: 0, layer: nil,
                              schematicFrom: .pin("symbol/top"), schematicTo: .junction("p")).withNetID("p"),
            HorizontalSegment(id: "bottom", from: .init(x: 0, y: -5_000_000), to: .init(x: 0, y: -7_500_000), width: 0, layer: nil,
                              schematicFrom: .pin("symbol/bottom"), schematicTo: .junction("g")).withNetID("g"),
        ]
        return sheet
    }

    /// The same part with its junctions on its pins, each wired on to a
    /// junction of its own that stays put: the symbol takes the junctions on
    /// its pins with it when it moves alone.
    private func junctionsOnPins() -> HorizontalSchematicSheet {
        var sheet = fixture()
        sheet.junctions = ["p": .init(x: 0, y: 5_000_000), "g": .init(x: 0, y: -5_000_000),
                           "p-end": .init(x: 0, y: 7_500_000), "g-end": .init(x: 0, y: -7_500_000)]
        sheet.junctionNetIDs = ["p": "p", "g": "g", "p-end": "p", "g-end": "g"]
        sheet.netLines = [
            HorizontalSegment(id: "top", from: .init(x: 0, y: 5_000_000), to: .init(x: 0, y: 7_500_000), width: 0, layer: nil,
                              schematicFrom: .junction("p"), schematicTo: .junction("p-end")).withNetID("p"),
            HorizontalSegment(id: "bottom", from: .init(x: 0, y: -5_000_000), to: .init(x: 0, y: -7_500_000), width: 0, layer: nil,
                              schematicFrom: .junction("g"), schematicTo: .junction("g-end")).withNetID("g"),
        ]
        return sheet
    }

    private func committedMove(by delta: HorizontalPoint, of sheet: HorizontalSchematicSheet? = nil,
                               symbolOnly: Bool = false) async throws -> HorizontalSchematicSheet {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let state = State(sheet ?? fixture())
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        func settle(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            return predicate()
        }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        if symbolOnly {
            state.actions?.selectComponents?(["component"])
        } else {
            state.actions?.dispatch(.selectAll)
        }
        let selected = await settle { state.actions?.canMoveSelection == true }
        XCTAssertTrue(selected)
        // A step at a time, as the arrow keys move it, through the step
        // that puts one junction where the other started.
        let step = HorizontalPoint(x: delta.x / 12, y: delta.y / 12)
        for _ in 0..<12 {
            state.actions?.dispatch(.moveSelectionBy(step))
            try await Task.sleep(for: .milliseconds(20))
        }
        state.actions?.dispatch(.commitInteraction)
        let committed = await settle { state.committed != nil }
        XCTAssertTrue(committed, "the move commits without asking which net to keep")
        return try XCTUnwrap(state.committed)
    }

    private func assertMovedApart(_ sheet: HorizontalSchematicSheet, by delta: HorizontalPoint,
                                  from original: HorizontalSchematicSheet? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let original = original ?? fixture()
        XCTAssertEqual(Set(sheet.junctions.keys), ["p", "g"], "neither junction swallowed the other", file: file, line: line)
        for id in ["p", "g"] {
            XCTAssertEqual(sheet.junctions[id], original.junctions[id].map { $0 + delta }, id, file: file, line: line)
        }
        XCTAssertEqual(sheet.junctionNetIDs["p"], "p", file: file, line: line)
        XCTAssertEqual(sheet.junctionNetIDs["g"], "g", file: file, line: line)
        for wire in original.netLines {
            let moved = sheet.netLines.first { $0.id == wire.id }
            XCTAssertEqual(moved?.from, wire.from + delta, wire.id, file: file, line: line)
            XCTAssertEqual(moved?.to, wire.to + delta, wire.id, file: file, line: line)
        }
    }

    func testMovingDownOntoTheLowerJunctionKeepsBothJunctions() async throws {
        let delta = HorizontalPoint(x: 0, y: -15_000_000)
        assertMovedApart(try await committedMove(by: delta), by: delta)
    }

    func testMovingUpOntoTheUpperJunctionKeepsBothJunctions() async throws {
        let delta = HorizontalPoint(x: 0, y: 15_000_000)
        assertMovedApart(try await committedMove(by: delta), by: delta)
    }

    /// Moved alone, the symbol takes the junctions on its pins through its
    /// connection plan, whose merges wait for the move to finish as well.
    func testASymbolMovedAloneOntoItsOwnPinsKeepsItsNetsApart() async throws {
        let original = junctionsOnPins()
        for delta in [HorizontalPoint(x: 0, y: -10_000_000), HorizontalPoint(x: 0, y: 10_000_000)] {
            let moved = try await committedMove(by: delta, of: original, symbolOnly: true)
            // A junction left alone on a pin hands its wire to the pin, as
            // Horizon's does; what matters is where each wire ends, and that
            // the nets stay two.
            for wire in original.netLines {
                let line = moved.netLines.first { $0.id == wire.id }
                XCTAssertEqual(line?.from, wire.from + delta, "\(wire.id) \(delta)")
                XCTAssertEqual(line?.to, wire.to, "\(wire.id) \(delta)")
                XCTAssertEqual(line?.netID, wire.netID, "\(wire.id) \(delta)")
            }
            XCTAssertEqual(moved.junctionNetIDs["p-end"], "p", "\(delta)")
            XCTAssertEqual(moved.junctionNetIDs["g-end"], "g", "\(delta)")
            XCTAssertEqual(Set(moved.netDetails.keys), ["p", "g"], "\(delta)")
        }
    }
}
#endif
