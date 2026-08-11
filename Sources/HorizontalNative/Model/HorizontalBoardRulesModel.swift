import Foundation

// A typed, pure-model reader for the subset of the board rules the plane
// (copper pour) generator needs: copper-copper clearances, copper-vs-non-copper
// clearances (holes, board edge, text), keepout clearances, and plane settings
// including thermal relief.
//
// Everything here is driven by the file. The clearance tables are BUILT FROM the
// rule's own `clearances` array — nothing is a transcribed constant — and patch
// types are matched by their JSON strings, so the enum's integer values are only
// an internal index into a flat table and never reach disk.
//
// Lookup semantics, which the file's meaning depends on:
//  • The first ENABLED rule whose match applies wins; later rules do not merge.
//  • Copper-vs-copper clearance is symmetric — (pad, track) and (track, pad) are
//    the same constraint — so the table is filled both ways from one entry.
//  • Copper-vs-non-copper is ordered: the copper type and the non-copper type
//    are distinct roles, not an unordered pair.
//  • A missing entry falls back to 0.1 mm rather than to zero, so an incomplete
//    rule set errs toward more clearance, never toward a short.
//
// This intentionally does NOT reuse HorizontalBoardRulesView, which is a SwiftUI
// editor that round-trips raw [String: Any] verbatim. The plane updater needs a
// typed lookup API; the editor needs verbatim preservation. They share the
// on-disk JSON shape but nothing else.

enum HorizontalPatchType: Int, Hashable, CaseIterable {
    case other = 0
    case track = 1
    case pad = 2
    case padTH = 3
    case via = 4
    case plane = 5
    case holePTH = 6
    case holeNPTH = 7
    case boardEdge = 8
    case text = 9
    case netTie = 10

    /// Mirrors PatchType::N_TYPES in common.hpp (used as the table stride).
    static let count = 11

    init?(jsonString: String) {
        switch jsonString {
        case "other": self = .other
        case "track": self = .track
        case "pad": self = .pad
        case "pad_th": self = .padTH
        case "via": self = .via
        case "plane": self = .plane
        case "hole_pth": self = .holePTH
        case "hole_npth": self = .holeNPTH
        case "board_edge": self = .boardEdge
        case "text": self = .text
        case "net_tie": self = .netTie
        default: return nil
        }
    }
}

/// Mirrors RuleMatch. Net UUIDs are normalized
/// (lowercased); the all-zero UUID is treated as "unset" so a `net`-mode rule
/// carrying it never matches a real net, matching C++ `uuid == net` semantics.
struct HorizontalRuleMatch: Hashable {
    enum Mode: String, Hashable {
        case all
        case net
        case nets
        case netClass = "net_class"
        case netNameRegex = "net_name_regex"
        case netClassRegex = "net_class_regex"
    }

    var mode: Mode
    var net: String?
    var netClass: String?
    var netNameRegex: String
    var netClassRegex: String
    var nets: Set<String>

    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    init(json: JSONDictionary?) {
        let json = json ?? [:]
        mode = Mode(rawValue: json.string("mode") ?? "all") ?? .all

        func normalizedNonZero(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            let normalized = value.lowercased()
            return normalized == Self.zeroUUID ? nil : normalized
        }

        net = normalizedNonZero(json.string("net"))
        netClass = normalizedNonZero(json.string("net_class"))
        netNameRegex = json.string("net_name_regex") ?? ""
        netClassRegex = json.string("net_class_regex") ?? ""
        if let rawNets = json["nets"] as? [Any] {
            nets = Set(rawNets.compactMap { ($0 as? String)?.lowercased() })
        } else {
            nets = []
        }
    }

    func matches(netID: String?, netDetails: [String: HorizontalNetDetails]) -> Bool {
        let normalizedNet = netID?.lowercased()
        switch mode {
        case .all:
            return true
        case .net:
            guard let normalizedNet, let net else { return false }
            return normalizedNet == net
        case .nets:
            guard let normalizedNet else { return false }
            return nets.contains(normalizedNet)
        case .netClass:
            guard let normalizedNet, let netClass,
                  let details = netDetails[normalizedNet],
                  let classID = details.netClassID else { return false }
            return classID == netClass
        case .netNameRegex:
            guard let normalizedNet, let details = netDetails[normalizedNet] else { return false }
            return Self.regexMatches(netNameRegex, details.name)
        case .netClassRegex:
            guard let normalizedNet,
                  let details = netDetails[normalizedNet],
                  let className = details.netClassName else { return false }
            return Self.regexMatches(netClassRegex, className)
        }
    }

