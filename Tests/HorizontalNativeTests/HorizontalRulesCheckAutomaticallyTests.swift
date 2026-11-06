#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Automatically check rules: the setting, on unless turned off, and the
/// rules results sidebar's checkbox, Check Now and out-of-date note.
@MainActor
final class HorizontalRulesCheckAutomaticallyTests: XCTestCase {
    func testRulesAreCheckedAutomaticallyUntilTurnedOff() throws {
        let defaults = try freshDefaults()
        XCTAssertTrue(HorizontalRulesCheckDefaults.checksAutomatically(defaults: defaults), "on before anything is chosen")
        defaults.set(false, forKey: HorizontalRulesCheckDefaults.checksAutomaticallyKey)
        XCTAssertFalse(HorizontalRulesCheckDefaults.checksAutomatically(defaults: defaults))
        defaults.set(true, forKey: HorizontalRulesCheckDefaults.checksAutomaticallyKey)
        XCTAssertTrue(HorizontalRulesCheckDefaults.checksAutomatically(defaults: defaults))
    }

    private final class SidebarState: ObservableObject {
        @Published var checksAutomatically: Bool
        @Published var result: HorizontalBoardRulesResultState?
        var checks = 0
        var opened = 0
        init(checksAutomatically: Bool, result: HorizontalBoardRulesResultState?) {
            self.checksAutomatically = checksAutomatically
            self.result = result
        }
    }

    private struct Sidebar: View {
        @ObservedObject var state: SidebarState
        var body: some View {
            HorizontalRulesResultsSidebarView(
                result: state.result,
                safeAreaInsets: EdgeInsets(),
                checksAutomatically: $state.checksAutomatically,
                onCheckNow: { state.checks += 1 },
                onOpenRules: { state.opened += 1 }
            )
        }
    }

    /// The checkbox turns the setting off and back on; Check Now is there
    /// only while the checks wait to be asked, and runs them.
    func testTheCheckboxTurnsTheChecksOffAndCheckNowRunsThem() async throws {
        let state = SidebarState(checksAutomatically: true, result: result(isOutOfDate: false))
        let (window, hosted) = mount(Sidebar(state: state))
        defer { window.close() }

        let shown = await settle { self.controls(in: hosted).count == 2 }
        XCTAssertTrue(shown, "the checkbox and Open Rules…, and no Check Now: \(controls(in: hosted).count) controls")
        try click(controls(in: hosted)[0], in: window)
        let off = await settle { !state.checksAutomatically }
        XCTAssertTrue(off, "the checkbox turns the setting off")

        let offered = await settle { self.controls(in: hosted).count == 3 }
        XCTAssertTrue(offered, "Check Now beside Open Rules…: \(controls(in: hosted).count) controls")
        try click(try XCTUnwrap(controls(in: hosted).last), in: window)
        let checked = await settle { state.checks == 1 }
        XCTAssertTrue(checked, "Check Now runs the checks: \(state.checks) runs")
        XCTAssertEqual(state.opened, 0, "and opens no rules window")
        XCTAssertFalse(state.checksAutomatically, "and leaves the setting off")

        try click(controls(in: hosted)[0], in: window)
        let on = await settle { state.checksAutomatically }
        XCTAssertTrue(on, "the checkbox turns the setting back on")
        let gone = await settle { self.controls(in: hosted).count == 2 }
        XCTAssertTrue(gone, "Check Now goes: \(controls(in: hosted).count) controls")
    }

    /// Results found before the latest change say so, a row of their own;
    /// a fresh run's don't.
    func testResultsFoundBeforeTheLatestChangeSaySo() async throws {
        let state = SidebarState(checksAutomatically: false, result: result(isOutOfDate: true))
        let (window, hosted) = mount(Sidebar(state: state))
        defer { window.close() }
        let mounted = await settle { self.controls(in: hosted).count == 3 }
        XCTAssertTrue(mounted, "the checkbox, Open Rules… and Check Now")
        let table = try XCTUnwrap(tables(in: hosted).first)
        let outOfDateRows = table.numberOfRows

        state.result = result(isOutOfDate: false)
        let cleared = await settle { table.numberOfRows == outOfDateRows - 1 }
        XCTAssertTrue(cleared, "a fresh run drops the out-of-date row: \(table.numberOfRows) rows, from \(outOfDateRows)")
        state.result = result(isOutOfDate: true)
        let marked = await settle { table.numberOfRows == outOfDateRows }
        XCTAssertTrue(marked, "a change since brings it back: \(table.numberOfRows) rows")
    }

    private final class DocumentState: ObservableObject {
        @Published var document: HorizontalProjectDocument
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var state: DocumentState
        var project: HorizontalProject
        @State var panes: Set<HorizontalPane> = [.board]
        @State var nets = Set<String>()
        @State var highlightedNets = Set<String>()
        @State var components = Set<String>()
        @State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $state.document, visiblePanes: $panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }

