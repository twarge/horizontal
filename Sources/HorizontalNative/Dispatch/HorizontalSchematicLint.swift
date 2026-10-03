import Foundation

/// What a sheet draws that connects nothing: wiring that reaches no pin, port
/// or bus ripper, whatever net its labels or power symbols name; wire ends
/// that stop at a bare junction; and wires whose ends name nothing at all.
/// Deleting parts leaves all three behind, and none of them is an error the
/// loader reports.
struct HorizontalSchematicDebris {
    struct Island {
        var junctions: [String] = []
        var lines: [String] = []
        var labels: [String] = []
        var powerSymbols: [String] = []
        var nets: Set<String> = []
        var position: [Int]?
    }

    /// A dead end, traced back to where it branches off wiring that goes
    /// somewhere. A run of several wires — rail, corner, nothing — is one
    /// stub, because pruning takes all of it.
    struct Stub {
        /// Every wire it takes, from the dead end back to the branch.
        var lines: [String] = []
        /// The junctions that go with them: the dead end and any corners.
        var junctions: [String] = []
        /// The bare junctions it stops at; more than one where dead ends meet.
        var ends: [String] = []
        /// The wire end it hangs from: a junction that stays, or a pin.
        var branch: JSONDictionary?
        /// Where the first dead end is.
        var position: [Int]?
    }

    private(set) var unanchored: [Island] = []
    private(set) var stubs: [Stub] = []
    private(set) var brokenLines: [String] = []

    init(sheet: JSONDictionary, block: JSONDictionary, symbolHasPin: (String, String) -> Bool) {
        let junctions = sheet.dictionaryMap("junctions")
        let position = { (id: String) -> [Int]? in
            junctions.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value["position"] as? [Int]
        }
        let junctionIDs = Set(junctions.keys.map { $0.lowercased() })
        let symbols = sheet.dictionaryMap("symbols").reduce(into: [String: JSONDictionary]()) { $0[$1.key.lowercased()] = $1.value }
        let lines = sheet.dictionaryMap("net_lines")

        func broken(_ end: JSONDictionary?) -> Bool {
            guard let end, HorizontalSchematicNetConnectivity.endpointID(end) != nil else { return true }
            if let junction = end.string("junc") { return !junctionIDs.contains(junction.lowercased()) }
            if let pin = end.string("pin") {
                let pieces = pin.lowercased().split(separator: "/").map(String.init)
                guard pieces.count == 2, let symbol = symbols[pieces[0]]?.string("symbol") else { return true }
                return !symbolHasPin(symbol, pieces[1])
            }
            return false
        }
        brokenLines = lines.filter { broken($0.value.dictionary("from")) || broken($0.value.dictionary("to")) }.keys.sorted()

        // Junctions a net tie or bus mark stands on hold something up even
        // with no pin in reach.
        var anchors = Set<String>()
        for key in ["bus_labels", "bus_rippers"] {
            for item in sheet.dictionaryMap(key).values {
                if let junction = item.string("junction") { anchors.insert("junc/" + junction.lowercased()) }
            }
        }
        for tie in sheet.dictionaryMap("net_ties").values {
            for end in ["from", "to"] {
                if let junction = tie.string(end) { anchors.insert("junc/" + junction.lowercased()) }
            }
        }

        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block, requiresKnownNet: false)
        var byIsland = [Int: Island]()
        func island(of endpoint: JSONDictionary) -> Int? {
            HorizontalSchematicNetConnectivity.endpointID(endpoint).flatMap { connectivity.islandOf[$0] }
        }
        func anchored(_ index: Int) -> Bool {
            connectivity.islands[index].members.contains { !$0.hasPrefix("junc/") || anchors.contains($0) }
        }
        let brokenSet = Set(brokenLines)
        for (id, line) in lines where !brokenSet.contains(id) {
            guard let from = line.dictionary("from"), let index = island(of: from), !anchored(index) else { continue }
            byIsland[index, default: Island()].lines.append(id)
        }
        for (key, table) in [("labels", "net_labels"), ("power", "power_symbols")] {
            for (id, mark) in sheet.dictionaryMap(table) {
                guard let junction = mark.string("junction") else { continue }
                guard let index = island(of: ["junc": junction]) else { continue }
                guard !anchored(index) else { continue }
                if key == "labels" { byIsland[index, default: Island()].labels.append(id) }
                else { byIsland[index, default: Island()].powerSymbols.append(id) }
            }
        }
        let markJunctions = ["net_labels", "power_symbols"].flatMap { table in
            sheet.dictionaryMap(table).values.compactMap { $0.string("junction")?.lowercased() }
        }
        for (index, var found) in byIsland {
            let members = connectivity.islands[index].members.filter { $0.hasPrefix("junc/") }.map { String($0.dropFirst(5)) }.sorted()
            found.junctions = members.compactMap { member in junctions.keys.first { $0.lowercased() == member } }
            found.nets = connectivity.islands[index].nets
            // Where to look: the label or power symbol if there is one — what
            // a reader sees — else the lowest, leftmost junction.
            let points = found.junctions.compactMap(position)
            found.position = markJunctions.first { members.contains($0) }.flatMap(position)
                ?? points.min { ($0[0], $0[1]) < ($1[0], $1[1]) }
            found.lines.sort(); found.labels.sort(); found.powerSymbols.sort()
            unanchored.append(found)
        }
        unanchored.sort { ($0.position?.first ?? 0, $0.position?.last ?? 0) < ($1.position?.first ?? 0, $1.position?.last ?? 0) }