    private static func regexMatches(_ pattern: String, _ value: String) -> Bool {
        // An empty pattern matches everything in C++ (Glib::Regex over ""), so a
        // net-name/net-class regex rule with an empty pattern matches any net.
        guard !pattern.isEmpty else { return true }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

/// Mirrors RuleMatchKeepout. The plane pour
/// only needs the `all` and `keepout_class` modes; component matching is treated
/// as non-matching here because the viewer doesn't resolve component instances
/// into the keepout contour set yet.
struct HorizontalRuleMatchKeepout: Hashable {
    enum Mode: String, Hashable {
        case all
        case component
        case keepoutClass = "keepout_class"
    }

    var mode: Mode
    var component: String?
    var keepoutClass: String

    init(json: JSONDictionary?) {
        let json = json ?? [:]
        mode = Mode(rawValue: json.string("mode") ?? "all") ?? .all
        component = json.string("component")?.lowercased()
        keepoutClass = json.string("keepout_class") ?? ""
    }

    func matches(keepoutClass keepoutClassValue: String) -> Bool {
        switch mode {
        case .all:
            return true
        case .keepoutClass:
            return keepoutClass == keepoutClassValue
        case .component:
            // Component-scoped keepout rules aren't resolvable in the viewer yet.
            return false
        }
    }
}

/// Mirrors RuleMatchComponent. The plane
/// updater can only supply the board-package instance UUID (parsed from a pad
/// id), not the schematic component UUID or its part UUID, so `component` /
/// `components` are matched against that board-package id and `part` mode never
/// matches. A thermals rule authored against a real component/part UUID will not
/// match here; rules (and the tests) must reference the board-package id.
struct HorizontalRuleMatchComponent: Hashable {
    enum Mode: String, Hashable {
        case component
        case components
        case part
    }

    var mode: Mode
    var component: String?
    var part: String?
    var components: Set<String>

    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    init(json: JSONDictionary?) {
        let json = json ?? [:]
        mode = Mode(rawValue: json.string("mode") ?? "component") ?? .component

        func normalizedNonZero(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            let normalized = value.lowercased()
            return normalized == Self.zeroUUID ? nil : normalized
        }

        component = normalizedNonZero(json.string("component"))
        part = normalizedNonZero(json.string("part"))
        if let rawComponents = json["components"] as? [Any] {
            components = Set(rawComponents.compactMap { ($0 as? String)?.lowercased() })
        } else {
            components = []
        }
    }

    /// Mirrors RuleMatchComponent::match — but `packageID` is the board-package
    /// instance UUID (see the type doc), not the schematic component UUID.
    func matches(packageID: String) -> Bool {
        let normalized = packageID.lowercased()
        switch mode {
        case .component:
            guard let component else { return false }
            return normalized == component
        case .components:
            return components.contains(normalized)
        case .part:
            // The viewer can't resolve a board package to its part UUID here.
            return false
        }
    }
}

/// Symmetric 11x11 copper-copper clearance table.
struct HorizontalRuleClearanceCopper: Hashable {
    var enabled: Bool
    var order: Int
    var layer: Int
    var match1: HorizontalRuleMatch
    var match2: HorizontalRuleMatch
    var clearances: [Int]

    static let defaultClearance = 100_000

    init(json: JSONDictionary) {
        enabled = json.bool("enabled") ?? true
        order = json.int("order") ?? 0
        layer = json.int("layer") ?? 10000
        match1 = HorizontalRuleMatch(json: json.dictionary("match_1"))
        match2 = HorizontalRuleMatch(json: json.dictionary("match_2"))
        var table = [Int](repeating: Self.defaultClearance, count: HorizontalPatchType.count * HorizontalPatchType.count)
        for entry in json.dictionaryArray("clearances") {
            guard let types = entry["types"] as? [Any], types.count >= 2,
                  let a = (types[0] as? String).flatMap(HorizontalPatchType.init(jsonString:)),
                  let b = (types[1] as? String).flatMap(HorizontalPatchType.init(jsonString:)),
                  let value = entry.int("clearance") else {
                continue
            }
            table[Self.index(a, b)] = value
        }
        clearances = table
    }

    /// Fallback rule with the default 0.1mm everywhere (matches the C++ static
    /// `fallback_clearance_copper`).
    static let fallback = HorizontalRuleClearanceCopper()

    private init() {
        enabled = true
        order = 0
        layer = 10000
        match1 = HorizontalRuleMatch(json: nil)
        match2 = HorizontalRuleMatch(json: nil)
        clearances = [Int](repeating: Self.defaultClearance, count: HorizontalPatchType.count * HorizontalPatchType.count)
    }

    private static func index(_ a: HorizontalPatchType, _ b: HorizontalPatchType) -> Int {
        var ai = a.rawValue
        var bi = b.rawValue
        if ai > bi { swap(&ai, &bi) }
        return ai * HorizontalPatchType.count + bi
    }

    func clearance(_ a: HorizontalPatchType, _ b: HorizontalPatchType) -> Int {
        let a = a == .netTie ? .track : a
        let b = b == .netTie ? .track : b
        return clearances[Self.index(a, b)]
    }
}

/// Ordered (copper, non-copper) clearance map.
struct HorizontalRuleClearanceCopperOther: Hashable {
    var enabled: Bool
    var order: Int
    var layer: Int
    var match: HorizontalRuleMatch
    var clearances: [Pair: Int]

    struct Pair: Hashable {
        var copper: HorizontalPatchType
        var nonCopper: HorizontalPatchType
    }

    static let defaultClearance = 100_000

    init(json: JSONDictionary) {
        enabled = json.bool("enabled") ?? true
        order = json.int("order") ?? 0
        layer = json.int("layer") ?? 10000
        match = HorizontalRuleMatch(json: json.dictionary("match"))
        var map = [Pair: Int]()
        for entry in json.dictionaryArray("clearances") {
            guard let types = entry["types"] as? [Any], types.count >= 2,
                  let a = (types[0] as? String).flatMap(HorizontalPatchType.init(jsonString:)),
                  let b = (types[1] as? String).flatMap(HorizontalPatchType.init(jsonString:)),
                  let value = entry.int("clearance") else {
                continue
            }
            map[Pair(copper: a, nonCopper: b)] = value
        }
        clearances = map
    }

    static let fallback = HorizontalRuleClearanceCopperOther()

    private init() {
        enabled = true
        order = 0
        layer = 10000
        match = HorizontalRuleMatch(json: nil)
        clearances = [:]
    }

    func clearance(copper ptCopper: HorizontalPatchType, nonCopper ptNonCopper: HorizontalPatchType) -> Int {
        let copper = ptCopper == .netTie ? .track : ptCopper
        // text counts as "other" (lines, arcs, etc.) per the reference.
        let nonCopper = ptNonCopper == .text ? .other : ptNonCopper
        return clearances[Pair(copper: copper, nonCopper: nonCopper)] ?? Self.defaultClearance
    }
}

/// Keepout clearance map. The
/// JSON `clearances` is an object {patchTypeString: Int} OR null; default 0.
struct HorizontalRuleClearanceCopperKeepout: Hashable {
    var enabled: Bool
    var order: Int
    var match: HorizontalRuleMatch
    var matchKeepout: HorizontalRuleMatchKeepout
    var clearances: [HorizontalPatchType: Int]

    init(json: JSONDictionary) {
        enabled = json.bool("enabled") ?? true
        order = json.int("order") ?? 0
        match = HorizontalRuleMatch(json: json.dictionary("match"))
        matchKeepout = HorizontalRuleMatchKeepout(json: json.dictionary("match_keepout"))
        var map = [HorizontalPatchType: Int]()
        if let raw = json["clearances"] as? JSONDictionary {
            for (key, value) in raw {
                guard let type = HorizontalPatchType(jsonString: key) else { continue }
                map[type] = JSONHelper.intValue(value)
            }
        }
        clearances = map
    }

    static let fallback = HorizontalRuleClearanceCopperKeepout()

    private init() {
        enabled = true
        order = 0
        match = HorizontalRuleMatch(json: nil)
        matchKeepout = HorizontalRuleMatchKeepout(json: nil)
        clearances = [:]
    }

    func clearance(_ pt: HorizontalPatchType) -> Int {
        let pt = pt == .netTie ? .track : pt
        return clearances[pt] ?? 0
    }
}

/// Thermal relief settings. Accepts both
/// the C++ spellings (from_plane) and the Swift editor spellings (none).
struct HorizontalThermalSettings: Hashable {
    enum ConnectStyle: Hashable {
        case solid
        case thermal
        case fromPlane
        /// Swift-editor-only spelling. Horizon C++ has no NONE; we model it as
        /// "isolate": cut the thermal antipad but add no spokes.
        case none
    }

    var connectStyle: ConnectStyle
    var thermalGapWidth: Int
    var thermalSpokeWidth: Int
    var nSpokes: Int
    var angle: Int

    /// Memberwise init used for the struct-default fallback (distinct from the
    /// from-JSON defaults, which differ: thermal_gap_width is 0.2mm here vs
    /// 0.1mm when parsed from a JSON `settings` object that omits the key).
    init(connectStyle: ConnectStyle, thermalGapWidth: Int, thermalSpokeWidth: Int, nSpokes: Int, angle: Int) {
        self.connectStyle = connectStyle
        self.thermalGapWidth = thermalGapWidth
        self.thermalSpokeWidth = thermalSpokeWidth
        self.nSpokes = nSpokes
        self.angle = angle
    }

    init(json: JSONDictionary?) {
        let json = json ?? [:]
        switch json.string("connect_style") {
        case "thermal": connectStyle = .thermal
        case "from_plane": connectStyle = .fromPlane
        case "none": connectStyle = .none
        default: connectStyle = .solid
        }
        // NOTE: the from-JSON default for thermal_gap_width is 0.1mm (plane.cpp:31),
        // which differs from the struct default of 0.2mm. Use 0.1mm when absent.
        thermalGapWidth = json.int("thermal_gap_width") ?? 100_000
        thermalSpokeWidth = json.int("thermal_spoke_width") ?? 200_000
        nSpokes = json.int("n_spokes") ?? 4
        angle = json.int("angle") ?? 0
    }

    /// C++ STRUCT defaults (plane.hpp): thermal_gap_width 0.2mm. Used when there
    /// is no `settings` object and no matching plane rule at all.
    static let `default` = HorizontalThermalSettings(
        connectStyle: .solid,
        thermalGapWidth: 200_000,
        thermalSpokeWidth: 200_000,
        nSpokes: 4,
        angle: 0)
}

/// Plane settings.
struct HorizontalPlaneSettings: Hashable {
    enum Style: Hashable { case round, square, miter }
    enum TextStyle: Hashable { case expand, bbox }
    enum FillStyle: Hashable { case solid, hatch }

    var minWidth: Int
    var style: Style
    var keepOrphans: Bool
    var textStyle: TextStyle
    var fillStyle: FillStyle
    var hatchBorderWidth: Int
    var hatchLineWidth: Int
    var hatchLineSpacing: Int
    var thermalSettings: HorizontalThermalSettings

    init(json: JSONDictionary?) {
        let json = json ?? [:]
        minWidth = json.int("min_width") ?? 200_000
        switch json.string("style") {
        case "square": style = .square
        case "miter": style = .miter
        default: style = .round
        }
        keepOrphans = json.bool("keep_orphans") ?? false
        switch json.string("text_style") {
        // Accept the Swift editor's "clip" spelling as a synonym for bbox.
        case "bbox", "clip": textStyle = .bbox
        default: textStyle = .expand
        }
        switch json.string("fill_style") {
        case "hatch": fillStyle = .hatch
        default: fillStyle = .solid
        }
        hatchBorderWidth = json.int("hatch_border_width") ?? 500_000
        hatchLineWidth = json.int("hatch_line_width") ?? 200_000
        hatchLineSpacing = json.int("hatch_line_spacing") ?? 500_000
        thermalSettings = HorizontalThermalSettings(json: json)
    }

    /// Struct-default fallback: same as parsing an empty object EXCEPT the
    /// thermal settings use the C++ struct defaults (0.2mm gap), not the
    /// from-JSON defaults.
    static let `default`: HorizontalPlaneSettings = {
        var settings = HorizontalPlaneSettings(json: nil)
        settings.thermalSettings = .default
        return settings
    }()
}

struct HorizontalRulePlane: Hashable {
    var enabled: Bool
    var order: Int
    var layer: Int
    var match: HorizontalRuleMatch
    var settings: HorizontalPlaneSettings

    init(json: JSONDictionary) {
        enabled = json.bool("enabled") ?? true
        order = json.int("order") ?? 0
        layer = json.int("layer") ?? 10000
        match = HorizontalRuleMatch(json: json.dictionary("match"))
        settings = HorizontalPlaneSettings(json: json.dictionary("settings"))
    }
}

/// Mirrors RuleThermals: a per-pad thermal-relief
/// override. A pad matches when the net match, the component match, the pad mode
/// (ALL, or the pad UUID is in `pads`), and the layer sentinel (10000 == any)
/// all pass. The editor flattens the thermal-settings keys (connect_style,
/// thermal_gap_width, …) into the rule object, so — like C++ `thermal_settings(j)`
/// — they parse straight from the rule json rather than a sub-object.
struct HorizontalRuleThermals: Hashable {
    enum PadMode: String, Hashable {
        case all
        case pads
    }

    var enabled: Bool
    var order: Int
    var layer: Int
    var match: HorizontalRuleMatch
    var matchComponent: HorizontalRuleMatchComponent
    var padMode: PadMode
    var pads: Set<String>
    var thermalSettings: HorizontalThermalSettings

    init(json: JSONDictionary) {
        enabled = json.bool("enabled") ?? true
        order = json.int("order") ?? 0
        layer = json.int("layer") ?? 10000
        match = HorizontalRuleMatch(json: json.dictionary("match"))
        matchComponent = HorizontalRuleMatchComponent(json: json.dictionary("match_component"))
        padMode = PadMode(rawValue: json.string("pad_mode") ?? "all") ?? .all
        if let rawPads = json["pads"] as? [Any] {
            pads = Set(rawPads.compactMap { ($0 as? String)?.lowercased() })
        } else {
            pads = []
        }
        thermalSettings = HorizontalThermalSettings(json: json)
    }

    /// Mirrors RuleThermals::matches (rule_thermals.cpp:50). `layer` is the pad's
    /// actual layer (`la` in the reference); `packageID`/`padID`/`net` identify
    /// the pad. Rules are expected to be pre-filtered by `enabled` by the caller,
    /// but we re-check here to match the reference predicate exactly.
    func matches(packageID: String, net: String?, padID: String, layer: Int,
                 netDetails: [String: HorizontalNetDetails]) -> Bool {
        guard enabled else { return false }
        guard matchComponent.matches(packageID: packageID) else { return false }
        guard match.matches(netID: net, netDetails: netDetails) else { return false }
        if padMode == .pads, !pads.contains(padID.lowercased()) { return false }
        return self.layer == 10000 || self.layer == layer
    }
}

/// The lookup engine. Each lookup returns the first
/// enabled rule (rules pre-sorted ascending by `order`) whose match predicates
/// and layer sentinel (10000 == any) pass, else a default fallback.
struct HorizontalBoardRules: Hashable {
    var clearanceCopperRules: [HorizontalRuleClearanceCopper]
    var clearanceCopperOtherRules: [HorizontalRuleClearanceCopperOther]
    var clearanceCopperKeepoutRules: [HorizontalRuleClearanceCopperKeepout]
    var planeRules: [HorizontalRulePlane]
    var thermalRules: [HorizontalRuleThermals]
    var netDetails: [String: HorizontalNetDetails]

    init(rules: JSONDictionary?, netDetails: [String: HorizontalNetDetails]) {
        let rules = rules ?? [:]
        self.netDetails = netDetails

        func parseGroup<T>(_ key: String, _ make: (JSONDictionary) -> T) -> [T] {
            rules.dictionaryMap(key)
                .values
                .map(make)
        }

        clearanceCopperRules = parseGroup("clearance_copper", HorizontalRuleClearanceCopper.init(json:))
            .sorted { $0.order < $1.order }
        clearanceCopperOtherRules = parseGroup("clearance_copper_other", HorizontalRuleClearanceCopperOther.init(json:))
            .sorted { $0.order < $1.order }
        clearanceCopperKeepoutRules = parseGroup("clearance_copper_keepout", HorizontalRuleClearanceCopperKeepout.init(json:))
            .sorted { $0.order < $1.order }
        planeRules = parseGroup("plane", HorizontalRulePlane.init(json:))
            .sorted { $0.order < $1.order }
        thermalRules = parseGroup("thermals", HorizontalRuleThermals.init(json:))
            .sorted { $0.order < $1.order }
    }

    static let empty = HorizontalBoardRules(rules: nil, netDetails: [:])

    private func layerMatches(_ ruleLayer: Int, _ layer: Int) -> Bool {
        ruleLayer == layer || ruleLayer == 10000
    }

    func clearanceCopper(net1: String?, net2: String?, layer: Int) -> HorizontalRuleClearanceCopper {
        for rule in clearanceCopperRules where rule.enabled && layerMatches(rule.layer, layer) {
            let direct = rule.match1.matches(netID: net1, netDetails: netDetails)
                && rule.match2.matches(netID: net2, netDetails: netDetails)
            let swapped = rule.match1.matches(netID: net2, netDetails: netDetails)
                && rule.match2.matches(netID: net1, netDetails: netDetails)
            if direct || swapped {
                return rule
            }
        }
        return .fallback
    }

    func clearanceCopperOther(net: String?, layer: Int) -> HorizontalRuleClearanceCopperOther {
        for rule in clearanceCopperOtherRules
        where rule.enabled && layerMatches(rule.layer, layer)
            && rule.match.matches(netID: net, netDetails: netDetails) {
            return rule
        }
        return .fallback
    }

    func clearanceCopperKeepout(net: String?, keepoutClass: String) -> HorizontalRuleClearanceCopperKeepout {
        for rule in clearanceCopperKeepoutRules
        where rule.enabled
            && rule.match.matches(netID: net, netDetails: netDetails)
            && rule.matchKeepout.matches(keepoutClass: keepoutClass) {
            return rule
        }
        return .fallback
    }

    /// Resolve plane settings for a plane that has `from_rules == true`.
    func planeSettings(net: String?, layer: Int) -> HorizontalPlaneSettings {
        for rule in planeRules
        where rule.enabled && layerMatches(rule.layer, layer)
            && rule.match.matches(netID: net, netDetails: netDetails) {
            return rule.settings
        }
        return .default
    }

    /// Mirrors BoardRules::get_thermal_settings (board_rules.cpp:801). Returns the
    /// thermal settings for one pad on one plane: the first enabled thermals rule
    /// whose component/net/pad/layer predicates match, unless that rule's
    /// connect_style is FROM_PLANE — in which case (and when no rule matches) the
    /// plane's own already-resolved thermal settings (`planeThermal`) are used.
    ///
    /// `packageID`/`padID` are the board-package and pad UUIDs parsed from a pad
    /// polygon id ("boardPackageID/pad/padID/…"); `net` is the pad's net (equal
    /// to the plane net for the same-net pads that get thermals).
    func thermalSettings(
        net: String?,
        packageID: String,
        padID: String,
        layer: Int,
        planeThermal: HorizontalThermalSettings
    ) -> HorizontalThermalSettings {
        for rule in thermalRules
        where rule.matches(packageID: packageID, net: net, padID: padID, layer: layer, netDetails: netDetails) {
            return rule.thermalSettings.connectStyle == .fromPlane ? planeThermal : rule.thermalSettings
        }
        return planeThermal
    }
}

extension JSONHelper {
    static func intValue(_ value: Any) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return 0
    }
}
