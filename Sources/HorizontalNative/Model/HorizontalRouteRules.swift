import Foundation

// What the board's rules ask of a track being routed, for the route
// inspector: the width it takes and where that came from, the clearance it
// keeps from each kind of thing it passes and the rule each comes from, and
// the edits that change those rules. Pure, so it is tested without a canvas.

/// Where a route's width comes from. It decides what the inspector says, and
/// whether the width follows the route onto another layer or net, or a change
/// to the rules.
enum HorizontalRouteWidthSource: Hashable {
    /// Set with W, the tool settings or the inspector, for this route and
    /// the next until it is cleared.
    case custom
    /// The width of the track the route started on, which it continues, as
    /// Horizon's router inherits the width of the track it starts from.
    case track(id: String)
    /// The first track width rule by order that takes the route's net, on
    /// its layer (BoardRules::get_default_track_width).
    case rule(id: String)
    /// No track width rule takes the net: the width most of its tracks have,
    /// else most of the board's.
    case existingTracks
    /// Nothing to go on: 0.2 mm, RuleTrackWidth's own default.
    case fallback

    /// Whether the width is a track width rule's, so the tracks the route
    /// lays take it from the rules (`HorizontalSegment.widthFromRules`).
    var isRule: Bool {
        if case .rule = self { true } else { false }
    }

    /// Whether the width is the rules' to give, so that a route moving to
    /// another layer or net, or a change to the rules, gives it again.
    var followsRules: Bool {
        switch self {
        case .custom, .track: false
        case .rule, .existingTracks, .fallback: true
        }
    }
}

enum HorizontalRouteWidth {
    struct Resolution: Equatable {
        var width: Double
        var source: HorizontalRouteWidthSource
    }

    /// The width the board gives a track on `net` on `layer` when nothing
    /// pins it: the matching track width rule's default; where no rule takes
    /// the net, the width most of its tracks (or the board's) have; else
    /// 0.2 mm.
    static func fromRules(
        net: String?,
        layer: Int,
        rules: HorizontalBoardRules,
        tracks: [HorizontalSegment]
    ) -> Resolution {
        if let match = rules.trackWidth(net: net, layer: layer), match.widths.def > 0 {
            return Resolution(width: match.widths.def, source: .rule(id: match.rule.id))
        }
        if let width = BoardTrackRouting.commonWidth(tracks: tracks, net: net) {
            return Resolution(width: width, source: .existingTracks)
        }
        return Resolution(width: BoardTrackRouting.defaultTrackWidth, source: .fallback)
    }

    /// A route's width as it starts. On a pad, the rules' (`fromRules`); on a
    /// track, the track's, or the rules' for a track whose width is theirs,
    /// as Horizon's router inherits a track's width and whether it is
    /// explicit; anywhere else a custom width when one is set, else the rules'.
    static func start(
        explicit: Double?,
        onPad: Bool = false,
        startTrack: HorizontalSegment?,
        net: String?,
        layer: Int,
        rules: HorizontalBoardRules,
        tracks: [HorizontalSegment]
    ) -> Resolution {
        if onPad {
            return fromRules(net: net, layer: layer, rules: rules, tracks: tracks)
        }
        if let startTrack, startTrack.width > 0 {
            if startTrack.widthFromRules, rules.trackWidth(net: net, layer: layer) != nil {
                return fromRules(net: net, layer: layer, rules: rules, tracks: tracks)
            }
            return Resolution(width: startTrack.width, source: .track(id: startTrack.id))
        }
        if let explicit, explicit > 0 {
            return Resolution(width: explicit, source: .custom)
        }
        return fromRules(net: net, layer: layer, rules: rules, tracks: tracks)
    }
}

