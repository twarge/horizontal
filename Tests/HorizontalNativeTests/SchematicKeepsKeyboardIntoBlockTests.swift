#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The schematic pane keeps the keyboard when it turns to a block's sheet.
/// A block's schematic is another file, so the pane's canvas is taken down
/// and one for that file put up; while it was down the keyboard went to the
/// board beside it and stayed there. ⌘V on the block's sheet, of what was
/// copied on the top one, then went to the board, which had nothing to paste.
extension SchematicClipboardTests {
    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.schematic]
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

    @MainActor func testTheSchematicKeepsTheKeyboardWhenItTurnsToABlocksSheet() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let (fixture, channel) = try channelFixture()
        let top = try XCTUnwrap(fixture.project.schematics.first { $0.block.isTop })
        let root = fixture.project.url

        // The workspace opens a project with the panes it was left with, and
        // one never opened with the schematic and the board both: whichever
        // canvas is up first then has the keyboard, and on a slow machine
        // that is the board's. Left with the schematic alone, it opens so.
        var left = HorizontalFileViewState.default
        left.visiblePanes = [.schematic]
        HorizontalFileViewStateStore.shared.save(left, for: root, projectID: fixture.project.uuid)
        defer { UserDefaults.standard.removeObject(forKey: "fileViewState.v1.project.\(fixture.project.uuid.lowercased())") }

        let spot = Spot(fixture.archive)
        let defaults = UserDefaults(suiteName: "keyboard-into-block-\(UUID().uuidString)")!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let hosted = NSHostingView(rootView: Workspace(spot: spot, shared: spot.shared, project: fixture.project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            return predicate()
        }
        func live() -> HorizontalLiveDocument? {
            HorizontalDispatchSession.shared.openEntries
                .first { $0.live != nil && $0.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() }?
                .live
        }
        func width(_ pane: HorizontalPane) -> Double { live()?.visibleBounds(pane)?.width ?? 0 }
        /// The pane a zoom with no pane named zooms: the one with the keyboard.
        /// Asked once both panes hold still, so a canvas still being laid
        /// out and fitted is not taken for the one that zoomed.
        func paneWithTheKeyboard() async -> HorizontalPane? {
            var last = (schematic: -1.0, board: -1.0), still = 0
            _ = await settle {
                let now = (schematic: width(.schematic), board: width(.board))
                still = now == last ? still + 1 : 0
                last = now
                return still >= 5
            }
            let before = (schematic: width(.schematic), board: width(.board))
            live()?.zoomBy(nil, 2)
            let zoomed = await settle(timeout: 2) {
                abs(width(.schematic) - before.schematic) > 1 || abs(width(.board) - before.board) > 1
            }
            guard zoomed else { return nil }
            return abs(width(.schematic) - before.schematic) > 1 ? .schematic : .board
        }

        // The schematic alone first, so it is the pane with the keyboard;
        // then the board beside it.
        let schematicUp = await settle(timeout: 15) { width(.schematic) > 0 }
        XCTAssertTrue(schematicUp, "the schematic shows")
        XCTAssertEqual(spot.panes, [.schematic], "alone, as the project was left")
        spot.panes = [.schematic, .board]
        let boardUp = await settle(timeout: 15) { width(.schematic) > 0 && width(.board) > 0 }
        XCTAssertTrue(boardUp, "and the board beside it")
        let document = try XCTUnwrap(live())
        XCTAssertEqual(document.currentSheet(), top.schematic.sheets.first?.id)
        let before = await paneWithTheKeyboard()
        XCTAssertEqual(before, .schematic, "precondition: the schematic has the keyboard")

        let sheet = try XCTUnwrap(channel.schematic.sheets.first)
        document.showSheet(channel.block.uuid, sheet.id)
        let turned = await settle { document.currentSheet() == sheet.id }
        XCTAssertTrue(turned, "the schematic turns to the block's sheet")
        // The block's canvas goes up a view update or two later.
        try await Task.sleep(for: .milliseconds(600))
        let canvasUp = await settle { width(.schematic) > 0 }
        XCTAssertTrue(canvasUp, "the block's sheet shows")
        let after = await paneWithTheKeyboard()
        XCTAssertEqual(after, .schematic, "the schematic still has the keyboard on the block's sheet")

        // So ⌘V, sent as a key is, pastes the top sheet's text on the
        // block's, and Return puts it down. A text alone: it joins nothing
        // wherever the pointer happens to have it land.
        let text = try XCTUnwrap(fixture.sheet.texts.first)
        try HorizontalSchematicClipboardEditor.copy(
            [HorizontalSelectableRef(id: text.id, type: .text)], from: fixture.sheet, schematicURL: top.schematic.url,
            anchor: .zero, archive: fixture.archive, project: fixture.project
        ).writeToPasteboard()
        func monitors(in view: NSView) -> [TrackpadCanvasMonitor.MonitorView] {
            (view as? TrackpadCanvasMonitor.MonitorView).map { [$0] } ?? view.subviews.flatMap { monitors(in: $0) }
        }
        func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )))
        }
        func blockTexts() -> Int {
            live()?.currentProject().schematics.first { !$0.block.isTop }?.schematic.sheets.first?.texts.count ?? 0
        }
        let textsBefore = blockTexts()
        XCTAssertEqual(textsBefore, sheet.texts.count)
        try send("v", keyCode: 9, modifiers: .command)
        let placing = await settle { monitors(in: hosted).contains { $0.handlesInteractionKeys } }
        XCTAssertTrue(placing, "what was copied follows the cursor on the block's sheet")
        try send("\r", keyCode: 36)
        let pasted = await settle { blockTexts() == textsBefore + 1 }
        XCTAssertTrue(pasted, "and is the block's once put down")
        XCTAssertEqual(live()?.currentProject().schematics.first { $0.block.isTop }?.schematic.sheets.first?.texts.count,
                       fixture.sheet.texts.count, "the top sheet keeps only its own")
    }
}
#endif
