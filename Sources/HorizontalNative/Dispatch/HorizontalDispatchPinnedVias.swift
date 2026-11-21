import Foundation

/// unpin_vias's reply: what `HorizontalPinnedVias` found on the board, the
/// vias it took the pin off (or would, in a dry run) and the conflicts it
/// left, each with where it is, so they can be found and settled by hand.
enum HorizontalDispatchPinnedVias {
    /// `unpinned` is the lowercased ids whose `net_set` came off; `name` is
    /// what to call a net.
    static func reply(_ review: HorizontalPinnedVias.Review, unpinned: Set<String>,
                      name: (String) -> String) -> JSONDictionary {
        func at(_ via: HorizontalPinnedVias.Via) -> JSONDictionary {
            ["via": via.id,
             "x_mm": HorizontalDispatchJSON.mm(via.position.x),
             "y_mm": HorizontalDispatchJSON.mm(via.position.y)]
        }
        var counts = JSONDictionary()
        for kind in HorizontalPinnedVias.Kind.allCases {
            counts[kind.rawValue] = review.count(kind)
        }
        let followed = review.following.filter { unpinned.contains($0.id.lowercased()) }
        let unpinnedEntries: [JSONDictionary] = followed.map { via in
            var entry = at(via)
            entry["net"] = name(via.pin)
            return entry
        }
        let conflicts: [JSONDictionary] = review.conflicts.map { via in
            var entry = at(via)
            entry["net_set"] = name(via.pin)
            entry["pads_net"] = via.padNets.sorted().map(name).first ?? ""
            return entry
        }
        return [
            "pinned": review.vias.count,
            "counts": counts,
            "unpinned_count": unpinnedEntries.count,
            "unpinned": unpinnedEntries,
            "conflicts": conflicts,
        ]
    }
}
