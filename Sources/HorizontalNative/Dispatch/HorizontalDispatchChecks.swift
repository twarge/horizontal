import Foundation

/// The checks Horizontal can run today, gathered for the `check` method.
/// There is no geometric design rule check yet; what exists is load
/// diagnostics, the rules editor's structural validation, and connectivity
/// facts the model already derives (annotation, single-pin nets, unplaced
/// packages, unrouted connections).
enum HorizontalDispatchChecks {
    struct Message {
        var level: String
        var category: String
        var title: String
        var detail: String
        var refdes: String? = nil
        var net: String? = nil
        /// Where a sheet warning is drawn.
        var location: Location? = nil

        struct Location {
            var sheet: Int
            var sheetName: String
            var sheetID: String
            /// The block whose sheet it is, when that is not the top block.
            var block: String?
            var blockID: String?
            var position: HorizontalPoint
            /// What the canvas says there.
            var message: String
            /// The pin's name, for a warning about a pin.
            var pin: String?
            /// The wires of the segment a warning about one is about.
            var netLines: [String] = []
        }

        var json: JSONDictionary {
            var json: JSONDictionary = ["level": level, "category": category, "title": title, "detail": detail]
            if let refdes { json["refdes"] = refdes }
            if let net { json["net"] = net }
            if let location {
                json["sheet"] = location.sheet
                json["sheet_name"] = location.sheetName
                json["sheet_id"] = location.sheetID
                json["x_mm"] = HorizontalDispatchJSON.mm(location.position.x)
                json["y_mm"] = HorizontalDispatchJSON.mm(location.position.y)
                json["message"] = location.message
                if let pin = location.pin { json["pin"] = pin }
                // Which wires the segment is, so a label can go on one of them;
                // a long run is named by its first few.
                if !location.netLines.isEmpty {
                    json["net_lines"] = Array(location.netLines.prefix(8))
                    if location.netLines.count > 8 { json["net_line_count"] = location.netLines.count }
                }
                if let block = location.block { json["block"] = block }
                if let blockID = location.blockID { json["block_id"] = blockID }
            }
            return json
        }
    }

    static func run(entry: HorizontalDispatchProjectEntry, full: Bool = false) -> JSONDictionary {
        let project = entry.project
        let index = entry.index
        var messages = [Message]()

        for diagnostic in project.diagnostics {
            messages.append(Message(level: "warning", category: "load", title: diagnostic.message, detail: ""))
        }

        var refdesCounts = [String: Int]()
        for component in index.sortedComponents {
            let refdes = component.refdes.trimmingCharacters(in: .whitespacesAndNewlines)
            if refdes.isEmpty || refdes.hasSuffix("?") {
                messages.append(Message(level: "warning", category: "annotation", title: "Component is not annotated", detail: "Value \(component.value), part \(component.details?.mpn ?? "none").", refdes: refdes))
            } else {
                refdesCounts[refdes, default: 0] += 1
            }
            if component.partID == nil, !component.noPopulate {
                messages.append(Message(level: "info", category: "part", title: "No part assigned", detail: "The component has an entity but no pool part, so it has no package or MPN.", refdes: refdes))
            }
            // A component created through the netlist alone is electrically
            // real and drawn nowhere: the schematic no longer shows the
            // circuit it describes. Gates are reported one by one, since half
            // a dual op-amp on a sheet is the same gap.
            let placed = Set(component.symbolPlacements.map { $0.gateID.lowercased() })
            let gates = Dictionary(component.pins.map { ($0.gateID.lowercased(), $0.gateSuffix) }, uniquingKeysWith: { first, _ in first })
            let missing = gates.keys.filter { !placed.contains($0) }.sorted()
            if !missing.isEmpty {
                let detail = placed.isEmpty && missing.count == gates.count
                    ? "The component is in the netlist but has no symbol on any sheet. place_symbol draws it."
                    : "Gate\(missing.count == 1 ? "" : "s") \(missing.map { gates[$0].flatMap { $0.isEmpty ? nil : $0 } ?? $0 }.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") on no sheet."
                messages.append(Message(level: "warning", category: "schematic", title: "Not drawn on a sheet", detail: detail, refdes: refdes))
            }
        }
        for (refdes, count) in refdesCounts where count > 1 {
            messages.append(Message(level: "error", category: "annotation", title: "Duplicate reference designator", detail: "\(count) components are named \(refdes).", refdes: refdes))
        }