        // A wire end at a junction nothing else uses goes nowhere. Peel such
        // ends back a wire at a time, until a junction that still leads
        // somewhere, a pin, or a label or power symbol stops it.
        let floating = Set(unanchored.flatMap(\.lines))
        var touching = [String: [String]]()
        for (id, line) in lines where !brokenSet.contains(id) && !floating.contains(id) {
            for end in ["from", "to"] {
                if let junction = line.dictionary(end)?.string("junc")?.lowercased() { touching[junction, default: []].append(id) }
            }
        }
        var marked = Set(anchors.map { String($0.dropFirst(5)) })
        for table in ["net_labels", "power_symbols"] {
            for mark in sheet.dictionaryMap(table).values {
                if let junction = mark.string("junction") { marked.insert(junction.lowercased()) }
            }
        }
        func junctionEnds(_ id: String) -> [String] {
            ["from", "to"].compactMap { lines[id]?.dictionary($0)?.string("junc")?.lowercased() }
        }
        var queue = touching.filter { $0.value.count == 1 && !marked.contains($0.key) }.keys.sorted()
        let deadEnds = Set(queue)
        var peeled = [String](), gone = [String](), goneSet = Set<String>()
        var next = 0
        while next < queue.count {
            let junction = queue[next]; next += 1
            guard !goneSet.contains(junction), let left = touching[junction], left.count == 1 else { continue }
            let id = left[0]
            peeled.append(id); gone.append(junction); goneSet.insert(junction)
            touching[junction] = []
            for other in junctionEnds(id) where other != junction {
                guard var rest = touching[other], let at = rest.firstIndex(of: id) else { continue }
                rest.remove(at: at)
                touching[other] = rest
                if rest.count == 1 && !marked.contains(other) { queue.append(other) }
            }
        }

        // One stub per run: wires joined through junctions that go with them.
        var parent = Dictionary(uniqueKeysWithValues: gone.map { ($0, $0) })
        func root(_ junction: String) -> String {
            var junction = junction
            while let up = parent[junction], up != junction { junction = up }
            return junction
        }
        for id in peeled {
            let ends = junctionEnds(id).filter(goneSet.contains)
            if ends.count == 2 { parent[root(ends[0])] = root(ends[1]) }
        }
        let original = junctions.keys.reduce(into: [String: String]()) { $0[$1.lowercased()] = $1 }
        var runs = [String: Stub]()
        for junction in gone {
            let key = original[junction] ?? junction
            runs[root(junction), default: Stub()].junctions.append(key)
            if deadEnds.contains(junction) { runs[root(junction), default: Stub()].ends.append(key) }
        }
        for id in peeled {
            guard let run = junctionEnds(id).first(where: goneSet.contains).map(root) else { continue }
            runs[run, default: Stub()].lines.append(id)
            for end in ["from", "to"] {
                guard let endpoint = lines[id]?.dictionary(end) else { continue }
                if let junction = endpoint.string("junc")?.lowercased(), goneSet.contains(junction) { continue }
                runs[run]?.branch = endpoint
            }
        }
        stubs = runs.values.map { run in
            var run = run
            run.position = run.ends.first.flatMap(position)
            return run
        }
        stubs.sort { ($0.position?.first ?? 0, $0.position?.last ?? 0, $0.lines.first ?? "") < ($1.position?.first ?? 0, $1.position?.last ?? 0, $1.lines.first ?? "") }
    }

    static func point(_ position: [Int]?) -> JSONDictionary? {
        guard let position, position.count == 2 else { return nil }
        return ["x_mm": HorizontalDispatchJSON.mm(Double(position[0])), "y_mm": HorizontalDispatchJSON.mm(Double(position[1]))]
    }
}

/// Places a sheet looks connected and is not: a wire running over a pin it
/// does not end on, junctions on the same spot that no wire joins, and a wire
/// ending in the middle of another without a junction there. Each is a short
/// or an open someone reading the schematic will not see.
struct HorizontalSchematicOverlaps {
    struct Finding {
        var kind: String
        var position: [Int]
        var detail: JSONDictionary
    }

    private(set) var findings: [Finding] = []