/// Horizon's Apply for the track width rules (`BoardRules::apply` for
/// `RuleID::TRACK_WIDTH`): every track and net tie whose width is the rules'
/// (`HorizontalSegment.widthFromRules`), on a net, takes the default width of
/// the first enabled rule by order that takes its net, on its layer.
enum HorizontalTrackWidthRules {
    /// Applies them to `board`, and returns the ids of the tracks and net ties
    /// it changed. Where no rule takes the net Horizon gives the track a width
    /// of 0, which no fabricator makes; this leaves it as it is.
    @discardableResult
    static func apply(to board: inout HorizontalBoard) -> [String] {
        var changed = [String]()
        func apply(_ segments: inout [HorizontalSegment]) {
            for index in segments.indices {
                let segment = segments[index]
                guard segment.widthFromRules, let net = segment.netID, let layer = segment.layer,
                      let rule = board.rules.trackWidth(net: net, layer: layer), rule.widths.def > 0,
                      segment.width != rule.widths.def else {
                    continue
                }
                segments[index].width = rule.widths.def
                changed.append(segment.id)
            }
        }
        apply(&board.tracks)
        apply(&board.netTies)
        return changed
    }
}

extension HorizontalPatchType {
    /// The rule tables' own spelling, as `init(jsonString:)` reads it.
    var jsonString: String {
        switch self {
        case .other: "other"
        case .track: "track"
        case .pad: "pad"
        case .padTH: "pad_th"
        case .via: "via"
        case .plane: "plane"
        case .holePTH: "hole_pth"
        case .holeNPTH: "hole_npth"
        case .boardEdge: "board_edge"
        case .text: "text"
        case .netTie: "net_tie"
        }
    }

    /// As the rules window titles it.
    var routeTitle: String {
        switch self {
        case .other: "Other"
        case .track: "Track"
        case .pad: "Pad"
        case .padTH: "TH pad"
        case .via: "Via"
        case .plane: "Plane"
        case .holePTH: "PTH hole"
        case .holeNPTH: "NPTH hole"
        case .boardEdge: "Board edge"
        case .text: "Text"
        case .netTie: "Net tie"
        }
    }
}

extension HorizontalRuleMatch {
    /// What the match takes, as RuleMatch::get_brief says it.
    func brief(netDetails: [String: HorizontalNetDetails], netClassNames: [String: String]) -> String {
        switch mode {
        case .all:
            return "All"
        case .net:
            return "Net " + (net.flatMap { netDetails[$0]?.name } ?? "?")
        case .nets:
            switch nets.count {
            case 0: return "No nets"
            case 1: return "One net"
            default: return "\(nets.count) nets"
            }
        case .netClass:
            return "Net class " + (netClass.flatMap { netClassNames[$0] } ?? "?")
        case .netNameRegex:
            return "Net name regex"
        case .netClassRegex:
            return "Net class regex"
        }
    }
}

/// Names for what the rules talk about: nets, net classes and layers.
struct HorizontalRouteRuleNames {
    var netDetails: [String: HorizontalNetDetails]
    /// Net class id (lowercased) to name.
    var netClassNames: [String: String]

    init(netDetails: [String: HorizontalNetDetails], netClasses: [HorizontalNetClass]) {
        self.netDetails = netDetails
        var names = [String: String]()
        for detail in netDetails.values {
            if let id = detail.netClassID, let name = detail.netClassName {
                names[id.lowercased()] = name
            }
        }
        for netClass in netClasses {
            names[netClass.id.lowercased()] = netClass.name
        }
        netClassNames = names
    }

    func match(_ match: HorizontalRuleMatch) -> String {
        match.brief(netDetails: netDetails, netClassNames: netClassNames)
    }

    static func layer(_ layer: Int) -> String {
        layer == 10000 ? "Any layer" : HorizontalBoardLayers.name(for: layer)
    }
}

/// The clearances a track on one net keeps on one layer, by what it passes,
/// with the rule each comes from: the inspector's Clearance list.
struct HorizontalRouteSpacing: Equatable {
    enum Table: Hashable {
        /// clearance_copper: between copper of two nets.
        case copper
        /// clearance_copper_other: between copper and what isn't copper.
        case copperOther
        /// clearance_copper_keepout, for keepouts of one class.
        case keepout(String)
    }

    /// The rule a clearance comes from. `id` nil is none: Horizon's 0.1 mm
    /// (0 for a keepout), which an edit gives a catch-all rule of its own.
    struct Rule: Equatable {
        var id: String?
        var brief: String
    }