        for net in index.sortedNets {
            if net.pins.count == 1, !net.isPort {
                let pin = net.pins[0]
                messages.append(Message(level: "warning", category: "connectivity", title: "Net has a single pin", detail: "Only \(pin.refdes) pin \(pin.pinName) is on it.", net: net.name))
            } else if net.pins.isEmpty {
                messages.append(Message(level: "info", category: "connectivity", title: "Net has no pins", detail: "The net exists in the block but nothing connects to it.", net: net.name))
            }
        }

        messages.append(contentsOf: schematicWarningMessages(project: project))

        if let board = project.board {
            for object in board.unplacedObjects {
                messages.append(Message(level: "warning", category: "board", title: "Not placed on the board", detail: object.subtitle, refdes: object.label))
            }
            // Poured plane copper joins the pads and vias inside it, so what
            // is left on a plane net is a pad the fill does not reach (or an
            // unpoured plane). Those are reported apart from the rest so a
            // real gap on a signal net is not lost among power pads.
            let netsWithPlanes = Set(board.planes.compactMap { $0.netID?.lowercased() })
            let airwiresByNet = Dictionary(grouping: board.airwires, by: { $0.netID?.lowercased() ?? "" })
            for (netID, airwires) in airwiresByNet where !netID.isEmpty {
                let net = index.net(id: netID)
                let resolvedName = net?.name ?? ""
                let name = resolvedName.isEmpty ? netID : resolvedName
                let count = "\(airwires.count) airwire\(airwires.count == 1 ? "" : "s")"
                // An unnamed net is only its uuid, which says nothing about
                // where it is; its pins do.
                var pins = ""
                if resolvedName.isEmpty, let net, !net.pins.isEmpty {
                    let listed = net.pins.map { "\($0.refdes).\($0.pinName)" }
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                        .prefix(6).joined(separator: ", ")
                    pins = " (\(listed)\(net.pins.count > 6 ? ", … \(net.pins.count) pins" : ""))"
                }
                if netsWithPlanes.contains(netID) {
                    // A plane net has hundreds of pins, so it is the airwires'
                    // own ends that say which pads the fill misses.
                    let ends = airwireEnds(airwires, net: net, board: board, index: index)
                    messages.append(Message(level: "info", category: "routing", title: "Not reached by the plane", detail: "\(count) on a net with a plane (\(ends)): the fill does not reach these pads, or the plane is not poured.", net: name))
                } else {
                    messages.append(Message(level: "warning", category: "routing", title: "Unrouted connections", detail: "\(count) \(airwires.count == 1 ? "remains" : "remain")\(pins).", net: name))
                }
            }
            messages.append(contentsOf: copperMessages(board: board, index: index))
            messages.append(contentsOf: rulesMessages(project: project, board: board))
        } else {
            messages.append(Message(level: "info", category: "board", title: "The project has no board", detail: ""))
        }

