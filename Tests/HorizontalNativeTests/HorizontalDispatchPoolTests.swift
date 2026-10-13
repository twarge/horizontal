import Foundation
import HorizontalProjectIO
import XCTest
import AppKit
import SwiftUI
@testable import HorizontalNative

/// Reaching a part the project has never used: finding it in the pools the
/// project draws from, copying it into the project pool, and putting it on a
/// sheet — the whole path, through the dispatcher.
final class HorizontalDispatchPoolTests: XCTestCase {
    @MainActor private final class DocumentState: ObservableObject {
        @Published var document = HorizontalProjectDocument()
        init(_ archive: HorizontalProjectArchive) { document.archive = archive }
    }

    private struct UpdateWorkspace: View {
        @ObservedObject var state: DocumentState
        var project: HorizontalProject
        @State private var panes: Set<HorizontalPane> = [.parts]
        @State private var nets = Set<String>()
        @State private var highlightedNets = Set<String>()
        @State private var components = Set<String>()
        @State private var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $state.document, visiblePanes: $panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents)
        }
    }
    private var root: URL!
    private var packageURL: URL!
    private var handle = 0
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-dispatch-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }

        testDefaults = UserDefaults(suiteName: "HorizontalDispatchPoolTests-\(UUID().uuidString)")
        HorizontalPoolRegistryStore.defaults = testDefaults
        HorizontalPoolLibrary.invalidateCache()
        addTeardownBlock {
            HorizontalPoolRegistryStore.defaults = .standard
            HorizontalPoolLibrary.invalidateCache()
        }
        try writeStockPool()
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: root.appendingPathComponent("stock", isDirectory: true)))

        packageURL = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject().write(to: packageURL)
        let summary = try XCTUnwrap(try result("open_project", ["path": packageURL.path]) as? [String: Any])
        handle = try XCTUnwrap(summary["handle"] as? Int)
        addTeardownBlock { [handle] in _ = HorizontalDispatch.call(#"{"jsonrpc":"2.0","id":0,"method":"close_project","params":{"handle":\#(handle)}}"#) }
    }

    @discardableResult
    private func write(_ json: JSONDictionary, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return url
    }

    /// A resistor in a base pool, complete enough to place: unit, symbol,
    /// entity, padstack, package and part.
    private func writeStockPool() throws {
        try write(["type": "pool", "uuid": "stock-pool", "name": "Stock"], to: "stock/pool.json")
        try write(
            ["type": "unit", "uuid": "unit-1", "name": "Resistor", "manufacturer": "",
             "pins": ["pin-1": ["primary_name": "1", "direction": "passive", "swap_group": 0, "names": []],
                      "pin-2": ["primary_name": "2", "direction": "passive", "swap_group": 0, "names": []]]],
            to: "stock/units/resistor.json"
        )
        try write(
            ["type": "symbol", "uuid": "sym-1", "name": "Resistor", "unit": "unit-1",
             "pins": ["pin-1": ["position": [-2_500_000, 0], "length": 2_500_000, "orientation": "left",
                                "name_visible": true, "pad_visible": true, "name_orientation": "in_line"],
                      "pin-2": ["position": [2_500_000, 0], "length": 2_500_000, "orientation": "right",
                                "name_visible": true, "pad_visible": true, "name_orientation": "in_line"]],
             "junctions": [:], "lines": [:], "arcs": [:], "texts": [:]],
            to: "stock/symbols/resistor.json"
        )
        try write(
            ["type": "entity", "uuid": "ent-1", "name": "Resistor", "manufacturer": "", "prefix": "R", "tags": [],
             "gates": ["gate-1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "unit-1"]]],
            to: "stock/entities/resistor.json"
        )
        try write(
            ["type": "padstack", "padstack_type": "top", "uuid": "ps-pool", "name": "SMD pad",
             "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
            to: "stock/padstacks/smd.json"
        )
        try write(
            ["type": "package", "uuid": "pkg-1", "name": "R0603", "manufacturer": "", "tags": [],
             "pads": ["pad-1": ["name": "1", "padstack": "ps-pool", "placement": ["shift": [-800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]],
                      "pad-2": ["name": "2", "padstack": "ps-pool", "placement": ["shift": [800_000, 0], "angle": 0, "mirror": false], "parameter_set": [:]]],
             "models": [:], "junctions": [:], "lines": [:], "arcs": [:], "texts": [:], "polygons": [:]],
            to: "stock/packages/r0603/package.json"
        )
        try write(
            ["type": "part", "uuid": "part-1", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RC0603FR-0710KL"], "value": [false, "10k"], "manufacturer": [false, "Yageo"],
             "description": [false, "Thick film resistor"], "datasheet": [false, ""],
             "tags": ["resistor", "0603"], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
             "parametric": [:]],
            to: "stock/parts/res-10k.json"
        )
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        var params = params
        if method != "open_project" {
            params["handle"] = handle
        }
        if ["apply", "import_pool_part", "update_project_parts", "clean_up_project_pool"].contains(method) {
            params["expected_revision"] = try HorizontalDispatchSession.shared.perform { try $0.entry(handle: handle).revision }
            params["operation_id"] = UUID().uuidString
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        let requestJSON = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HorizontalDispatch.call(requestJSON).utf8)) as? [String: Any])
    }

    private func result(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let response = try call(method, params)
        if let error = response["error"] as? [String: Any] {
            XCTFail("\(method) failed: \(error["message"] ?? error)")
        }
        return try XCTUnwrap(response["result"])
    }

    func testSearchFindsPartsTheProjectPoolDoesNotHave() throws {
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0,
                       "an untouched project pool has no parts")

        let found = try XCTUnwrap(try result("search_pool", ["query": "0710KL", "kind": "part"]) as? [String: Any])
        let items = try XCTUnwrap(found["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["uuid"] as? String, "part-1")
        XCTAssertEqual(items[0]["name"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(items[0]["manufacturer"] as? String, "Yageo")
        XCTAssertEqual(items[0]["pool"] as? String, "Stock")
        XCTAssertEqual(items[0]["in_project_pool"] as? Bool, false)

        let pools = try XCTUnwrap(found["pools"] as? [[String: Any]])
        XCTAssertEqual(pools.first?["is_project_pool"] as? Bool, true)
        XCTAssertTrue(pools.contains { $0["uuid"] as? String == "stock-pool" }, "\(pools)")

        // Tags and manufacturers match as well as names, and kind narrows.
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "Yageo"]) as? [String: Any])["total"] as? Int), 1)
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["kind": "symbol"]) as? [String: Any])["total"] as? Int), 1)
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "nothing here"]) as? [String: Any])["total"] as? Int), 0)

        XCTAssertNotNil(try call("search_pool", ["kind": "gizmo"])["error"])
    }

    func testPartUpdateReviewDryRunAndCommitShareThePlanner() throws {
        _ = try result("import_pool_part", ["part": "part-1"])
        let original = try HorizontalProjectArchive.snapshot(from: packageURL)
        let current = try XCTUnwrap(try result("list_part_updates") as? JSONDictionary)
        XCTAssertEqual((current["parts"] as? [JSONDictionary])?.first?.string("status"), "current")
        var source = try JSONHelper.loadDictionary(from: root.appendingPathComponent("stock/symbols/resistor.json"))
        source["name"] = "Updated resistor symbol"
        try write(source, to: "stock/symbols/resistor.json")
        let review = try XCTUnwrap(try result("list_part_updates") as? JSONDictionary)
        XCTAssertEqual((review["parts"] as? [JSONDictionary])?.first?.string("status"), "updateAvailable")
        let params: JSONDictionary = ["parts": ["part-1"], "review_digest": try XCTUnwrap(review.string("review_digest")), "dry_run": true]
        let dry = try XCTUnwrap(try result("update_project_parts", params) as? JSONDictionary)
        XCTAssertEqual(dry.bool("dry_run"), true)
        XCTAssertEqual(original, try HorizontalProjectArchive.snapshot(from: packageURL))
        var commit = params
        commit["dry_run"] = false
        commit["plan_digest"] = try XCTUnwrap(dry.string("plan_digest"))
        let updated = try XCTUnwrap(try result("update_project_parts", commit) as? JSONDictionary)
        XCTAssertEqual(updated.string("status"), "committed")
        XCTAssertEqual(updated["affected_parts"] as? [String], ["part-1"])
        XCTAssertNotEqual(original, try HorizontalProjectArchive.snapshot(from: packageURL))
        let nextReview = try XCTUnwrap(try result("list_part_updates") as? JSONDictionary)
        XCTAssertEqual((nextReview["parts"] as? [JSONDictionary])?.first?.string("status"), "current")
    }

    func testStaleLibraryReviewIsRefusedWithoutWriting() throws {
        _ = try result("import_pool_part", ["part": "part-1"])
        var source = try JSONHelper.loadDictionary(from: root.appendingPathComponent("stock/symbols/resistor.json"))
        source["name"] = "First update"
        try write(source, to: "stock/symbols/resistor.json")
        let review = try XCTUnwrap(try result("list_part_updates") as? JSONDictionary)
        source["name"] = "Second update"
        try write(source, to: "stock/symbols/resistor.json")
        let original = try HorizontalProjectArchive.snapshot(from: packageURL)
        let refused = try call("update_project_parts", ["parts": ["part-1"], "review_digest": try XCTUnwrap(review.string("review_digest"))])
        XCTAssertNotNil(refused["error"])
        XCTAssertEqual(original, try HorizontalProjectArchive.snapshot(from: packageURL))
    }

    func testPinRemovalCannotBeForcedThroughDispatch() throws {
        _ = try result("import_pool_part", ["part": "part-1"])
        var source = try JSONHelper.loadDictionary(from: root.appendingPathComponent("stock/symbols/resistor.json"))
        var pins = source.dictionaryMap("pins")
        pins.removeValue(forKey: "pin-1")
        source["pins"] = pins
        try write(source, to: "stock/symbols/resistor.json")
        let original = try HorizontalProjectArchive.snapshot(from: packageURL)
        let refused = try call("update_project_parts", ["parts": ["part-1"], "allow_project_changes": true])
        XCTAssertNotNil(refused["error"])
        XCTAssertEqual(original, try HorizontalProjectArchive.snapshot(from: packageURL))
    }

    @MainActor func testMountedLivePartUpdatePreservesUnsavedEditsAndUndoesAsOneStep() async throws {
        _ = NSApplication.shared
        _ = try result("import_pool_part", ["part": "part-1"])
        let originalDisk = try HorizontalProjectArchive.snapshot(from: packageURL)
        let loaded = try HorizontalProject.load(from: packageURL)
        let unsaved = try HorizontalCanvasProjectEdit.archive(applying: [["op": "place_text", "text": "Unsaved note", "x_mm": 5, "y_mm": 6]],
                                                              to: originalDisk, in: loaded).archive
        var project = try HorizontalProject.loadSnapshot(of: unsaved)
        project.rebaseURLs(onto: loaded)
        let state = DocumentState(unsaved)
        let defaults = UserDefaults(suiteName: "parts-live-\(UUID().uuidString)")!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let registeredDocument = NSDocument()
        registeredDocument.fileURL = packageURL
        registeredDocument.undoManager = undo
        NSDocumentController.shared.addDocument(registeredDocument)
        defer { NSDocumentController.shared.removeDocument(registeredDocument) }
        let hosted = NSHostingView(rootView: UpdateWorkspace(state: state, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(10)
        while !HorizontalDispatchSession.shared.openEntries.contains(where: { $0.live != nil && $0.url.resolvingSymlinksInPath() == packageURL.resolvingSymlinksInPath() }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        let live = try XCTUnwrap(HorizontalDispatchSession.shared.openEntries.first { $0.live != nil && $0.url.resolvingSymlinksInPath() == packageURL.resolvingSymlinksInPath() })
        var symbol = try JSONHelper.loadDictionary(from: root.appendingPathComponent("stock/symbols/resistor.json"))
        symbol["name"] = "Live symbol update"
        try write(symbol, to: "stock/symbols/resistor.json")
        undo.beginUndoGrouping()
        let result = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "update_project_parts", "params": [
            "handle": live.handle, "parts": ["part-1"], "expected_revision": live.revision, "operation_id": "live-part-update"
        ]])
        undo.endUndoGrouping()
        XCTAssertNil(result["error"], "\(result)")
        let updated = state.document.archive
        let cached = try JSONHelper.loadDictionary(from: XCTUnwrap(updated.regularFileData(relativePath: "pool/symbols/cache/sym-1.json")))
        XCTAssertEqual(cached.string("name"), "Live symbol update")
        XCTAssertEqual(try HorizontalProject.loadSnapshot(of: updated).schematic?.sheets.first?.texts.map(\.text), ["Unsaved note"])
        XCTAssertEqual(try HorizontalProjectArchive.snapshot(from: packageURL), originalDisk, "a live update never writes the last-saved project")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(state.document.archive, unsaved)
        XCTAssertFalse(undo.canUndo, "one update is one undo step")
        undo.redo()
        XCTAssertEqual(state.document.archive, updated)
    }

    func testImportedPartBecomesUsableAndDrawable() throws {
        let before = try HorizontalProjectArchive.snapshot(from: packageURL)
        let revision = try result("project_info") as! JSONDictionary
        let dry = try XCTUnwrap(try result("import_pool_part", ["part": "part-1", "dry_run": true]) as? [String: Any])
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual(dry["status"] as? String, "preview")
        XCTAssertEqual(dry["written"] as? [String], [])
        XCTAssertFalse((dry["would_write"] as? [String] ?? []).isEmpty)
        XCTAssertNil(dry["durability"])
        XCTAssertNil(dry["after_revision"])
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: packageURL))
        XCTAssertEqual(revision.string("revision"), (try result("project_info") as? JSONDictionary)?.string("revision"))
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0, "a dry run writes nothing")

        let imported = try XCTUnwrap(try result("import_pool_part", ["part": "part-1"]) as? [String: Any])
        XCTAssertEqual(imported["mpn"] as? String, "RC0603FR-0710KL")
        XCTAssertEqual(imported["already_cached"] as? Bool, false)
        let written = try XCTUnwrap(imported["written"] as? [String])
        for kind in ["parts/cache/part-1.json", "entities/cache/ent-1.json", "units/cache/unit-1.json",
                     "symbols/cache/sym-1.json", "packages/cache/pkg-1/package.json", "padstacks/cache/ps-pool.json"] {
            XCTAssertTrue(written.contains { $0.hasSuffix(kind) }, "\(kind) missing from \(written)")
        }
        XCTAssertEqual((imported["project"] as? [String: Any])?["diagnostics"] as? [String], [])

        let parts = try XCTUnwrap(try result("list_parts") as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])
        XCTAssertEqual(parts.first?["in_project_pool"] as? Bool, true)
        let again = try XCTUnwrap(try result("search_pool", ["query": "0710KL"]) as? [String: Any])
        XCTAssertEqual((again["items"] as? [[String: Any]])?.first?["in_project_pool"] as? Bool, true)

        // The point of importing: the part can now carry a component, and the
        // symbol that came with it can draw it on a sheet.
        _ = try result("apply", ["ops": [
            ["op": "ensure_component", "refdes": "R1", "part": "part-1"],
            ["op": "place_symbol", "component": "R1", "x_mm": 25, "y_mm": 35]
        ]])
        let component = try XCTUnwrap(try result("get_component", ["refdes": "R1"]) as? [String: Any])
        let symbols = try XCTUnwrap(component["symbols"] as? [[String: Any]])
        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols[0]["x_mm"] as? Double, 25)
        XCTAssertEqual(component["mpn"] as? String, "RC0603FR-0710KL")
    }

    func testImportingTwiceIsIdempotentAndUnknownPartsAreNamed() throws {
        _ = try result("import_pool_part", ["part": "RC0603FR-0710KL"])
        let again = try XCTUnwrap(try result("import_pool_part", ["part": "part-1"]) as? [String: Any])
        XCTAssertEqual(again["already_cached"] as? Bool, true)
        XCTAssertEqual(again["written"] as? [String], [])

        let missing = try call("import_pool_part", ["part": "NOT-A-PART"])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testScopedListPartsSeesTheBasePoolsBeforeAnythingIsImported() throws {
        let all = try XCTUnwrap(try result("list_parts", ["scope": "all"]) as? [[String: Any]])
        XCTAssertEqual(all.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])
        XCTAssertEqual(all.first?["in_project_pool"] as? Bool, false)
        XCTAssertEqual(all.first?["pool"] as? String, "Stock")
        XCTAssertNotNil(try call("list_parts", ["scope": "sideways"])["error"])
    }

    // MARK: - Round twenty-nine: notes 92 and 94

    private func editPackageJSON(_ relativePath: String, _ edit: (inout JSONDictionary) -> Void) throws {
        let url = packageURL.appendingPathComponent(relativePath)
        var json = try JSONHelper.loadDictionary(from: url)
        edit(&json)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    /// What the design reaches stays: a component's part and its tree (the
    /// block typed or not), the BOM's concrete part, a sheet's frame, a board
    /// decal and a via's padstack. Only what nothing names is offered.
    func testCleanUpReviewOffersOnlyWhatNothingInTheDesignReaches() throws {
        _ = try result("import_pool_part", ["part": "part-1"])
        _ = try result("apply", ["ops": [["op": "ensure_component", "refdes": "R1", "part": "part-1"]]])
        let pool = "Untitled.horizontal/pool/"
        for id in ["frame-used", "frame-unused"] {
            try write(["type": "frame", "uuid": id, "name": id, "width": 297_000_000, "height": 210_000_000,
                       "lines": [:], "arcs": [:], "texts": [:], "polygons": [:], "junctions": [:]], to: pool + "frames/cache/\(id).json")
        }
        try write(["type": "decal", "uuid": "decal-used", "name": "Logo", "polygons": [:], "lines": [:], "arcs": [:], "texts": [:], "junctions": [:]],
                  to: pool + "decals/cache/decal-used.json")
        for id in ["via-ps", "stray-ps"] {
            try write(["type": "padstack", "padstack_type": "via", "uuid": id, "name": id, "shapes": [:], "holes": [:], "polygons": [:], "parameter_set": [:]],
                      to: pool + "padstacks/cache/\(id).json")
        }
        var concrete = try JSONHelper.loadDictionary(from: packageURL.appendingPathComponent("pool/parts/cache/part-1.json"))
        concrete["uuid"] = "concrete-1"
        concrete["MPN"] = [false, "CONCRETE-1"]
        try write(concrete, to: pool + "parts/cache/concrete-1.json")
        concrete["uuid"] = "stray-part"
        concrete["MPN"] = [false, "STRAY-1"]
        try write(concrete, to: pool + "parts/cache/stray-part.json")
        let model = packageURL.appendingPathComponent("pool/3d_models/cache/stock-pool/3d_models/stray.step")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("solid".utf8).write(to: model)

        try editPackageJSON("top_schematic.json") { json in
            json["sheets"] = json.dictionaryMap("sheets").mapValues { sheet -> JSONDictionary in
                var sheet = sheet
                sheet["frame"] = "frame-used"
                return sheet
            }
        }
        try editPackageJSON("board.json") { json in
            json["decals"] = ["d1": ["decal": "decal-used", "placement": ["shift": [0, 0], "angle": 0, "mirror": false], "scale": 1, "flags": 0]]
            json["vias"] = ["v1": ["padstack": "via-ps", "junction": "j1", "parameter_set": [:], "from_rules": false, "locked": false, "source": "local"]]
        }
        try editPackageJSON("top_block.json") { json in
            // Billo's block has no type key (note 92).
            json.removeValue(forKey: "type")
            json["bom_export_settings"] = ["concrete_parts": ["part-1": "concrete-1"]]
        }

        let archive = try HorizontalProjectArchive.snapshot(from: packageURL)
        let project = try HorizontalProject.loadSnapshot(of: archive)
        let files = HorizontalPoolCacheUpdater.files(in: archive, poolDirectory: "pool")
        let review = HorizontalPoolCacheCleanup.review(archive: archive, project: project, files: files)
        XCTAssertEqual(review.items.map(\.id), ["part|stray-part", "padstack|stray-ps", "frame|frame-unused",
                                                "model|3d_models/cache/stock-pool/3d_models/stray.step"])
        XCTAssertEqual(review.items.first?.name, "STRAY-1 / Yageo")
        XCTAssertEqual(review.items.first?.paths, ["parts/cache/stray-part.json"])
        XCTAssertEqual(review.items.last?.bytes, 5)

        // Note 92: the components are found without the block's type key.
        XCTAssertEqual(HorizontalPoolCacheUpdater.references(in: archive, project: project)["part-1"], ["R1"])
        XCTAssertEqual(HorizontalPoolCacheUpdater.references(in: archive)["part-1"], nil, "without the project, an untyped block is not found")
    }

    func testCleanUpDryRunListsAndTheCommitRemovesFilesAndManifestEntries() throws {
        let empty = try XCTUnwrap(try result("clean_up_project_pool", ["dry_run": true]) as? JSONDictionary)
        XCTAssertEqual((empty["items"] as? [JSONDictionary])?.count, 0)
        XCTAssertEqual(empty.bool("unchanged"), true)

        _ = try result("import_pool_part", ["part": "part-1"])
        let before = try HorizontalProjectArchive.snapshot(from: packageURL)
        let dry = try XCTUnwrap(try result("clean_up_project_pool", ["dry_run": true]) as? JSONDictionary)
        let ids = (dry["items"] as? [JSONDictionary])?.compactMap { $0.string("id") }
        XCTAssertEqual(ids, ["part|part-1", "entity|ent-1", "unit|unit-1", "symbol|sym-1", "package|pkg-1", "padstack|ps-pool"])
        let wouldWrite = try XCTUnwrap(dry["would_write"] as? [String])
        XCTAssertTrue(wouldWrite.contains("pool/parts/cache/part-1.json"), "\(wouldWrite)")
        XCTAssertTrue(wouldWrite.contains("pool/.horizontal/pool-cache.json"), "the manifest loses their entries")
        XCTAssertEqual(before, try HorizontalProjectArchive.snapshot(from: packageURL), "a dry run writes nothing")
        XCTAssertNotNil(try call("clean_up_project_pool", ["remove": ["part|nope"], "dry_run": true])["error"])

        // Used by a component, the part and its tree stay.
        _ = try result("apply", ["ops": [["op": "ensure_component", "refdes": "R1", "part": "part-1"]]])
        XCTAssertEqual((try XCTUnwrap(try result("clean_up_project_pool", ["dry_run": true]) as? JSONDictionary)["items"] as? [JSONDictionary])?.count, 0)
        _ = try result("apply", ["ops": [["op": "remove_component", "component": "R1"]]])

        let plan = try XCTUnwrap(try result("clean_up_project_pool", ["dry_run": true, "remove": ["part|part-1", "symbol|sym-1"]]) as? JSONDictionary)
        XCTAssertEqual((plan["remove"] as? [JSONDictionary])?.compactMap { $0.string("id") }, ["part|part-1", "symbol|sym-1"])
        let committed = try XCTUnwrap(try result("clean_up_project_pool", [
            "remove": ["part|part-1", "symbol|sym-1"], "plan_digest": try XCTUnwrap(plan.string("plan_digest")),
            "review_digest": try XCTUnwrap(plan.string("review_digest"))
        ]) as? JSONDictionary)
        XCTAssertEqual(committed.string("status"), "committed")
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.appendingPathComponent("pool/parts/cache/part-1.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.appendingPathComponent("pool/symbols/cache/sym-1.json").path))
        XCTAssertTrue(fileManager.fileExists(atPath: packageURL.appendingPathComponent("pool/entities/cache/ent-1.json").path))
        let manifest = try HorizontalPoolCacheProvenance.load(Data(contentsOf: packageURL.appendingPathComponent("pool/.horizontal/pool-cache.json")))
        XCTAssertNil(manifest.files["parts/cache/part-1.json"])
        XCTAssertNotNil(manifest.files["entities/cache/ent-1.json"])
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.count, 0)

        // Everything else goes too, and then nothing is left to offer.
        _ = try result("clean_up_project_pool")
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.appendingPathComponent("pool/packages/cache/pkg-1").path))
        XCTAssertEqual((try XCTUnwrap(try result("clean_up_project_pool", ["dry_run": true]) as? JSONDictionary)["items"] as? [JSONDictionary])?.count, 0)
    }

    @MainActor func testMountedLiveCleanUpIsOneUndoStep() async throws {
        _ = NSApplication.shared
        _ = try result("import_pool_part", ["part": "part-1"])
        let originalDisk = try HorizontalProjectArchive.snapshot(from: packageURL)
        var project = try HorizontalProject.loadSnapshot(of: originalDisk)
        project.rebaseURLs(onto: try HorizontalProject.load(from: packageURL))
        let state = DocumentState(originalDisk)
        let defaults = UserDefaults(suiteName: "cleanup-live-\(UUID().uuidString)")!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let registeredDocument = NSDocument()
        registeredDocument.fileURL = packageURL
        registeredDocument.undoManager = undo
        NSDocumentController.shared.addDocument(registeredDocument)
        defer { NSDocumentController.shared.removeDocument(registeredDocument) }
        let hosted = NSHostingView(rootView: UpdateWorkspace(state: state, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(10)
        while !HorizontalDispatchSession.shared.openEntries.contains(where: { $0.live != nil && $0.url.resolvingSymlinksInPath() == packageURL.resolvingSymlinksInPath() }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        let live = try XCTUnwrap(HorizontalDispatchSession.shared.openEntries.first { $0.live != nil && $0.url.resolvingSymlinksInPath() == packageURL.resolvingSymlinksInPath() })
        undo.beginUndoGrouping()
        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 3, "method": "clean_up_project_pool", "params": [
            "handle": live.handle, "expected_revision": live.revision, "operation_id": "live-cleanup"
        ]])
        undo.endUndoGrouping()
        XCTAssertNil(response["error"], "\(response)")
        let cleaned = state.document.archive
        XCTAssertNil(cleaned.regularFileData(relativePath: "pool/parts/cache/part-1.json"))
        XCTAssertNil(cleaned.regularFileData(relativePath: "pool/packages/cache/pkg-1/package.json"))
        XCTAssertEqual(try HorizontalProjectArchive.snapshot(from: packageURL), originalDisk, "a live cleanup leaves the saved project alone")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertNotNil(state.document.archive.regularFileData(relativePath: "pool/parts/cache/part-1.json"))
        XCTAssertFalse(undo.canUndo, "one cleanup is one undo step")
    }

    // MARK: - Round twenty-two: notes 74–76

    func testPoolRowsKeepTheirDescriptionListTheBasePoolsCopyAndShareOneShape() throws {
        // 74: a base-pool row's description is the part's, not its manufacturer.
        let before = try XCTUnwrap(try result("list_parts", ["scope": "pools"]) as? [[String: Any]])
        XCTAssertEqual(before.map { $0["description"] as? String }, ["Thick film resistor"])
        XCTAssertEqual(before.first?["manufacturer"] as? String, "Yageo")

        // 75: once cached, "pools" still lists the part as Stock holds it,
        // marked in_project_pool, and "all" lists it once, as the project's.
        _ = try result("import_pool_part", ["part": "part-1"])
        let pools = try XCTUnwrap(try result("list_parts", ["scope": "pools"]) as? [[String: Any]])
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools.first?["pool"] as? String, "Stock")
        XCTAssertEqual(pools.first?["in_project_pool"] as? Bool, true)
        XCTAssertEqual(pools.first?["description"] as? String, "Thick film resistor")
        let all = try XCTUnwrap(try result("list_parts", ["scope": "all"]) as? [[String: Any]])
        XCTAssertEqual(all.count, 1, "the cached copy is not listed twice")
        XCTAssertNotEqual(all.first?["pool"] as? String, "Stock")
        XCTAssertTrue((all.first?["path"] as? String)?.hasSuffix("parts/cache/part-1.json") ?? false, "\(all)")

        // 75: every row has the same keys; what only the entity says is null
        // on a base-pool row.
        let project = try XCTUnwrap(try result("list_parts") as? [[String: Any]])
        XCTAssertEqual(Set(project[0].keys), Set(pools[0].keys))
        XCTAssertEqual(Set(all[0].keys), Set(pools[0].keys))
        XCTAssertEqual(project[0]["refdes_prefix"] as? String, "R")
        XCTAssertEqual(project[0]["gate_count"] as? Int, 1)
        XCTAssertTrue(pools[0]["refdes_prefix"] is NSNull)
        XCTAssertTrue(pools[0]["gate_count"] is NSNull)
        for row in [project[0], pools[0]] {
            XCTAssertEqual(row["uuid"] as? String, "part-1")
            XCTAssertEqual(row["id"] as? String, "part-1")
            XCTAssertEqual(row["entity_id"] as? String, "ent-1")
            XCTAssertEqual(row["package_id"] as? String, "pkg-1")
            XCTAssertEqual(row["package"] as? String, "R0603")
            XCTAssertEqual(row["kind"] as? String, "part")
        }
    }

    func testEveryRowNamesThePoolsHoldingItAndSearchPartRowsReadAsListPartsRows() throws {
        func search(_ query: String, kind: String) throws -> [[String: Any]] {
            try XCTUnwrap((try result("search_pool", ["query": query, "kind": kind]) as? [String: Any])?["items"] as? [[String: Any]])
        }
        // 80: before the part is cached, Stock alone holds it.
        XCTAssertEqual(try XCTUnwrap(try result("list_parts", ["scope": "pools"]) as? [[String: Any]]).first?["pools"] as? [String], ["Stock"])
        XCTAssertEqual(try search("0710KL", kind: "part").first?["pools"] as? [String], ["Stock"])

        // Once cached, every row names both pools, its own first, so the
        // project's row still says where the part came from.
        _ = try result("import_pool_part", ["part": "part-1"])
        let project = try XCTUnwrap(try result("list_parts") as? [[String: Any]])
        let projectPool = try XCTUnwrap(project.first?["pool"] as? String)
        XCTAssertNotEqual(projectPool, "Stock")
        XCTAssertEqual(project.first?["pools"] as? [String], [projectPool, "Stock"])
        let pools = try XCTUnwrap(try result("list_parts", ["scope": "pools"]) as? [[String: Any]])
        XCTAssertEqual(pools.first?["pools"] as? [String], ["Stock", projectPool])
        let all = try XCTUnwrap(try result("list_parts", ["scope": "all"]) as? [[String: Any]])
        XCTAssertEqual(all.first?["pools"] as? [String], [projectPool, "Stock"])

        // 81: search_pool's part row is the project's copy, with the keys and
        // the entity's facts a list_parts row has.
        let found = try XCTUnwrap(try search("0710KL", kind: "part").first)
        XCTAssertEqual(Set(found.keys), Set(project[0].keys))
        XCTAssertEqual(found["pool"] as? String, projectPool)
        XCTAssertEqual(found["pools"] as? [String], [projectPool, "Stock"])
        XCTAssertEqual(found["refdes_prefix"] as? String, "R")
        XCTAssertEqual(found["gate_count"] as? Int, 1)
        for key in ["id", "mpn", "entity_id", "package", "package_id", "description", "manufacturer"] {
            XCTAssertEqual(found[key] as? String, project[0][key] as? String, key)
        }

        // Any kind of item names its pools, a cached entity included.
        let entity = try XCTUnwrap(try search("Resistor", kind: "entity").first)
        XCTAssertEqual(entity["pools"] as? [String], [projectPool, "Stock"])
        XCTAssertNil(entity["refdes_prefix"], "only a part row takes the part keys")
    }

    func testAPartListGivesTheValueAPartStoresAndAComponentStillShowsItsMPN() throws {
        // 84: a part that stores no value read its MPN as value on a project
        // row and "" on a base-pool row. The MPN is in mpn already.
        try write(
            ["type": "part", "uuid": "part-2", "entity": "ent-1", "package": "pkg-1", "base": NSNull(),
             "MPN": [false, "RC0603JR-070RL"], "value": [false, ""], "manufacturer": [false, "Yageo"],
             "description": [false, "Zero ohm link"], "datasheet": [false, ""],
             "tags": ["resistor"], "inherit_tags": false, "inherit_model": true,
             "pad_map": ["pad-1": ["gate": "gate-1", "pin": "pin-1"], "pad-2": ["gate": "gate-1", "pin": "pin-2"]],
             "parametric": [:]],
            to: "stock/parts/res-0r.json"
        )
        HorizontalPoolLibrary.invalidateCache()
        _ = try result("import_pool_part", ["part": "part-2"])
        func row(_ params: [String: Any]) throws -> [String: Any]? {
            try XCTUnwrap(try result("list_parts", params) as? [[String: Any]]).first { $0["uuid"] as? String == "part-2" }
        }
        XCTAssertEqual(try row([:])?["value"] as? String, "")
        XCTAssertEqual(try row(["scope": "pools"])?["value"] as? String, "")
        XCTAssertEqual(try row([:])?["mpn"] as? String, "RC0603JR-070RL")
        let found = try XCTUnwrap((try result("search_pool", ["query": "070RL", "kind": "part"]) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(found.first?["value"] as? String, "")

        // What a component on it shows is still Horizon's Part::get_value.
        let part = try HorizontalDispatchSession.shared.perform { session in
            try session.entry(handle: handle).project.poolParts.first { $0.id == "part-2" }
        }
        XCTAssertEqual(part?.value, "")
        XCTAssertEqual(part?.displayValue, "RC0603JR-070RL")
    }

    func testAnExportToAFolderThisProcessCannotWriteIsAPermissionError() throws {
        // 76: refused before the exporters run, as a typed error, where it
        // used to come back as a status of "error" with Cocoa's wording.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        for target in [locked, locked.appendingPathComponent("inside", isDirectory: true)] {
            let refused = try XCTUnwrap(try call("export", ["sections": ["bom"], "target_directory": target.path])["error"] as? [String: Any])
            XCTAssertEqual(refused["code"] as? Int, -32010, "\(refused)")
            let data = try XCTUnwrap(refused["data"] as? [String: Any])
            XCTAssertEqual(data["code"] as? String, "PERMISSION_DENIED")
            XCTAssertEqual((data["details"] as? [String: Any])?["target_directory"] as? String, target.path)
            XCTAssertEqual((data["details"] as? [String: Any])?["sandboxed"] as? Bool, false)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locked.path), [], "nothing was written")

        let open = root.appendingPathComponent("open", isDirectory: true)
        let exported = try XCTUnwrap(try result("export", ["sections": ["bom"], "target_directory": open.path]) as? [String: Any])
        XCTAssertEqual(exported["status"] as? String, "success", "\(exported)")
        XCTAssertFalse((exported["files"] as? [String] ?? []).contains { $0.hasPrefix(".horizontal-export-probe") }, "the probe is removed")
    }

    /// A worker process has its own user defaults, so it cannot see the pools
    /// the app registered. Naming the directory reaches them anyway.
    func testAnUnregisteredPoolIsReachableByPath() throws {
        let stock = root.appendingPathComponent("stock", isDirectory: true)
        HorizontalPoolRegistryStore.removePool(at: stock)
        HorizontalPoolLibrary.invalidateCache()
        XCTAssertEqual((try XCTUnwrap(try result("search_pool", ["query": "0710KL"]) as? [String: Any])["total"] as? Int), 0,
                       "an unregistered pool is not discovered")

        let named = try XCTUnwrap(try result("search_pool", ["query": "0710KL", "pool_path": stock.path]) as? [String: Any])
        XCTAssertEqual((named["items"] as? [[String: Any]])?.first?["uuid"] as? String, "part-1")

        _ = try result("import_pool_part", ["part": "part-1", "pool_path": stock.path])
        XCTAssertEqual((try result("list_parts") as? [[String: Any]])?.map { $0["mpn"] as? String }, ["RC0603FR-0710KL"])

        let notAPool = try call("search_pool", ["pool_path": root.appendingPathComponent("nowhere").path])
        XCTAssertEqual((notAPool["error"] as? [String: Any])?["code"] as? Int, -32001)
    }

    func testAPoolReachedThroughASymlinkIsScannedAndListedOnce() throws {
        // 85: a pool whose root is a symlink scanned as empty, since the
        // enumerator doesn't descend into a link, and reached two ways it was
        // listed twice.
        let stock = root.appendingPathComponent("stock", isDirectory: true)
        let link = root.appendingPathComponent("stock-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stock)
        let canonical = HorizontalPoolLibrary.canonicalURL(stock).path
        XCTAssertEqual(HorizontalPoolLibrary.canonicalURL(link).path, canonical)

        HorizontalPoolRegistryStore.removePool(at: stock)
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: link))
        HorizontalPoolLibrary.invalidateCache()
        func stockPools() throws -> [[String: Any]] {
            let found = try XCTUnwrap(try result("search_pool", ["query": "0710KL"]) as? [String: Any])
            XCTAssertEqual(found["total"] as? Int, 1, "the part is found through the link")
            return (found["pools"] as? [[String: Any]] ?? []).filter { $0["uuid"] as? String == "stock-pool" }
        }
        var pools = try stockPools()
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools.first?["path"] as? String, canonical, "listed as the directory it points to")
        XCTAssertGreaterThan(pools.first?["item_count"] as? Int ?? 0, 0)

        // Reached both ways, it is one pool.
        XCTAssertTrue(HorizontalPoolRegistryStore.addPool(at: stock))
        HorizontalPoolLibrary.invalidateCache()
        pools = try stockPools()
        XCTAssertEqual(pools.count, 1, "\(pools)")

        // Scanned by the link, its items carry the canonical pool.
        let items = HorizontalPoolLibrary.items(inPool: link, poolName: "Stock")
        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(Set(items.map(\.poolURL.path)), [canonical])
        // And pool_path names it either way.
        let named = try XCTUnwrap(try result("search_pool", ["query": "0710KL", "pool_path": link.path]) as? [String: Any])
        XCTAssertEqual((named["items"] as? [[String: Any]])?.first?["uuid"] as? String, "part-1")
    }
}

