import Foundation
import HorizontalProjectIO

struct HorizontalDispatchMethod: Sendable {
    typealias Handler = @Sendable (HorizontalDispatchSession, JSONDictionary) throws -> Any

    var name: String
    var summary: String
    var params: [String: String]
    var handler: Handler
}

/// The method table. Every method takes a JSON object of parameters and
/// returns a JSON value; the ones that act on a project take `handle` from
/// `open_project`.
enum HorizontalDispatchMethods {
    static func handler(named name: String) -> HorizontalDispatchMethod.Handler? {
        byName[name]?.handler
    }

    private static let byName: [String: HorizontalDispatchMethod] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0) }
    )

    static let all: [HorizontalDispatchMethod] = [
        .init(name: "version", summary: "Dispatch API version and host.", params: [:], handler: { _, _ in version() }),
        .init(name: "methods", summary: "List every method with its parameters.", params: [:], handler: { _, _ in
            HorizontalDispatchMethods.all.map { ["name": $0.name, "summary": $0.summary, "params": $0.params] }
        }),
        .init(
            name: "open_project",
            summary: "Open a .hprj or .horizontal project and return a handle plus a summary. Opening the same path again returns the existing handle.",
            params: ["path": "Project file (.hprj) or package (.horizontal) path."],
            handler: openProject
        ),
        .init(
            name: "new_project",
            summary: "Create a project from the new-document template as a .horizontal package and open it.",
            params: ["path": "Where to write the package; must end in .horizontal.", "name": "Project name (optional)."],
            handler: newProject
        ),
        .init(
            name: "save",
            summary: "Write an open document to its file, the way the Save command does. An edit through the live channel is one undoable step in the app and nothing more until this runs. A disk context is already written, and says so.",
            params: ["handle": "Project handle."],
            handler: save
        ),
        .init(name: "close_project", summary: "Close an open project.", params: ["handle": "Project handle."], handler: closeProject),
        .init(name: "reload_project", summary: "Re-read an open project from disk.", params: ["handle": "Project handle."], handler: reloadProject),
        .init(name: "list_projects", summary: "The projects currently open in this session.", params: [:], handler: { session, _ in
            session.openEntries.map { projectSummary($0) }
        }),
        .init(name: "project_info", summary: "Summary of an open project: blocks, sheets, counts, diagnostics.", params: ["handle": "Project handle."], handler: { session, params in
            projectSummary(try session.entry(for: params))
        }),
        .init(name: "project_files", summary: "The files that make up the project on disk.", params: ["handle": "Project handle."], handler: projectFiles),
        .init(name: "list_sheets", summary: "Schematic sheets in page order.", params: ["handle": "Project handle."], handler: { session, params in
            try session.entry(for: params).index.sheets.map(sheetJSON)
        }),
        .init(
            name: "list_components",
            summary: "Every component with part, value, and placement summary.",
            params: ["handle": "Project handle.", "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: listComponents
        ),
        .init(
            name: "get_component",
            summary: "One component in full: pins with their nets, symbol placements, board placement.",
            params: ["handle": "Project handle.", "refdes": "Reference designator, e.g. U1.", "id": "Component uuid (alternative to refdes)."],
            handler: getComponent
        ),
        .init(name: "list_nets", summary: "Every net with class, flags, and pin count.", params: ["handle": "Project handle."], handler: { session, params in
            let entry = try session.entry(for: params)
            return entry.index.sortedNets.map { netJSON($0, entry: entry, full: false) }
        }),
        .init(
            name: "get_net",
            summary: "One net in full: its pins and board routing counts.",
            params: ["handle": "Project handle.", "name": "Net name.", "id": "Net uuid (alternative to name)."],
            handler: getNet
        ),
        .init(
            name: "netlist",
            summary: "The whole netlist: every net with its pins, plus unconnected pins.",
            params: ["handle": "Project handle.", "include_unconnected": "Include pins with no net (default false)."],
            handler: netlist
        ),
        .init(
            name: "bom",
            summary: "Bill of materials grouped by part, the way the BOM exporter groups it.",
            params: ["handle": "Project handle.", "include_no_populate": "Include do-not-populate parts (default true)."],
            handler: bom
        ),
        .init(
            name: "list_parts",
            summary: "Parts the project can use. By default only the project pool — the self-contained cache beside the project; scope \"pools\" or \"all\" also lists the base pools it draws from, which have to be imported before use.",
            params: ["handle": "Project handle.", "scope": "project (default), pools, or all."],
            handler: listParts
        ),
        .init(
            name: "search_pool",
            summary: "Search every pool the project draws from — its own pool, the pools that pool includes, and the discovered base pools — for parts, entities, symbols, packages, padstacks, units, frames and decals. Items outside the project pool need import_pool_part before a component can use them.",
            params: ["handle": "Project handle.", "query": "Case-insensitive substring of name, description, manufacturer, tags or uuid (optional).",
                     "kind": "One of \(HorizontalPoolItemCategory.allCases.map(\.rawValue).joined(separator: ", ")) (optional).",
                     "pool_path": "Directory of one pool to search (optional). A pool the project already draws from narrows the search; any other pool directory is searched as well, which is how a worker process reaches a pool registered only in the app.",
                     "limit": "Maximum items to return; default 50, maximum 500."],
            handler: HorizontalDispatchPool.search
        ),
        .init(
            name: "get_pool_item",
            summary: "One pool item's own JSON — the bytes pool_write takes back. A project-pool item is read through the project, so an unsaved change to it is what comes back.",
            params: ["handle": "Project handle.", "uuid": "The item's uuid, from search_pool.",
                     "kind": "Item kind, when one uuid is used by more than one (optional).",
                     "pool_path": "Directory of the pool to read from (optional)."],
            handler: HorizontalDispatchPool.getItem
        ),
        .init(
            name: "import_pool_part",
            summary: "Copy a part and everything it needs — entity, units, symbols, package, padstacks and 3D models — from a base pool into the project pool cache, the way placing it from the library does, so ensure_component can name it. One transaction; a live document takes it as one undoable step.",
            params: ["handle": "Project handle.", "part": "Pool part uuid, or MPN when it is unambiguous.",
                     "pool_path": "Directory of the pool to take it from (optional; needed when the pool is not discovered).",
                     "expected_revision": "The revision this edit was planned against.", "operation_id": "Caller-chosen id for this mutation.",
                     "dry_run": "Report the files it would add without writing (default false)."],
            handler: HorizontalDispatchPool.importPart
        ),
        .init(
            name: "list_symbols",
            summary: "Symbol instances on the schematic sheets: which component and gate each draws, where, and the instance id place_symbol and draw_net_line refer to.",
            params: ["handle": "Project handle.", "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: listSymbols
        ),
        .init(
            name: "list_net_lines",
            summary: "The wires drawn on the schematic sheets, with the ids and endpoints they connect. An endpoint is a symbol pin, a junction, a bus ripper or a block port; the pin ones name the component and gate.",
            params: ["handle": "Project handle.", "net": "Only wires on this net, by name or id (optional).",
                     "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: listNetLines
        ),
        .init(
            name: "list_block_instances",
            summary: "The blocks this block uses: each instance, the block it stands for, its reference designator, which ports are wired, and where its symbol is drawn.",
            params: ["handle": "Project handle."],
            handler: listBlockInstances
        ),
        .init(
            name: "list_net_labels",
            summary: "Net labels on the schematic sheets: which net each names, where it sits, and the id remove_net_label takes.",
            params: ["handle": "Project handle.", "net": "Only labels for this net, by name or id (optional).",
                     "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: { session, params in try listSheetMarks(session, params, key: "net_labels", netKey: "last_net") }
        ),
        .init(
            name: "list_power_symbols",
            summary: "Power symbols on the schematic sheets, with the net each marks and the id remove_power_symbol takes. The symbol's shape comes from the net's power_symbol_style.",
            params: ["handle": "Project handle.", "net": "Only symbols for this net, by name or id (optional).",
                     "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: { session, params in try listSheetMarks(session, params, key: "power_symbols", netKey: "net") }
        ),
        .init(
            name: "list_planes",
            summary: "Copper pours on the board: the net each carries, its layer, priority, and whether it has been filled. A plane defined but never poured shows its outline and no copper.",
            params: ["handle": "Project handle.", "net": "Only planes on this net, by name or id (optional)."],
            handler: listPlanes
        ),
        .init(
            name: "list_polygons",
            summary: "Board polygons, with the layer each is on and the id the polygon ops take. Layer 100 is the board outline. A polygon a plane pours into names that plane.",
            params: ["handle": "Project handle.", "layer": "Only polygons on this layer (optional)."],
            handler: listPolygons
        ),
        .init(
            name: "autoroute",
            summary: "Try to route a net's airwires automatically, on one layer. Best effort and usually not enough: on a dense board it completes a small minority, because it walks around one obstacle at a time rather than searching. What it does complete is checked clear before it is written; what it cannot is reported and left as an airwire for place_track.",
            params: ["handle": "Project handle.", "net": "Net name or id to route.",
                     "layer": "Copper layer number (optional; default 0, the top).",
                     "width_mm": "Track width (optional; the net class's track_width rule, else required).",
                     "max_routes": "Stop after this many airwires; default 20, maximum 200.",
                     "expected_revision": "The revision this was planned against.",
                     "operation_id": "Caller-chosen id for this mutation.", "dry_run": "Report without writing (default false)."],
            handler: autoroute
        ),
        .init(
            name: "pour_planes",
            summary: "Fill every plane on the board, the way Update All Planes does. Planes are defined by place_plane and stay empty until this runs; it recomputes them all from the board as it now stands.",
            params: ["handle": "Project handle.", "expected_revision": "The revision this was planned against.",
                     "operation_id": "Caller-chosen id for this mutation.", "dry_run": "Report without writing (default false)."],
            handler: pourPlanes
        ),
        .init(
            name: "list_tracks",
            summary: "Copper tracks on the board, with the net, layer, width and what each end lands on. Boards carry thousands, so filter by net or layer; the result says whether it was truncated.",
            params: ["handle": "Project handle.", "net": "Only tracks on this net, by name or id (optional).",
                     "layer": "Only tracks on this layer number (optional).", "limit": "Maximum tracks to return; default 200, maximum 5000."],
            handler: listTracks
        ),
        .init(
            name: "list_vias",
            summary: "Vias on the board, with the net, position, the layers each spans and the padstack or via definition it takes its shape from.",
            params: ["handle": "Project handle.", "net": "Only vias on this net, by name or id (optional).",
                     "limit": "Maximum vias to return; default 200, maximum 5000."],
            handler: listVias
        ),
        .init(
            name: "list_texts",
            summary: "Free text on the schematic sheets, with the ids place_text and remove_text take. A text a symbol carries is marked from_smash and belongs to that symbol.",
            params: ["handle": "Project handle.", "sheet": "Optional sheet index.", "sheet_id": "Sheet UUID.", "name": "Sheet name.", "block_id": "Block UUID to disambiguate a sheet."],
            handler: listTexts
        ),
        .init(
            name: "board_rules",
            summary: "The board's design rules as data, with the net classes they select and the stackup they apply to. Clearances, track widths, via and plane rules — what a route has to respect, and what check validates.",
            params: ["handle": "Project handle.", "kind": "Only rules of this kind, e.g. track_width or clearance_copper (optional)."],
            handler: boardRules
        ),
        .init(name: "board_info", summary: "Board size, stackup, layers, and object counts.", params: ["handle": "Project handle."], handler: boardInfo),
        .init(
            name: "recompute_connectivity",
            summary: "Re-derive track and via nets from pad connectivity and regenerate the rats' nest, as the editor does after an edit. In memory only; returns before/after counts.",
            params: ["handle": "Project handle."],
            handler: recomputeConnectivity
        ),
        .init(
            name: "check",
            summary: "Run the checks Horizontal has: load diagnostics, rules validation, annotation, single-pin nets, unplaced parts, unrouted connections.",
            params: ["handle": "Project handle."],
            handler: { session, params in HorizontalDispatchChecks.run(entry: try session.entry(for: params)) }
        ),
        .init(
            name: "pool_write",
            summary: "Write pool items (unit, entity, symbol, part, package, padstack) into the project pool cache and reload. Items already present with the same bytes are skipped. A live document takes them as one undoable step.",
            params: ["handle": "Project handle.", "items": "Array of pool item objects, each with \"type\" and \"uuid\".",
                     "dry_run": "Report the files it would write without writing (default false)."],
            handler: poolWrite
        ),
        .init(
            name: "list_ops",
            summary: "The edit operations `apply` accepts, with their parameters.",
            params: [:],
            handler: { _, _ in
                HorizontalEditOperationKind.allCases.map { ["op": $0.rawValue, "summary": $0.summary, "params": $0.params] }
            }
        ),
        .init(
            name: "apply",
            summary: "Apply edit operations to the project files and reload. Components and nets may be named by refdes or net name. Writes only the files that changed; dry_run reports without writing.",
            params: [
                "handle": "Project handle.",
                "ops": "Array of operations, each {\"op\": name, ...params}; see list_ops.",
                "block": "Block uuid or name to edit (optional; default the top block). A sub-block has no board, so board operations are refused for one.",
                "pool_items": "Pool items to install in the same transaction.",
                "dry_run": "Validate and report without writing (default false)."
            ],
            handler: applyOperations
        ),
        .init(
            name: "live_state",
            summary: "Documents open in Horizontal and their selection and highlight, with handles. Only answered by the app's live channel.",
            params: [:],
            handler: liveState
        ),
        .init(
            name: "select",
            summary: "Select components and nets in the app (by refdes and net name); empty lists clear. Live channel only.",
            params: ["handle": "Live project handle.", "components": "Reference designators.", "nets": "Net names."],
            handler: { session, params in try liveSelection(session, params, highlight: false) }
        ),
        .init(
            name: "highlight",
            summary: "Highlight components and nets in the app's canvases; empty lists clear the highlight. Live channel only.",
            params: ["handle": "Live project handle.", "components": "Reference designators.", "nets": "Net names."],
            handler: { session, params in try liveSelection(session, params, highlight: true) }
        ),
        .init(
            name: "export",
            summary: "Run the app's exporters. Sections: schematic_pdf, bom, gerber, odb, pick_and_place, board_step, board_drawing, board_dxf.",
            params: [
                "handle": "Project handle.",
                "sections": "Array of section names.",
                "target_directory": "Output directory; absolute, or relative to the project's parent. Defaults to the app's export folder next to the project.",
                "options": "Optional overrides, e.g. {\"bom\": {\"include_no_populate\": false}, \"board_step\": {\"include_3d_models\": false}}."
            ],
            handler: export
        ),
        .init(
            name: "render_sheet",
            summary: "Render a schematic sheet to PNG, whole or a region of it.",
            params: [
                "handle": "Project handle.",
                "sheet": "Sheet index (default: first sheet).",
                "name": "Sheet name (alternative to sheet).",
                "sheet_id": "Sheet id (alternative to sheet).",
                "block_id": "Block UUID to disambiguate a sheet.",
                "region": "Optional {min_x_mm, min_y_mm, max_x_mm, max_y_mm} to render only that part of the sheet.",
                "dpi": "Resolution (default 150).",
                "max_pixels": "Cap on the longer side (default 4096).",
                "output_path": "Write the PNG here instead of returning it base64-encoded."
            ],
            handler: renderSheet
        ),
        .init(
            name: "render_board",
            summary: "Render the board drawing to PNG, whole or a region of it.",
            params: [
                "handle": "Project handle.",
                "layers": "Layer names or numbers to include (default: the exporter's defaults). Use board_info to list them.",
                "mirrored": "View from the bottom (default false).",
                "region": "Optional {min_x_mm, min_y_mm, max_x_mm, max_y_mm} to render only that part of the board.",
                "dpi": "Resolution (default 150).",
                "max_pixels": "Cap on the longer side (default 4096).",
                "output_path": "Write the PNG here instead of returning it base64-encoded."
            ],
            handler: renderBoard
        ),
        .init(
            name: "zoom_to",
            summary: "Frame a component or net in the app's board or schematic pane. Live channel only.",
            params: [
                "handle": "Live project handle.",
                "refdes": "Component to frame.",
                "net": "Net to frame (alternative to refdes).",
                "pane": "board or schematic (default: board when the component is placed there, else schematic).",
                "margin_mm": "Space around the target (default 3)."
            ],
            handler: zoomTo
        ),
        .init(
            name: "render_viewport",
            summary: "Render what a pane of the app currently shows, in the exporter's drawing style. Live channel only.",
            params: [
                "handle": "Live project handle.",
                "pane": "board or schematic (default board).",
                "dpi": "Resolution (default 150).",
                "max_pixels": "Cap on the longer side (default 4096).",
                "output_path": "Write the PNG here instead of returning it base64-encoded."
            ],
            handler: renderViewport
        ),
        .init(
            name: "list_groups",
            summary: "Horizon groups (instances of a sub-circuit) with their members by tag and whether each is placed on the board.",
            params: ["handle": "Project handle."],
            handler: listGroups
        ),
        .init(name: "analysis_snapshot", summary: "Immutable electrical input with schematic evidence and file hashes.", params: ["handle": "Project handle."], handler: analysisSnapshot),
        .init(name: "freeze_project", summary: "Pin a read-only snapshot for repeated analysis and renders. Close it when finished.", params: ["handle": "Project handle."], handler: { session, params in projectSummary(try session.freeze(session.entry(for: params))) }),
        .init(name: "transaction_status", summary: "Look up a mutation receipt without replaying it.", params: ["handle": "Project handle.", "operation_id": "Mutation identifier."], handler: transactionStatus)
    ]

    // MARK: - Handlers

    @Sendable private static func analysisSnapshot(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let snapshot = entry.snapshot else { throw HorizontalDispatchError.failed("No snapshot.") }
        let components = try entry.index.sortedComponents.map { component -> Any in
            var json = try getComponent(session, ["handle": entry.handle, "id": component.id]) as! JSONDictionary
            let block = entry.project.blocks.first { $0.uuid == component.blockID }
            json["evidence"] = ["file": block?.blockFilename as Any,
                                "json_pointer": "/components/\(component.id)",
                                "snapshot_id": snapshot.id, "symbols": json["symbols"] ?? []]
            return json
        }
        let hashes = Dictionary(uniqueKeysWithValues: snapshot.files.map { path in
            (path, HorizontalProjectTransaction.digest(snapshot.archive.regularFileData(relativePath: path) ?? Data()))
        })
        return ["schema_version": 1, "meta": entry.metadata, "project": projectSummary(entry),
                "components": components, "nets": entry.index.sortedNets.map { netJSON($0, entry: entry, full: true) },
                "file_hashes": hashes, "hierarchy_supported": entry.project.blocks.count <= 1,
                "symbolic_links": snapshot.archive.symbolicLinkCount] as JSONDictionary
    }

    @Sendable private static func transactionStatus(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let id = params.string("operation_id"), !id.isEmpty else { throw HorizontalDispatchError.invalidParams("operation_id is required.") }
        if entry.live != nil { return entry.receipts[id] ?? ["operation_id": id, "status": "unknown", "instance_id": entry.instanceID] }
        guard let transaction = try HorizontalProjectTransaction.existing(projectURL: entry.url) else { return ["operation_id": id, "status": "unknown"] }
        try transaction.recover()
        if let data = try transaction.receipt(operationID: id) { return try JSONHelper.loadDictionary(from: data) }
        return ["operation_id": id, "status": "unknown"]
    }

    private static func version() -> Any {
        var result: JSONDictionary = ["api": HorizontalDispatch.apiVersion, "module": "HorizontalNative", "capabilities": ["source_snapshots", "revision_checked_edits", "transactions", "electrical_snapshot", "typed_errors"], "instance_id": HorizontalDispatchSession.shared.serverID]
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            result["host_version"] = version
        }
        if let identifier = Bundle.main.bundleIdentifier {
            result["host"] = identifier
        }
        return result
    }

    @Sendable private static func openProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        guard let path = params.string("path"), !path.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"path\".")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HorizontalDispatchError.notFound("Nothing at \(url.path).")
        }
        if let live = session.liveEntry(for: url) {
            return projectSummary(live)
        }
        return projectSummary(try session.open(url: url))
    }

    @Sendable private static func newProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        guard let path = params.string("path"), !path.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Missing \"path\".")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame else {
            throw HorizontalDispatchError.invalidParams("A new project is a .horizontal package; \(url.lastPathComponent) is not.")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw HorizontalDispatchError.invalidParams("\(url.path) already exists.")
        }
        let name = params.string("name") ?? url.deletingPathExtension().lastPathComponent
        try HorizontalProjectArchive.newProject(named: name).write(to: url)
        return projectSummary(try session.open(url: url))
    }

    @Sendable private static func poolWrite(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let items = params["items"] as? [Any], !items.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"items\", a non-empty array of pool item objects.")
        }
        let targets = try poolTargets(items, entry: entry)
        defer {
            HorizontalPoolLibrary.invalidateCache()
            HorizontalPoolPadstacks.invalidateCaches()
        }
        return try HorizontalDispatchMutation.execute(session: session, entry: entry, params: params) { store in
            let written = try writePoolItems(targets, to: store)
            return ["written": written, "skipped": targets.count - written.count, "applied": written.count]
        }
    }

    private static func poolTargets(_ items: [Any], entry: HorizontalDispatchProjectEntry) throws -> [(URL, Data)] {
        guard let poolDirectory = entry.project.poolDirectory else {
            throw HorizontalDispatchError.failed("The project has no pool directory.")
        }
        var targets = [(URL, Data)]()
        for (index, raw) in items.enumerated() {
            guard let json = raw as? JSONDictionary else {
                throw HorizontalDispatchError.invalidParams("Item \(index) is not an object.")
            }
            guard let type = json.string("type"), let category = HorizontalPoolItemCategory(rawValue: type) else {
                throw HorizontalDispatchError.invalidParams("Item \(index) has no pool item \"type\".")
            }
            guard let uuid = json.string("uuid")?.lowercased(), UUID(uuidString: uuid) != nil else {
                throw HorizontalDispatchError.invalidParams("Item \(index) has no \"uuid\".")
            }
            do { _ = try HorizontalPoolItemModel.load(category: category, json: json) }
            catch { throw HorizontalDispatchError.invalidParams("Invalid pool item \(index): \(error.localizedDescription)") }
            let directory = entry.project.baseURL
                .appendingPathComponent(poolDirectory)
                .appendingPathComponent(HorizontalPoolItemFactory.directoryName(for: category))
                .appendingPathComponent("cache")
            let url = category == .package
                ? directory.appendingPathComponent(uuid).appendingPathComponent("package.json")
                : directory.appendingPathComponent("\(uuid).json")
            guard !targets.contains(where: { $0.0 == url }) else { throw HorizontalDispatchError.invalidParams("Duplicate pool item target \(uuid).") }
            targets.append((url, try HorizontalHorizonJSONWriter.data(json)))
        }

        return targets
    }

    private static func writePoolItems(_ targets: [(URL, Data)], to store: HorizontalProjectFileStore) throws -> [String] {
        var written = [String]()
        for (url, data) in targets {
            if let existing = try store.read(url), existing == data {
                continue
            }
            if store is HorizontalDiskFileStore {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try store.write(data, to: url)
            written.append(url.path)
        }
        return written
    }

    @Sendable private static func save(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard !entry.frozen else {
            throw HorizontalDispatchError(code: .readOnly, message: "A pinned snapshot has no document to save.")
        }
        guard let live = entry.live else {
            // Nothing to do rather than an error: a disk edit committed its
            // files as part of the transaction that made it. Named distinctly
            // from the live answer, so "nothing was saved" can never be read as
            // "the document was saved".
            return ["saved": false, "source": "disk", "path": entry.url.path,
                    "note": "This is a disk context: its edits were written when they committed. "
                        + "A document open in the app is a different context — open it with source \"live\" to save that."]
        }
        guard Thread.isMainThread else {
            throw HorizontalDispatchError.failed("Saving a document requires the app channel.")
        }
        let edited: Bool = try MainActor.assumeIsolated {
            guard !live.isReadOnly() else {
                throw HorizontalDispatchError(code: .readOnly, message: "The document is read-only.")
            }
            let edited = live.isEdited()
            try live.save()
            return edited
        }
        // Trusting the document's edited flag is what let a save report success
        // over a stale file: the flag was false because the edit had gone onto
        // an undo manager the document system never saw. So the answer is
        // checked against the file rather than asserted — what is on disk must
        // be what the document holds.
        let onDisk = try HorizontalDispatchSnapshot.capture(url: entry.url)
        let matches = onDisk.id == entry.snapshot?.id
        guard matches else {
            throw HorizontalDispatchError(
                code: .applicationError,
                message: "The document was asked to save and the file still does not match it. "
                    + "Nothing here can force it; save in Horizontal, or report this.",
                details: ["document_snapshot": entry.snapshot?.id ?? "", "file_snapshot": onDisk.id]
            )
        }
        return ["saved": edited, "had_unsaved_changes": edited, "source": "live",
                "path": entry.url.path, "verified": true,
                "snapshot_id": onDisk.id, "revision": entry.revision] as JSONDictionary
    }

    @Sendable private static func closeProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard session.close(handle: entry.handle) else { throw HorizontalDispatchError.invalidParams("A live document belongs to the app; release the client context instead.") }
        return ["closed": entry.handle]
    }

    @Sendable private static func reloadProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        return projectSummary(try session.reload(handle: entry.handle))
    }

    @Sendable private static func projectFiles(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let snapshot = entry.snapshot else { throw HorizontalDispatchError.failed("No snapshot.") }
        return [
            "base": entry.project.baseURL.path,
            "project_file": entry.project.projectFileURL.path,
            "files": snapshot.files,
            "pool_directory": entry.project.poolDirectory as Any,
            "snapshot_id": snapshot.id
        ]
    }

    @Sendable private static func listComponents(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        var components = entry.index.sortedComponents
        if let sheet = try HorizontalDispatchValidation.sheet(params, index: entry.index) {
            components = components.filter { component in
                component.symbolPlacements.contains { $0.sheetID == sheet.id && $0.blockID == sheet.blockID }
            }
        }
        return components.map { componentJSON($0, full: false) }
    }

    @Sendable private static func getComponent(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let component: HorizontalDesignComponent?
        if let refdes = params.string("refdes") {
            let candidates = entry.index.sortedComponents.filter { $0.refdes.caseInsensitiveCompare(refdes) == .orderedSame }
            if candidates.count > 1 { throw HorizontalDispatchError.ambiguous("Component name is ambiguous; use id.", candidates: candidates.map(\.id)) }
            component = entry.index.component(refdes: refdes)
        } else if let id = params.string("id") {
            component = entry.index.component(id: id)
        } else {
            throw HorizontalDispatchError.invalidParams("Pass \"refdes\" or \"id\".")
        }
        guard let component else {
            throw HorizontalDispatchError.notFound("No such component.")
        }
        var json = componentJSON(component, full: true, index: entry.index)
        json["pins"] = component.pins.map { pin -> JSONDictionary in
            var pinJSON: JSONDictionary = [
                "gate": pin.gateName,
                "gate_suffix": pin.gateSuffix,
                "pin": pin.pinName,
                "direction": pin.direction,
                "gate_pin_path": pin.gatePinPath
            ]
            pinJSON["gate_id"] = pin.gateID
            pinJSON["pin_id"] = pin.pinID
            pinJSON["connection_state"] = pin.connectionState
            pinJSON["physical_pads"] = pin.physicalPads.map { ["id": $0.id, "name": $0.name] }
            pinJSON["mapping_status"] = pin.physicalPads.isEmpty ? "unresolved" : "resolved"
            if let netID = pin.netID {
                pinJSON["net_id"] = netID
                pinJSON["net"] = entry.index.net(id: netID)?.name ?? ""
            } else {
                pinJSON["net"] = NSNull()
            }
            return pinJSON
        }
        return json
    }

    @Sendable private static func getNet(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let net: HorizontalDesignNet?
        if let name = params.string("name") {
            let candidates = entry.index.sortedNets.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if candidates.count > 1 { throw HorizontalDispatchError.ambiguous("Net name is ambiguous; use id.", candidates: candidates.map(\.id)) }
            net = entry.index.net(named: name)
        } else if let id = params.string("id") {
            net = entry.index.net(id: id)
        } else {
            throw HorizontalDispatchError.invalidParams("Pass \"name\" or \"id\".")
        }
        guard let net else {
            throw HorizontalDispatchError.notFound("No such net.")
        }
        return netJSON(net, entry: entry, full: true)
    }

    @Sendable private static func netlist(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let index = entry.index
        var result: JSONDictionary = [
            "nets": index.sortedNets.map { netJSON($0, entry: entry, full: true) },
            "component_count": index.components.count,
            "net_count": index.nets.count
        ]
        if params.bool("include_unconnected") ?? false {
            result["unconnected_pins"] = index.sortedComponents.flatMap { component in
                component.pins.filter { $0.netID == nil }.map { pin -> JSONDictionary in
                    ["refdes": component.refdes, "pin": pin.pinName, "gate_suffix": pin.gateSuffix, "direction": pin.direction]
                }
            }
        }
        return result
    }

    @Sendable private static func bom(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let includeNoPopulate = params.bool("include_no_populate") ?? true
        struct Key: Hashable {
            var mpn: String
            var value: String
            var manufacturer: String
            var package: String
            var description: String
            var datasheet: String
        }
        var groups = [Key: [String]]()
        var noPopulate = [Key: Bool]()
        for component in entry.index.sortedComponents {
            guard includeNoPopulate || !component.noPopulate else {
                continue
            }
            let details = component.details
            let key = Key(
                mpn: nonEmpty(details?.mpn) ?? nonEmpty(component.partID) ?? "",
                value: nonEmpty(component.value) ?? nonEmpty(details?.value) ?? "",
                manufacturer: nonEmpty(details?.manufacturer) ?? "",
                package: nonEmpty(details?.packageName) ?? "",
                description: nonEmpty(details?.description) ?? "",
                datasheet: nonEmpty(details?.datasheet) ?? ""
            )
            groups[key, default: []].append(component.refdes)
            noPopulate[key] = (noPopulate[key] ?? true) && component.noPopulate
        }
        let rows = groups.map { key, refdes -> JSONDictionary in
            let sorted = refdes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return [
                "mpn": key.mpn,
                "value": key.value,
                "manufacturer": key.manufacturer,
                "package": key.package,
                "description": key.description,
                "datasheet": key.datasheet,
                "quantity": sorted.count,
                "refdes": sorted,
                "no_populate": noPopulate[key] ?? false
            ]
        }
        .sorted { lhs, rhs in
            let left = (lhs["refdes"] as? [String])?.first ?? ""
            let right = (rhs["refdes"] as? [String])?.first ?? ""
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return ["rows": rows, "line_count": rows.count, "component_count": rows.reduce(0) { $0 + (($1["quantity"] as? Int) ?? 0) }]
    }

    /// The top block as it stands in the selected source.
    private static func blockJSON(_ entry: HorizontalDispatchProjectEntry) -> JSONDictionary? {
        let filename = entry.project.blocks.first(where: \.isTop)?.blockFilename ?? entry.project.blockFilename
        guard let filename, !filename.isEmpty else { return nil }
        let url = entry.project.baseURL.appendingPathComponent(filename)
        return entry.snapshot?.json(at: url) ?? (try? JSONHelper.loadDictionary(from: url))
    }

    /// The block's net classes, by id.
    private static func netClasses(_ entry: HorizontalDispatchProjectEntry) -> [String: String] {
        guard let block = blockJSON(entry) else { return [:] }
        return block.dictionaryMap("net_classes").reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value.string("name") ?? ""
        }
    }

    @Sendable private static func boardRules(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        let json = try boardJSON(entry)
        let classes = netClasses(entry)
        let kind = params.string("kind")
        // Rules are handed over as the file states them. There are twenty kinds
        // with twenty shapes, and inventing a normalized form for each would
        // lose the detail a router or a review actually needs.
        let rules = json.dictionaryMap("rules").compactMap { id, item -> JSONDictionary? in
            let ruleKind = item.string("rule") ?? id
            guard kind == nil || kind == ruleKind else { return nil }
            var entryJSON: JSONDictionary = ["id": id, "kind": ruleKind, "rule": item]
            if let match = item.dictionary("match") {
                let mode = match.string("mode") ?? "all"
                entryJSON["applies_to"] = mode == "all"
                    ? "every net"
                    : (mode == "net_class" ? "net class \(match.string("net_class").flatMap { classes[$0.lowercased()] } ?? "?")" : mode)
            }
            entryJSON["enabled"] = item.bool("enabled") ?? true
            return entryJSON
        }.sorted { ($0.string("kind") ?? "", $0.string("id") ?? "") < ($1.string("kind") ?? "", $1.string("id") ?? "") }

        let stackup: [JSONDictionary] = board.stackupLayers.map { layer in
            ["layer": layer.layer, "name": HorizontalBoardLayers.name(for: layer.layer)]
        }
        return [
            "rules": rules,
            "kinds": Array(Set(json.dictionaryMap("rules").values.compactMap { $0.string("rule") })).sorted(),
            "net_classes": classes.map { ["id": $0.key, "name": $0.value] as JSONDictionary }
                .sorted { ($0.string("name") ?? "") < ($1.string("name") ?? "") },
            "stackup": stackup,
            "note": rules.isEmpty
                ? "This board declares no rules, so nothing here constrains a route. Horizon falls back to its own defaults."
                : "Rules are given as the file states them; check validates them."
        ] as JSONDictionary
    }

    @Sendable private static func boardInfo(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        let netsWithAirwires = Set(board.airwires.compactMap { $0.netID?.lowercased() }).count
        let stackup: [JSONDictionary] = board.stackupLayers.map { layer in
            ["layer": layer.layer, "name": HorizontalBoardLayers.name(for: layer.layer)]
        }
        let userLayers: [JSONDictionary] = board.userLayers.map { layer in
            ["layer": layer.id, "name": layer.name]
        }
        var netClasses = [String: Int]()
        for net in entry.index.nets.values {
            netClasses[net.netClassName ?? "", default: 0] += 1
        }
        var counts: JSONDictionary = [:]
        counts["packages"] = board.packages.count
        counts["unplaced"] = board.unplacedObjects.count
        counts["tracks"] = board.tracks.count
        counts["vias"] = board.vias.count
        counts["airwires"] = board.airwires.count
        counts["nets_with_airwires"] = netsWithAirwires
        counts["planes"] = board.planes.count
        counts["polygons"] = board.polygons.count
        counts["holes"] = board.holes.count
        counts["keepouts"] = board.keepouts.count
        counts["dimensions"] = board.dimensions.count
        counts["texts"] = board.texts.count
        var json: JSONDictionary = [:]
        json["file"] = board.url.path
        json["bounds"] = HorizontalDispatchJSON.rect(board.physicalBounds)
        json["stackup"] = stackup
        json["user_layers"] = userLayers
        json["drawing_layers"] = HorizontalDispatchRender.boardDrawingLayers(project: entry.project)
        json["net_classes"] = netClasses
        json["counts"] = counts
        return json
    }

    @Sendable private static func recomputeConnectivity(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        try entry.requireRevision(params)
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        let before: JSONDictionary = [
            "airwires": board.airwires.count,
            "tracks_without_net": board.tracks.filter { $0.netID == nil }.count,
            "vias_without_net": board.vias.filter { $0.netID == nil }.count
        ]
        var resolved = HorizontalBoardConnectivity.recompute(board)
        resolved.regenerateAirwires()
        entry.project.board = resolved
        entry.generation += 1
        entry.invalidateIndex()
        let after: JSONDictionary = [
            "airwires": resolved.airwires.count,
            "tracks_without_net": resolved.tracks.filter { $0.netID == nil }.count,
            "vias_without_net": resolved.vias.filter { $0.netID == nil }.count
        ]
        return ["before": before, "after": after]
    }

    @Sendable private static func applyOperations(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let rawOps = params["ops"] as? [Any], !rawOps.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"ops\", a non-empty array of operations.")
        }
        let operations = try rawOps.enumerated().map { index, raw -> HorizontalEditOperation in
            guard let json = raw as? JSONDictionary else {
                throw HorizontalDispatchError.invalidParams("Operation \(index) is not an object.")
            }
            return try HorizontalEditOperation(json: json)
        }
        return try HorizontalDispatchMutation.execute(session: session, entry: entry, params: params) { store in
            if let items = params["pool_items"] as? [JSONDictionary] {
                _ = try writePoolItems(poolTargets(items, entry: entry), to: store)
            }
            let snapshot = HorizontalDispatchSnapshot(archive: store.archive, baseURL: entry.project.baseURL)
            let project = params["pool_items"] == nil ? entry.project : try HorizontalDispatchSession.project(from: snapshot, url: entry.url)
            let editor = try HorizontalProjectEditor(project: project, store: store, snapshot: snapshot,
                                                     block: params.string("block"))
            try editor.apply(operations)
            _ = try editor.write()
            let normalized = zip(operations, editor.changes).map { operation, change -> JSONDictionary in
                var json = operation.params
                if operation.kind == .ensureComponent { json["id"] = change["component"] }
                if operation.kind == .ensureNet { json["id"] = change["net"] }
                return json
            }
            return ["applied": editor.changes.count, "changes": editor.changes, "normalized_ops": normalized,
                    "block": editor.blockID, "is_top_block": editor.isTopBlock]
        }
    }

    private static func liveDocument(_ entry: HorizontalDispatchProjectEntry) throws -> HorizontalLiveDocument {
        guard let live = entry.live else {
            throw HorizontalDispatchError.invalidParams("Handle \(entry.handle) is not a document open in Horizontal.")
        }
        guard Thread.isMainThread else {
            throw HorizontalDispatchError.failed("Live documents are only reachable through the app's live channel.")
        }
        return live
    }

    @Sendable private static func liveState(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        guard Thread.isMainThread else {
            throw HorizontalDispatchError.failed("live_state is only answered by the app's live channel.")
        }
        let output = HorizontalUnsafeSendableBox<[JSONDictionary]>([])
        MainActor.assumeIsolated {
            session.syncLiveEntries()
            output.value = session.openEntries.compactMap { entry -> JSONDictionary? in
                guard let live = entry.live else {
                    return nil
                }
                var json = projectSummary(entry)
                json["live"] = true
                json["read_only"] = live.isReadOnly()
                json["selection"] = selectionJSON(live.selection(), entry: entry)
                return json
            }
        }
        return output.value
    }

    @Sendable private static func liveSelection(_ session: HorizontalDispatchSession, _ params: JSONDictionary, highlight: Bool) throws -> Any {
        let entry = try session.entry(for: params)
        let live = try liveDocument(entry)
        let index = entry.index
        var componentIDs = Set<String>()
        for refdes in (params["components"] as? [Any])?.map({ "\($0)" }) ?? [] {
            let component = try HorizontalDispatchValidation.component(refdes, index: index)
            componentIDs.insert(component.id)
        }
        var netIDs = Set<String>()
        for name in (params["nets"] as? [Any])?.map({ "\($0)" }) ?? [] {
            let net = try HorizontalDispatchValidation.net(name, index: index)
            netIDs.insert(net.id)
        }
        let input = HorizontalUnsafeSendableBox(entry)
        let output = HorizontalUnsafeSendableBox<JSONDictionary>([:])
        MainActor.assumeIsolated {
            if highlight {
                live.setHighlight(netIDs, componentIDs)
            } else {
                live.setSelection(netIDs, componentIDs)
            }
            output.value = selectionJSON(live.selection(), entry: input.value)
        }
        return output.value
    }

    private static func selectionJSON(_ selection: HorizontalLiveSelection, entry: HorizontalDispatchProjectEntry) -> JSONDictionary {
        let index = entry.index
        func names(ofNets ids: Set<String>) -> [String] {
            ids.map { index.net(id: $0)?.name ?? $0 }.sorted()
        }
        func refdes(of ids: Set<String>) -> [String] {
            ids.map { index.component(id: $0)?.refdes ?? $0 }.sorted()
        }
        return [
            "components": refdes(of: selection.componentIDs),
            "nets": names(ofNets: selection.netIDs),
            "component_ids": selection.componentIDs.sorted(),
            "net_ids": selection.netIDs.sorted(),
            "highlighted_component_ids": selection.highlightedComponentIDs.sorted(),
            "highlighted_net_ids": selection.highlightedNetIDs.sorted(),
            "highlighted_components": refdes(of: selection.highlightedComponentIDs),
            "highlighted_nets": names(ofNets: selection.highlightedNetIDs),
            "panes": selection.panes.sorted()
        ]
    }

    @Sendable private static func export(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let names = params["sections"] as? [String], !names.isEmpty else {
            throw HorizontalDispatchError.invalidParams("Pass \"sections\", an array of section names.")
        }
        let sections = try names.map(exportSection)
        var settings = HorizontalExportSettings(project: entry.project)
        if let directory = params.string("target_directory"), !directory.isEmpty {
            settings.targetDirectory = directory
        }
        applyExportOptions(params["options"] as? JSONDictionary, to: &settings)
        let targetURL = try HorizontalExportSettings.exportTargetDirectory(for: entry.project, requestedPath: settings.targetDirectory)
        settings.targetDirectory = targetURL.path
        let source = try entry.snapshot?.materializedProject() ?? entry.project
        let status = HorizontalExportBackend.export(sections: sections, settings: settings, project: source)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: targetURL.path))?.sorted() ?? []
        return [
            "status": exportStatusName(status.kind),
            "message": status.message,
            "target_directory": targetURL.path,
            "files": files
        ]
    }

    @Sendable private static func renderSheet(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let selected = try HorizontalDispatchValidation.sheet(params, index: entry.index, defaultFirst: true)
        let project = try entry.snapshot?.materializedProject() ?? entry.project
        let (image, sheet) = try HorizontalDispatchRender.renderSheet(
            project: project,
            sheetIndex: nil,
            sheetName: nil,
            sheetID: selected?.id,
            blockID: selected?.blockID,
            region: try regionParam(params),
            dpi: params.double("dpi") ?? 150,
            maxPixels: params.int("max_pixels") ?? 4096
        )
        var result = imageJSON(image, outputPath: params.string("output_path"))
        result["sheet"] = ["index": sheet.index, "name": sheet.name, "id": sheet.id]
        return result
    }

    @Sendable private static func renderBoard(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let layers = (params["layers"] as? [Any])?.map { "\($0)" }
        let image = try HorizontalDispatchRender.renderBoard(
            project: try entry.snapshot?.materializedProject() ?? entry.project,
            layerNames: layers,
            mirrored: params.bool("mirrored") ?? false,
            region: try regionParam(params),
            dpi: params.double("dpi") ?? 150,
            maxPixels: params.int("max_pixels") ?? 4096
        )
        return imageJSON(image, outputPath: params.string("output_path"))
    }

    /// `region` as {min_x_mm, min_y_mm, max_x_mm, max_y_mm}, in nanometres.
    private static func regionParam(_ params: JSONDictionary) throws -> HorizontalRect? {
        guard let region = params.dictionary("region") else {
            return nil
        }
        guard let minX = region.double("min_x_mm"), let minY = region.double("min_y_mm"),
              let maxX = region.double("max_x_mm"), let maxY = region.double("max_y_mm"), maxX > minX, maxY > minY else {
            throw HorizontalDispatchError.invalidParams("region needs min_x_mm, min_y_mm, max_x_mm, max_y_mm with max above min.")
        }
        let scale: Double = 1_000_000
        let low = HorizontalPoint(x: minX * scale, y: minY * scale)
        let high = HorizontalPoint(x: maxX * scale, y: maxY * scale)
        return HorizontalRect(points: [low, high])
    }

    private static func pane(_ params: JSONDictionary, default defaultPane: HorizontalPane) throws -> HorizontalPane {
        guard let name = params.string("pane") else {
            return defaultPane
        }
        switch name.lowercased() {
        case "board": return .board
        case "schematic": return .schematic
        default: throw HorizontalDispatchError.invalidParams("pane must be board or schematic.")
        }
    }

    /// The rectangle a component or net occupies in a pane, for zoom-to.
    private static func targetRect(_ params: JSONDictionary, entry: HorizontalDispatchProjectEntry) throws -> (rect: HorizontalRect, pane: HorizontalPane, sheetID: String?, blockID: String?, label: String) {
        let index = entry.index
        let margin = (params.double("margin_mm") ?? 3) * 1_000_000
        if let refdes = params.string("refdes") {
            let component = try HorizontalDispatchValidation.component(refdes, index: index)
            let wanted = try pane(params, default: component.boardPlacement != nil ? .board : .schematic)
            if wanted == .board {
                guard let placement = component.boardPlacement, let board = entry.project.board else {
                    throw HorizontalDispatchError.notFound("\(component.refdes) is not placed on the board.")
                }
                // The package's pads on the board, or a box around its origin.
                let packageID: String? = board.packages.first { $0.componentID?.lowercased() == component.id }?.id.lowercased()
                var points: [HorizontalPoint] = []
                if let packageID {
                    let prefix = packageID + "/"
                    for pad in board.packagePads where pad.id.lowercased().hasPrefix(prefix) {
                        points.append(contentsOf: pad.vertices)
                    }
                }
                if points.isEmpty {
                    points = [placement.position]
                }
                var rect = HorizontalRect(points: points)
                if rect.isEmpty {
                    rect = HorizontalRect(center: placement.position, size: 2_000_000)
                }
                return (expand(rect, by: margin), .board, nil, nil, component.refdes)
            }
            guard let symbol = component.symbolPlacements.first else {
                throw HorizontalDispatchError.notFound("\(component.refdes) has no symbol on any sheet.")
            }
            let rect = HorizontalRect(center: symbol.position, size: 20_000_000)
            return (expand(rect, by: margin), .schematic, symbol.sheetID, symbol.blockID, component.refdes)
        }
        if let netName = params.string("net") {
            let net = try HorizontalDispatchValidation.net(netName, index: index)
            let wanted = try pane(params, default: .board)
            if wanted == .board, let board = entry.project.board {
                var points: [HorizontalPoint] = []
                for pad in board.packagePads where pad.netID?.lowercased() == net.id {
                    points.append(contentsOf: pad.vertices)
                }
                for segment in board.tracks where segment.netID?.lowercased() == net.id {
                    points.append(segment.from)
                    points.append(segment.to)
                }
                for segment in board.airwires where segment.netID?.lowercased() == net.id {
                    points.append(segment.from)
                    points.append(segment.to)
                }
                guard let first = points.first else {
                    throw HorizontalDispatchError.notFound("\(net.name) has nothing on the board.")
                }
                var rect = HorizontalRect(points: points)
                if rect.isEmpty {
                    rect = HorizontalRect(center: first, size: 2_000_000)
                }
                return (expand(rect, by: margin), .board, nil, nil, net.name)
            }
            // Schematic: the sheet holding the most of the net's pins.
            var bySheet = [String: [HorizontalPoint]]()
            for pin in net.pins {
                guard let component = index.component(id: pin.componentID) else {
                    continue
                }
                for placement in component.symbolPlacements {
                    bySheet["\(placement.blockID ?? "")/\(placement.sheetID)", default: []].append(placement.position)
                }
            }
            guard let best = bySheet.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }).first, let first = best.value.first else {
                throw HorizontalDispatchError.notFound("\(net.name) has no symbols on any sheet.")
            }
            let points: [HorizontalPoint] = best.value
            let sheet = index.sheets.first { "\($0.blockID ?? "")/\($0.id)" == best.key }
            var rect = HorizontalRect(points: points)
            if rect.isEmpty {
                rect = HorizontalRect(center: first, size: 20_000_000)
            }
            return (expand(rect, by: margin + 10_000_000), .schematic, sheet?.id, sheet?.blockID, net.name)
        }
        throw HorizontalDispatchError.invalidParams("Pass \"refdes\" or \"net\".")
    }

    private static func expand(_ rect: HorizontalRect, by margin: Double) -> HorizontalRect {
        let low = HorizontalPoint(x: rect.minX - margin, y: rect.minY - margin)
        let high = HorizontalPoint(x: rect.maxX + margin, y: rect.maxY + margin)
        return HorizontalRect(points: [low, high])
    }

    @Sendable private static func zoomTo(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let live = try liveDocument(entry)
        let target = try targetRect(params, entry: entry)
        let input = HorizontalUnsafeSendableBox(target)
        let output = HorizontalUnsafeSendableBox<JSONDictionary>([:])
        MainActor.assumeIsolated {
            let target = input.value
            let paneName: String = target.pane == .board ? "board" : "schematic"
            var result: JSONDictionary = [:]
            result["target"] = target.label
            result["pane"] = paneName
            result["region"] = HorizontalDispatchJSON.rect(target.rect)
            if target.pane == .schematic, let sheetID = target.sheetID, live.currentSheet() != sheetID {
                // Showing another sheet swaps the canvas; frame once it is up.
                live.showSheet(target.blockID, sheetID)
                result["sheet_changed"] = true
                let rect = target.rect
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    live.frame(.schematic, rect)
                }
            } else {
                live.frame(target.pane, target.rect)
            }
            output.value = result
        }
        return output.value
    }

    @Sendable private static func renderViewport(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let live = try liveDocument(entry)
        let wanted = try pane(params, default: .board)
        let state = HorizontalUnsafeSendableBox<(HorizontalRect?, String?)>((nil, nil))
        MainActor.assumeIsolated {
            state.value = (live.visibleBounds(wanted), live.currentSheet())
        }
        guard let region = state.value.0, !region.isEmpty else {
            throw HorizontalDispatchError.notFound("The \(wanted == .board ? "board" : "schematic") pane is not showing anything.")
        }
        let dpi = params.double("dpi") ?? 150
        let maxPixels = params.int("max_pixels") ?? 4096
        let project = try entry.snapshot?.materializedProject() ?? entry.project
        var result: JSONDictionary
        if wanted == .board {
            let image = try HorizontalDispatchRender.renderBoard(project: project, layerNames: nil, mirrored: false, region: region, dpi: dpi, maxPixels: maxPixels)
            result = imageJSON(image, outputPath: params.string("output_path"))
        } else {
            let (image, sheet) = try HorizontalDispatchRender.renderSheet(project: project, sheetIndex: nil, sheetName: nil, sheetID: state.value.1, region: region, dpi: dpi, maxPixels: maxPixels)
            result = imageJSON(image, outputPath: params.string("output_path"))
            result["sheet"] = ["index": sheet.index, "name": sheet.name, "id": sheet.id]
        }
        result["region"] = HorizontalDispatchJSON.rect(region)
        result["pane"] = wanted == .board ? "board" : "schematic"
        return result
    }

    @Sendable private static func listGroups(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let index = entry.index
        var members = [String: [JSONDictionary]]()
        for component in index.sortedComponents {
            guard let group = component.group, group != HorizontalProjectEditor.nullUUID else {
                continue
            }
            members[group, default: []].append([
                "refdes": component.refdes,
                "component": component.id,
                "tag": index.tagName(component.tag) ?? "",
                "tag_id": component.tag ?? "",
                "placed": component.boardPlacement != nil,
                "part_id": component.partID ?? ""
            ])
        }
        var groups: [JSONDictionary] = []
        for (id, list) in members {
            let sortedMembers: [JSONDictionary] = list.sorted { lhs, rhs in
                let left = lhs["tag"] as? String ?? ""
                let right = rhs["tag"] as? String ?? ""
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            let placedCount: Int = list.filter { ($0["placed"] as? Bool) == true }.count
            var json: JSONDictionary = [:]
            json["id"] = id
            json["name"] = index.groupName(id) ?? String(id.prefix(8))
            json["members"] = sortedMembers
            json["placed_count"] = placedCount
            groups.append(json)
        }
        return groups.sorted { lhs, rhs in
            let left = lhs["name"] as? String ?? ""
            let right = rhs["name"] as? String ?? ""
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    // MARK: - JSON shapes

    static func projectSummary(_ entry: HorizontalDispatchProjectEntry) -> JSONDictionary {
        let project = entry.project
        let index = entry.index
        let blocks: [JSONDictionary] = project.blocks.map { block in
            var json: JSONDictionary = ["uuid": block.uuid, "name": block.displayName, "is_top": block.isTop]
            json["block_filename"] = block.blockFilename ?? NSNull()
            json["schematic_filename"] = block.schematicFilename ?? NSNull()
            return json
        }
        let sheets: [JSONDictionary] = index.sheets.map(sheetJSON)
        let diagnostics: [String] = project.diagnostics.map(\.message)
        var json: JSONDictionary = [:]
        json["handle"] = entry.handle
        json["path"] = entry.url.path
        json["project_file"] = project.projectFileURL.path
        json["title"] = project.displayTitle
        json["name"] = project.name
        json["project_meta"] = project.projectMeta
        json["blocks"] = blocks
        json["sheets"] = sheets
        json["has_board"] = project.board != nil
        json["component_count"] = index.components.count
        json["net_count"] = index.nets.count
        json["pool_part_count"] = project.poolParts.count
        json["live"] = entry.live != nil || (!entry.frozen && entry.readMetadata?.string("source") == "live")
        // What the file does not have yet. An edit through this channel is one
        // undo step in the app until `save` writes it.
        if let live = entry.live, Thread.isMainThread {
            json["unsaved_changes"] = MainActor.assumeIsolated { live.isEdited() }
        }
        // Who else has the project open. A disk context can only be edited
        // when this is empty, and it is the one answer that does not depend on
        // the live channel being switched on.
        if entry.live == nil, !entry.frozen {
            let holders = HorizontalProjectHolders.others(projectURL: entry.url)
            json["held_by"] = holders.map(\.summary)
            json["editable"] = holders.isEmpty
        }
        json["diagnostics"] = diagnostics
        json["loaded_at"] = ISO8601DateFormatter().string(from: entry.loadedAt)
        json.merge(entry.metadata) { _, new in new }
        return json
    }

    static func sheetJSON(_ sheet: HorizontalDesignSheet) -> JSONDictionary {
        ["index": sheet.index, "name": sheet.name, "id": sheet.id, "symbol_count": sheet.symbolCount, "block": sheet.blockName, "block_id": sheet.blockID as Any, "is_top_block": sheet.isTopBlock]
    }

    static func componentJSON(_ component: HorizontalDesignComponent, full: Bool, index: HorizontalDesignIndex? = nil) -> JSONDictionary {
        let details = component.details
        var json: JSONDictionary = [
            "id": component.id,
            "refdes": component.refdes,
            "value": component.value,
            "mpn": details?.mpn ?? "",
            "manufacturer": details?.manufacturer ?? "",
            "package": details?.packageName ?? "",
            "description": details?.description ?? "",
            "part_id": component.partID as Any,
            "entity": component.entityName ?? "",
            "no_populate": component.noPopulate,
            "pin_count": component.pins.count,
            "connected_pin_count": component.connectedPins.count,
            "sheets": Array(Set(component.symbolPlacements.map(\.sheetIndex))).sorted(),
            "placed_on_board": component.boardPlacement != nil
        ]
        let effective = component.partValue.isEmpty ? component.rawValue : component.partValue
        json["raw_value"] = component.rawValue
        json["part_value"] = component.partValue
        json["effective_value"] = effective
        json["value_source"] = component.partValue.isEmpty ? "component" : "part"
        json["electrical_value"] = HorizontalElectricalValue.parse(effective, refdes: component.refdes,
                                                                    parametric: component.details?.parametricValues ?? [:])
        json["block_id"] = component.blockID as Any
        json["physical_terminals"] = component.physicalTerminals
        if let placement = component.boardPlacement {
            json["board"] = [
                "x_mm": HorizontalDispatchJSON.mm(placement.position.x),
                "y_mm": HorizontalDispatchJSON.mm(placement.position.y),
                "angle_deg": HorizontalDispatchJSON.degrees(placement.angle),
                "side": placement.bottom ? "bottom" : "top",
                "fixed": placement.fixed,
                // The instance on the board, which a track's pad endpoint
                // names; `package_id` is the pool package it draws.
                "package_instance": placement.instanceID,
                "package_id": placement.packageID as Any
            ]
        }
        guard full else {
            return json
        }
        json["datasheet"] = details?.datasheet ?? ""
        json["parametric"] = details?.parametricValues ?? [:]
        json["entity_id"] = component.entityID as Any
        json["group"] = component.group as Any
        json["tag"] = component.tag as Any
        json["group_name"] = index?.groupName(component.group) ?? NSNull()
        json["tag_name"] = index?.tagName(component.tag) ?? NSNull()
        json["symbols"] = component.symbolPlacements.map { placement -> JSONDictionary in
            [
                "sheet": placement.sheetIndex,
                "sheet_name": placement.sheetName,
                "sheet_id": placement.sheetID,
                // The symbol instance on the sheet, not the pool symbol that
                // draws it. `symbol_id` is the same value under the name it
                // shipped with; analysis evidence still reads that one.
                "symbol_instance": placement.symbolID,
                "symbol_id": placement.symbolID,
                "block_id": placement.blockID as Any,
                "gate_id": placement.gateID,
                "gate_suffix": placement.gateSuffix,
                "x_mm": HorizontalDispatchJSON.mm(placement.position.x),
                "y_mm": HorizontalDispatchJSON.mm(placement.position.y),
                "angle_deg": HorizontalDispatchJSON.degrees(placement.angle),
                "mirrored": placement.mirrored
            ]
        }
        return json
    }

    static func netJSON(_ net: HorizontalDesignNet, entry: HorizontalDispatchProjectEntry, full: Bool) -> JSONDictionary {
        var json: JSONDictionary = [
            "id": net.id,
            "name": net.name,
            "net_class": net.netClassName ?? "",
            "is_power": net.isPower,
            "is_port": net.isPort,
            "pin_count": net.pins.count
        ]
        if let board = entry.project.board {
            json["track_count"] = board.tracks.filter { $0.netID?.lowercased() == net.id }.count
            json["airwire_count"] = board.airwires.filter { $0.netID?.lowercased() == net.id }.count
        }
        guard full else {
            return json
        }
        json["pins"] = net.pins.map { pin -> JSONDictionary in
            ["refdes": pin.refdes, "component_id": pin.componentID, "pin": pin.pinName, "gate": pin.gateName, "gate_suffix": pin.gateSuffix, "direction": pin.direction,
             "gate_id": pin.gateID, "pin_id": pin.pinID, "gate_pin_path": "\(pin.gateID)/\(pin.pinID)",
             "physical_pads": pin.physicalPads.map { ["id": $0.id, "name": $0.name] }]
        }
        if let board = entry.project.board {
            let airwires = board.airwires.filter { $0.netID?.lowercased() == net.id }
            json["airwires"] = airwires.prefix(50).map { segment -> JSONDictionary in
                ["from": HorizontalDispatchJSON.point(segment.from), "to": HorizontalDispatchJSON.point(segment.to)]
            }
        }
        return json
    }

    /// The top block's schematic as it stands in the selected source, so a
    /// read of the sheets sees an unsaved document rather than the last save.
    private static func schematicJSON(_ entry: HorizontalDispatchProjectEntry) throws -> JSONDictionary {
        let filename = entry.project.blocks.first(where: \.isTop)?.schematicFilename ?? entry.project.schematicFilename
        guard let filename, !filename.isEmpty else {
            throw HorizontalDispatchError.notFound("The project has no schematic.")
        }
        let url = entry.project.baseURL.appendingPathComponent(filename)
        guard let json = entry.snapshot?.json(at: url) ?? (try? JSONHelper.loadDictionary(from: url)) else {
            throw HorizontalDispatchError.notFound("Could not read \(filename).")
        }
        return json
    }

    /// The board file as it stands in the selected source. The parsed model
    /// resolves endpoints to points for drawing; the file says what they are.
    private static func boardJSON(_ entry: HorizontalDispatchProjectEntry) throws -> JSONDictionary {
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        guard let json = entry.snapshot?.json(at: board.url) ?? (try? JSONHelper.loadDictionary(from: board.url)) else {
            throw HorizontalDispatchError.notFound("Could not read \(board.url.lastPathComponent).")
        }
        return json
    }

    /// The sheets of the top block's schematic that a selector picks, as raw
    /// JSON paired with the sheet the index knows.
    private static func selectedSheets(_ entry: HorizontalDispatchProjectEntry, _ params: JSONDictionary) throws
        -> [(id: String, index: Int, json: JSONDictionary)] {
        let selected = try HorizontalDispatchValidation.sheet(params, index: entry.index)
        let sheets = (try schematicJSON(entry)["sheets"] as? JSONDictionary ?? [:])
            .compactMap { id, value in (value as? JSONDictionary).map { (id: id, index: $0.int("index") ?? 0, json: $0) } }
            .sorted { ($0.index, $0.id) < ($1.index, $1.id) }
        guard let selected else { return sheets }
        return sheets.filter { $0.id.caseInsensitiveCompare(selected.id) == .orderedSame }
    }

    /// Resolves a net selector to one net id, for the read filters.
    private static func netFilter(_ entry: HorizontalDispatchProjectEntry, _ params: JSONDictionary) throws -> String? {
        guard let reference = params.string("net"), !reference.isEmpty else { return nil }
        if let net = entry.index.net(id: reference) { return net.id }
        let named = entry.index.sortedNets.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        guard named.count <= 1 else {
            throw HorizontalDispatchError.ambiguous("More than one net is named \(reference); use its id.", candidates: named.map(\.id))
        }
        guard let net = named.first else { throw HorizontalDispatchError.notFound("No net \(reference).") }
        return net.id
    }

    /// Net labels and power symbols read the same way: a mark on a sheet that
    /// names a net at a junction.
    @Sendable private static func listSheetMarks(_ session: HorizontalDispatchSession, _ params: JSONDictionary,
                                                  key: String, netKey: String) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try netFilter(entry, params)
        return try selectedSheets(entry, params).flatMap { sheet -> [JSONDictionary] in
            let junctions = sheet.json.dictionaryMap("junctions")
            return sheet.json.dictionaryMap(key).compactMap { id, item -> JSONDictionary? in
                let netID = item.string(netKey)?.lowercased()
                guard wanted == nil || wanted == netID else { return nil }
                let net = netID.flatMap { entry.index.net(id: $0) }
                let junction = item.string("junction")
                let position = junction.flatMap { junctions[$0]?["position"] as? [Any] } ?? []
                var json: JSONDictionary = [
                    "id": id,
                    "sheet": sheet.id,
                    "sheet_index": sheet.index,
                    "net": netID as Any? as Any,
                    "net_name": net?.name as Any? as Any,
                    "junction": junction as Any? as Any,
                    "x_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(position.first ?? 0)),
                    "y_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(position.count > 1 ? position[1] : 0)),
                    "orientation": item.string("orientation") ?? (key == "power_symbols" ? "up" : "right")
                ]
                if key == "power_symbols" {
                    json["mirror"] = item.bool("mirror") ?? false
                    json["style"] = netID.flatMap { powerSymbolStyle(entry, netID: $0) } ?? "gnd"
                } else {
                    json["size_mm"] = HorizontalDispatchJSON.mm(item.double("size") ?? 1_000_000)
                    json["offsheet_refs"] = item.bool("offsheet_refs") ?? true
                }
                return json
            }.sorted { ($0.string("net_name") ?? "", $0.string("id") ?? "") < ($1.string("net_name") ?? "", $1.string("id") ?? "") }
        }
    }

    /// The shape a net's power symbols draw with, which lives on the net.
    private static func powerSymbolStyle(_ entry: HorizontalDispatchProjectEntry, netID: String) -> String? {
        blockJSON(entry)?.dictionaryMap("nets").first { $0.key.lowercased() == netID }?.value.string("power_symbol_style")
    }

    @Sendable private static func listBlockInstances(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let block = blockJSON(entry) else {
            throw HorizontalDispatchError.notFound("The project has no block.")
        }
        let names = Dictionary(uniqueKeysWithValues: entry.project.blocks.map { ($0.uuid.lowercased(), $0.displayName) })
        // Where each instance is drawn, so a caller can find the symbol to move.
        var sheetsByInstance = [String: [JSONDictionary]]()
        for sheet in (try? selectedSheets(entry, [:])) ?? [] {
            for (symbolID, symbol) in sheet.json.dictionaryMap("block_symbols") {
                guard let instance = symbol.string("block_instance")?.lowercased() else { continue }
                sheetsByInstance[instance, default: []].append(["block_symbol": symbolID, "sheet": sheet.id, "sheet_index": sheet.index])
            }
        }
        return block.dictionaryMap("block_instances").map { id, item -> JSONDictionary in
            let used = item.string("block")?.lowercased()
            let connections = item.dictionaryMap("connections").compactMap { port, value -> JSONDictionary? in
                guard let net = value.string("net")?.lowercased() else { return nil }
                return ["port": port, "net": net, "net_name": entry.index.net(id: net)?.name as Any? as Any]
            }.sorted { ($0.string("net_name") ?? "") < ($1.string("net_name") ?? "") }
            return [
                "id": id,
                "block": used as Any? as Any,
                "block_name": used.flatMap { names[$0] } as Any? as Any,
                "refdes": item.string("refdes") ?? "",
                "connections": connections,
                "symbols": sheetsByInstance[id.lowercased()] ?? []
            ]
        }.sorted { ($0.string("refdes") ?? "", $0.string("id") ?? "") < ($1.string("refdes") ?? "", $1.string("id") ?? "") }
    }

    @Sendable private static func listSymbols(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        return try selectedSheets(entry, params).flatMap { sheet -> [JSONDictionary] in
            sheet.json.dictionaryMap("symbols").map { id, item -> JSONDictionary in
                let componentID = item.string("component")?.lowercased()
                let component = componentID.flatMap { entry.index.component(id: $0) }
                let placement = item.dictionary("placement") ?? [:]
                let shift = placement["shift"] as? [Any] ?? []
                return [
                    "id": id,
                    "sheet": sheet.id,
                    "sheet_index": sheet.index,
                    "component": componentID as Any,
                    "refdes": component?.refdes as Any,
                    "gate": item.string("gate") as Any,
                    "symbol": item.string("symbol") as Any,
                    "x_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(shift.first ?? 0)),
                    "y_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(shift.count > 1 ? shift[1] : 0)),
                    "angle_deg": HorizontalDispatchJSON.degrees(placement.int("angle") ?? 0),
                    "mirror": placement.bool("mirror") ?? false,
                    "smashed": item.bool("smashed") ?? false,
                    "texts": item["texts"] as? [String] ?? []
                ]
            }.sorted { ($0.string("refdes") ?? "", $0.string("id") ?? "") < ($1.string("refdes") ?? "", $1.string("id") ?? "") }
        }
    }

    /// One end of a wire, said the way the file says it rather than as a point.
    private static func netLineEndpoint(_ endpoint: JSONDictionary?,
                                        symbols: [String: JSONDictionary],
                                        entry: HorizontalDispatchProjectEntry) -> JSONDictionary {
        guard let endpoint else { return ["kind": "unknown"] }
        if let junction = endpoint.string("junc") {
            return ["kind": "junction", "junction": junction]
        }
        if let pin = endpoint.string("pin") {
            let parts = pin.split(separator: "/").map(String.init)
            var json: JSONDictionary = ["kind": "pin", "symbol": parts.first as Any, "pin": parts.count > 1 ? parts[1] : ""]
            if let instance = parts.first, let symbol = symbols[instance.lowercased()],
               let componentID = symbol.string("component")?.lowercased() {
                json["component"] = componentID
                json["refdes"] = entry.index.component(id: componentID)?.refdes as Any
                json["gate"] = symbol.string("gate") as Any
            }
            return json
        }
        if let ripper = endpoint.string("bus_ripper") { return ["kind": "bus_ripper", "bus_ripper": ripper] }
        if let port = endpoint.string("port") { return ["kind": "port", "port": port] }
        return ["kind": "unknown"]
    }

    @Sendable private static func listNetLines(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try netFilter(entry, params)
        return try selectedSheets(entry, params).flatMap { sheet -> [JSONDictionary] in
            let symbols = sheet.json.dictionaryMap("symbols").reduce(into: [String: JSONDictionary]()) { $0[$1.key.lowercased()] = $1.value }
            return sheet.json.dictionaryMap("net_lines").compactMap { id, item -> JSONDictionary? in
                let netID = item.string("net")?.lowercased()
                guard wanted == nil || wanted == netID else { return nil }
                return [
                    "id": id,
                    "sheet": sheet.id,
                    "sheet_index": sheet.index,
                    "net": netID as Any,
                    "net_name": netID.flatMap { entry.index.net(id: $0)?.name } as Any,
                    "from": netLineEndpoint(item.dictionary("from"), symbols: symbols, entry: entry),
                    "to": netLineEndpoint(item.dictionary("to"), symbols: symbols, entry: entry)
                ]
            }.sorted { ($0.string("net_name") ?? "", $0.string("id") ?? "") < ($1.string("net_name") ?? "", $1.string("id") ?? "") }
        }
    }

    /// One end of a track: a junction, or a pad on a placed package.
    private static func trackEndpoint(_ endpoint: JSONDictionary?, entry: HorizontalDispatchProjectEntry) -> JSONDictionary {
        guard let endpoint else { return ["kind": "unknown"] }
        if let junction = endpoint.string("junc") { return ["kind": "junction", "junction": junction] }
        guard let pad = endpoint.string("pad") else { return ["kind": "unknown"] }
        let parts = pad.split(separator: "/").map(String.init)
        var json: JSONDictionary = ["kind": "pad", "package": parts.first as Any, "pad": parts.count > 1 ? parts[1] : ""]
        if let packageID = parts.first?.lowercased(),
           let component = entry.index.sortedComponents.first(where: { $0.boardPlacement?.instanceID.lowercased() == packageID }) {
            json["component"] = component.id
            json["refdes"] = component.refdes
        }
        return json
    }

    private static func readLimit(_ params: JSONDictionary) -> Int {
        min(max(params.int("limit") ?? 200, 1), 5000)
    }

    @Sendable private static func listPlanes(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try netFilter(entry, params)
        let polygons = try boardJSON(entry).dictionaryMap("polygons")
        let filled = Dictionary(uniqueKeysWithValues: (entry.project.board?.planes ?? []).map { ($0.id.lowercased(), $0) })
        return try boardJSON(entry).dictionaryMap("planes").compactMap { id, item -> JSONDictionary? in
            let netID = item.string("net")?.lowercased()
            guard wanted == nil || wanted == netID else { return nil }
            let polygonID = item.string("polygon")
            let layer = polygonID.flatMap { key in polygons.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value.int("layer") }
            let plane = filled[id.lowercased()]
            return [
                "id": id,
                "net": netID as Any? as Any,
                "net_name": netID.flatMap { entry.index.net(id: $0)?.name } as Any? as Any,
                "polygon": polygonID as Any? as Any,
                "layer": layer as Any? as Any,
                "layer_name": layer.map { HorizontalBoardLayers.name(for: $0) } as Any? as Any,
                "priority": item.int("priority") ?? 0,
                "from_rules": item.bool("from_rules") ?? true,
                // A plane with no fragments has been defined but never poured.
                "fragment_count": plane?.fragments.count ?? 0,
                "poured": (plane?.fragments.isEmpty == false)
            ]
        }.sorted { ($0.string("net_name") ?? "", $0.string("id") ?? "") < ($1.string("net_name") ?? "", $1.string("id") ?? "") }
    }

    @Sendable private static func listPolygons(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let layer = params.int("layer")
        let json = try boardJSON(entry)
        var planeByPolygon = [String: String]()
        for (planeID, plane) in json.dictionaryMap("planes") {
            if let polygon = plane.string("polygon") { planeByPolygon[polygon.lowercased()] = planeID }
        }
        return json.dictionaryMap("polygons").compactMap { id, item -> JSONDictionary? in
            let polygonLayer = item.int("layer")
            guard layer == nil || layer == polygonLayer else { return nil }
            let vertices = (item["vertices"] as? [JSONDictionary] ?? []).map { vertex -> JSONDictionary in
                let position = vertex["position"] as? [Any] ?? []
                return ["x_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(position.first ?? 0)),
                        "y_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(position.count > 1 ? position[1] : 0)),
                        "type": vertex.string("type") ?? "line"]
            }
            return [
                "id": id,
                "layer": polygonLayer as Any? as Any,
                "layer_name": polygonLayer.map { HorizontalBoardLayers.name(for: $0) } as Any? as Any,
                "is_board_outline": polygonLayer == HorizontalBoardLayers.outline,
                "plane": planeByPolygon[id.lowercased()] as Any? as Any,
                "vertices": vertices
            ]
        }.sorted { ($0.int("layer") ?? 0, $0.string("id") ?? "") < ($1.int("layer") ?? 0, $1.string("id") ?? "") }
    }

    /// Fills every plane from the board as it now stands, and writes the fills
    /// to the plane cache file. The definitions are already on disk — pouring
    /// from anything but the committed board would describe copper that is not
    /// there.
    @Sendable private static func pourPlanes(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        guard entry.project.planesFilename != nil else {
            throw HorizontalDispatchError.failed("The project declares no planes_filename, so poured copper has nowhere to live.")
        }
        // A board with no planes still goes through the mutation path: the
        // revision precondition and the result envelope are the same contract
        // whether or not there was anything to pour.
        let poured = board.planes.isEmpty ? board : HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)
        return try HorizontalDispatchMutation.execute(session: session, entry: entry, params: params) { store in
            if !poured.planes.isEmpty {
                var archive = store.archive
                try HorizontalProjectJSONApplicator.applyPlaneCache(board: poured, in: entry.project, to: &archive)
                for path in archive.regularFilePaths where path == entry.project.planesFilename {
                    if let data = archive.regularFileData(relativePath: path) {
                        try store.write(data, to: entry.project.baseURL.appendingPathComponent(path))
                    }
                }
            }
            var result: JSONDictionary = ["poured": poured.planes.count,
                                          "fragments": poured.planes.reduce(0) { $0 + $1.fragments.count },
                                          "applied": poured.planes.count]
            if poured.planes.isEmpty { result["note"] = "The board has no planes; place_plane defines one." }
            return result
        }
    }

    /// Best-effort automatic routing of one net's airwires.
    ///
    /// The finder walks around one obstacle at a time and gives up after trying
    /// both ways past each, so on a real board it completes a few percent of
    /// requests. That is the honest state of it. What it does complete is
    /// verified clear by the finder before it is reported complete, so a route
    /// written here respects the board's clearances; everything else stays an
    /// airwire and is named in the result.
    @Sendable private static func autoroute(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        guard let netID = try netFilter(entry, params) else {
            throw HorizontalDispatchError.invalidParams("autoroute needs \"net\": the net whose airwires to route.")
        }
        let layer = params.int("layer") ?? HorizontalBoardLayers.topCopper
        let limit = min(max(params.int("max_routes") ?? 20, 1), 200)
        let airwires = board.airwires.filter { $0.netID?.lowercased() == netID }.prefix(limit)
        guard !airwires.isEmpty else {
            throw HorizontalDispatchError.invalidParams(
                "\(entry.index.net(id: netID)?.name ?? netID) has no airwires on the board; there is nothing to route."
            )
        }
        guard let width = params.double("width_mm") ?? ruledWidth(entry, netID: netID, layer: layer) else {
            throw HorizontalDispatchError.invalidParams(
                "autoroute needs \"width_mm\": this board states no track_width rule for that net class on layer \(layer)."
            )
        }

        let router = HorizontalBoardTrackRouterSession(board: board)
        var routed: [[HorizontalPoint]] = []
        var failures: [JSONDictionary] = []
        for airwire in airwires {
            let result = router.route(from: airwire.from, to: airwire.to, layer: layer,
                                      netID: netID, width: width * 1_000_000, diagonalFirst: true)
            if result.isComplete, result.points.count > 1 {
                routed.append(result.points)
            } else {
                failures.append(["from": HorizontalDispatchJSON.point(airwire.from),
                                 "to": HorizontalDispatchJSON.point(airwire.to),
                                 "blocked_by": router.blockingObjectID(for: result) as Any? as Any])
            }
        }

        return try HorizontalDispatchMutation.execute(session: session, entry: entry, params: params) { store in
            var written = 0
            if !routed.isEmpty {
                let editor = try HorizontalProjectEditor(project: entry.project, store: store, snapshot: entry.snapshot)
                written = try editor.writeRoutedPaths(routed, net: netID, layer: layer, widthMM: width)
                _ = try editor.write()
            }
            return ["applied": written, "routed": routed.count, "segments": written,
                    "attempted": airwires.count, "failed": failures.count, "unrouted": failures,
                    "width_mm": width, "layer": layer,
                    "note": failures.isEmpty
                        ? "Every airwire tried was routed."
                        : "\(failures.count) of \(airwires.count) could not be routed and remain airwires; place_track draws those by hand."]
        }
    }

    /// The width a `track_width` rule states for a net's class on a layer.
    private static func ruledWidth(_ entry: HorizontalDispatchProjectEntry, netID: String, layer: Int) -> Double? {
        guard let rules = (try? boardJSON(entry))?.dictionary("rules") else { return nil }
        let netClass = blockJSON(entry)?.dictionaryMap("nets")
            .first { $0.key.lowercased() == netID }?.value.string("net_class")?.lowercased()
        var fallback: Double?
        for (_, value) in rules {
            guard let rule = value as? JSONDictionary, rule.string("rule") == "track_width",
                  rule.bool("enabled") ?? true,
                  let width = rule.dictionary("widths")?.dictionary(String(layer))?.double("def") else { continue }
            let match = rule.dictionary("match")
            switch match?.string("mode") ?? "all" {
            case "all": fallback = fallback ?? width / 1_000_000
            case "net_class":
                if let netClass, match?.string("net_class")?.lowercased() == netClass { return width / 1_000_000 }
            default: continue
            }
        }
        return fallback
    }

    @Sendable private static func listTracks(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try netFilter(entry, params)
        let layer = params.int("layer")
        // The file says what an end lands on; the parsed model says where that
        // ended up, so the two are joined by id.
        let resolved = Dictionary(uniqueKeysWithValues: (entry.project.board?.tracks ?? []).map { ($0.id.lowercased(), $0) })
        let matched = try boardJSON(entry).dictionaryMap("tracks").compactMap { id, item -> JSONDictionary? in
            let netID = item.string("net")?.lowercased()
            guard wanted == nil || wanted == netID else { return nil }
            let trackLayer = item.int("layer")
            guard layer == nil || layer == trackLayer else { return nil }
            var json: JSONDictionary = [
                "id": id,
                "net": netID as Any,
                "net_name": netID.flatMap { entry.index.net(id: $0)?.name } as Any,
                "layer": trackLayer as Any,
                "layer_name": trackLayer.map { HorizontalBoardLayers.name(for: $0) } as Any,
                "width_mm": HorizontalDispatchJSON.mm(item.double("width") ?? 0),
                "from": trackEndpoint(item.dictionary("from"), entry: entry),
                "to": trackEndpoint(item.dictionary("to"), entry: entry)
            ]
            if let segment = resolved[id.lowercased()] {
                json["from_mm"] = HorizontalDispatchJSON.point(segment.from)
                json["to_mm"] = HorizontalDispatchJSON.point(segment.to)
            }
            return json
        }.sorted { ($0.string("net_name") ?? "", $0.string("id") ?? "") < ($1.string("net_name") ?? "", $1.string("id") ?? "") }
        let limit = readLimit(params)
        return ["total": matched.count, "truncated": matched.count > limit, "tracks": Array(matched.prefix(limit))] as JSONDictionary
    }

    @Sendable private static func listVias(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try netFilter(entry, params)
        let resolved = Dictionary(uniqueKeysWithValues: (entry.project.board?.vias ?? []).map { ($0.id.lowercased(), $0) })
        let matched = try boardJSON(entry).dictionaryMap("vias").compactMap { id, item -> JSONDictionary? in
            let via = resolved[id.lowercased()]
            let netID = (item.string("net_set") ?? via?.netID)?.lowercased()
            guard wanted == nil || wanted == netID else { return nil }
            var json: JSONDictionary = [
                "id": id,
                "net": netID as Any,
                "net_name": netID.flatMap { entry.index.net(id: $0)?.name } as Any,
                "junction": item.string("junction") as Any,
                "padstack": (item.string("padstack") ?? via?.padstackID) as Any? as Any,
                "definition": (item.string("definition") ?? via?.definitionID) as Any? as Any,
                "source": item.string("source") ?? "padstack",
                "from_rules": item.bool("from_rules") ?? false,
                "net_pinned": item.string("net_set") != nil
            ]
            if let via {
                json["x_mm"] = HorizontalDispatchJSON.mm(via.position.x)
                json["y_mm"] = HorizontalDispatchJSON.mm(via.position.y)
                json["size_mm"] = HorizontalDispatchJSON.mm(via.size)
                json["hole_mm"] = via.holeSize.map { HorizontalDispatchJSON.mm($0) } as Any
                json["layers"] = via.connectedLayers
            }
            return json
        }.sorted { ($0.string("net_name") ?? "", $0.string("id") ?? "") < ($1.string("net_name") ?? "", $1.string("id") ?? "") }
        let limit = readLimit(params)
        return ["total": matched.count, "truncated": matched.count > limit, "vias": Array(matched.prefix(limit))] as JSONDictionary
    }

    @Sendable private static func listTexts(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let wanted = try selectedSheets(entry, params)
        // A symbol's smashed texts are listed too, marked with the symbol they
        // belong to, so a caller can see why they are not free to edit.
        return wanted.flatMap { sheet -> [JSONDictionary] in
            var ownerBySymbol = [String: String]()
            for (symbolID, symbol) in sheet.json.dictionaryMap("symbols") {
                for id in symbol["texts"] as? [String] ?? [] { ownerBySymbol[id.lowercased()] = symbolID }
            }
            return sheet.json.dictionaryMap("texts").map { id, item -> JSONDictionary in
                let placement = item.dictionary("placement") ?? [:]
                let shift = placement["shift"] as? [Any] ?? []
                var json: JSONDictionary = [
                    "id": id,
                    "sheet": sheet.id,
                    "sheet_index": sheet.index,
                    "text": item.string("text") ?? "",
                    "x_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(shift.first ?? 0)),
                    "y_mm": HorizontalDispatchJSON.mm(JSONHelper.doubleValue(shift.count > 1 ? shift[1] : 0)),
                    "angle_deg": HorizontalDispatchJSON.degrees(placement.int("angle") ?? 0),
                    "mirror": placement.bool("mirror") ?? false,
                    "size_mm": HorizontalDispatchJSON.mm(item.double("size") ?? 1_000_000),
                    "width_mm": HorizontalDispatchJSON.mm(item.double("width") ?? 0),
                    "origin": item.string("origin") ?? "center",
                    "font": item.string("font") ?? "simplex",
                    "from_smash": item.bool("from_smash") ?? false
                ]
                json["symbol"] = ownerBySymbol[id.lowercased()] as Any
                return json
            }.sorted { ($0.string("text") ?? "", $0.string("id") ?? "") < ($1.string("text") ?? "", $1.string("id") ?? "") }
        }
    }

    @Sendable private static func listParts(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let scope = params.string("scope") ?? "project"
        guard ["project", "pools", "all"].contains(scope) else {
            throw HorizontalDispatchError.invalidParams("scope must be project, pools, or all.")
        }
        var rows = [JSONDictionary]()
        if scope != "pools" {
            rows = entry.project.poolParts
                .sorted { $0.mpn.localizedStandardCompare($1.mpn) == .orderedAscending }
                .map { partJSON($0).merging(["in_project_pool": true]) { _, new in new } }
        }
        guard scope != "project" else { return rows }
        let (items, _, inProject) = HorizontalDispatchPool.scan(try HorizontalDispatchPool.poolURLs(for: entry))
        var seen = Set(rows.compactMap { $0.string("id")?.lowercased() })
        let library = items
            .filter { $0.category == .part && seen.insert($0.uuid).inserted }
            .sorted { ($0.name.localizedLowercase, $0.uuid) < ($1.name.localizedLowercase, $1.uuid) }
            .map { item -> JSONDictionary in
                var json = HorizontalDispatchPool.itemJSON(item, inProject: inProject)
                json["id"] = item.uuid
                json["mpn"] = item.name
                json["description"] = item.detail
                return json
            }
        // One row shape throughout: a part cached in the project pool carries
        // the extra fields the project's own loader resolves.
        return rows + library
    }

    static func partJSON(_ part: HorizontalPoolPart) -> JSONDictionary {
        [
            "id": part.id,
            "mpn": part.mpn,
            "manufacturer": part.manufacturer,
            "value": part.value,
            "package": part.packageName,
            "description": part.partDescription,
            "tags": part.tags,
            "entity_id": part.entityID as Any,
            "refdes_prefix": part.refdesPrefix,
            "gate_count": part.gates.count
        ]
    }

    private static func imageJSON(_ image: HorizontalDispatchRender.Image, outputPath: String?) -> JSONDictionary {
        var json: JSONDictionary = ["width": image.width, "height": image.height, "format": "png"]
        if let outputPath, !outputPath.isEmpty {
            let url = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
            do {
                try image.png.write(to: url)
                json["path"] = url.path
            } catch {
                json["error"] = error.localizedDescription
            }
        } else {
            json["png_base64"] = image.png.base64EncodedString()
        }
        return json
    }

    // MARK: - Export helpers

    private static func exportSection(named name: String) throws -> HorizontalExportSection {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        let aliases: [String: HorizontalExportSection] = [
            "schematicpdf": .schematicPDF, "schematic": .schematicPDF, "pdf": .schematicPDF,
            "bom": .bom,
            "gerber": .gerber, "gerbers": .gerber,
            "odb": .odb, "odb++": .odb,
            "pickandplace": .pickAndPlace, "pnp": .pickAndPlace,
            "boardstep": .boardSTEP, "step": .boardSTEP, "3dmodel": .boardSTEP,
            "boarddrawing": .boardDrawing, "drawing": .boardDrawing,
            "boarddxf": .boardDXF, "dxf": .boardDXF
        ]
        guard let section = aliases[normalized] else {
            throw HorizontalDispatchError.invalidParams("Unknown export section \(name). Known: schematic_pdf, bom, gerber, odb, pick_and_place, board_step, board_drawing, board_dxf.")
        }
        return section
    }

    private static func applyExportOptions(_ options: JSONDictionary?, to settings: inout HorizontalExportSettings) {
        guard let options else {
            return
        }
        if let bom = options.dictionary("bom") {
            if let flag = bom.bool("include_no_populate") { settings.bom.includeNoPopulate = flag }
            if let name = bom.string("filename") { settings.bom.filename = name }
        }
        if let pdf = options.dictionary("schematic_pdf") {
            if let width = pdf.double("minimum_line_width_mm") { settings.schematicPDF.minimumLineWidthMM = width }
            if let name = pdf.string("filename") { settings.schematicPDF.filename = name }
        }
        if let step = options.dictionary("board_step") {
            if let flag = step.bool("include_3d_models") { settings.boardSTEP.include3DModels = flag }
            if let name = step.string("filename") { settings.boardSTEP.filename = name }
        }
        if let gerber = options.dictionary("gerber") {
            if let flag = gerber.bool("zip_output") { settings.gerber.zipOutput = flag }
            if let flag = gerber.bool("remove_individual_files_after_zip") { settings.gerber.removeIndividualFilesAfterZip = flag }
            if let prefix = gerber.string("prefix") { settings.gerber.prefix = prefix }
        }
        if let drawing = options.dictionary("board_drawing") {
            if let flag = drawing.bool("mirrored") { settings.boardDrawing.mirrored = flag }
            if let name = drawing.string("filename") { settings.boardDrawing.filename = name }
        }
        if let pnp = options.dictionary("pick_and_place") {
            if let flag = pnp.bool("include_no_populate") { settings.pickAndPlace.includeNoPopulate = flag }
        }
    }

    private static func exportStatusName(_ kind: HorizontalExportStatus.Kind) -> String {
        switch kind {
        case .info: "info"
        case .success: "success"
        case .warning: "warning"
        case .error: "error"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
