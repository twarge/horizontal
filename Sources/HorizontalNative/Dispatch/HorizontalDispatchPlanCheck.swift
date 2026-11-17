import Foundation

/// A dry run's `check`: the board checks on the board the plan would leave,
/// set against the same checks on the board as it is, so the reply says what
/// the plan breaks and what it fixes before anything is committed.
///
/// The staged project a dry run already loads is a whole board, and the
/// checks are functions of a board, so nothing here is a second measure of
/// anything: the findings are `check`'s, on another board.
enum HorizontalDispatchPlanCheck {
    /// One board's findings, kept to compare another's against.
    struct State {
        struct Finding {
            var key: String
            var json: JSONDictionary
            var level: String
            /// The ids of what it is about: tracks, vias, pads' paths, packages.
            var objects: [String]
            var clearance: HorizontalClearanceFinding?
        }

        var findings: [Finding] = []
        var airwires: [String: Int] = [:]
        var airwireCount = 0
        var planes = "none"
        var board: HorizontalBoard
    }

    /// The most findings of one list a reply carries; `*_count` gives the rest.
    static let listLimit = 200

    static func mode(_ params: JSONDictionary) throws -> String? {
        guard let value = params["check"] else { return nil }
        guard let mode = value as? String, ["delta", "full"].contains(mode) else {
            throw HorizontalDispatchError.invalidParams("check is \"delta\" or \"full\".")
        }
        guard params.bool("dry_run") == true else {
            throw HorizontalDispatchError.invalidParams("check goes with dry_run: it reports on a plan, and a commit's board is what the check method reads.")
        }
        return mode
    }

    /// The checks on `board`, re-poured first when `pour`. `connect` runs the
    /// editor's connectivity pass, which a board loaded for a live document
    /// has not had and a pour always needs again.
    static func state(of project: HorizontalProject, board: HorizontalBoard, pour: Bool, connect: Bool) -> State {
        var board = board
        var planes = board.planes.isEmpty ? "none" : "stale"
        if pour, !board.planes.isEmpty {
            board = HorizontalBoardPlaneUpdater.updateAllPlanes(in: board)
            planes = "repoured"
        }
        if connect || planes == "repoured" {
            board = HorizontalBoardConnectivity.recompute(board)
            board.regenerateAirwires()
        }
        var state = State(board: board)
        state.planes = planes
        for airwire in board.airwires {
            state.airwires[airwire.netID?.lowercased() ?? "", default: 0] += 1
        }
        state.airwireCount = board.airwires.count
        guard let results = HorizontalBoardRulesCheck.run(board: board, tiedNets: HorizontalBoardClearanceCheck.tiedNets(of: project)) else {
            return state
        }
        for finding in results.clearance {
            guard let json = HorizontalDispatchChecks.clearanceMessages([finding]).first?.json else { continue }
            state.findings.append(.init(key: finding.id, json: json, level: "error",
                                        objects: [finding.first.id, finding.second.id].filter { !$0.isEmpty }, clearance: finding))
        }
        var seen = Set<String>()
        for finding in results.findings {
            // Airwires are counted on their own, net by net.
            guard finding.check != "airwire" else { continue }
            let json: JSONDictionary
            if let message = HorizontalDispatchChecks.ruleMessages([finding]).first {
                json = message.json
            } else if finding.kind == nil {
                // Horizontal's own copper checks, which `check` words itself.
                var own: JSONDictionary = ["level": finding.level.rawValue, "category": "copper", "title": finding.title,
                                           "detail": finding.text, "check": finding.check]
                if let at = finding.location {
                    own["x_mm"] = HorizontalDispatchJSON.mm(at.x)
                    own["y_mm"] = HorizontalDispatchJSON.mm(at.y)
                }
                if !finding.objectIDs.isEmpty { own["objects"] = finding.objectIDs }
                if !finding.netNames.isEmpty { own["net"] = finding.netNames.joined(separator: " / ") }
                json = own
            } else {
                continue
            }
            // What a finding is about and what it says, not where: a net in
            // unconnected groups names whichever group is smallest, which a
            // plan that leaves the net alone can change.
            let about = finding.kind == .boardConnectivity ? finding.netIDs : finding.objectIDs.sorted()
            let identity = "\(finding.kind?.rawValue ?? "copper")|\(finding.check)|\(finding.message)|\(about.joined(separator: ","))"
            // Two findings alike in every word are one to a reader.
            var key = identity
            var copy = 2
            while !seen.insert(key).inserted {
                key = "\(identity)#\(copy)"
                copy += 1
            }
            state.findings.append(.init(key: key, json: json, level: finding.level.rawValue,
                                        objects: finding.objectIDs + finding.componentIDs, clearance: nil))
        }
        return state
    }

