import Foundation

/// The airwire filter's view of a board: the nets it lists, and which of a
/// board's airwires it lets draw. What it hides lives in
/// `BoardDisplayOptions.hiddenAirwireNetIDs`; the board itself never changes.
enum BoardAirwireFilter {
    /// One net in the filter's list.
    struct Row: Identifiable, Hashable {
        /// The net's uuid, lowercased.
        var id: String
        var name: String
        var netClassID: String?
        var netClassName: String?
        var airwireCount: Int
        var isShown: Bool
    }

    /// A net class the list can be narrowed to.
    struct NetClass: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// The nets that have airwires, and the hidden ones the board still has
    /// (routed since, say), so a net can always be shown again; by name.
    static func rows(board: HorizontalBoard, options: BoardDisplayOptions) -> [Row] {
        var counts = [String: Int]()
        for airwire in board.airwires {
            guard let netID = airwire.netID?.lowercased() else {
                continue
            }
            counts[netID, default: 0] += 1
        }
        var details = [String: HorizontalNetDetails]()
        for (netID, net) in board.netDetails {
            details[netID.lowercased()] = net
        }
        let netIDs = Set(counts.keys).union(options.hiddenAirwireNetIDs.filter { details[$0] != nil })
        return netIDs.map { netID in
            let net = details[netID]
            return Row(
                id: netID,
                name: displayName(net?.name, netID: netID),
                netClassID: net?.netClassID?.lowercased(),
                netClassName: net?.netClassName,
                airwireCount: counts[netID] ?? 0,
                isShown: options.showsAirwires(ofNet: netID)
            )
        }
        .sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }

    /// The net classes `rows` has nets in, by name.
    static func netClasses(in rows: [Row]) -> [NetClass] {
        var classes = [String: String]()
        for row in rows {
            if let id = row.netClassID {
                classes[id] = row.netClassName ?? String(id.prefix(8))
            }
        }
        return classes.map { NetClass(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The rows whose name contains `search`, ignoring case (all of them for
    /// an empty search), in the net class `netClassID` names, or any.
    static func matching(_ rows: [Row], search: String, netClassID: String?) -> [Row] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            (netClassID == nil || row.netClassID == netClassID)
                && (search.isEmpty || row.name.localizedCaseInsensitiveContains(search))
        }
    }

    /// The airwires the filter lets draw. The Connections switch is not
    /// asked: with it off, none draw at all.
    static func shown(_ airwires: [HorizontalSegment], options: BoardDisplayOptions) -> [HorizontalSegment] {
        guard !options.hiddenAirwireNetIDs.isEmpty else {
            return airwires
        }
        return airwires.filter { options.showsAirwires(ofNet: $0.netID) }
    }

    /// An unnamed net has only its uuid, which the list shortens.
    static func displayName(_ name: String?, netID: String) -> String {
        guard let name, !name.isEmpty else {
            return "Unnamed net \(netID.prefix(8))"
        }
        return name
    }
}
