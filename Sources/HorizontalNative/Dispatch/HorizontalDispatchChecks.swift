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

        var json: JSONDictionary {
            var json: JSONDictionary = ["level": level, "category": category, "title": title, "detail": detail]
            if let refdes { json["refdes"] = refdes }
            if let net { json["net"] = net }
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
                    messages.append(Message(level: "info", category: "routing", title: "Not reached by the plane", detail: "\(count) on a net with a plane\(pins): the fill does not reach these pads, or the plane is not poured.", net: name))
                } else {
                    messages.append(Message(level: "warning", category: "routing", title: "Unrouted connections", detail: "\(count) \(airwires.count == 1 ? "remains" : "remain")\(pins).", net: name))
                }
            }
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
            return (lhs.refdes ?? lhs.net ?? lhs.title).localizedStandardCompare(rhs.refdes ?? rhs.net ?? rhs.title) == .orderedAscending
        }
        let counts = Dictionary(grouping: messages, by: \.level).mapValues(\.count)
        return [
            "ok": (counts["error"] ?? 0) == 0,
            "counts": ["error": counts["error"] ?? 0, "warning": counts["warning"] ?? 0, "info": counts["info"] ?? 0],
            "messages": full ? messages.map(\.json) : grouped(messages),
            "note": "Horizontal has no geometric design rule check yet; these are load diagnostics, rules validation, and connectivity facts, plus the components and board packages nothing has placed. Poured planes count as copper for the rats' nest."
        ]
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
