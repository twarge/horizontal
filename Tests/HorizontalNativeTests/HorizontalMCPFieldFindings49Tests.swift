import Foundation
#if os(macOS)
import AppKit
#endif
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// MCP field findings 49: items 152–155 in the notes — the Pools pane
/// missing what the MCP wrote, remap_part refusing a no-connect pin, no way
/// to find a unit's symbols, live calls timing out while the app idled — and
/// the user's requests that came with them: links both ways between pool
/// items, in the MCP and on screen.
@MainActor
final class HorizontalMCPFieldFindings49Tests: XCTestCase {
    private struct Part {
        var items: [JSONDictionary]
        var part: String
        var entity: String
        var unit: String
        var symbol: String
        var package: String
        var padstack: String
    }

    /// A one-gate part with pins named `names`, each on a pad of its own, all
    /// of one padstack; `named` names its unit, entity and symbol.
    private func part(_ named: String, _ names: [String]) -> Part {
        let pins = names.map { _ in UUID().uuidString.lowercased() }
        let pads = names.map { _ in UUID().uuidString.lowercased() }
        var unit = HorizontalPoolItemFactory.newUnit()
        unit.name = named
        for i in pins.indices {
            unit.pins[pins[i]] = HorizontalUnitPin(id: pins[i], primaryName: names[i], direction: .bidirectional, alternateNames: [])
        }
        var entity = HorizontalPoolItemFactory.newEntity(for: unit)
        entity.name = named
        let gate = entity.gates.keys.first!
        var symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        symbol.name = named
        for i in pins.indices {
            symbol.pins[pins[i]] = HorizontalSymbolPin(id: pins[i], position: HorizontalPoint(x: 0, y: -Double(i) * 2_540_000),
                                                       length: 2_540_000, orientation: .left)
        }
        var padstack = HorizontalPoolItemFactory.newPadstack(type: .top)
        padstack.name = "\(named) pad"
        let shape = UUID().uuidString.lowercased()
        padstack.shapes[shape] = HorizontalPadstackShape(id: shape, form: .rectangle, params: [800_000, 900_000])
        var package = HorizontalPoolItemFactory.newPackage()
        package.name = "\(named)-PKG"
        for i in pads.indices {
            package.pads[pads[i]] = HorizontalPad(id: pads[i], name: String(i + 1), padstackID: padstack.uuid,
                placement: HorizontalPlacementTransform(shift: HorizontalPoint(x: 0, y: Double(i) * 2_000_000), angle: 0, mirrored: false))
        }
        var part = HorizontalPoolItemFactory.newPart(entity: entity, packageID: package.uuid)
        for i in pins.indices { part.padMap[pads[i]] = HorizontalPartPadMapEntry(gateID: gate, pinID: pins[i]) }
        return Part(items: [unit.json(), entity.json(), symbol.json(), padstack.json(), package.json(), part.json()],
                    part: part.uuid.lowercased(), entity: entity.uuid.lowercased(), unit: unit.uuid.lowercased(),
                    symbol: symbol.uuid.lowercased(), package: package.uuid.lowercased(), padstack: padstack.uuid.lowercased())
    }

    private var root: URL!
    private var session: HorizontalDispatchSession!
    private var handle = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("field49-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalMCPFieldFindings49Tests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
        let project = root.appendingPathComponent("Project.horizontal")
        try HorizontalProjectArchive.newProject().write(to: project)
        session = HorizontalDispatchSession()
        handle = try session.open(url: project).handle
    }

