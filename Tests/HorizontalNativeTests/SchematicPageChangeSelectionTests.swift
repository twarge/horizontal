#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A schematic page change drops the schematic's own selection, which is of
/// the objects on the page it leaves, and nothing else. A selection the board
/// made, or one made outside both canvases, is still selected where it was
/// made: it stays the workspace's, boxed in blue on the page turned to and
/// what Spotlight spotlights. It used to go with every page change.
@MainActor
final class SchematicPageChangeSelectionTests: XCTestCase {
    func testOnlyASelectionTheSchematicMadeGoesWithItsPage() {
        let window = UUID()
        XCTAssertTrue(HorizontalSelectionOrigin(pane: .schematic, window: window).goesWithSchematicPage(in: window))
        XCTAssertFalse(HorizontalSelectionOrigin(pane: .board, window: window).goesWithSchematicPage(in: window),
                       "the board's is still selected on the board")
        XCTAssertFalse(HorizontalSelectionOrigin(pane: nil, window: window).goesWithSchematicPage(in: window),
                       "as is one from the 3D view, Find, the Parts pane or the live channel")
        XCTAssertFalse(HorizontalSelectionOrigin(pane: .schematic, window: UUID()).goesWithSchematicPage(in: window),
                       "and one another window's schematic made")
        XCTAssertTrue(HorizontalSelectionOrigin(pane: .schematic).goesWithSchematicPage(), "one window, as on the iPad")
        XCTAssertFalse(HorizontalSelectionOrigin(pane: .board).goesWithSchematicPage())
    }

    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.schematic, .board]
        let shared = HorizontalSharedProject()
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var spot: Spot
        @ObservedObject var shared: HorizontalSharedProject
        var project: HorizontalProject
        var body: some View {
            ProjectWorkspaceView(project: project, document: $spot.document, visiblePanes: $spot.panes,
                                 selectedNetIDs: $shared.selectedNetIDs, highlightedNetIDs: $shared.highlightedNetIDs,
                                 selectedComponentIDs: $shared.selectedComponentIDs,
                                 highlightedComponentIDs: $shared.highlightedComponentIDs,
                                 sharedProject: shared)
        }
    }

    private func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The starter project with a second sheet, the schematic and the board
    /// showing. A selection and a spotlight made over the live channel, as
    /// one made in the 3D view or by Find is, are still there after the
    /// schematic turns to the second sheet and back.
    func testASelectionMadeOutsideTheSchematicStaysThroughAPageChange() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-selection-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let starter = try HorizontalProject.load(from: root)
        let edited = try HorizontalCanvasProjectEdit.archive(
            applying: [["op": "add_sheet", "name": "Two"]],
            to: try HorizontalProjectArchive.snapshot(from: root), in: starter, block: nil
        ).archive
        var project = try HorizontalProject.loadSnapshot(of: edited)
        project.rebaseURLs(onto: starter)
        let schematic = try XCTUnwrap(project.schematics.first)
        let sheets = schematic.schematic.sheets.sorted { $0.index < $1.index }
        XCTAssertEqual(sheets.count, 2, "precondition: two pages to turn between")

        let spot = Spot(edited)
        let defaults = UserDefaults(suiteName: "page-selection-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: Workspace(spot: spot, shared: spot.shared, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        func live() -> HorizontalLiveDocument? {
            HorizontalDispatchSession.shared.openEntries
                .first { $0.live != nil && $0.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() }?
                .live
        }
        let up = await settle(timeout: 15) {
            (live()?.visibleBounds(.schematic)?.width ?? 0) > 0 && (live()?.visibleBounds(.board)?.width ?? 0) > 0
        }
        XCTAssertTrue(up, "the schematic and the board show")
        let document = try XCTUnwrap(live())
        XCTAssertEqual(document.currentSheet(), sheets[0].id)

        document.setSelection(["net-1"], ["part-1"])
        document.setHighlight(["net-1"], ["part-1"])
        XCTAssertEqual(spot.shared.selectedComponentIDs, ["part-1"])
        XCTAssertEqual(spot.shared.selectedNetIDs, ["net-1"])

        for sheet in [sheets[1], sheets[0]] {
            document.showSheet(schematic.block.uuid, sheet.id)
            let turned = await settle { document.currentSheet() == sheet.id }
            XCTAssertTrue(turned, "the schematic turns to \(sheet.name)")
            // The canvas takes the page a view update or two later.
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(spot.shared.selectedComponentIDs, ["part-1"], "the selection stays, on \(sheet.name)")
            XCTAssertEqual(spot.shared.selectedNetIDs, ["net-1"])
            XCTAssertEqual(spot.shared.highlightedNetIDs, ["net-1"], "and the spotlight")
            XCTAssertEqual(spot.shared.highlightedComponentIDs, ["part-1"])
        }
    }
}
#endif
