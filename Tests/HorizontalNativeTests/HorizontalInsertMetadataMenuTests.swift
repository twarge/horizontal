#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A text field for a board or sheet text has Insert Metadata ▸ in its
/// right-click menu, after the field editor's own items: each title-block key
/// as `$key` with its value beneath, inserting `$key` at the cursor. The
/// inspector shows the text as stored, and what is typed there draws resolved.
@MainActor
final class HorizontalInsertMetadataMenuTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var marked = "Rev "
        @Published var plain = "Plain"
        @Published var inline = "Sheet "
    }

    private struct Fields: View {
        @ObservedObject var model: Model
        var items: [HorizontalTextVariableItem]
        var body: some View {
            VStack(spacing: 20) {
                TextField("", text: $model.marked)
                    .textFieldStyle(.roundedBorder)
                    .insertMetadataMenu(items)
                TextField("", text: $model.plain)
                    .textFieldStyle(.roundedBorder)
                BoardInlineTextEditorField(text: $model.inline, textVariables: items, onSubmit: {})
            }
            .frame(width: 320)
            .padding(20)
        }
    }

    private let items = [
        HorizontalTextVariableItem(key: "rev", title: "Revision", value: "2A"),
        HorizontalTextVariableItem(key: "author", title: "Author", value: ""),
    ]

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
    }

    private func rightClick(atTheEndOf field: NSTextField, in window: NSWindow) throws -> NSEvent {
        let frame = field.convert(field.bounds, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: frame.maxX - 4, y: frame.midY), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func mount(_ model: Model) async throws -> (NSWindow, [NSTextField]) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Fields(model: model, items: items))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { textFields(in: hosted).count == 3 }
        XCTAssertTrue(mounted)
        let fields = textFields(in: hosted).sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        return (window, fields)
    }

    private func insertItem(_ code: String, in menu: NSMenu) throws -> NSMenuItem {
        let submenu = try XCTUnwrap(menu.items.last?.submenu)
        return try XCTUnwrap(submenu.items.first { $0.title == code })
    }

    func testAMarkedFieldsMenuEndsWithInsertMetadata() async throws {
        let model = Model()
        let (window, fields) = try await mount(model)
        defer { window.close() }

        let (menu, editor) = try XCTUnwrap(HorizontalInsertMetadataMenu.shared.contextMenu(
            for: try rightClick(atTheEndOf: fields[0], in: window)))
        XCTAssertTrue(menu.items.contains { $0.title == "Paste" }, "the field editor's own items stay: \(menu.items.map(\.title))")
        XCTAssertEqual(menu.items.last?.title, "Insert Metadata")
        let submenu = try XCTUnwrap(menu.items.last?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["$rev", "$author"])
        XCTAssertEqual(submenu.items.map(\.subtitle), ["2A", "No value"], "each key with its value in this design")
        XCTAssertTrue(editor.delegate === fields[0], "the click began editing the field")

        let item = try insertItem("$rev", in: menu)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let inserted = await settle { model.marked == "Rev $rev" }
        XCTAssertTrue(inserted, "inserted where the click put the cursor, at the end: \(model.marked)")
    }

    func testAFieldWithoutTheModifierKeepsItsClick() async throws {
        let model = Model()
        let (window, fields) = try await mount(model)
        defer { window.close() }

        XCTAssertNil(HorizontalInsertMetadataMenu.shared.contextMenu(for: try rightClick(atTheEndOf: fields[1], in: window)))
    }

    /// The canvas's inline text editor, a field that grows over lines.
    func testTheInlineTextEditorHasTheMenuToo() async throws {
        let model = Model()
        let (window, fields) = try await mount(model)
        defer { window.close() }

        let (menu, _) = try XCTUnwrap(HorizontalInsertMetadataMenu.shared.contextMenu(
            for: try rightClick(atTheEndOf: fields[2], in: window)))
        let item = try insertItem("$author", in: menu)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        let inserted = await settle { model.inline == "Sheet $author" }
        XCTAssertTrue(inserted, model.inline)
    }
}