/// Reading a real board's rules.
///
/// The synthetic fixtures elsewhere were written from an assumption about how
/// Horizon stores rules, and the assumption was wrong — rules are keyed by
/// kind, with the kinds that hold several keying those by uuid underneath, and
/// a reader that treats each top-level entry as one rule reports whole families
/// as single rules. A fixture written from the same misunderstanding agrees
/// with it, so this reads a board the app did not write.
final class HorizontalBoardRulesRealBoardTests: XCTestCase {
    func testRealRulesReadAsIndividualRules() throws {
        let path = ProcessInfo.processInfo.environment["HORIZONTAL_GOLDEN_BOARD"]
            ?? "/Users/kornack/Repositories/randi/Randi Short Horizon/Randi Short.hprj"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real board available")
        }
        let opened = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 1, "method": "open_project",
                                              "params": ["path": path]])
        let handle = try XCTUnwrap((opened["result"] as? [String: Any])?["handle"] as? Int)
        addTeardownBlock { _ = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 0, "method": "close_project",
                                                        "params": ["handle": handle]]) }

        let response = HorizontalDispatch.call(["jsonrpc": "2.0", "id": 2, "method": "board_rules",
                                                "params": ["handle": handle]])
        XCTAssertNil(response["error"], "\(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let rules = try XCTUnwrap(result["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.isEmpty, "a real board states rules")

        for rule in rules {
            let kind = try XCTUnwrap(rule["kind"] as? String)
            XCTAssertNotNil(HorizontalBoardRuleKind(rawValue: kind), "\(kind) is a rule kind, not a rule id")
            let body = try XCTUnwrap(rule["rule"] as? [String: Any])
            // A family read as one rule shows up here: its keys are uuids, and
            // an individual rule always carries `enabled`.
            XCTAssertNotNil(body["enabled"], "\(kind) looks like a family rather than one rule: \(body.keys.sorted())")
            if HorizontalBoardRuleKind(rawValue: kind)?.isMulti == true {
                XCTAssertNotNil(rule["id"] as? String, "\(kind) holds several rules, so each needs an id")
            } else {
                XCTAssertNil(rule["id"] as? String, "\(kind) holds one rule, so it has no id")
            }
        }
        // More rules than kinds is the point: at least one family holds several.
        let kinds = Set(rules.compactMap { $0["kind"] as? String })
        XCTAssertGreaterThanOrEqual(rules.count, kinds.count)
    }
}