    override func tearDownWithError() throws {
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        var params = args
        params["handle"] = handle
        if ["apply", "pool_write"].contains(method) {
            params["expected_revision"] = try session.entry(handle: handle).revision
            params["operation_id"] = UUID().uuidString
        }
        return try JSONHelper.loadDictionary(from: Data(HorizontalDispatch.serialize(HorizontalDispatch.call(
            ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], in: session), pretty: false).utf8))
    }

    private func result(_ method: String, _ args: JSONDictionary = [:]) throws -> JSONDictionary {
        let response = try call(method, args)
        XCTAssertNil(response["error"], "\(method): \(response)")
        return try XCTUnwrap(response["result"] as? JSONDictionary, "\(response)")
    }

    @discardableResult
    private func apply(_ ops: [JSONDictionary], _ extra: JSONDictionary = [:]) throws -> JSONDictionary {
        try result("apply", extra.merging(["ops": ops]) { new, _ in new })
    }

    private func poolWrite(_ items: [JSONDictionary]) throws {
        _ = try result("pool_write", ["items": items])
    }

    private func pins(_ refdes: String) throws -> [JSONDictionary] {
        try result("get_component", ["refdes": refdes]).dictionaryArray("pins")
    }

    private var poolURL: URL {
        get throws { try session.entry(handle: handle).project.baseURL.appendingPathComponent("pool") }
    }

    // MARK: - 153: remap_part and a no-connect pin with no counterpart

    func testRemapPartDropsANoConnectMarkThePinHasNoCounterpartFor() throws {
        // Cinnamon's U23: the ADA4523-1's SD and COM marked no-connect, the
        // ADA4077-1 on a plain single op-amp with neither.
        let shutdown = part("Opamp-SD-SDCOM", ["IN", "OUT", "SD", "COM"])
        let plain = part("Single Opamp", ["IN", "OUT"])
        try apply([["op": "ensure_component", "refdes": "U23", "part": shutdown.part],
                   ["op": "connect", "component": "U23", "pin": "IN", "net": "SIG", "create_net": true],
                   ["op": "set_no_connect", "component": "U23", "pins": ["SD", "COM"]]],
                  ["pool_items": shutdown.items + plain.items])
        let reply = try apply([["op": "remap_part", "component": "U23", "part": plain.part]])
        let change = try XCTUnwrap(reply.dictionaryArray("changes").first, "\(reply)")
        XCTAssertEqual(change["no_connects_dropped"] as? [String], ["COM", "SD"], "\(change)")
        XCTAssertEqual(change["preserved_connections"] as? Int, 1)
        let after = try pins("U23")
        XCTAssertEqual(after.compactMap { $0.string("pin") }.sorted(), ["IN", "OUT"])
        XCTAssertNotNil(after.first { $0.string("pin") == "IN" }?.string("net_id"), "IN stays on SIG")
    }

    func testRemapPartStillRefusesAPinOnANetWithNoCounterpart() throws {
        let shutdown = part("Opamp-SD", ["IN", "OUT", "SD"])
        let plain = part("Single Opamp", ["IN", "OUT"])
        try apply([["op": "ensure_component", "refdes": "U23", "part": shutdown.part],
                   ["op": "connect", "component": "U23", "pin": "SD", "net": "EN", "create_net": true]],
                  ["pool_items": shutdown.items + plain.items])
        let response = try call("apply", ["ops": [["op": "remap_part", "component": "U23", "part": plain.part]]])
        let message = try XCTUnwrap((response["error"] as? JSONDictionary)?.string("message"), "\(response)")
        XCTAssertTrue(message.contains("SD") && message.contains("no counterpart"), message)
    }

    // MARK: - 154: what uses what, in search_pool

    private func search(_ args: JSONDictionary) throws -> [JSONDictionary] {
        try result("search_pool", args).dictionaryArray("items")
    }

    func testSearchPoolFollowsLinksBothWays() throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        try poolWrite(opamp.items)

        // A unit's symbols, which no row used to name (Cinnamon's ADA4077-1).
        let symbols = try search(["kind": "symbol", "uses": opamp.unit])
        XCTAssertEqual(symbols.map { $0.string("uuid") }, [opamp.symbol])
        XCTAssertEqual(symbols.first?.string("unit_id"), opamp.unit)
        XCTAssertEqual(symbols.first?.string("unit"), "Opamp")
        // The entities a symbol's unit can draw, by its first eight digits.
        XCTAssertEqual(try search(["kind": "entity", "uses": String(opamp.unit.prefix(8))]).map { $0.string("uuid") }, [opamp.entity])
        XCTAssertEqual(try search(["kind": "entity", "uses": opamp.unit]).first?["unit_ids"] as? [String], [opamp.unit])
        // An entity's parts, a package's parts, a padstack's packages.
        XCTAssertEqual(try search(["uses": opamp.entity]).map { $0.string("uuid") }, [opamp.part])
        XCTAssertEqual(try search(["uses": opamp.package]).map { $0.string("uuid") }, [opamp.part])
        let packages = try search(["uses": opamp.padstack])
        XCTAssertEqual(packages.map { $0.string("uuid") }, [opamp.package])
        XCTAssertEqual(packages.first?["padstack_ids"] as? [String], [opamp.padstack])

        // And the other way: what a part names.
        let named = try search(["used_by": opamp.part])
        XCTAssertEqual(Set(named.map { "\($0.string("kind") ?? "")|\($0.string("uuid") ?? "")" }),
                       ["entity|\(opamp.entity)", "package|\(opamp.package)"])
        XCTAssertEqual(try search(["used_by": opamp.symbol]).map { $0.string("uuid") }, [opamp.unit])
    }

    func testSearchPoolNamesWhatAUsedByItemNamesThatNoPoolHolds() throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        var symbol = opamp.items[2]
        let missing = UUID().uuidString.lowercased()
        symbol["unit"] = missing
        try poolWrite([symbol])
        let reply = try result("search_pool", ["used_by": opamp.symbol])
        XCTAssertEqual(reply.dictionaryArray("items").count, 0)
        XCTAssertEqual(reply.dictionaryArray("missing_links").first?.string("uuid"), missing)
        XCTAssertEqual(reply.dictionaryArray("missing_links").first?.string("kind"), "unit")
    }

    func testSearchPoolRefusesAShortOrAmbiguousLink() throws {
        try poolWrite(part("Opamp", ["IN"]).items)
        let short = try call("search_pool", ["uses": "abc"])
        XCTAssertEqual((short["error"] as? JSONDictionary)?.dictionary("data")?.string("code"), "INVALID_ARGUMENT", "\(short)")
        let nothing = try call("search_pool", ["uses": "00000000"])
        XCTAssertEqual((nothing["error"] as? JSONDictionary)?.dictionary("data")?.string("code"), "NOT_FOUND", "\(nothing)")
    }

    // MARK: - Links in the Pools pane and the item editors

    private func index(_ parts: [Part]) throws -> HorizontalPoolLibraryIndex {
        if !parts.isEmpty { try poolWrite(parts.flatMap(\.items)) }
        HorizontalPoolLibrary.invalidateCache()
        let items = HorizontalPoolLibrary.resolvingInheritance(HorizontalPoolLibrary.items(inPool: try poolURL, poolName: "Project"))
        return HorizontalPoolLibraryIndex(items: items)
    }

    private func links(_ category: HorizontalPoolItemCategory, _ uuid: String, in index: HorizontalPoolLibraryIndex) throws -> [HorizontalPoolItemLink] {
        let item = try XCTUnwrap(index.item(category, uuid: uuid))
        return HorizontalPoolPreviewBuilder.links(for: item, json: try JSONHelper.loadDictionary(from: item.url), index: index)
    }

    private func names(_ links: [HorizontalPoolItemLink], _ role: HorizontalPoolItemLink.Role) -> [String] {
        links.filter { $0.role == role }.map(\.name)
    }

    func testEachKindLinksToWhatItUsesAndWhatUsesIt() throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        let index = try index([opamp])

        // A symbol: its unit, and the entities that can draw it.
        let symbol = try links(.symbol, opamp.symbol, in: index)
        XCTAssertEqual(names(symbol, .unit), ["Opamp"])
        XCTAssertEqual(names(symbol, .entity), ["Opamp"])
        // A unit: the symbols that draw it and the entities using it.
        let unit = try links(.unit, opamp.unit, in: index)
        XCTAssertEqual(names(unit, .symbol), ["Opamp"])
        XCTAssertEqual(names(unit, .entity), ["Opamp"])
        // An entity: its units, their symbols, and its parts.
        let entity = try links(.entity, opamp.entity, in: index)
        XCTAssertEqual(names(entity, .unit), ["Opamp"])
        XCTAssertEqual(names(entity, .symbol), ["Opamp"])
        XCTAssertEqual(entity.filter { $0.role == .part }.map(\.uuid), [opamp.part])
        // A package: its padstacks and its parts; a padstack: its packages.
        XCTAssertEqual(try links(.package, opamp.package, in: index).filter { $0.role == .part }.map(\.uuid), [opamp.part])
        XCTAssertEqual(names(try links(.padstack, opamp.padstack, in: index), .package), ["Opamp-PKG"])
        XCTAssertTrue(symbol.allSatisfy(\.isResolved))
    }

    func testAPartLinksToThePartsDerivedFromIt() throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        let derived = HorizontalPoolItemFactory.newPart(basedOn: try HorizontalPoolPartItem(json: opamp.items[5]))
        try poolWrite(opamp.items + [derived.json()])
        let index = try index([])
        let base = try links(.part, opamp.part, in: index)
        XCTAssertEqual(base.filter { $0.role == .derivedPart }.map(\.uuid), [derived.uuid.lowercased()])
        // Through its base, the derived part is one of the entity's parts too.
        XCTAssertEqual(Set(try links(.entity, opamp.entity, in: index).filter { $0.role == .part }.map(\.uuid)),
                       [opamp.part, derived.uuid.lowercased()])
    }

    func testAFieldOfManyLinksEndsWithASearchForTheRest() throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        let count = HorizontalPoolPreviewBuilder.maximumLinksPerField + 6
        let parts = (0..<count).map { i -> JSONDictionary in
            var part = opamp.items[5]
            part["uuid"] = UUID().uuidString.lowercased()
            part["MPN"] = [false, "OPA-\(i)"]
            return part
        }
        try poolWrite(opamp.items + parts)
        let index = try index([])
        let entity = try XCTUnwrap(index.item(.entity, uuid: opamp.entity))
        let fields = HorizontalPoolPreviewBuilder.linkFields(
            try links(.entity, opamp.entity, in: index), owner: entity
        )
        let partsField = try XCTUnwrap(fields.first { $0.label == "Parts" })
        XCTAssertEqual(partsField.links.count, HorizontalPoolPreviewBuilder.maximumLinksPerField)
        XCTAssertEqual(partsField.moreLinks, count + 1 - HorizontalPoolPreviewBuilder.maximumLinksPerField)
        let search = try XCTUnwrap(partsField.moreSearch)
        XCTAssertEqual(search, HorizontalPoolSearch(category: .part, term: opamp.entity))
        // The search lists them all: the Pools pane matches the uuids a part names.
        let listed = HorizontalPoolBrowserView.listed(index.items(in: .part), category: .part, search: search.term, replacement: nil)
        XCTAssertEqual(listed.count, count + 1)
        // What the entity names isn't a search away: its units aren't its users.
        XCTAssertNil(fields.first { $0.label == "Unit" }?.moreSearch)
    }

    func testAnEditorsLinksComeFromTheModelAsEdited() async throws {
        let opamp = part("Opamp", ["IN", "OUT"])
        _ = try index([opamp])
        let unit = try XCTUnwrap(HorizontalPoolLibrary.items(inPool: try poolURL, poolName: "Project").first { $0.uuid == opamp.unit })
        let session = try HorizontalPoolItemEditorSession(itemURL: unit.url, poolURL: try poolURL, category: .unit,
                                                          data: try Data(contentsOf: unit.url))
        await session.rebuildIndex()
        XCTAssertEqual(session.linkFields.map(\.label), ["Entity", "Symbol"])
        var opened = [HorizontalPoolLibraryItem]()
        let actions = try XCTUnwrap(session.linkActions { opened.append($0) })
        actions.open(try XCTUnwrap(session.linkFields.first { $0.label == "Symbol" }?.links.first))
        XCTAssertEqual(opened.map(\.uuid), [opamp.symbol])
        XCTAssertNil(session.linkActions(open: nil), "Nothing to open with, no links to click")
    }

    // MARK: - 152: the pools are watched

    func testWhatAWatchedPoolsChangesCanMove() {
        XCTAssertTrue(HorizontalPoolWatcher.mayHoldItems(""))
        XCTAssertTrue(HorizontalPoolWatcher.mayHoldItems("parts/opa.json"))
        XCTAssertTrue(HorizontalPoolWatcher.mayHoldItems("packages/soic-8"), "A folder removed takes its items with it")
        XCTAssertFalse(HorizontalPoolWatcher.mayHoldItems(".git/index"))
        XCTAssertFalse(HorizontalPoolWatcher.mayHoldItems("3d_models/soic.step"))
        XCTAssertFalse(HorizontalPoolWatcher.mayHoldItems("parts/.DS_Store"))
        XCTAssertFalse(HorizontalPoolWatcher.mayHoldItems(".horizontal/pool-cache.json"))
    }

    func testInvalidatingTheCacheTellsWhatShowsPoolItems() {
        let url = root.appendingPathComponent("some-pool")
        let one = expectation(forNotification: HorizontalPoolLibrary.poolsDidChangeNotification, object: nil) { notification in
            HorizontalPoolLibrary.notification(notification, concerns: [url])
                && !HorizontalPoolLibrary.notification(notification, concerns: [self.root.appendingPathComponent("other")])
        }
        HorizontalPoolLibrary.invalidateCache(for: url)
        let every = expectation(forNotification: HorizontalPoolLibrary.poolsDidChangeNotification, object: nil) { notification in
            HorizontalPoolLibrary.notification(notification, concerns: [self.root.appendingPathComponent("other")])
        }
        HorizontalPoolLibrary.invalidateCache()
        wait(for: [one, every], timeout: 1)
    }

    #if os(macOS)
    func testAWatchedPoolReadsAgainWhatSomethingElseWrote() async throws {
        let pool = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(["type": "pool", "uuid": UUID().uuidString.lowercased(), "name": "Watched"])
            .write(to: pool.appendingPathComponent("pool.json"))
        let opamp = part("Opamp", ["IN", "OUT"])
        let unitURL = pool.appendingPathComponent("units/opamp.json")
        try FileManager.default.createDirectory(at: unitURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(opamp.items[0]).write(to: unitURL)
        XCTAssertEqual(HorizontalPoolLibrary.items(inPool: pool, poolName: "Watched").count, 1)

        let lease = HorizontalPoolWatcher.shared.watch([pool])
        defer { lease.release() }
        XCTAssertTrue(HorizontalPoolWatcher.shared.watchedPaths.contains(HorizontalPoolLibrary.canonicalURL(pool).path))
        var announced = 0
        let observer = NotificationCenter.default.addObserver(forName: HorizontalPoolLibrary.poolsDidChangeNotification,
                                                              object: nil, queue: .main) { notification in
            if notification.userInfo != nil { announced += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await Task.sleep(for: .milliseconds(300))

        // Another writer adds a symbol, as git or Horizon would, past the cache.
        let symbolURL = pool.appendingPathComponent("symbols/opamp.json")
        try FileManager.default.createDirectory(at: symbolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try HorizontalHorizonJSONWriter.data(opamp.items[2]).write(to: symbolURL)
        let deadline = Date().addingTimeInterval(5)
        while announced == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(announced, 1)
        XCTAssertEqual(HorizontalPoolLibrary.items(inPool: pool, poolName: "Watched").count, 2, "The cache holds the new scan")

        // Written again as it was — an autosave rewriting a project's pool —
        // it lists nothing new, and nothing is announced.
        try HorizontalHorizonJSONWriter.data(opamp.items[2]).write(to: symbolURL)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(announced, 1)

        lease.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(HorizontalPoolWatcher.shared.watchedPaths.contains(HorizontalPoolLibrary.canonicalURL(pool).path))
    }

    // MARK: - 155: the app stays awake for a live client

    func testTheLiveChannelHoldsOffAppNapWhileAClientIsConnected() {
        let activity = HorizontalLiveActivity()
        XCTAssertFalse(activity.isHeld)
        activity.connectionOpened()
        activity.connectionOpened()
        XCTAssertTrue(activity.isHeld)
        activity.connectionClosed()
        XCTAssertTrue(activity.isHeld, "One client is still connected")
        activity.connectionClosed()
        XCTAssertFalse(activity.isHeld)
        activity.connectionClosed()
        XCTAssertFalse(activity.isHeld)
    }
    #endif

    // MARK: - Net lines at an angle, and highlights

    func testAClickOnAnAngledWireHitsItWhereTheGridPointBesideItMisses() {
        // A wire from (0, 0) to (10, 5) mm, clicked on it at (4, 2) mm at
        // 20 pt/mm: the 1.25 mm grid's nearest point is (3.75, 2.5), 0.56 mm off.
        let wire = HorizontalSegment(id: "net-line-1", from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 10_000_000, y: 5_000_000), width: 0)
        let scene = HorizontalCanvasSelectableScene(
            selectables: HorizontalCanvasModeSupport.segmentSelectables([wire], type: .lineNet)
        )
        let unitsPerPoint = 50_000.0
        let pointer = HorizontalCanvasPointer(snapped: HorizontalPoint(x: 3_750_000, y: 2_500_000),
                                              raw: HorizontalPoint(x: 4_000_000, y: 2_000_000))
        XCTAssertNil(scene.hitSelectable(at: pointer.snapped, worldUnitsPerPoint: unitsPerPoint), "Where the click used to be tested")
        XCTAssertEqual(scene.hitSelectable(at: pointer.raw, worldUnitsPerPoint: unitsPerPoint)?.type, .lineNet)
    }

    #if os(macOS)
    @MainActor private final class HighlightState: ObservableObject {
        @Published var nets: Set<String> = ["net"]
        @Published var components: Set<String> = ["component"]
        var actions: HorizontalCanvasCommandActions?
    }

    private struct HighlightCanvas: View {
        @ObservedObject var state: HighlightState
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(
                sheet: HorizontalSchematicSheet.poolEditorSheet(id: "sheet", name: "Sheet", gridSpacing: 1_250_000),
                viewport: $viewport,
                highlightedNetIDs: state.nets, highlightedComponentIDs: state.components,
                onHighlightNetCommand: { state.nets = $0 },
                onHighlightComponentCommand: { state.components = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 }
            )
        }
    }

    /// A highlight made from the board, the MCP or before a page flip comes
    /// with no selection behind it, and Escape at rest left it there.
    func testEscapeWithNoToolActiveEndsAHighlightWithNoSelectionBehindIt() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = HighlightState()
        let hosted = NSHostingView(rootView: HighlightCanvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        var deadline = Date().addingTimeInterval(3)
        while state.actions == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let actions = try XCTUnwrap(state.actions)
        actions.dispatch(.cancelInteraction)
        deadline = Date().addingTimeInterval(3)
        while !state.nets.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(state.nets, [])
        XCTAssertEqual(state.components, [])
    }
    #endif

    func testAClickOnNothingEndsTheHighlight() {
        XCTAssertTrue(HorizontalCanvasModeSupport.clearsHighlight(hitNothing: true, action: .replace))
        XCTAssertFalse(HorizontalCanvasModeSupport.clearsHighlight(hitNothing: true, action: .add), "Shift-clicking nothing adds nothing")
        XCTAssertFalse(HorizontalCanvasModeSupport.clearsHighlight(hitNothing: false, action: .replace))
    }
}