    /// The `check` block of a dry run's reply.
    static func run(entry: HorizontalDispatchProjectEntry, staged: HorizontalProject, result: JSONDictionary,
                    mode: String, pour: Bool) -> JSONDictionary {
        guard let current = entry.project.board, let planned = staged.board else {
            return ["note": "The project has no board, so there is nothing for the board checks to read."]
        }
        let key = "\(entry.revision)|\(entry.livePlaneFillRevision)|\(pour)"
        let before: State
        if let cached = entry.cachedBoardCheck, cached.key == key {
            before = cached.state
        } else {
            before = state(of: entry.project, board: current, pour: pour, connect: false)
            entry.cachedBoardCheck = (key, before)
        }
        let after = state(of: staged, board: planned, pour: pour, connect: entry.live != nil)

        let stretched = stretchedTracks(before: before.board, after: after.board)
        let opIDs = idsByOp(result, stretched: stretched)
        func fromOps(_ finding: State.Finding) -> [Int] {
            let parts = Set(finding.objects.flatMap { $0.lowercased().split(separator: "/").map(String.init) })
            return opIDs.enumerated().filter { !$0.element.isDisjoint(with: parts) }.map(\.offset)
        }

        let beforeKeys = Set(before.findings.map(\.key)), afterKeys = Set(after.findings.map(\.key))
        let introduced = after.findings.filter { !beforeKeys.contains($0.key) }.map { finding -> JSONDictionary in
            var json = finding.json
            json["from_ops"] = fromOps(finding)
            return json
        }
        var afterItems: HorizontalBoardItems?
        let resolved = before.findings.filter { !afterKeys.contains($0.key) }.map { finding -> JSONDictionary in
            var json = finding.json
            // How far apart the two are now, where both are still there.
            if let clearance = finding.clearance, clearance.check == .copper || clearance.check == .hole {
                let items = afterItems ?? HorizontalBoardItems(board: after.board)
                afterItems = items
                if let gap = gap(clearance.first.id, clearance.second.id, in: items) {
                    json["now_distance_mm"] = HorizontalDispatchJSON.mm(gap)
                } else {
                    json["now"] = "gone"
                }
            }
            return json
        }
        let unchanged = after.findings.filter { beforeKeys.contains($0.key) }

        func counts(_ findings: [State.Finding]) -> JSONDictionary {
            ["error": findings.filter { $0.level == "error" }.count, "warning": findings.filter { $0.level == "warning" }.count]
        }
        func capped(_ list: [JSONDictionary], _ name: String, into json: inout JSONDictionary) {
            json[name] = Array(list.prefix(listLimit))
            if list.count > listLimit {
                json[name + "_count"] = list.count
                json["truncated"] = true
            }
        }
        func name(_ net: String) -> String {
            let name = after.board.netDetails[net]?.name ?? before.board.netDetails[net]?.name ?? ""
            return name.isEmpty ? (net.isEmpty ? "no net" : net) : name
        }
        let grown = after.airwires.filter { $0.value > before.airwires[$0.key, default: 0] }.keys.map(name)
        let cleared = before.airwires.filter { $0.value > after.airwires[$0.key, default: 0] }.keys.map(name)

        var check: JSONDictionary = ["mode": mode, "planes": after.planes]
        capped(introduced, "introduced", into: &check)
        capped(resolved, "resolved", into: &check)
        check["unchanged"] = counts(unchanged)
        check["counts"] = ["before": counts(before.findings), "after": counts(after.findings)] as JSONDictionary
        check["airwires"] = [
            "before": before.airwireCount, "after": after.airwireCount,
            "nets": grown.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "nets_routed": cleared.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
        ] as JSONDictionary
        capped(stretched.map(\.json), "stretched", into: &check)
        if mode == "full" {
            capped(after.findings.map(\.json), "findings", into: &check)
        }
        check["ok"] = introduced.isEmpty && after.airwireCount <= before.airwireCount
        if after.planes == "stale" {
            check["note"] = "The planes' fills are as last poured, so clearance to them and the silkscreen rule, which measures to copper the mask leaves bare, fills included, may be measured against copper that will move. pour: true pours them again on both boards first."
        }
        return check
    }

