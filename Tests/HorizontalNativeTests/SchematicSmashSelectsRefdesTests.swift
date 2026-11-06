#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// H on a symbol smashed already selects its smashed refdes, as on the
/// board, where it did nothing, the symbol having nothing left to smash.
@MainActor
final class SchematicSmashSelectsRefdesTests: XCTestCase {
    @MainActor private final class State {
        let sheet: HorizontalSchematicSheet
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        var edits: [[JSONDictionary]] = []
        init(_ sheet: HorizontalSchematicSheet) { self.sheet = sheet }
    }

    private struct Canvas: View {
        var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(
                sheet: state.sheet, allSheets: [state.sheet],
                viewport: $viewport,
                onApplyProjectEdit: { operations, _ in state.edits.append(operations) },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 }
            )
        }
    }

    private let mm = 1_000_000.0

    private func text(_ id: String, _ drawn: String, stored: String, at x: Double) -> HorizontalText {
        HorizontalText(id: id, text: drawn, position: HorizontalPoint(x: x * mm, y: 3 * mm), size: 1.5 * mm, layer: nil,
                       fromSmash: true, placeholder: HorizontalTextPlaceholder(stored: stored, drawn: drawn))
    }

    /// R1, smashed, owning a refdes and a value text on the sheet; with
    /// `unsmashed`, R2 beside it, drawing its own.
    private func sheet(unsmashed: Bool) throws -> HorizontalSchematicSheet {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smash-refdes-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var sheet = try XCTUnwrap(HorizontalProject.load(from: root).schematic?.sheets.first)
        sheet.symbols = [HorizontalPlacement(id: "s1", position: .zero, angle: 0, mirrored: false, label: "R1",
                                             componentID: "c1", smashed: true, smashedTextIDs: ["t-rd", "t-val"])]
        if unsmashed {
            sheet.symbols.append(HorizontalPlacement(id: "s2", position: HorizontalPoint(x: 20 * mm, y: 0), angle: 0,
                                                     mirrored: false, label: "R2", componentID: "c2"))
        }
        sheet.texts = [text("t-rd", "R1", stored: "$REFDES", at: 0), text("t-val", "10k", stored: "$VALUE", at: 5)]
        return sheet
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

    private func selected(_ state: State) -> [String] {
        state.details.groups.flatMap { $0.items.map(\.ref.id) }.sorted()
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
        let all = await settle { Set(state.details.groups.map(\.type)) == [.schematicSymbol, .text] }
        XCTAssertTrue(all, "\(state.details.groups.map(\.type))")

        let handle = try XCTUnwrap(monitor(in: hosted)).makeEventHandler()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4))
        XCTAssertNil(handle(event), "the canvas takes H")
        return window
    }

    func testHOnASmashedSymbolSelectsItsRefdes() async throws {
        let state = State(try sheet(unsmashed: false))
        let window = try await pressHOnEverything(state)
        defer { window.close() }

        let refdes = await settle { self.selected(state) == ["t-rd"] }
        XCTAssertTrue(refdes, "the refdes alone, not the symbol or its value: \(selected(state))")
        XCTAssertEqual(state.edits.count, 0, "nothing changed")
    }

    /// Beside a symbol not smashed yet, H smashes that one alone, as before.
    func testHSmashesOnlyTheSymbolsNotSmashedYet() async throws {
        let state = State(try sheet(unsmashed: true))
        let window = try await pressHOnEverything(state)
        defer { window.close() }

        let edited = await settle { state.edits.count == 1 }
        XCTAssertTrue(edited)
        let operations = try XCTUnwrap(state.edits.first)
        XCTAssertEqual(operations.map { $0.string("op") }, ["smash"])
        XCTAssertEqual(operations.map { $0.string("symbol_instance") }, ["s2"])
    }
}
#endif