/// The board's and the schematic's text inspectors: the Text field shows the
/// stored form and offers the design's keys, and a value typed into it draws
/// resolved at once, keeping what was typed for the file.
@MainActor
final class HorizontalTextInspectorVariablesTests: XCTestCase {
    @MainActor private final class BoardState: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct BoardCanvas: View {
        @ObservedObject var state: BoardState
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: BoardState) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                toolSettings: state.toolSettings)
        }
    }

    @MainActor private final class SheetState: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        let sheet: HorizontalSchematicSheet
        var committed: [HorizontalSchematicSheet] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        init(_ sheet: HorizontalSchematicSheet) { self.sheet = sheet }
    }

    private struct SheetCanvas: View {
        @ObservedObject var state: SheetState
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(
                sheet: state.sheet, allSheets: [state.sheet],
                viewport: $viewport,
                onSheetChange: { state.committed.append($0) },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change
            )
        }
    }

    private let mm = 1_000_000.0
    private let variables = HorizontalTextVariables.project(["project_title": "Board A", "rev": "2A"])

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func window(hosting view: some View) -> NSWindow {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: view
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return window
    }

    private func textProperty(_ details: HorizontalSelectionDetailState) -> HorizontalSelectionProperty? {
        details.groups.first { $0.type == .text }?.items.first?.properties.first { $0.id == "text" }
    }

    private func text(drawn: String, stored: String) -> HorizontalText {
        HorizontalText(id: "t", text: drawn, position: HorizontalPoint(x: 10 * mm, y: 10 * mm), size: 1.5 * mm, layer: 20,
                       placeholder: HorizontalTextPlaceholder(stored: stored, drawn: drawn))
    }

    func testTheBoardInspectorShowsTheStoredTextAndDrawsAnEditResolved() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = HorizontalGerberExportFixture.board(texts: [text(drawn: "Rev 2A", stored: "Rev $rev")])
        board.textVariables = variables
        let state = BoardState(board)
        let window = window(hosting: BoardCanvas(state: state))
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { self.textProperty(state.details) != nil }
        XCTAssertTrue(selected)
        let property = try XCTUnwrap(textProperty(state.details))
        XCTAssertEqual(property.value, .text("Rev $rev"), "what the file stores, not what it draws")
        XCTAssertEqual(property.textVariables.first { $0.key == "project_title" }?.value, "Board A")

        state.undo.beginUndoGrouping()
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: HorizontalSelectableRef(id: "t", type: .text, layer: 20), type: .text, propertyID: "text",
            value: .text("$project_title $rev"), applyToAll: false))
        let committed = await settle { state.committed.last?.texts.first?.text == "Board A 2A" }
        state.undo.endUndoGrouping()
        XCTAssertTrue(committed, "drawn resolved as it is committed: \(state.committed.last?.texts.first?.text ?? "nothing")")
        XCTAssertEqual(state.committed.last?.texts.first?.fileText, "$project_title $rev")
    }

    func testTheSchematicInspectorShowsTheStoredTextAndDrawsAnEditResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-inspector-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var sheet = try XCTUnwrap(HorizontalProject.load(from: root).schematic?.sheets.first)
        var sheetText = text(drawn: "Rev 2A", stored: "Rev $rev")
        sheetText.layer = nil
        sheet.texts = [sheetText]
        sheet.textVariables = variables
        let state = SheetState(sheet)
        let window = window(hosting: SheetCanvas(state: state))
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)

        state.actions?.dispatch(.selectAll)
        let selected = await settle { self.textProperty(state.details) != nil }
        XCTAssertTrue(selected)
        let property = try XCTUnwrap(textProperty(state.details))
        XCTAssertEqual(property.value, .text("Rev $rev"))
        XCTAssertEqual(property.textVariables.first { $0.key == "rev" }?.value, "2A")

        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: HorizontalSelectableRef(id: "t", type: .text), type: .text, propertyID: "text",
            value: .text("$project_title"), applyToAll: false))
        let committed = await settle { state.committed.last?.texts.first?.text == "Board A" }
        XCTAssertTrue(committed, "\(state.committed.last?.texts.first?.text ?? "nothing")")
        XCTAssertEqual(state.committed.last?.texts.first?.fileText, "$project_title")
    }
}
#endif
