#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The schematic and the board stay mounted once shown, so Tab between them
/// shows the other as it was left, its canvas, scenes, view and selection,
/// instead of building it again behind a loading spinner. Hidden, a kept pane
/// sits in the split at no width, past the window's edge.
@MainActor
final class WarmCanvasPanesTests: XCTestCase {
    @MainActor private final class Record: ObservableObject {
        @Published var shown: [HorizontalPane]
        var made = [HorizontalPane: Int]()
        var frames = [HorizontalPane: CGRect]()
        init(_ shown: [HorizontalPane]) {
            self.shown = shown
        }
    }

    /// Counts its own making: a `@StateObject` is made once each time its
    /// view is mounted.
    @MainActor private final class Made: ObservableObject {
        init(_ pane: HorizontalPane, in record: Record) {
            record.made[pane, default: 0] += 1
        }
    }

    private struct Pane: View {
        var pane: HorizontalPane
        var record: Record
        @StateObject private var made: Made

        init(pane: HorizontalPane, record: Record) {
            self.pane = pane
            self.record = record
            _made = StateObject(wrappedValue: Made(pane, in: record))
        }

        var body: some View {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.gray
                    .onAppear { record.frames[pane] = frame }
                    .onChange(of: frame) { _, frame in record.frames[pane] = frame }
            }
        }
    }

    private struct Split: View {
        @ObservedObject var record: Record
        var keeps: Set<HorizontalPane>
        @State private var fractions = [HorizontalPane: CGFloat]()

        var body: some View {
            ResizablePaneSplitView(panes: record.shown, sizeFractions: $fractions, keepsMounted: keeps) { pane, _ in
                Pane(pane: pane, record: record)
            }
        }
    }

    private final class DocumentState: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.schematic, .board]
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var state: DocumentState
        var project: HorizontalProject
        @State var nets = Set<String>()
        @State var highlightedNets = Set<String>()
        @State var components = Set<String>()
        @State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $state.document, visiblePanes: $state.panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }

    private func window(showing view: some View, width: CGFloat = 800, height: CGFloat = 600) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (window, hosted)
    }

    private func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func width(_ pane: HorizontalPane, _ record: Record) -> CGFloat {
        record.frames[pane]?.width ?? -1
    }

    func testAKeptPaneHiddenStaysMountedAtNoWidthPastTheWindow() async throws {
        let record = Record([.schematic])
        let (window, _) = window(showing: Split(record: record, keeps: [.schematic, .board]))
        defer { window.close() }
        let shown = await settle { self.width(.schematic, record) > 0 }
        XCTAssertTrue(shown)

        // Tab with one pane open: the other takes its place.
        record.shown = [.board]
        let swapped = await settle { self.width(.board, record) > 0 && self.width(.schematic, record) == 0 }
        XCTAssertTrue(swapped, "\(record.frames)")
        XCTAssertGreaterThanOrEqual(record.frames[.schematic]?.minX ?? 0, 800, "A hidden pane is past the window's edge")
        XCTAssertEqual(record.frames[.board]?.width ?? 0, 800, accuracy: 1, "A hidden pane takes nothing from the shown one")

        record.shown = [.schematic]
        let back = await settle { self.width(.schematic, record) > 0 && self.width(.board, record) == 0 }
        XCTAssertTrue(back, "\(record.frames)")
        // Both open, then the schematic hidden from its pane button.
        record.shown = [.schematic, .board]
        let both = await settle { self.width(.schematic, record) > 0 && self.width(.board, record) > 0 }
        XCTAssertTrue(both, "\(record.frames)")
        record.shown = [.board]
        let alone = await settle { self.width(.schematic, record) == 0 }
        XCTAssertTrue(alone, "\(record.frames)")
        XCTAssertEqual(record.made, [.schematic: 1, .board: 1], "Neither pane is made again")
    }

    func testAPaneNotKeptIsMadeAgainWhenShownAgain() async throws {
        let record = Record([.schematic])
        let (window, _) = window(showing: Split(record: record, keeps: [.board]))
        defer { window.close() }
        let shown = await settle { self.width(.schematic, record) > 0 }
        XCTAssertTrue(shown)
        record.shown = [.board]
        let swapped = await settle { self.width(.board, record) > 0 }
        XCTAssertTrue(swapped)
        record.shown = [.schematic]
        let back = await settle { record.made[.schematic] == 2 }
        XCTAssertTrue(back, "\(record.made)")
        XCTAssertEqual(record.made[.board], 1, "The kept one is still the one made first")
    }

    private func monitors(in view: NSView) -> [TrackpadCanvasMonitor.MonitorView] {
        var found = [TrackpadCanvasMonitor.MonitorView]()
        if let monitor = view as? TrackpadCanvasMonitor.MonitorView {
            found.append(monitor)
        }
        return found + view.subviews.flatMap { monitors(in: $0) }
    }

    private func tab(_ monitor: TrackpadCanvasMonitor.MonitorView, in window: NSWindow) throws -> Bool {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        return monitor.makeEventHandler()(event) == nil
    }

    /// The real workspace, schematic alone: Tab shows the board in its place
    /// and Tab there the schematic again, both times the same canvases, the
    /// hidden one still in the window at no width.
    func testTabBetweenTheSchematicAndTheBoardKeepsBothCanvases() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warm-panes-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = DocumentState(try HorizontalProjectArchive.snapshot(from: root))
        let project = try HorizontalProject.load(from: root)
        let defaults = UserDefaults(suiteName: "warm-panes-\(UUID().uuidString)")!
        let (window, hosted) = window(
            showing: Workspace(state: state, project: project)
                .environmentObject(HorizontalAppearanceSettings(defaults: defaults)),
            width: 1200, height: 700
        )
        defer { window.close() }

        let mounted = await settle(timeout: 10) { self.monitors(in: hosted).filter { $0.bounds.width > 0 }.count == 2 }
        XCTAssertTrue(mounted, "Both canvases come up")
        guard mounted else { return }
        // Left to right, as the panes are laid out.
        let canvases = monitors(in: hosted).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let schematic = canvases[0]
        let board = canvases[1]

        state.panes = [.schematic]
        let alone = await settle { board.bounds.width == 0 && schematic.bounds.width > 0 && schematic.hasKeyboardFocus }
        XCTAssertTrue(alone, "Hidden from its pane button, the board stays, at no width")

        XCTAssertTrue(try tab(schematic, in: window))
        let onBoard = await settle { board.bounds.width > 0 && schematic.bounds.width == 0 }
        XCTAssertTrue(onBoard, "Tab shows the board in the schematic's place")
        XCTAssertEqual(state.panes, [.board])
        XCTAssertNotNil(schematic.window, "The schematic's canvas stays mounted")
        XCTAssertFalse(try tab(schematic, in: window), "The hidden canvas takes no keys")

        let focused = await settle { board.hasKeyboardFocus }
        XCTAssertTrue(focused)
        XCTAssertTrue(try tab(board, in: window))
        let onSchematic = await settle { schematic.bounds.width > 0 && board.bounds.width == 0 }
        XCTAssertTrue(onSchematic, "Tab shows the schematic again")
        XCTAssertEqual(state.panes, [.schematic])
        XCTAssertNotNil(board.window, "The board's canvas stays mounted")
        XCTAssertEqual(monitors(in: hosted).map(ObjectIdentifier.init).sorted(),
                       [schematic, board].map(ObjectIdentifier.init).sorted(),
                       "No canvas was made again")
    }
}
#endif