    /// `pinTips` gives every drawn pin's connection point, keyed by
    /// "symbolInstance/pin" in lowercase.
    init(sheet: JSONDictionary, block: JSONDictionary, pinTips: [String: [Int]]) {
        let junctions = sheet.dictionaryMap("junctions").reduce(into: [String: [Int]]()) { result, item in
            if let position = item.value["position"] as? [Int], position.count == 2 { result[item.key.lowercased()] = position }
        }
        let connectivity = HorizontalSchematicNetConnectivity(sheet: sheet, block: block, requiresKnownNet: false)
        func islandOf(_ id: String) -> Int? { connectivity.islandOf[id] }

        struct Segment { var id: String; var a: [Int]; var b: [Int]; var ends: Set<String> }
        var segments = [Segment]()
        for (id, line) in sheet.dictionaryMap("net_lines") {
            func resolve(_ end: JSONDictionary?) -> (point: [Int], identity: String)? {
                guard let end else { return nil }
                if let junction = end.string("junc")?.lowercased(), let point = junctions[junction] { return (point, "junc/" + junction) }
                if let pin = end.string("pin")?.lowercased(), let point = pinTips[pin] { return (point, "pin/" + pin) }
                return nil
            }
            guard let a = resolve(line.dictionary("from")), let b = resolve(line.dictionary("to")) else { continue }
            segments.append(Segment(id: id, a: a.point, b: b.point, ends: [a.identity, b.identity]))
        }
        func on(_ p: [Int], _ s: Segment, interior: Bool) -> Bool {
            let (ax, ay, bx, by, px, py) = (Int64(s.a[0]), Int64(s.a[1]), Int64(s.b[0]), Int64(s.b[1]), Int64(p[0]), Int64(p[1]))
            guard (bx - ax) * (py - ay) - (by - ay) * (px - ax) == 0,
                  min(ax, bx) <= px, px <= max(ax, bx), min(ay, by) <= py, py <= max(ay, by) else { return false }
            return !interior || (p != s.a && p != s.b)
        }

        // A pin under a wire it is not an end of.
        for (pin, tip) in pinTips.sorted(by: { $0.key < $1.key }) {
            for segment in segments where !segment.ends.contains("pin/" + pin) && on(tip, segment, interior: false) {
                findings.append(Finding(kind: "wire_over_pin", position: tip, detail: ["pin": pin, "net_line": segment.id]))
            }
            for (junction, point) in junctions where point == tip {
                let wiredToPin = segments.contains { $0.ends.contains("junc/" + junction) && $0.ends.contains("pin/" + pin) }
                if !wiredToPin && !segments.contains(where: { $0.ends.contains("junc/" + junction) && on(tip, $0, interior: false) }) {
                    findings.append(Finding(kind: "junction_on_pin", position: tip, detail: ["pin": pin, "junction": junction]))
                }
            }
        }
        // Junctions sharing a point that no wire joins.
        let byPoint = Dictionary(grouping: junctions.keys.sorted()) { junctions[$0]! }
        for (point, ids) in byPoint.sorted(by: { ($0.key[0], $0.key[1]) < ($1.key[0], $1.key[1]) }) where ids.count > 1 {
            let islands = Set(ids.compactMap { islandOf("junc/" + $0) })
            if islands.count > 1 {
                findings.append(Finding(kind: "unjoined_junctions", position: point, detail: ["junctions": ids]))
            }
        }
        // A wire ending part way along another.
        for segment in segments {
            for end in segment.ends where end.hasPrefix("junc/") {
                guard let point = junctions[String(end.dropFirst(5))] else { continue }
                for other in segments where other.id != segment.id && !other.ends.contains(end) && on(point, other, interior: true) {
                    let same = islandOf(end) != nil && islandOf(end) == other.ends.first.flatMap(islandOf)
                    findings.append(Finding(kind: "t_without_junction", position: point,
                                            detail: ["net_line": segment.id, "crossed_line": other.id, "same_net": same]))
                }
            }
        }
    }
}

/// Which drawn symbol a free text sits by. Nothing in the file ties a note to
/// the parts it describes, so nearness is the evidence there is: the distance
/// to the closest point the symbol occupies — its origin or a pin tip.
enum HorizontalSchematicTextProximity {
    static func reach(of symbol: JSONDictionary, pool: HorizontalDispatchPoolIndex) -> [HorizontalPoint] {
        let transform = (HorizontalPlacementTransform(json: symbol.dictionary("placement")) ?? .identity).schematicGeometry
        let pins = symbol.string("symbol").map { pool.symbolPins($0) } ?? [:]
        return [transform.shift] + pins.values.map { transform.applying(to: $0.position) }
    }

    static func position(of text: JSONDictionary) -> HorizontalPoint {
        let shift = text.dictionary("placement")?["shift"] as? [Any] ?? []
        return HorizontalPoint(x: JSONHelper.doubleValue(shift.first ?? 0), y: JSONHelper.doubleValue(shift.count > 1 ? shift[1] : 0))
    }

    /// The closest symbol instance to `point` among `symbols`, and how far, in nanometres.
    static func nearest(to point: HorizontalPoint, symbols: [String: JSONDictionary],
                        pool: HorizontalDispatchPoolIndex) -> (id: String, distance: Double)? {
        symbols.compactMap { id, symbol -> (id: String, distance: Double)? in
            let distances = reach(of: symbol, pool: pool).map { hypot($0.x - point.x, $0.y - point.y) }
            return distances.min().map { (id, $0) }
        }.min { ($0.distance, $0.id) < ($1.distance, $1.id) }
    }
}
