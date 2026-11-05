import Foundation

/// The Diff pair row the schematic's and the board's net inspectors show:
/// Horizon's Diffpair property ("Pri: TX-", "Sec: TX+", "None") as a choice
/// of partner, which is its Set Diff Pair and Clear Diff Pair. Choosing a
/// net pairs this one with it, this one the primary, as Horizon's Set Diff
/// Pair does with the net its dialog picks; choosing None clears the pair.
/// The partners offered are the named nets in no pair, power nets left out.
enum HorizontalDiffpairProperty {
    static let id = "diffpair"
    static let noneID = "none"
    static let label = "Diff pair"

    /// Horizon's text for a net's pair: "Pri: name", "Sec: name" or "None".
    static func summary(for netID: String, in details: [String: HorizontalNetDetails]) -> String {
        guard let detail = details[netID.lowercased()], let partner = detail.diffpairID else {
            return "None"
        }
        return (detail.isDiffpairPrimary ? "Pri: " : "Sec: ") + name(partner, in: details)
    }

    /// The row for `netID`'s pair: a choice when it can be edited, its
    /// summary otherwise. Nil for no net, or a power net, which has none.
    static func property(
        for netID: String?,
        in details: [String: HorizontalNetDetails],
        editable: Bool
    ) -> HorizontalSelectionProperty? {
        guard let netID = netID?.lowercased(), let detail = details[netID], !detail.isPower else {
            return nil
        }
        guard editable else {
            return HorizontalSelectionProperty(id: id, label: label, editor: .readOnly,
                                               value: .readOnly(summary(for: netID, in: details)))
        }
        var options = [HorizontalSelectionPropertyOption(id: noneID, title: "None")]
        if let partner = detail.diffpairID {
            options.append(HorizontalSelectionPropertyOption(id: partner, title: summary(for: netID, in: details)))
        }
        let candidates = details.values.filter { other in
            let otherID = other.id.lowercased()
            return otherID != netID && otherID != detail.diffpairID && other.diffpairID == nil && !other.isPower
                && !other.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .sorted(by: nameOrder)
        options += candidates.map { HorizontalSelectionPropertyOption(id: $0.id.lowercased(), title: $0.name) }
        return HorizontalSelectionProperty(id: id, label: label, editor: .choice(options),
                                           value: .choice(detail.diffpairID ?? noneID))
    }

    /// The edit a choice of `choice` for `netID` makes, as project edit ops,
    /// and its undo title; nil when it changes nothing.
    static func operations(
        for netID: String,
        choice: String,
        in details: [String: HorizontalNetDetails]
    ) -> (ops: [JSONDictionary], actionName: String)? {
        let netID = netID.lowercased(), choice = choice.lowercased()
        let current = details[netID]?.diffpairID
        guard choice != current else {
            return nil
        }
        if choice == noneID {
            return current == nil ? nil : ([["op": "clear_diffpair", "net": netID]], "Clear Diff Pair")
        }
        var ops = [JSONDictionary]()
        if current != nil {
            ops.append(["op": "clear_diffpair", "net": netID])
        }
        ops.append(["op": "set_diffpair", "net": netID, "partner": choice])
        return (ops, "Set Diff Pair")
    }

    /// Horizon's Set Diff Pair for two selected nets: the pair, the one whose
    /// name sorts first the primary (TX+ before TX-). Nil unless both are
    /// nets with names that are in no pair but this one.
    static func pairing(of netIDs: Set<String>, in details: [String: HorizontalNetDetails]) -> (ops: [JSONDictionary], actionName: String)? {
        let nets = netIDs.map { $0.lowercased() }.compactMap { details[$0] }
        guard nets.count == 2, nets.allSatisfy({ !$0.isPower }) else {
            return nil
        }
        // By the characters themselves, so TX+ comes before TX- (+ is
        // before - in ASCII), where Finder's order puts TX- first.
        let sorted = nets.sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
        let primary = sorted[0].id.lowercased(), secondary = sorted[1].id.lowercased()
        for net in sorted where net.diffpairID != nil && net.diffpairID != primary && net.diffpairID != secondary {
            return nil
        }
        if sorted[0].diffpairID == secondary, sorted[0].isDiffpairPrimary {
            return nil
        }
        return ([["op": "set_diffpair", "net": primary, "partner": secondary]], "Set Diff Pair")
    }

    /// Horizon's Clear Diff Pair for one selected net in a pair.
    static func clearing(of netIDs: Set<String>, in details: [String: HorizontalNetDetails]) -> (ops: [JSONDictionary], actionName: String)? {
        guard netIDs.count == 1, let netID = netIDs.first?.lowercased(), details[netID]?.diffpairID != nil else {
            return nil
        }
        return ([["op": "clear_diffpair", "net": netID]], "Clear Diff Pair")
    }

    /// Nets by name as Finder sorts them (D2 before D10), then by the
    /// characters themselves where it finds two names the same.
    static func nameOrder(_ lhs: HorizontalNetDetails, _ rhs: HorizontalNetDetails) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.name != rhs.name ? lhs.name < rhs.name : lhs.id < rhs.id
    }

    private static func name(_ netID: String, in details: [String: HorizontalNetDetails]) -> String {
        let name = details[netID.lowercased()]?.name ?? ""
        return name.isEmpty ? String(netID.prefix(8)) : name
    }
}

/// Where a net inspector sends its pair's edits: the project edit, for the
/// nets `canEdit` takes — on the board, the top block's own, since an
/// instance's net is its block's, paired in that block's schematic.
struct HorizontalDiffpairEditing {
    var canEdit: (String) -> Bool
    var apply: ([JSONDictionary], String) -> Void
}
