import Foundation

/// The order the power net editor lists power nets in. Horizon's files keep
/// none, and a key of ours in the block would be dropped the next time Horizon
/// saves it, so the order is the app's: a rank for each net, by its uuid. Net
/// uuids are unique to their project, so one table serves every project, and
/// ranks only ever compare among one block's nets. A net never ranked (a new
/// one) comes after the ranked ones, in name order.
enum HorizontalPowerNetOrder {
    static let defaultsKey = "Horizontal.powerNets.order"

    static func ranks(in defaults: UserDefaults = .standard) -> [String: Int] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Int] ?? [:]
    }

    /// `items` ranked first, in rank order, then the rest in the order they
    /// came in, which callers give by name.
    static func sorted<Item>(_ items: [Item], id: (Item) -> String, ranks: [String: Int]) -> [Item] {
        items.enumerated()
            .sorted { lhs, rhs in
                switch (ranks[id(lhs.element).lowercased()], ranks[id(rhs.element).lowercased()]) {
                case let (left?, right?) where left != right: left < right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    static func sorted<Item>(_ items: [Item], id: (Item) -> String, in defaults: UserDefaults = .standard) -> [Item] {
        sorted(items, id: id, ranks: ranks(in: defaults))
    }

    /// `ids` with `id` moved to where `target` is: after it when moving down
    /// the list, before it when moving up, as a dragged row lands.
    static func moving(_ id: String, to target: String, in ids: [String]) -> [String] {
        guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target), from != to else {
            return ids
        }
        var result = ids
        result.remove(at: from)
        result.insert(id, at: to)
        return result
    }

    /// `ranks` with `ids` ranked in the order given; other projects' nets
    /// keep theirs.
    static func ranking(_ ids: [String], over ranks: [String: Int]) -> [String: Int] {
        var result = ranks
        for (rank, id) in ids.enumerated() {
            result[id.lowercased()] = rank
        }
        return result
    }

    static func save(_ ranks: [String: Int], to defaults: UserDefaults = .standard) {
        defaults.set(ranks, forKey: defaultsKey)
    }
}
