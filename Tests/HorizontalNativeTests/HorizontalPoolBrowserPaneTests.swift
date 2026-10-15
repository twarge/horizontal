#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The Pools pane mounted in a window, on a small pool of three resistors and
/// a capacitor: what its list shows with components selected (126), what the
/// parametric section grows (127), and the arrows walking the list while a
/// canvas holds the keyboard focus (128). The pane's toolbar draws no AppKit
/// controls a test can find, so Place and Replace are checked through the
/// rules their buttons follow.
@MainActor
final class HorizontalPoolBrowserPaneTests: XCTestCase {
    private var poolURL: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        poolURL = FileManager.default.temporaryDirectory.appendingPathComponent("pools-pane-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "HorizontalPoolBrowserPaneTests-\(UUID().uuidString)")
        // A debug build edits only once read-only operation is turned off;
        // with it on, a row's Return would open the item's editor.
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        HorizontalPoolLibrary.invalidateCache()
        try write(["type": "pool", "uuid": UUID().uuidString.lowercased(), "name": "Pane Pool"], to: "pool.json")
        try write(["tables": ["resistors": ["display_name": "Resistors", "columns": [
            ["name": "value", "display_name": "Value", "type": "quantity", "unit": "Ω", "use_si": true, "digits": 2],
        ]] as JSONDictionary] as JSONDictionary], to: "tables.json")
        try write(["type": "entity", "uuid": "e-res", "name": "Resistor", "prefix": "R", "gates": [String: Any]()], to: "entities/r.json")
        try write(["type": "entity", "uuid": "e-cap", "name": "Capacitor", "prefix": "C", "gates": [String: Any]()], to: "entities/c.json")
        for (index, value) in ["1000", "4700", "10000"].enumerated() {
            try write(["type": "part", "uuid": "p-r\(index)", "MPN": [false, "RES-\(value)"], "manufacturer": [false, "Yageo"],
                       "entity": "e-res", "package": "pkg", "parametric": ["table": "resistors", "value": value]],
                      to: "parts/r\(index).json")
        }
        try write(["type": "part", "uuid": "p-c", "MPN": [false, "CAP-100N"], "entity": "e-cap", "package": "pkg"], to: "parts/c.json")
    }

