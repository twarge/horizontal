#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A net's class set in the board inspector reaches the schematic canvas.
/// That canvas edits a copy of its sheet, nets and all, and writes the copy's
/// nets to the block with every edit. So the host hands it the sheet again
/// (`syncRevision`) when the board puts a net in another class: its inspector
/// shows the class, and its next edit writes that class, not the one its copy
/// had. Left with the copy, the next edit on the sheet put the old class back
/// in the block, and the board followed it, with the old class's widths.
@MainActor
final class SchematicTakesANetClassSetOnTheBoardTests: XCTestCase {
    private static let fast = "aaaaaaaa-0000-4000-8000-000000000001"

    @MainActor private final class State: ObservableObject {
        @Published var project: HorizontalProject
        @Published var revision = 0
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var archive: HorizontalProjectArchive
        var published: [HorizontalSchematicSheet] = []
        var details = HorizontalSelectionDetailState.empty
        var actions: HorizontalCanvasCommandActions?
        var sheet: HorizontalSchematicSheet { project.schematic!.sheets[0] }

        init(project: HorizontalProject, archive: HorizontalProjectArchive) {
            self.project = project
            self.archive = archive
        }

        /// As the workspace takes a sheet a canvas edited: into the project.
        func take(_ sheet: HorizontalSchematicSheet) {
            published.append(sheet)
            project.schematic?.sheets[0] = sheet
        }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(
                sheet: state.sheet, allSheets: [state.sheet],
                viewport: $viewport,
                onSheetChange: { state.take($0) },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                syncRevision: state.revision
            )
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// A new project with a second class, Fast, and its GND net labelled on
    /// the sheet.
    private func fixture() throws -> (state: State, gndKey: String, defaultClass: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("schematic-takes-a-net-class-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Test.horizontal")

        var template = HorizontalProjectArchive.newProject()
        let data = try XCTUnwrap(template.regularFileData(relativePath: "top_block.json"))
        var block = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        var classes = try XCTUnwrap(block["net_classes"] as? JSONDictionary)
        let defaultClass = try XCTUnwrap(classes.keys.first).lowercased()
        classes[Self.fast] = ["name": "Fast"] as JSONDictionary
        block["net_classes"] = classes
        let gndKey = try XCTUnwrap((block["nets"] as? JSONDictionary)?.keys.first)
        try template.replaceRegularFileData(
            relativePath: "top_block.json", with: JSONSerialization.data(withJSONObject: block, options: [.sortedKeys]))
        try template.write(to: url)

        let labelled = try HorizontalCanvasProjectEdit.archive(
            applying: [["op": "place_net_label", "net": "GND", "x_mm": 50, "y_mm": 50]],
            to: try HorizontalProjectArchive.completeProject(from: url), in: try HorizontalProject.load(from: url))
        try labelled.archive.write(to: url)
        let state = State(project: try HorizontalProject.load(from: url),
                          archive: try HorizontalProjectArchive.completeProject(from: url))
        return (state, gndKey, defaultClass)
    }

    /// The class the inspector shows for the selected label's net.
    private func shownClass(_ details: HorizontalSelectionDetailState) -> String? {
        let property = details.groups.first { $0.type == .netLabel }?.items.first?.properties.first { $0.id == "netClass" }
        guard case .choice(let id) = property?.value else { return nil }
        return id
    }

    private func blockClass(of netKey: String, in archive: HorizontalProjectArchive) throws -> String? {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "top_block.json"))
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? JSONDictionary)
        return ((block["nets"] as? JSONDictionary)?[netKey] as? JSONDictionary)?["net_class"] as? String
    }

    func testACanvasEditingItsSheetShowsAndWritesAClassSetOnTheBoard() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let (state, gndKey, defaultClass) = try fixture()
        let gnd = gndKey.lowercased()
        let label = try XCTUnwrap(state.sheet.netLabels.first)
        let ref = HorizontalSelectableRef(id: label.id, type: .netLabel)
        func resize(_ size: Double) {
            state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
                ref: ref, type: .netLabel, propertyID: "size", value: .length(size), applyToAll: false))
        }

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
        let selected = await settle { self.shownClass(state.details) == defaultClass }
        XCTAssertTrue(selected, "the label selected, its net in the Default class")

        // An edit on the sheet: from here the canvas has a copy of its own.
        resize(2_000_000)
        let edited = await settle { state.published.count == 1 }
        XCTAssertTrue(edited)
        XCTAssertEqual(state.published.last?.netDetails[gnd]?.netClassID, defaultClass)

        // The board inspector puts GND in Fast, as the workspace takes it:
        // the block and every copy of the net, and the sheet handed over again.
        try state.project.putNet(gnd, inClass: Self.fast, archive: &state.archive)
        state.revision += 1
        let shown = await settle { self.shownClass(state.details) == Self.fast }
        XCTAssertTrue(shown, "the schematic inspector shows Fast: \(shownClass(state.details) ?? "nothing")")

        // The next edit on the sheet writes its nets to the block, as every
        // sheet edit does: Fast, with the edit made before it kept.
        resize(2_500_000)
        let editedAgain = await settle { state.published.count == 2 }
        XCTAssertTrue(editedAgain)
        let sheet = try XCTUnwrap(state.published.last)
        XCTAssertEqual(sheet.netDetails[gnd]?.netClassID, Self.fast)
        XCTAssertEqual(sheet.netDetails[gnd]?.netClassName, "Fast")
        XCTAssertEqual(sheet.netLabels.first?.size, 2_500_000)
        try HorizontalProjectJSONApplicator.apply(
            schematicSheet: sheet, schematicURL: try XCTUnwrap(state.project.schematic).url, in: state.project, to: &state.archive)
        XCTAssertEqual(try blockClass(of: gndKey, in: state.archive), Self.fast, "the block keeps the class the board gave")
    }
}
#endif