    struct Row: Identifiable, Equatable {
        var table: Table
        /// What the track passes.
        var other: HorizontalPatchType
        var title: String
        var clearance: Double
        var rule: Rule

        var id: String {
            switch table {
            case .copper: "copper/\(other.jsonString)"
            case .copperOther: "other/\(other.jsonString)"
            case .keepout(let keepoutClass): "keepout/\(keepoutClass)"
            }
        }
    }

    /// A copper clearance rule other than the main one, which some of the
    /// other nets get instead: how many, and the most it asks of a track.
    struct OtherCopperRule: Identifiable, Equatable {
        var rule: Rule
        var netCount: Int
        var widest: Double

        var id: String { rule.id ?? "" }
    }

    /// The copper clearance rule most other nets get with this one.
    var copperRule: Rule
    var otherRule: Rule
    var rows: [Row]
    var otherCopperRules: [OtherCopperRule]

    /// What a track is cleared from in the copper table, and in the
    /// copper-to-other one.
    static let copperTypes: [HorizontalPatchType] = [.track, .pad, .padTH, .via, .plane]
    static let otherTypes: [HorizontalPatchType] = [.boardEdge, .holeNPTH]

    /// The clearances for a track on `net` on `layer`. The copper rule
    /// depends on the other net too, so it is the one most of `otherNets`
    /// (nil for copper on no net) get; the rest are listed with how many nets
    /// they take. `keepoutClasses` are the classes of the keepouts on the
    /// board that bar tracks.
    static func make(
        net: String?,
        layer: Int,
        rules: HorizontalBoardRules,
        otherNets: [String?],
        keepoutClasses: [String],
        names: HorizontalRouteRuleNames
    ) -> HorizontalRouteSpacing {
        func copperBrief(_ rule: HorizontalRuleClearanceCopper) -> Rule {
            guard !rule.id.isEmpty else {
                return Rule(id: nil, brief: "No rule — Horizon's 0.1 mm")
            }
            return Rule(
                id: rule.id,
                brief: "\(names.match(rule.match1)) / \(names.match(rule.match2)) · \(HorizontalRouteRuleNames.layer(rule.layer))")
        }

        // Which copper rule each other net gets with this one, by rule id ("" is
        // the fallback), keeping the first rule of each in order of appearance.
        var counts = [String: Int]()
        var byID = [String: HorizontalRuleClearanceCopper]()
        var firstSeen = [String]()
        for other in otherNets {
            let rule = rules.clearanceCopper(net1: net, net2: other, layer: layer)
            if byID[rule.id] == nil {
                byID[rule.id] = rule
                firstSeen.append(rule.id)
            }
            counts[rule.id, default: 0] += 1
        }
        if firstSeen.isEmpty {
            let rule = rules.clearanceCopper(net1: net, net2: nil, layer: layer)
            byID[rule.id] = rule
            firstSeen = [rule.id]
            counts[rule.id] = 0
        }
        let ranked = firstSeen.enumerated().sorted { lhs, rhs in
            let lhsCount = counts[lhs.element] ?? 0
            let rhsCount = counts[rhs.element] ?? 0
            return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
        }.map(\.element)
        let main = byID[ranked[0]]!

        let other = rules.clearanceCopperOther(net: net, layer: layer)
        let otherRule = other.id.isEmpty
            ? Rule(id: nil, brief: "No rule — Horizon's 0.1 mm")
            : Rule(id: other.id, brief: "\(names.match(other.match)) · \(HorizontalRouteRuleNames.layer(other.layer))")

        var rows = copperTypes.map { type in
            Row(table: .copper, other: type, title: type.routeTitle,
                clearance: Double(main.clearance(.track, type)), rule: copperBrief(main))
        }
        rows += otherTypes.map { type in
            Row(table: .copperOther, other: type, title: type.routeTitle,
                clearance: Double(other.clearance(copper: .track, nonCopper: type)), rule: otherRule)
        }
        for keepoutClass in keepoutClasses {
            let rule = rules.clearanceCopperKeepout(net: net, keepoutClass: keepoutClass)
            let source = rule.id.isEmpty
                ? Rule(id: nil, brief: "No rule — no clearance")
                : Rule(id: rule.id, brief: "\(names.match(rule.match)) / keepouts")
            rows.append(Row(
                table: .keepout(keepoutClass), other: .track,
                title: keepoutClass.isEmpty ? "Keepout" : "Keepout \(keepoutClass)",
                clearance: Double(rule.clearance(.track)), rule: source))
        }

        let others = ranked.dropFirst().compactMap { id -> OtherCopperRule? in
            guard let rule = byID[id] else { return nil }
            let widest = copperTypes.map { Double(rule.clearance(.track, $0)) }.max() ?? 0
            return OtherCopperRule(rule: copperBrief(rule), netCount: counts[id] ?? 0, widest: widest)
        }

        return HorizontalRouteSpacing(
            copperRule: copperBrief(main),
            otherRule: otherRule,
            rows: rows,
            otherCopperRules: others
        )
    }
}