        messages.sort { lhs, rhs in
            let order = ["error": 0, "warning": 1, "info": 2]
            let left = order[lhs.level] ?? 3
            let right = order[rhs.level] ?? 3
            if left != right {
                return left < right
            }
            if lhs.category != rhs.category {
                return lhs.category < rhs.category
            }
            switch (lhs.refdes ?? lhs.net ?? lhs.title).localizedStandardCompare(rhs.refdes ?? rhs.net ?? rhs.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                // Sheet warnings of one net or part read page by page, top to
                // bottom, so a run of them comes back in the same order each time.
                guard let left = lhs.location, let right = rhs.location else {
                    return lhs.location == nil && rhs.location != nil
                }
                return (left.blockID ?? "", left.sheet, -left.position.y, left.position.x, lhs.title, left.message)
                    < (right.blockID ?? "", right.sheet, -right.position.y, right.position.x, rhs.title, right.message)
            }
        }
        let counts = Dictionary(grouping: messages, by: \.level).mapValues(\.count)
        return [
            "ok": (counts["error"] ?? 0) == 0,
            "counts": ["error": counts["error"] ?? 0, "warning": counts["warning"] ?? 0, "info": counts["info"] ?? 0],
            "messages": full ? messages.map(\.json) : grouped(messages),
            "note": "Horizontal has no geometric design rule check yet; these are load diagnostics, rules validation, and connectivity facts, plus the components and board packages nothing has placed, the warnings the schematic canvas draws on each sheet, and copper that joins two nets — tracks and vias reaching pads of both, or a poured plane over a pad of another. Poured planes count as copper for the rats' nest."
        ]
    }

    /// The warnings the schematic canvas draws (Horizon's sheet warnings),
    /// on every sheet of every block: one message each, with its sheet and
    /// where on it, and the net or part it is about.
    static func schematicWarningMessages(project: HorizontalProject) -> [Message] {
        var messages = [Message]()
        for entry in HorizontalDesignIndex.schematics(of: project) {
            let sheets = entry.schematic.sheets
            let block = entry.block.isTop ? nil : entry.block.displayName
            for sheet in sheets {
                // A duplicate refdes is already an annotation error, once
                // per refdes; the canvas marks each symbol of it as well.
                for finding in HorizontalSchematicWarnings.findings(sheet, allSheets: sheets) where finding.title != "Duplicate refdes" {
                    let net = finding.netID.flatMap { sheet.netDetails[$0.lowercased()]?.name }.flatMap { $0.isEmpty ? nil : $0 }
                    let refdes = finding.componentID.flatMap { sheet.componentInfo[$0.lowercased()]?.refdes }.flatMap { $0.isEmpty ? nil : $0 }
                    let position = String(format: "(%.2f, %.2f) mm", finding.position.x / 1_000_000, finding.position.y / 1_000_000)
                    // Where, what the canvas says there, and what it is about
                    // when the message does not already name it.
                    var detail = "\(block.map { "Block \($0), sheet" } ?? "Sheet") \(sheet.index) (\(sheet.name)) at \(position)"
                    if finding.message != finding.title { detail += ": \(finding.message)" }
                    var about = [String]()
                    if let net, !finding.message.contains(net) { about.append("net \(net)") }
                    if let refdes, !finding.message.contains(refdes) {
                        about.append(finding.pinName.map { "\(refdes) pin \($0)" } ?? refdes)
                    }
                    if !about.isEmpty {
                        detail += finding.message != finding.title ? " (\(about.joined(separator: ", ")))" : ", \(about.joined(separator: ", "))"
                    }
                    messages.append(Message(
                        level: "warning", category: "schematic", title: finding.title, detail: detail + ".",
                        refdes: refdes, net: net,
                        location: .init(sheet: sheet.index, sheetName: sheet.name, sheetID: sheet.id,
                                        block: block, blockID: entry.block.isTop ? nil : entry.block.uuid,
                                        position: finding.position, message: finding.message, pin: finding.pinName,
                                        netLines: finding.netLineIDs)
                    ))
                }
            }
        }
        return messages
    }

    /// Shorts copper makes on its own, which need no geometry to find: tracks
    /// and vias that join pads of two nets — what a pin moved to another net
    /// leaves when its tracks stay — and a poured plane that runs over a pad
    /// on another net, which a pour made before the pad changed nets does.
    static func copperMessages(board: HorizontalBoard, index: HorizontalDesignIndex) -> [Message] {
        var padNames = [String: String]()   // package/pad → refdes.pad
        for component in index.sortedComponents {
            guard let package = component.boardPlacement?.instanceID.lowercased(), !package.isEmpty else { continue }
            for terminal in component.physicalTerminals {
                guard let id = terminal.string("id")?.lowercased() else { continue }
                padNames["\(package)/\(id)"] = "\(component.refdes).\(terminal.string("name") ?? id)"
            }
        }
        func net(_ id: String?) -> String {
            guard let id else { return "no net" }
            let name = index.net(id: id)?.name ?? ""
            return name.isEmpty ? id : name
        }
        func natural(_ names: [String]) -> [String] { names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        var messages = [Message]()
        for short in HorizontalBoardConnectivity.shorts(board) {
            let byNet = Dictionary(grouping: short.pads, by: \.value).mapValues { natural($0.map { padNames[$0.key] ?? $0.key }) }
            let sides = byNet.keys.sorted { net($0) < net($1) }.map { "\(net($0)) (\(byNet[$0]!.prefix(4).joined(separator: ", "))\(byNet[$0]!.count > 4 ? ", …" : ""))" }
            let copper = "\(short.trackIDs.count) track\(short.trackIDs.count == 1 ? "" : "s")"
                + (short.viaIDs.isEmpty ? "" : " and \(short.viaIDs.count) via\(short.viaIDs.count == 1 ? "" : "s")")
            var detail = "\(copper) join \(sides.joined(separator: " to "))"
            if let at = short.position { detail += String(format: ", from (%.2f, %.2f) mm", at.x / 1_000_000, at.y / 1_000_000) }
            detail += ". Tracks: \(short.trackIDs.prefix(6).joined(separator: ", "))\(short.trackIDs.count > 6 ? ", …" : "")."
            messages.append(Message(level: "error", category: "copper", title: "Copper joins two nets", detail: detail,
                                    net: short.nets.map(net).sorted().joined(separator: " / ")))
        }
        let padsByLayer = Dictionary(grouping: board.packagePads.filter { $0.netID != nil && $0.layer != nil }, by: { $0.layer! })
        for plane in board.planes {
            guard let layer = plane.layer, let planeNet = plane.netID?.lowercased(), !plane.fragments.isEmpty else { continue }
            var covered = Set<String>()
            for pad in padsByLayer[layer] ?? [] where pad.netID?.lowercased() != planeNet {
                let center = HorizontalRect(points: pad.renderVertices(arcPrecision: 24)).center
                let inside = plane.fragments.contains { fragment in
                    fragment.containmentPaths.filter { $0.contains(center) }.count % 2 == 1
                }
                guard inside else { continue }
                let parts = pad.id.lowercased().split(separator: "/").map(String.init)
                let path = parts.count >= 3 ? "\(parts[0])/\(parts[2])" : pad.id
                covered.insert("\(padNames[path] ?? path) (\(net(pad.netID?.lowercased())))")
            }
            guard !covered.isEmpty else { continue }
            let pads = natural(Array(covered))
            messages.append(Message(level: "error", category: "copper", title: "Plane runs over a pad on another net",
                                    detail: "The \(net(planeNet)) plane on \(HorizontalBoardLayers.name(for: layer)) covers \(pads.prefix(6).joined(separator: ", "))\(pads.count > 6 ? ", … \(pads.count) pads" : ""). It was poured before those pads took their nets, most likely; pour_planes pours it again.",
                                    net: net(planeNet)))
        }
        return messages
    }

    /// Each airwire as "C61.N to U8.VSS_12", at most three of them. An end
    /// that is no pad of the net (a via, a junction) is its position in mm.
    /// The rats' nest runs an airwire either way and lists them in no set
    /// order, which changes from one run of the app to the next, so the ends
    /// and then the airwires are put in natural order: the same board reads
    /// the same, and names the same three.
    static func airwireEnds(_ airwires: [HorizontalSegment], net: HorizontalDesignNet?, board: HorizontalBoard,
                            index: HorizontalDesignIndex) -> String {
        func key(_ point: HorizontalPoint) -> String { "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))" }
        var padNames = [String: String]()   // package/pad → refdes.pin
        for pin in net?.pins ?? [] {
            guard let package = index.component(id: pin.componentID)?.boardPlacement?.instanceID.lowercased(), !package.isEmpty else { continue }
            for pad in pin.physicalPads { padNames["\(package)/\(pad.id.lowercased())"] = "\(pin.refdes).\(pin.pinName)" }
        }
        var namesAt = [String: String]()
        for (path, point) in board.packagePadPositions {
            if let name = padNames[path.lowercased()] { namesAt[key(point)] = name }
        }
        func name(_ point: HorizontalPoint) -> String {
            namesAt[key(point)] ?? String(format: "(%.2f, %.2f) mm", point.x / 1_000_000, point.y / 1_000_000)
        }
        func before(_ lhs: String, _ rhs: String) -> Bool { lhs.localizedStandardCompare(rhs) == .orderedAscending }
        let pairs = airwires
            .map { airwire -> (String, String) in
                let from = name(airwire.from), to = name(airwire.to)
                return before(to, from) ? (to, from) : (from, to)
            }
            .sorted { lhs, rhs in
                let first = lhs.0.localizedStandardCompare(rhs.0)
                return first == .orderedSame ? before(lhs.1, rhs.1) : first == .orderedAscending
            }
        let listed = pairs.prefix(3).map { "\($0.0) to \($0.1)" }
        return listed.joined(separator: "; ") + (airwires.count > 3 ? "; … \(airwires.count - 3) more" : "")
    }

    /// Findings that share a level, category and title, more than three of
    /// them, as one message: 49 unplaced packages read as one line naming
    /// them, not 49. The names keep their order; a detail they all share stays
    /// detail, otherwise details gives each its own. counts still counts every
    /// finding, and full lists them one by one.
    static func grouped(_ messages: [Message]) -> [JSONDictionary] {
        var runs = [String: [Message]]()
        var order = [String]()
        for message in messages {
            let key = "\(message.level)|\(message.category)|\(message.title)"
            if runs[key] == nil { order.append(key) }
            runs[key, default: []].append(message)
        }
        return order.flatMap { key -> [JSONDictionary] in
            let run = runs[key]!
            guard run.count > 3 else { return run.map(\.json) }
            let first = run[0]
            var json: JSONDictionary = ["level": first.level, "category": first.category, "title": first.title, "count": run.count]
            let names = run.map { $0.refdes ?? $0.net ?? "" }
            if run.allSatisfy({ $0.refdes != nil }) { json["refdes"] = names }
            else if run.allSatisfy({ $0.net != nil }) { json["nets"] = names }
            if Set(run.map(\.detail)).count == 1 { json["detail"] = first.detail }
            else if names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count {
                json["details"] = Dictionary(uniqueKeysWithValues: zip(names, run.map(\.detail)))
            } else {
                json["details"] = run.map(\.detail)
            }
            return [json]
        }
    }

    private static func rulesMessages(project: HorizontalProject, board: HorizontalBoard) -> [Message] {
        guard let boardJSON = try? JSONHelper.loadDictionary(from: board.url),
              let rules = boardJSON["rules"] as? JSONDictionary else {
            return [Message(level: "info", category: "rules", title: "Board has no rules object", detail: "")]
        }
        let netClasses = HorizontalDesignIndex.schematics(of: project).first(where: \.block.isTop)?.schematic.netClasses
            ?? project.schematic?.netClasses
            ?? []
        let context = HorizontalBoardRuleContext(board: board, netClasses: netClasses)
        var seen = Set<String>()
        var messages = [Message]()
        for kind in HorizontalBoardRuleKind.visibleCases {
            for message in HorizontalBoardRulesValidator.validate(rules: rules, selectedKind: kind, context: context) {
                let key = "\(message.title)|\(message.detail)"
                guard seen.insert(key).inserted else {
                    continue
                }
                let level = message.level == .error ? "error" : "warning"
                messages.append(Message(level: level, category: "rules", title: message.title, detail: message.detail))
            }
        }
        return messages
    }
}
