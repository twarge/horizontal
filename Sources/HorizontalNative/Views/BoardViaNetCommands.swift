import Foundation

/// The board canvas's Clear Net on the selected vias and its Let Vias Follow
/// Their Tracks…, the two ways to take a via's pinned net (`net_set`) off so
/// it takes its tracks' net again and follows them to another.
///
/// Clear Net is Horizon's Clear via net on every selected via that holds a
/// net, whatever its copper: the user chose those vias. Let Vias Follow Their
/// Tracks… looks at every pinned via on the board and takes the pin off only
/// those whose pads already give their copper the pinned net
/// (`HorizontalPinnedVias`), so no net changes; it says how many those are,
/// and how many are pinned to a net their pads don't give, before it does.
/// The canvas makes each one undoable edit.
enum BoardViaNetCommands {
    /// The vias among `refs` that hold a net, which Clear Net takes it off.
    static func pinnedVias(among refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        let viaRefs = refs.filter { $0.type == .via }
        guard !viaRefs.isEmpty else {
            return []
        }
        let pinned = Set(board.vias.filter { $0.netSetID != nil }.map { HorizontalCanvasModeSupport.normalizedID($0.id) })
        var seen = Set<String>()
        return viaRefs.filter { ref in
            let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
            return pinned.contains(id) && seen.insert(id).inserted
        }
    }

    /// Which of Clear Net (1) and Let Vias Follow Their Tracks… (2) the
    /// selection and board offer, as bits, so the canvas republishes its
    /// commands when a pin comes off or goes back.
    static func commandSignature(_ selection: [HorizontalSelectableRef], in board: HorizontalBoard) -> Int {
        guard board.vias.contains(where: { $0.netSetID != nil }) else {
            return 0
        }
        return 2 | (pinnedVias(among: selection, in: board).isEmpty ? 0 : 1)
    }

    /// What a right-click's Clear Net acts on: the selection where `ref` is
    /// part of it, as the menu keeps it, else `ref` alone.
    static func menuRefs(for ref: HorizontalSelectableRef, selection: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        selection.contains(ref) ? selection : [ref]
    }

    /// Clear Net in a track's or via's right-click menu, where what it acts
    /// on holds a pinned via; nil elsewhere.
    static func menuEntry(
        for ref: HorizontalSelectableRef,
        selection: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> HorizontalTargetItemMenuEntry? {
        guard ref.type == .via || ref.type == .track,
              !pinnedVias(among: menuRefs(for: ref, selection: selection), in: board).isEmpty else {
            return nil
        }
        return .command(title: "Clear Net", .clearViaNets)
    }

    /// Clear Net on the vias among `refs` that hold a net. Returns whether
    /// any changed; the canvas recomputes connectivity, which gives each the
    /// net its copper has, or none.
    @discardableResult
    static func clearNets(on refs: [HorizontalSelectableRef], in board: inout HorizontalBoard) -> Bool {
        BoardSetNet.clearNet(on: pinnedVias(among: refs, in: board), in: &board)
    }

    /// Let Vias Follow Their Tracks…: the pin taken off every via `review`
    /// found following its pads' net. Returns whether any changed.
    @discardableResult
    static func letViasFollow(_ review: HorizontalPinnedVias.Review, in board: inout HorizontalBoard) -> Bool {
        BoardSetNet.clearNet(on: review.following.map { HorizontalSelectableRef(id: $0.id, type: .via) }, in: &board)
    }

    // MARK: - The confirmation

    static let title = "Let Vias Follow Their Tracks"

    /// The confirming button, naming how many vias change; nil when none
    /// would, and the alert only says why.
    static func confirmTitle(_ review: HorizontalPinnedVias.Review) -> String? {
        let count = review.count(.follows)
        guard count > 0 else {
            return nil
        }
        return count == 1 ? "Unpin 1 Via" : "Unpin \(count) Vias"
    }

    /// What the alert says: how many vias follow and are unpinned, which
    /// are conflicts, and what keeps its pin and why. `name` is the canvas's
    /// name for a net.
    static func message(_ review: HorizontalPinnedVias.Review, name: (String) -> String) -> String {
        func vias(_ count: Int) -> String { count == 1 ? "1 via" : "\(count) vias" }
        let follows = review.count(.follows)
        var lines = [String]()
        if review.vias.isEmpty {
            return "No via on the board holds a net of its own."
        }
        if follows > 0 {
            lines.append("\(vias(follows)) of the \(review.vias.count) that hold a net of their own are pinned to the net "
                + "their pads already give them. Unpinned, each takes its tracks' net, which is the same, and follows "
                + "them when the schematic moves them to another net.")
        } else {
            lines.append("None of the \(vias(review.vias.count)) that hold a net of their own is pinned to the net its pads give it.")
        }
        let conflicts = review.conflicts
        if !conflicts.isEmpty {
            var line = "\(vias(conflicts.count)) \(conflicts.count == 1 ? "is" : "are") pinned to another net than "
                + "\(conflicts.count == 1 ? "its" : "their") pads give, and \(conflicts.count == 1 ? "keeps its pin" : "keep their pins"):"
            for via in conflicts.prefix(5) {
                line += "\n• " + String(format: "(%.2f, %.2f) mm", via.position.x / 1_000_000, via.position.y / 1_000_000)
                    + " pinned to \(name(via.pin)) on \(via.padNets.sorted().map(name).joined(separator: ", ")) copper"
            }
            if conflicts.count > 5 {
                line += "\n• and \(conflicts.count - 5) more"
            }
            lines.append(line)
        }
        // What keeps each of the rest pinned, said of one via and of several.
        let kept: [(HorizontalPinnedVias.Kind, String, String)] = [
            (.stitching, "stands alone, as a stitching via does", "stand alone, as stitching vias do"),
            (.noPad, "joins tracks that reach no pad on a net", "join tracks that reach no pad on a net"),
            (.short, "is on copper that joins several nets", "are on copper that joins several nets"),
        ]
        let keeping = kept.compactMap { kind, one, several -> String? in
            let count = review.count(kind)
            return count > 0 ? "\(vias(count)) \(count == 1 ? one : several)" : nil
        }
        if !keeping.isEmpty {
            lines.append("These keep their pins too: " + keeping.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n\n")
    }
}