/// A change the route inspector makes to the board's rules.
enum HorizontalRouteRuleEdit: Equatable {
    /// A track width rule's widths on one layer.
    case trackWidth(ruleID: String, layer: Int, widths: HorizontalRuleTrackWidth.Widths)
    /// A new track width rule that takes every net, after the others, with
    /// `width` as its default on `layer` and Horizon's widths on the other
    /// copper layers: what a board none of whose rules take the net gets.
    case addTrackWidthRule(layer: Int, width: Double)
    /// One entry of a copper clearance rule's table. With no rule, a new one
    /// that takes every pair of nets on every layer, after the others.
    case copperClearance(ruleID: String?, HorizontalPatchType, HorizontalPatchType, Double)
    /// One entry of a copper-to-other clearance rule's table, as above.
    case copperOtherClearance(ruleID: String?, copper: HorizontalPatchType, nonCopper: HorizontalPatchType, Double)
    /// A copper keepout clearance rule's entry for one kind of copper. With
    /// no rule, a new one for keepouts of `keepoutClass`.
    case keepoutClearance(ruleID: String?, keepoutClass: String, copper: HorizontalPatchType, Double)
    /// A via rule's `via_diameter` and `hole_diameter`. The rule as the board
    /// has it, since a board whose file states no via rule is given Horizon's
    /// at load, which the file doesn't have yet.
    case viaParameters(rule: HorizontalRuleVia, diameter: Double, holeDiameter: Double)
    /// A new via rule that takes every net, after the others, with
    /// `padstackID` at this size: what a board none of whose via rules take
    /// the net gets, so V has a via to drop.
    case addViaRule(padstackID: String, diameter: Double, holeDiameter: Double)

    var actionName: String {
        switch self {
        case .trackWidth: "Change Track Width Rule"
        case .addTrackWidthRule: "Add Track Width Rule"
        case .viaParameters: "Change Via Rule"
        case .addViaRule: "Add Via Rule"
        case .copperClearance(let ruleID, _, _, _), .copperOtherClearance(let ruleID, _, _, _),
             .keepoutClearance(let ruleID, _, _, _):
            ruleID == nil ? "Add Clearance Rule" : "Change Clearance Rule"
        }
    }
}

enum HorizontalRouteRuleEditing {
    private static let nullUUID = "00000000-0000-0000-0000-000000000000"
    private static let anyLayer = 10000

    /// The match RuleMatch writes for one that takes every net.
    static var matchAll: JSONDictionary {
        ["mode": "all", "net": nullUUID, "net_class": nullUUID, "net_name_regex": ""]
    }

