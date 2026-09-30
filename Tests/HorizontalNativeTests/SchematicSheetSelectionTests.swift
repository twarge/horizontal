#if os(macOS)
import AppKit
import HorizontalProjectIO
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

@MainActor
final class SchematicSheetSelectionTests: XCTestCase {
    private final class State: ObservableObject {
        let sheets: [HorizontalSchematicSheet]
        @Published var sheetIndex = 0
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var selectedComponents = Set<String>()

        init(sheets: [HorizontalSchematicSheet]) { self.sheets = sheets }

        func selectComponents(_ ids: Set<String>) {
            selectedComponents = ids
            // Match the workspace's round trip back to both canvases. A stale
            // callback searches the previous sheet and clears the new selection.
            actions?.selectComponents?(ids)
        }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @State private var viewport = CanvasViewport()

        var body: some View {
            SchematicCanvasView(
                sheet: state.sheets[state.sheetIndex], allSheets: state.sheets,
                viewport: $viewport,
                onSelectedComponentChange: state.selectComponents,
                onSelectionClearedBySheetChange: { state.selectComponents([]) },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 }
            )
        }
    }

    func testComponentAndGroupSelectionOnAnotherSheetBeforeSelectingAnyNet() async throws {
        let (state, window, hosted) = try mountCanvas()
        defer { window.close() }
        let mounted = await settle { state.actions != nil && self.renderer(in: hosted)?.presentedContentKey != nil }
        XCTAssertTrue(mounted)
        let renderer = try XCTUnwrap(renderer(in: hosted))

        // Both pages start with no selection. A sheet switch must refresh
        // the workspace's callbacks even when no selection state changed.
        let firstFrame = renderer.presentedContentKey
        state.sheetIndex = 1
        let switched = await settle { renderer.presentedContentKey != firstFrame }
        XCTAssertTrue(switched)
        state.actions?.selectComponents?(["component-1-0"])
        let selected = await settle { self.selectedSymbolIDs(state) == ["symbol-1-0"] }
        XCTAssertTrue(selected, "The first component selection on the second sheet must work without selecting a net first")

        state.actions?.selectComponents?(["component-1-0", "component-1-1"])
        let groupSelected = await settle { self.selectedSymbolIDs(state) == ["symbol-1-0", "symbol-1-1"] }
        XCTAssertTrue(groupSelected, "A group must select the current sheet's symbols")

        // Return to a cached sheet with an empty selection: its original
        // callbacks must not be reused for whichever page was last active.
        state.actions?.selectComponents?([])
        let cleared = await settle { self.selectedSymbolIDs(state).isEmpty }
        XCTAssertTrue(cleared)
        let secondFrame = renderer.presentedContentKey
        state.sheetIndex = 0
        let returned = await settle { renderer.presentedContentKey != secondFrame }
        XCTAssertTrue(returned)
        state.actions?.dispatch(.selectAll)
        let allSelected = await settle { self.selectedSymbolIDs(state) == ["symbol-0-0", "symbol-0-1"] }
        XCTAssertTrue(allSelected, "Select All and selection reporting must use the current page")
        XCTAssertEqual(state.selectedComponents, ["component-0-0", "component-0-1"])
    }

    private func selectedSymbolIDs(_ state: State) -> Set<String> {
        Set(state.details.groups.flatMap(\.items).filter { $0.ref.type == .schematicSymbol }.map(\.ref.id))
    }

    private func settle(until predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func renderer(in view: NSView) -> HorizontalMetalBackdropView.Renderer? {
        if let metal = view as? MTKView,
           let renderer = metal.delegate as? HorizontalMetalBackdropView.Renderer,
           renderer.loadProfileLabel == "Metal overlay" { return renderer }
        return view.subviews.lazy.compactMap { self.renderer(in: $0) }.first
    }

    private func mountCanvas() throws -> (State, NSWindow, NSView) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-selection-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try XCTUnwrap(HorizontalProject.load(from: root).schematic?.sheets.first)
        let sheets = (0..<2).map { index in
            var sheet = template
            sheet.id = "sheet-\(index)"
            sheet.name = "Sheet \(index + 1)"
            sheet.index = index + 1
            sheet.symbols = (0..<2).map { symbol in
                HorizontalPlacement(id: "symbol-\(index)-\(symbol)",
                                    position: HorizontalPoint(x: Double(symbol) * 5_000_000, y: 0),
                                    angle: 0, mirrored: false, label: "R\(index * 2 + symbol + 1)",
                                    componentID: "component-\(index)-\(symbol)")
            }
            return sheet
        }
        let state = State(sheets: sheets)
        let defaults = UserDefaults(suiteName: "sheet-selection-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        return (state, window, hosted)
    }
}
#endif
