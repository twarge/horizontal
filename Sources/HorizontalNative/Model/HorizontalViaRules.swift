import Foundation

/// Horizon's Apply for the via rules (`BoardRules::apply(RuleID::VIA)`): a via
/// that takes its shape from the rules, on a net, gets the padstack and
/// parameters of the first enabled via rule, by order, whose match takes the
/// net. Horizon does this only when the rules are applied (from its rules
/// window, or for a via being placed or routed), never when it opens a board,
/// so a via can hold parameters its rule no longer gives, or leave some out.
enum HorizontalViaRules {
    private static let nullUUID = "00000000-0000-0000-0000-000000000000"

    /// The via rule that shapes a via on `net`, with its id, from the board
    /// file's `rules`.
    static func rule(
        net: String?,
        in rules: JSONDictionary,
        netDetails: [String: HorizontalNetDetails]
    ) -> (id: String, rule: JSONDictionary)? {
        rules.dictionaryMap("via")
            .filter { $0.value.bool("enabled") ?? true }
            .sorted { ($0.value.int("order") ?? 0, $0.key) < ($1.value.int("order") ?? 0, $1.key) }
            .first { HorizontalRuleMatch(json: $0.value.dictionary("match")).matches(netID: net?.lowercased(), netDetails: netDetails) }
            .map { ($0.key, $0.value) }
    }

    /// Whether a via in the board file takes its shape from the rules: its
    /// `source`, or `from_rules` in a file written before sources.
    static func takesShapeFromRules(_ via: JSONDictionary) -> Bool {
        (via.string("source") ?? ((via.bool("from_rules") ?? true) ? "rules" : "local")) == "rules"
    }

    /// The board file's `vias` with the rules applied, and the ids of the vias
    /// that changed. `net` gives a via's net from its id and entry; a via on no
    /// net is left as it is, as Horizon leaves it, and so is one whose rule
    /// names no padstack.
    static func applied(
        to vias: [String: JSONDictionary],
        rules: JSONDictionary,
        netDetails: [String: HorizontalNetDetails],
        net: (String, JSONDictionary) -> String?
    ) -> (vias: [String: JSONDictionary], changed: [String]) {
        var vias = vias
        var changed = [String]()
        for (id, var via) in vias.sorted(by: { $0.key < $1.key }) where takesShapeFromRules(via) {
            guard let net = net(id, via),
                  let rule = rule(net: net, in: rules, netDetails: netDetails)?.rule,
                  let padstack = rule.string("padstack"), !padstack.isEmpty, padstack != nullUUID else {
                continue
            }
            let parameters = rule.dictionary("parameter_set") ?? [:]
            guard via.string("padstack")?.lowercased() != padstack.lowercased()
                    || !NSDictionary(dictionary: via.dictionary("parameter_set") ?? [:]).isEqual(to: parameters) else {
                continue
            }
            via["padstack"] = padstack
            via["parameter_set"] = parameters
            vias[id] = via
            changed.append(id)
        }
        return (vias, changed)
    }
}

extension HorizontalBoard {
    /// Each via's net as the board's connectivity has it, by lowercased id:
    /// what the via rules match a via by when they are applied.
    var viaNetsForRules: [String: String] {
        Dictionary(
            vias.compactMap { via in via.netID.map { (via.id.lowercased(), $0.lowercased()) } },
            uniquingKeysWith: { first, _ in first })
    }
}