    /// `rules` with `edit` made, or nil where it changes nothing or names a
    /// rule the rules don't have. `copperLayers` are the board's, for the
    /// widths a new track width rule states. `newRuleID` names a rule the
    /// edit adds.
    static func applying(
        _ edit: HorizontalRouteRuleEdit,
        to rules: JSONDictionary,
        copperLayers: [Int],
        newRuleID: () -> String = { UUID().uuidString.lowercased() }
    ) -> JSONDictionary? {
        var rules = rules
        switch edit {
        case .trackWidth(let ruleID, let layer, let widths):
            guard widths.def > 0, widths.min >= 0, widths.max > 0,
                  var family = rules["track_width"] as? JSONDictionary,
                  let key = family.keys.first(where: { $0.lowercased() == ruleID.lowercased() }),
                  var rule = family[key] as? JSONDictionary else {
                return nil
            }
            // A default outside the range would be one the rules check flags
            // at once, so the range widens to take it.
            let coherent = HorizontalRuleTrackWidth.Widths(
                min: Swift.min(widths.min, widths.def), max: Swift.max(widths.max, widths.def), def: widths.def)
            var stated = rule["widths"] as? JSONDictionary ?? [:]
            let existing = (stated[String(layer)] as? JSONDictionary).map(HorizontalRuleTrackWidth.Widths.init(json:))
            guard existing != coherent else {
                return nil
            }
            stated[String(layer)] = coherent.json
            rule["widths"] = stated
            family[key] = rule
            rules["track_width"] = family

        case .addTrackWidthRule(let layer, let width):
            guard width > 0 else {
                return nil
            }
            var family = rules["track_width"] as? JSONDictionary ?? [:]
            var widths = JSONDictionary()
            for copper in Set(copperLayers + [layer]) {
                var layerWidths = HorizontalRuleTrackWidth.Widths.horizonDefault
                if copper == layer {
                    layerWidths = HorizontalRuleTrackWidth.Widths(
                        min: Swift.min(layerWidths.min, width), max: Swift.max(layerWidths.max, width), def: width)
                }
                widths[String(copper)] = layerWidths.json
            }
            family[newRuleID()] = [
                "enabled": true,
                "order": nextOrder(in: family),
                "match": matchAll,
                "widths": widths
            ] as JSONDictionary
            rules["track_width"] = family

        case .copperClearance(let ruleID, let a, let b, let value):
            guard let value = clearanceValue(value) else {
                return nil
            }
            var family = rules["clearance_copper"] as? JSONDictionary ?? [:]
            let pair = a.rawValue <= b.rawValue ? [a, b] : [b, a]
            if let ruleID {
                guard let key = family.keys.first(where: { $0.lowercased() == ruleID.lowercased() }),
                      var rule = family[key] as? JSONDictionary else {
                    return nil
                }
                var clearances = rule["clearances"] as? [Any] ?? []
                guard setClearance(value, types: pair, symmetric: true, in: &clearances) else {
                    return nil
                }
                rule["clearances"] = clearances
                family[key] = rule
            } else {
                family[newRuleID()] = [
                    "enabled": true,
                    "order": nextOrder(in: family),
                    "match_1": matchAll,
                    "match_2": matchAll,
                    "layer": anyLayer,
                    "routing_offset": 50_000,
                    "clearances": [clearanceEntry(value, types: pair)]
                ] as JSONDictionary
            }
            rules["clearance_copper"] = family

        case .copperOtherClearance(let ruleID, let copper, let nonCopper, let value):
            guard let value = clearanceValue(value) else {
                return nil
            }
            var family = rules["clearance_copper_other"] as? JSONDictionary ?? [:]
            if let ruleID {
                guard let key = family.keys.first(where: { $0.lowercased() == ruleID.lowercased() }),
                      var rule = family[key] as? JSONDictionary else {
                    return nil
                }
                var clearances = rule["clearances"] as? [Any] ?? []
                guard setClearance(value, types: [copper, nonCopper], symmetric: false, in: &clearances) else {
                    return nil
                }
                rule["clearances"] = clearances
                family[key] = rule
            } else {
                family[newRuleID()] = [
                    "enabled": true,
                    "order": nextOrder(in: family),
                    "match": matchAll,
                    "layer": anyLayer,
                    "routing_offset": 50_000,
                    "clearances": [clearanceEntry(value, types: [copper, nonCopper])]
                ] as JSONDictionary
            }
            rules["clearance_copper_other"] = family

        case .keepoutClearance(let ruleID, let keepoutClass, let copper, let value):
            guard let value = clearanceValue(value) else {
                return nil
            }
            var family = rules["clearance_copper_keepout"] as? JSONDictionary ?? [:]
            if let ruleID {
                guard let key = family.keys.first(where: { $0.lowercased() == ruleID.lowercased() }),
                      var rule = family[key] as? JSONDictionary else {
                    return nil
                }
                var clearances = rule["clearances"] as? JSONDictionary ?? [:]
                guard (clearances[copper.jsonString]).map(JSONHelper.intValue) != value else {
                    return nil
                }
                clearances[copper.jsonString] = value
                rule["clearances"] = clearances
                family[key] = rule
            } else {
                family[newRuleID()] = [
                    "enabled": true,
                    "order": nextOrder(in: family),
                    "match": matchAll,
                    "match_keepout": [
                        "mode": keepoutClass.isEmpty ? "all" : "keepout_class",
                        "component": nullUUID,
                        "keepout_class": keepoutClass
                    ] as JSONDictionary,
                    "routing_offset": 50_000,
                    "clearances": [copper.jsonString: value]
                ] as JSONDictionary
            }
            rules["clearance_copper_keepout"] = family

        case .viaParameters(let rule, let diameter, let holeDiameter):
            guard diameter > 0, holeDiameter > 0 else {
                return nil
            }
            var family = rules["via"] as? JSONDictionary ?? [:]
            let key = family.keys.first { $0.lowercased() == rule.id.lowercased() } ?? rule.id
            var stated = family[key] as? JSONDictionary ?? rule.json
            var parameters = stated["parameter_set"] as? JSONDictionary ?? [:]
            let sizes = ["via_diameter": Int(diameter.rounded()), "hole_diameter": Int(holeDiameter.rounded())]
            guard family[key] == nil || sizes.contains(where: { parameters.int($0.key) != $0.value }) else {
                return nil
            }
            parameters.merge(sizes) { _, new in new }
            stated["parameter_set"] = parameters
            family[key] = stated
            rules["via"] = family

        case .addViaRule(let padstackID, let diameter, let holeDiameter):
            guard diameter > 0, holeDiameter > 0, !padstackID.isEmpty else {
                return nil
            }
            var family = rules["via"] as? JSONDictionary ?? [:]
            family[newRuleID()] = [
                "enabled": true,
                "order": nextOrder(in: family),
                "match": matchAll,
                "padstack": padstackID,
                "parameter_set": [
                    "via_diameter": Int(diameter.rounded()),
                    "hole_diameter": Int(holeDiameter.rounded())
                ] as JSONDictionary
            ] as JSONDictionary
            rules["via"] = family
        }
        return rules
    }

