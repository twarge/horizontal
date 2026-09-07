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

    static func run(entry: HorizontalDispatchProjectEntry) -> JSONDictionary {
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
                let resolvedName = index.net(id: netID)?.name ?? ""
                let name = resolvedName.isEmpty ? netID : resolvedName
                let count = "\(airwires.count) airwire\(airwires.count == 1 ? "" : "s")"
                if netsWithPlanes.contains(netID) {
                    messages.append(Message(level: "info", category: "routing", title: "Not reached by the plane", detail: "\(count) on a net with a plane: the fill does not reach these pads, or the plane is not poured.", net: name))
                } else {
                    messages.append(Message(level: "warning", category: "routing", title: "Unrouted connections", detail: "\(count) remain.", net: name))
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
            "messages": messages.map(\.json),
            "note": "Horizontal has no geometric design rule check yet; these are load diagnostics, rules validation, and connectivity facts. Poured planes count as copper for the rats' nest."
        ]
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