    /// The document window with the setting off: nothing is checked on open
    /// or after an edit, Check Now checks, an edit since marks the results
    /// out of date and leaves them, and turning the setting on checks again.
    func testWithTheSettingOffTheWorkspaceChecksOnlyWhenAsked() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required for the canvas") }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-check-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = HorizontalDispatchSession()
        let entry = try disk.open(url: root)
        let seeded = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "apply", "params": [
            "handle": entry.handle, "expected_revision": entry.revision, "operation_id": "seed",
            "ops": [["op": "place_board_text", "text": "LABEL", "layer": HorizontalBoardLayers.topSilkscreen, "x_mm": 20, "y_mm": 20]]
        ]], in: disk)
        XCTAssertNil(seeded["error"], "\(seeded)")
        let text = try XCTUnwrap(try XCTUnwrap(seeded.dictionary("result")).dictionaryArray("changes").first?.string("id"))

        let project = try HorizontalProject.load(from: root)
        let viewStateKey = "fileViewState.v1.project.\(project.uuid.lowercased())"
        HorizontalFileViewStateStore.shared.save(HorizontalFileViewState(
            visiblePanes: [.board], showsNavigatorSidebar: false, showsSelectionSidebar: false,
            rightSidebarPane: .rulesResults, schematicDisplayOptions: SchematicDisplayOptions(),
            boardDisplayOptions: BoardDisplayOptions()), for: root, projectID: project.uuid)
        defer { UserDefaults.standard.removeObject(forKey: viewStateKey) }
        let defaults = try freshDefaults()
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        defaults.set(false, forKey: HorizontalRulesCheckDefaults.checksAutomaticallyKey)

        let state = DocumentState(try HorizontalProjectArchive.snapshot(from: root))
        let hosted = NSHostingView(rootView: Workspace(state: state, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults))
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        // The rules results sidebar: the list furthest right, its checkbox,
        // Open Rules… and Check Now under No checks run.
        var sidebar: NSTableView?
        let opened = await settle(timeout: 10) {
            sidebar = self.tables(in: hosted).max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            return sidebar.map { self.controls(in: $0).count == 3 } ?? false
        }
        XCTAssertTrue(opened, "the sidebar with Check Now: \(sidebar.map { controls(in: $0).count } ?? -1) controls")
        let list = try XCTUnwrap(sidebar)
        let unchecked = list.numberOfRows
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(list.numberOfRows, unchecked, "nothing is checked on open")

        try click(try XCTUnwrap(controls(in: list).last), in: window)
        let checked = await settle(timeout: 10) { list.numberOfRows > unchecked }
        XCTAssertTrue(checked, "Check Now checks: \(list.numberOfRows) rows, from \(unchecked)")
        // The board and schematic checks settle 400 ms after they start.
        try await Task.sleep(for: .seconds(2))
        let results = list.numberOfRows

        let live = try XCTUnwrap(HorizontalDispatchSession.shared.openEntries.first {
            $0.live != nil && $0.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath()
        })
        let moved = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "apply", "params": [
            "handle": live.handle, "expected_revision": live.revision, "operation_id": "move",
            "ops": [["op": "place_board_text", "id": text, "x_mm": 25, "y_mm": 20]]
        ]])
        XCTAssertNil(moved["error"], "\(moved)")
        let marked = await settle(timeout: 5) { list.numberOfRows == results + 1 }
        XCTAssertTrue(marked, "the edit adds the out-of-date row: \(list.numberOfRows) rows, from \(results)")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(list.numberOfRows, results + 1, "and nothing checks again on its own")

        // A finding's row has buttons of its own, so Check Now is the one
        // control fewer.
        let controlsWhileOff = controls(in: list).count
        defaults.set(true, forKey: HorizontalRulesCheckDefaults.checksAutomaticallyKey)
        let rechecked = await settle(timeout: 10) {
            list.numberOfRows == results && self.controls(in: list).count == controlsWhileOff - 1
        }
        XCTAssertTrue(rechecked, "turned on, the checks catch up and Check Now goes: \(list.numberOfRows) rows of \(results), "
                      + "\(controls(in: list).count) controls of \(controlsWhileOff)")
    }

    private func result(isOutOfDate: Bool) -> HorizontalBoardRulesResultState {
        var result = HorizontalBoardRulesResultState(ruleTitle: "Design Rules", messages: [],
                                                     clearanceFindings: [], boardFindings: [], schematicFindings: [])
        result.isOutOfDate = isOutOfDate
        return result
    }

    private func mount<Content: View>(_ content: Content) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (window, hosted)
    }

    /// The sidebar's buttons and checkboxes, top to bottom and left to
    /// right. SwiftUI draws them itself, with no NSButton and, until an
    /// assistive app asks, no accessibility elements; what AppKit has of each
    /// is the focus ring view it puts around a control.
    private func controls(in view: NSView) -> [NSView] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(view)
            .filter { String(describing: type(of: $0)).contains("FocusRing") }
            .map { (view: $0, frame: $0.convert($0.bounds, to: nil)) }
            .sorted { ($0.frame.midY.rounded(), -$0.frame.minX) > ($1.frame.midY.rounded(), -$1.frame.minX) }
            .map(\.view)
    }

    /// A click in the middle of `control`, as the mouse makes one. A push
    /// button tracks the mouse from its down until it takes the up off the
    /// event queue, so the up is queued first; a checkbox takes its down and
    /// leaves the up there, and nothing here runs the app's event loop to
    /// hand it on, so this does.
    private func click(_ control: NSView, in window: NSWindow) throws {
        let frame = control.convert(control.bounds, to: nil)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(up)
        }
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    private func settle(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "horizontal-rules-check-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
#endif