    // MARK: - Where a placed text draws

    /// Gives each place_board_text change the box the text fills on the
    /// staged board and the way it runs, so a label is placed by its reply
    /// and not by a render.
    static func annotateTexts(_ result: inout JSONDictionary, staged: HorizontalProject) {
        guard var changes = result["changes"] as? [JSONDictionary], let board = staged.board,
              changes.contains(where: { $0.string("op") == HorizontalEditOperationKind.placeBoardText.rawValue }) else { return }
        let extents = HorizontalDispatchBoardGeometry.textExtents(board)
        for index in changes.indices where changes[index].string("op") == HorizontalEditOperationKind.placeBoardText.rawValue {
            guard let id = changes[index].string("id")?.lowercased(), let extent = extents[id] else { continue }
            changes[index]["box_mm"] = HorizontalDispatchBoardGeometry.box(extent.box)
            changes[index]["runs"] = extent.runs
        }
        result["changes"] = changes
    }

    // MARK: - Stretched tracks

    struct Stretched {
        var track: String
        var end: String
        var pad: String?
        var package: String?
        var was: HorizontalPoint
        var now: HorizontalPoint

        var json: JSONDictionary {
            var json: JSONDictionary = ["track": track, "end": end, "was_mm": HorizontalDispatchJSON.point(was),
                                        "now_mm": HorizontalDispatchJSON.point(now)]
            if let pad { json["pad"] = pad }
            if let package { json["package"] = package }
            return json
        }
    }

    /// The tracks an end of which a part carried with it: the end is on a
    /// pad, not a junction, and is somewhere else on the planned board.
    static func stretchedTracks(before: HorizontalBoard, after: HorizontalBoard) -> [Stretched] {
        let old = Dictionary(before.tracks.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ point: HorizontalPoint) -> String { "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))" }
        var padAt = [String: String]()
        for (path, point) in after.packagePadPositions { padAt[key(point)] = path.lowercased() }
        let names = HorizontalBoardRulesCheck.padNames(after)
        var stretched = [Stretched]()
        for track in after.tracks {
            guard let was = old[track.id.lowercased()] else { continue }
            for (end, junction, from, to) in [("from", track.fromJunctionID, was.from, track.from), ("to", track.toJunctionID, was.to, track.to)] {
                guard junction == nil, hypot(from.x - to.x, from.y - to.y) >= 1 else { continue }
                let path = padAt[key(to)]
                stretched.append(Stretched(track: track.id, end: end, pad: path.flatMap { names[$0] },
                                           package: path.flatMap { $0.split(separator: "/").first.map(String.init) },
                                           was: from, now: to))
            }
        }
        return stretched.sorted { ($0.track, $0.end) < ($1.track, $1.end) }
    }

    // MARK: - Which op

    /// For each op of the batch, the ids its change names, and the tracks a
    /// package it names carried with it.
    static func idsByOp(_ result: JSONDictionary, stretched: [Stretched]) -> [Set<String>] {
        guard let changes = result["changes"] as? [JSONDictionary] else { return [] }
        return changes.map { change in
            var ids = Set<String>()
            func take(_ value: Any) {
                if let text = value as? String {
                    for part in text.split(separator: "/") where part.count == 36 && UUID(uuidString: String(part)) != nil {
                        ids.insert(part.lowercased())
                    }
                } else if let list = value as? [Any] {
                    list.forEach(take)
                } else if let table = value as? JSONDictionary {
                    table.values.forEach(take)
                }
            }
            change.values.forEach(take)
            for track in stretched {
                if let package = track.package, ids.contains(package) { ids.insert(track.track.lowercased()) }
            }
            return ids
        }
    }

    // MARK: - A pair, measured again

    /// The least gap between the items of two ids on a layer they share; nil
    /// when either is gone.
    static func gap(_ first: String, _ second: String, in items: HorizontalBoardItems) -> Double? {
        let a = items.items.filter { $0.id.caseInsensitiveCompare(first) == .orderedSame }
        let b = items.items.filter { $0.id.caseInsensitiveCompare(second) == .orderedSame }
        var least: Double?
        for one in a {
            for other in b where one.layerMin <= other.layerMax && other.layerMin <= one.layerMax {
                if let gap = HorizontalShapeGap.between(one.shape, other.shape) {
                    least = min(least ?? gap.distance, gap.distance)
                }
            }
        }
        return least
    }
}