    private static func clearanceValue(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return Int(value.rounded())
    }

    /// After every rule of the family, as the rules window adds one.
    private static func nextOrder(in family: JSONDictionary) -> Int {
        let orders = family.values.compactMap { ($0 as? JSONDictionary)?.int("order") }
        return (orders.max() ?? -1) + 1
    }

    private static func clearanceEntry(_ value: Int, types: [HorizontalPatchType]) -> JSONDictionary {
        ["types": types.map(\.jsonString), "clearance": value]
    }

    /// Sets the entry for `types` in a rule's `clearances` list, adding one
    /// where it has none. The copper table is symmetric, so an entry naming
    /// the pair the other way round is the same one. False where the entry
    /// already has the value.
    private static func setClearance(_ value: Int, types: [HorizontalPatchType], symmetric: Bool, in clearances: inout [Any]) -> Bool {
        func entryTypes(_ entry: JSONDictionary) -> [HorizontalPatchType]? {
            let types = (entry["types"] as? [Any])?.compactMap { ($0 as? String).flatMap(HorizontalPatchType.init(jsonString:)) }
            return types?.count == 2 ? types : nil
        }
        for index in clearances.indices {
            guard var entry = clearances[index] as? JSONDictionary, let stated = entryTypes(entry) else {
                continue
            }
            let same = stated == types || (symmetric && stated == types.reversed())
            guard same else {
                continue
            }
            if entry.int("clearance") == value {
                return false
            }
            entry["clearance"] = value
            clearances[index] = entry
            return true
        }
        clearances.append(clearanceEntry(value, types: types))
        return true
    }
}
