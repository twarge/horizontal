import Foundation

/// The board canvas's Clear Net on the selected vias and its Let Vias Follow
/// Their Tracks…, the two ways to take a via's pinned net (`net_set`) off so
/// it takes its tracks' net again and follows them to another; and Pin Net,
/// which puts one on.
///
/// Pin Net pins the net a via's copper gives it onto the via, which then
/// holds it itself as a stitching via does: it keeps the net when its
/// tracks go, and no longer follows them to another. Set Net… cannot do
/// that for a via whose copper reaches a pad, since the pad's net is not
/// one to choose; this takes the net the via already has.
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

    /// The vias among `refs` that Pin Net pins: each has a net, from the
    /// copper it joins, and does not hold it. One on no net has none to
    /// pin (Set Net… gives it one), and one that holds its net is pinned.
    static func pinnableVias(among refs: [HorizontalSelectableRef], in board: HorizontalBoard) -> [HorizontalSelectableRef] {
        let viaRefs = refs.filter { $0.type == .via }
        guard !viaRefs.isEmpty else {
            return []
        }
        let pinnable = Set(board.vias.filter { $0.netSetID == nil && $0.netID != nil }.map { HorizontalCanvasModeSupport.normalizedID($0.id) })
        var seen = Set<String>()
        return viaRefs.filter { ref in
            let id = HorizontalCanvasModeSupport.normalizedID(ref.id)
            return pinnable.contains(id) && seen.insert(id).inserted
        }
    }

    /// Which of Clear Net (1), Let Vias Follow Their Tracks… (2) and Pin
    /// Net (4) the selection and board offer, as bits, so the canvas
    /// republishes its commands when a pin comes off, goes on or goes back.
    static func commandSignature(_ selection: [HorizontalSelectableRef], in board: HorizontalBoard) -> Int {
        let pin = pinnableVias(among: selection, in: board).isEmpty ? 0 : 4
        guard board.vias.contains(where: { $0.netSetID != nil }) else {
            return pin
        }
        return pin | 2 | (pinnedVias(among: selection, in: board).isEmpty ? 0 : 1)
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

    /// Pin Net in a via's right-click menu, where what it acts on has a via
    /// to pin; nil elsewhere, a track's menu too.
    static func pinMenuEntry(
        for ref: HorizontalSelectableRef,
        selection: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> HorizontalTargetItemMenuEntry? {
        guard ref.type == .via,
              !pinnableVias(among: menuRefs(for: ref, selection: selection), in: board).isEmpty else {
            return nil
        }
        return .command(title: "Pin Net", .pinViaNets)
    }

    /// Pin Net on the vias among `refs` that have a net and do not hold it:
    /// each holds the net it has. Returns whether any changed; no net does,
    /// so the copper keeps the nets it had.
    @discardableResult
    static func pinNets(on refs: [HorizontalSelectableRef], in board: inout HorizontalBoard) -> Bool {
        let ids = Set(pinnableVias(among: refs, in: board).map { HorizontalCanvasModeSupport.normalizedID($0.id) })
        var changed = false
        for index in board.vias.indices where ids.contains(HorizontalCanvasModeSupport.normalizedID(board.vias[index].id)) {
            guard board.vias[index].netSetID == nil, let net = board.vias[index].netID else {
                continue
            }
            board.vias[index].netSetID = HorizontalCanvasModeSupport.normalizedID(net)
            changed = true
        }
        return changed
    }

    /// What the canvas says once Pin Net has pinned `count` vias.
    static func pinnedNote(_ count: Int) -> String {
        count == 1 ? "1 via holds its net" : "\(count) vias hold their nets"
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