    override func tearDownWithError() throws {
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: poolURL)
    }

    private func write(_ json: JSONDictionary, to path: String) throws {
        let url = poolURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    /// R1, on the first resistor.
    private var replacement: HorizontalPartReplacement {
        HorizontalPartReplacement(
            componentIDs: ["c1"],
            block: ["components": ["c1": ["refdes": "R1", "entity": "e-res", "part": "p-r0"] as JSONDictionary] as JSONDictionary]
        )!
    }

    private final class Calls {
        var placed = [String]()
        var replaced = [String]()
    }

    private func actions(_ calls: Calls, replacement: HorizontalPartReplacement?) -> HorizontalPoolPartActions {
        HorizontalPoolPartActions(
            place: { calls.placed.append($0.uuid) }, placeUnavailableReason: nil, replacement: replacement,
            replace: { item, _, _ in calls.replaced.append(item.uuid) }
        )
    }

    /// The pane in a window, beside a canvas's event monitor holding the
    /// keyboard focus, as the schematic's does in a project window.
    private func mount(_ actions: HorizontalPoolPartActions?, showingFilters: Bool = false)
        -> (window: NSWindow, canvas: TrackpadCanvasMonitor.MonitorView) {
        _ = NSApplication.shared
        defaults.set(showingFilters, forKey: "poolBrowser.showsParametricFilters")
        let view = HorizontalPoolBrowserView(root: .pool(poolURL), partActions: actions)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults))
            .defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        let canvas = TrackpadCanvasMonitor.MonitorView(frame: NSRect(x: 0, y: 0, width: 200, height: 700))
        let hosted = NSHostingView(rootView: view)
        hosted.frame = NSRect(x: 200, y: 0, width: 1100, height: 700)
        container.addSubview(canvas)
        container.addSubview(hosted)
        window.contentView = container
        window.orderFront(nil)
        canvas.hasKeyboardFocus = true
        return (window, canvas)
    }

    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }

    /// The pane's list: the table whose first column is the name.
    private func list(in window: NSWindow, columns first: String, rows: Int) async throws -> NSTableView {
        let content = try XCTUnwrap(window.contentView)
        let deadline = Date().addingTimeInterval(5)
        var found: NSTableView?
        repeat {
            try await Task.sleep(for: .milliseconds(40))
            found = tables(in: content).first {
                $0.tableColumns.first?.title == first && $0.numberOfRows == rows
            }
        } while found == nil && Date() < deadline
        let seen = tables(in: content).map { ($0.tableColumns.map(\.title), $0.numberOfRows) }
        return try XCTUnwrap(found, "a list headed \(first) with \(rows) rows: \(seen)")
    }

    func testWithComponentsSelectedTheListShowsTheirPartsWithTheCurrentOneSelected() async throws {
        let (all, _) = mount(actions(Calls(), replacement: nil))
        defer { all.close() }
        _ = try await list(in: all, columns: "Name", rows: 4)

        let (window, _) = mount(actions(Calls(), replacement: replacement))
        defer { window.close() }
        let table = try await list(in: window, columns: "Name", rows: 3)
        XCTAssertEqual(table.selectedRow, 0, "R1's own part, RES-1000, first by name")
    }

    /// With the section open, Replace opens on the table R1's part is in:
    /// the list grows a column per value, and the section a filter box for
    /// the values left (one manufacturer and one package, so no box for them).
    func testTheParametricSectionGrowsTheTablesFiltersAndColumns() async throws {
        let (window, _) = mount(actions(Calls(), replacement: replacement), showingFilters: true)
        defer { window.close() }
        let table = try await list(in: window, columns: "MPN", rows: 3)
        XCTAssertEqual(table.tableColumns.map(\.title), ["MPN", "Manufacturer", "Package", "Value", "Pool"])
        XCTAssertEqual(table.selectedRow, 0)
        let boxes = tables(in: try XCTUnwrap(window.contentView)).filter { $0 !== table }
        XCTAssertEqual(boxes.map(\.numberOfRows), [3], "the Value box")

        // Closed, with no table chosen, the list is the plain one and no
        // filter box shows.
        let (collapsed, _) = mount(actions(Calls(), replacement: nil), showingFilters: false)
        defer { collapsed.close() }
        let plain = try await list(in: collapsed, columns: "Name", rows: 4)
        XCTAssertEqual(tables(in: try XCTUnwrap(collapsed.contentView)).filter { $0 !== plain }.count, 0)
    }

    /// 128: with a canvas holding the keyboard focus, the list takes the
    /// arrows once it has the keyboard.
    func testTheArrowsWalkTheListWhileACanvasHoldsTheKeyboardFocus() async throws {
        let (window, canvas) = mount(actions(Calls(), replacement: nil))
        defer { window.close() }
        let table = try await list(in: window, columns: "Name", rows: 4)
        var nudges = 0
        canvas.onMoveSelectionByGrid = { _, _ in nudges += 1 }
        XCTAssertTrue(window.makeFirstResponder(table))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: 125))
        for row in 1...2 {
            XCTAssertNotNil(canvas.makeEventHandler()(down), "the canvas's monitor passes the arrow on")
            window.sendEvent(down)
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(table.selectedRow, row)
        }
        XCTAssertEqual(nudges, 0)
    }

    /// Down in the search field takes the keyboard into the list, its first
    /// row selected, so the arrows carry on through it.
    func testDownFromTheSearchGoesIntoTheList() async throws {
        let (window, _) = mount(actions(Calls(), replacement: nil))
        defer { window.close() }
        let table = try await list(in: window, columns: "Name", rows: 4)
        func field(_ view: NSView) -> NSTextField? {
            (view as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? view.subviews.lazy.compactMap(field).first
        }
        let search = try XCTUnwrap(field(try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertTrue(window.firstResponder is NSTextView, "the search is being typed in")
        let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
            isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        let deadline = Date().addingTimeInterval(2)
        while !(window.firstResponder === table), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(window.firstResponder === table, "the list has the keyboard: \(String(describing: window.firstResponder))")
        XCTAssertEqual(table.selectedRow, 0)
    }

    /// The Parts pane's Return places its part only while the keyboard is
    /// in that pane. Its Place button's shortcut was window-wide, and with
    /// 128 the canvas no longer swallows a Return the Pools list has, so
    /// Return in the Pools list placed the Parts pane's selected part.
    func testReturnInThePoolsListLeavesThePartsPanesPlaceAlone() async throws {
        _ = NSApplication.shared
        let calls = Calls()
        var partsPlaced = [String]()
        let part = HorizontalPoolPart(
            id: "pp-1", mpn: "PARTS-PANE-PART", manufacturer: "Yageo", partDescription: "", packageName: "R0603", tags: [],
            value: "", displayValue: "PARTS-PANE-PART", entityID: "e-res", refdesPrefix: "R",
            gates: [HorizontalPoolPartGate(id: "g", suffix: "", unitID: "u", symbolID: "s")])
        let parts = HorizontalPartBrowserView(parts: [part], onPlacePart: { partsPlaced.append($0.id) })
        let pools = HorizontalPoolBrowserView(root: .pool(poolURL), partActions: actions(calls, replacement: nil))
        let view = HStack(spacing: 0) {
            parts.frame(width: 1100)
            pools.frame(width: 1100)
        }
        .environmentObject(HorizontalAppearanceSettings(defaults: defaults))
        .defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2200, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosted = NSHostingView(rootView: view)
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        let partsTable = try await list(in: window, columns: "MPN", rows: 1)
        let poolsTable = try await list(in: window, columns: "Name", rows: 4)
        partsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        poolsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        // A key equivalent is tried before the first responder gets the key,
        // as the window does it.
        func pressReturn() async throws {
            if !window.performKeyEquivalent(with: enter) {
                window.sendEvent(enter)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTAssertTrue(window.makeFirstResponder(poolsTable))
        try await pressReturn()
        XCTAssertEqual(partsPlaced, [], "Return in the Pools list is the Pools list's")
        XCTAssertEqual(calls.placed, ["p-c"], "it places the Pools list's own part, CAP-100N")

        // In the Parts pane, Return still places its part.
        XCTAssertTrue(window.makeFirstResponder(partsTable))
        try await Task.sleep(for: .milliseconds(100))
        try await pressReturn()
        XCTAssertEqual(partsPlaced, ["pp-1"])
        XCTAssertEqual(calls.placed, ["p-c"])

        // And from its search field.
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).flatMap { $0.isEditable ? [$0] : nil } ?? []) + view.subviews.flatMap(fields)
        }
        let partsSearch = try XCTUnwrap(fields(hosted).first { $0.convert($0.bounds, to: nil).midX < 1100 })
        XCTAssertTrue(window.makeFirstResponder(partsSearch))
        try await Task.sleep(for: .milliseconds(100))
        try await pressReturn()
        XCTAssertEqual(partsPlaced, ["pp-1", "pp-1"])
    }

    /// What the Place and Replace buttons say, and when they act.
    func testPlaceAndReplaceSayWhyTheyCantAct() throws {
        let calls = Calls()
        let part = HorizontalPoolLibraryItem(
            id: "x|part|p-r1", uuid: "p-r1", name: "RES-4700", detail: "", tags: "", category: .part, poolName: "Pane Pool",
            poolURL: poolURL, url: poolURL.appendingPathComponent("parts/r1.json"), partEntityID: "e-res")
        var package = part
        package.category = .package
        let place = actions(calls, replacement: nil)
        XCTAssertNil(HorizontalPoolBrowserView.placeUnavailableReason(for: part, actions: place, isReadOnly: false))
        XCTAssertEqual(HorizontalPoolBrowserView.placeUnavailableReason(for: nil, actions: place, isReadOnly: false),
                       "Select a part to place it in the schematic.")
        XCTAssertEqual(HorizontalPoolBrowserView.placeUnavailableReason(for: package, actions: place, isReadOnly: false),
                       "Only parts are placed. Choose Parts in the kind menu.")
        XCTAssertEqual(HorizontalPoolBrowserView.placeUnavailableReason(for: part, actions: place, isReadOnly: true),
                       "Read-only operation is enabled in Horizontal.")
        let noSchematic = HorizontalPoolPartActions(place: nil, placeUnavailableReason: "This project has no schematic to place parts in.")
        XCTAssertEqual(HorizontalPoolBrowserView.placeUnavailableReason(for: part, actions: noSchematic, isReadOnly: false),
                       "This project has no schematic to place parts in.")

        let replace = actions(calls, replacement: replacement)
        XCTAssertNil(HorizontalPoolBrowserView.replaceRefusal(for: part, replacement, actions: replace, isReadOnly: false))
        XCTAssertEqual(HorizontalPoolBrowserView.replaceRefusal(for: nil, replacement, actions: replace, isReadOnly: false),
                       "Select a part to give to R1.")
        var current = part
        current.uuid = "p-r0"
        current.name = "RES-1000"
        XCTAssertEqual(HorizontalPoolBrowserView.replaceRefusal(for: current, replacement, actions: replace, isReadOnly: false),
                       "R1 already uses “RES-1000”.")
        XCTAssertEqual(HorizontalPoolBrowserView.replaceRefusal(for: part, replacement, actions: replace, isReadOnly: true),
                       "Read-only operation is enabled in Horizontal.")
    }
}
#endif
