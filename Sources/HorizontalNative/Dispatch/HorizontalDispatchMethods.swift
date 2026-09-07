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
            params: ["handle": "Project handle.", "sheet": "Optional sheet index; only components with a symbol on that sheet."],
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
        .init(name: "list_parts", summary: "Parts in the project pool.", params: ["handle": "Project handle."], handler: { session, params in
            try session.entry(for: params).project.poolParts
                .sorted { $0.mpn.localizedStandardCompare($1.mpn) == .orderedAscending }
                .map(partJSON)
        }),
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
            params: ["handle": "Project handle.", "items": "Array of pool item objects, each with \"type\" and \"uuid\"."],
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
        )
    ]

    // MARK: - Handlers

    private static func version() -> Any {
        var result: JSONDictionary = ["api": HorizontalDispatch.apiVersion, "module": "HorizontalNative"]
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
            let directory = entry.project.baseURL
                .appendingPathComponent(poolDirectory)
                .appendingPathComponent(HorizontalPoolItemFactory.directoryName(for: category))
                .appendingPathComponent("cache")
            let url = category == .package
                ? directory.appendingPathComponent(uuid).appendingPathComponent("package.json")
                : directory.appendingPathComponent("\(uuid).json")
            targets.append((url, try HorizontalHorizonJSONWriter.data(json)))
        }

        if entry.live != nil {
            let live = try liveDocument(entry)
            let input = HorizontalUnsafeSendableBox((entry: entry, targets: targets))
            let output = HorizontalUnsafeSendableBox<JSONDictionary>([:])
            try MainActor.assumeIsolated {
                let entry = input.value.entry
                guard !live.isReadOnly() else {
                    throw HorizontalDispatchError.failed("Read-only operation is enabled in Horizontal.")
                }
                let store = HorizontalArchiveFileStore(archive: live.archive(), baseURL: entry.project.baseURL)
                let written = try writePoolItems(input.value.targets, to: store)
                if !written.isEmpty {
                    try live.applyArchive(store.archive, "Add \(written.count) Pool Item\(written.count == 1 ? "" : "s")")
                    session.syncLiveEntries()
                }
                output.value = ["written": written, "skipped": input.value.targets.count - written.count, "live": true]
            }
            return output.value
        }
        let written = try writePoolItems(targets, to: HorizontalDiskFileStore())
        if !written.isEmpty {
            _ = try session.reload(handle: entry.handle)
        }
        return ["written": written, "skipped": targets.count - written.count]
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

    @Sendable private static func closeProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        session.close(handle: entry.handle)
        return ["closed": entry.handle]
    }

    @Sendable private static func reloadProject(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        projectSummary(try session.reload(handle: try session.entry(for: params).handle))
    }

    @Sendable private static func projectFiles(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let manifest = try HorizontalProjectManifest.discover(from: entry.url)
        return [
            "base": manifest.baseURL.path,
            "project_file": manifest.projectFileURL.path,
            "files": manifest.relativePaths.sorted(),
            "pool_directory": manifest.poolDirectoryURL?.path as Any,
            "missing_references": manifest.missingReferences,
            "external_references": manifest.externalReferences.map(\.path)
        ]
    }

    @Sendable private static func listComponents(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        var components = entry.index.sortedComponents
        if let sheet = params.int("sheet") {
            components = components.filter { component in
                component.symbolPlacements.contains { $0.sheetIndex == sheet }
            }
        }
        return components.map { componentJSON($0, full: false) }
    }

    @Sendable private static func getComponent(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let component: HorizontalDesignComponent?
        if let refdes = params.string("refdes") {
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
        if entry.live != nil {
            return try applyLive(session, entry: entry, operations: operations, dryRun: params.bool("dry_run") ?? false)
        }
        let editor = try HorizontalProjectEditor(project: entry.project)
        try editor.apply(operations)
        var result: JSONDictionary = ["applied": editor.changes.count, "changes": editor.changes]
        if params.bool("dry_run") ?? false {
            result["dry_run"] = true
            result["would_write"] = editor.changedFiles
            return result
        }
        result["written"] = try editor.write()
        result["project"] = projectSummary(try session.reload(handle: entry.handle))
        return result
    }

    /// Edits against an open document: the ops run over the document's
    /// archive and the app swaps the result in as one undoable step.
    private static func applyLive(
        _ session: HorizontalDispatchSession,
        entry: HorizontalDispatchProjectEntry,
        operations: [HorizontalEditOperation],
        dryRun: Bool
    ) throws -> Any {
        let live = try liveDocument(entry)
        let input = HorizontalUnsafeSendableBox((entry: entry, operations: operations))
        let output = HorizontalUnsafeSendableBox<JSONDictionary>([:])
        try MainActor.assumeIsolated {
            let entry = input.value.entry
            guard !live.isReadOnly() else {
                throw HorizontalDispatchError.failed("Read-only operation is enabled in Horizontal.")
            }
            let store = HorizontalArchiveFileStore(archive: live.archive(), baseURL: entry.project.baseURL)
            let editor = try HorizontalProjectEditor(project: entry.project, store: store)
            try editor.apply(input.value.operations)
            var result: JSONDictionary = ["applied": editor.changes.count, "changes": editor.changes, "live": true]
            if dryRun {
                result["dry_run"] = true
                result["would_write"] = editor.changedFiles
                output.value = result
                return
            }
            result["written"] = try editor.write()
            let count = editor.changes.count
            try live.applyArchive(store.archive, "Apply \(count) Edit\(count == 1 ? "" : "s")")
            session.syncLiveEntries()
            result["project"] = projectSummary(entry)
            output.value = result
        }
        return output.value
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
            guard let component = index.component(refdes: refdes) ?? index.component(id: refdes) else {
                throw HorizontalDispatchError.notFound("No component \(refdes).")
            }
            componentIDs.insert(component.id)
        }
        var netIDs = Set<String>()
        for name in (params["nets"] as? [Any])?.map({ "\($0)" }) ?? [] {
            guard let net = index.net(named: name) ?? index.net(id: name) else {
                throw HorizontalDispatchError.notFound("No net \(name).")
            }
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
        let status = HorizontalExportBackend.export(sections: sections, settings: settings, project: entry.project)
        let targetURL = try HorizontalExportSettings.exportTargetDirectory(for: entry.project, requestedPath: settings.targetDirectory)
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
        let (image, sheet) = try HorizontalDispatchRender.renderSheet(
            project: entry.project,
            sheetIndex: params.int("sheet"),
            sheetName: params.string("name"),
            sheetID: params.string("sheet_id"),
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
            project: entry.project,
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
            guard let component = index.component(refdes: refdes) ?? index.component(id: refdes) else {
                throw HorizontalDispatchError.notFound("No component \(refdes).")
            }
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
            let sheet = index.sheets.first { $0.index == symbol.sheetIndex }
            let rect = HorizontalRect(center: symbol.position, size: 20_000_000)
            return (expand(rect, by: margin), .schematic, sheet?.id, sheet?.blockID, component.refdes)
        }
        if let netName = params.string("net") {
            guard let net = index.net(named: netName) ?? index.net(id: netName) else {
                throw HorizontalDispatchError.notFound("No net \(netName).")
            }
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
            var bySheet = [Int: [HorizontalPoint]]()
            for pin in net.pins {
                guard let component = index.component(id: pin.componentID) else {
                    continue
                }
                for placement in component.symbolPlacements {
                    bySheet[placement.sheetIndex, default: []].append(placement.position)
                }
            }
            guard let best = bySheet.max(by: { $0.value.count < $1.value.count }), let first = best.value.first else {
                throw HorizontalDispatchError.notFound("\(net.name) has no symbols on any sheet.")
            }
            let sheetIndex: Int = best.key
            let points: [HorizontalPoint] = best.value
            let sheet = index.sheets.first { $0.index == sheetIndex }
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
        var result: JSONDictionary
        if wanted == .board {
            let image = try HorizontalDispatchRender.renderBoard(project: entry.project, layerNames: nil, mirrored: false, region: region, dpi: dpi, maxPixels: maxPixels)
            result = imageJSON(image, outputPath: params.string("output_path"))
        } else {
            let (image, sheet) = try HorizontalDispatchRender.renderSheet(project: entry.project, sheetIndex: nil, sheetName: nil, sheetID: state.value.1, region: region, dpi: dpi, maxPixels: maxPixels)
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
        json["live"] = entry.live != nil
        json["diagnostics"] = diagnostics
        json["loaded_at"] = ISO8601DateFormatter().string(from: entry.loadedAt)
        return json
    }

    static func sheetJSON(_ sheet: HorizontalDesignSheet) -> JSONDictionary {
        ["index": sheet.index, "name": sheet.name, "id": sheet.id, "symbol_count": sheet.symbolCount, "block": sheet.blockName, "is_top_block": sheet.isTopBlock]
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
        if let placement = component.boardPlacement {
            json["board"] = [
                "x_mm": HorizontalDispatchJSON.mm(placement.position.x),
                "y_mm": HorizontalDispatchJSON.mm(placement.position.y),
                "angle_deg": HorizontalDispatchJSON.degrees(placement.angle),
                "side": placement.bottom ? "bottom" : "top",
                "fixed": placement.fixed,
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
            ["refdes": pin.refdes, "pin": pin.pinName, "gate": pin.gateName, "gate_suffix": pin.gateSuffix, "direction": pin.direction]
        }
        if let board = entry.project.board {
            let airwires = board.airwires.filter { $0.netID?.lowercased() == net.id }
            json["airwires"] = airwires.prefix(50).map { segment -> JSONDictionary in
                ["from": HorizontalDispatchJSON.point(segment.from), "to": HorizontalDispatchJSON.point(segment.to)]
            }
        }
        return json
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
