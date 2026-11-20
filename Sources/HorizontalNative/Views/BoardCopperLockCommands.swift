import Foundation

/// The board canvas's side of Lock, Unlock and Unlock All
/// (`BoardCopperLock`), and of a via's Net in the inspector (`BoardSetNet`):
/// the right-click entry, the inspector rows and what an edit of them does.
/// The canvas makes each one undoable edit.
enum BoardCopperLockCommands {
    /// The inspector's Locked row on a track or via.
    static let lockedPropertyID = "locked"
    /// The inspector's Net row on a via whose copper can take one.
    static let viaNetPropertyID = "viaNet"
    /// The inspector's Clear Net button on a via that holds its net.
    static let clearViaNetPropertyID = "clearViaNet"

    /// Lock or Unlock in a track's or via's right-click menu, as the copper
    /// is; nil on anything else.
    static func menuEntry(for ref: HorizontalSelectableRef, in board: HorizontalBoard) -> HorizontalTargetItemMenuEntry? {
        guard BoardCopperLock.isLockable(ref) else {
            return nil
        }
        return BoardCopperLock.isLocked(ref, in: board)
            ? .command(title: "Unlock", .setCopperLocked(false))
            : .command(title: "Lock", .setCopperLocked(true))
    }

    /// A Locked switch for a track or via; nil on anything else.
    static func lockedProperty(_ ref: HorizontalSelectableRef, locked: Bool) -> HorizontalSelectionProperty? {
        guard BoardCopperLock.isLockable(ref) else {
            return nil
        }
        return HorizontalSelectionProperty(id: lockedPropertyID, label: "Locked", editor: .bool, value: .bool(locked))
    }

    /// A via's net comes one of two ways, as Horizon's does: from the copper
    /// it joins, its tracks and through them their pads, or from the via
    /// itself, which holds one set on it (`net_set`) and stands on it alone,
    /// as a stitching via does. The rows say which: the Net row marks a set
    /// net "(set)", as Horizon's via properties do, and a via that holds one
    /// gets Clear Net, which hands its net back to its copper.
    ///
    /// The Net row is the choice `viaNetProperty` makes where Set Net…
    /// could give the via one, else the net read-only: `name` is the
    /// canvas's name for a net. Nothing is editable where `editable` is
    /// false (a read-only document, or a mode with no Set Net…).
    static func viaNetProperties(
        _ via: HorizontalMarker,
        in board: HorizontalBoard,
        editable: Bool,
        name: (String?) -> String?,
        options: () -> [HorizontalSelectionPropertyOption]
    ) -> [HorizontalSelectionProperty] {
        let net = (editable ? viaNetProperty(via, in: board, options: options) : nil)
            ?? name(via.netID).flatMap { title -> HorizontalSelectionProperty? in
                guard !title.isEmpty else {
                    return nil
                }
                return HorizontalSelectionProperty(
                    id: "name", label: "Net", editor: .readOnly, value: .readOnly(setNetTitle(title, via: via)))
            }
        let clear = editable ? clearViaNetProperty(via) : nil
        return [net, clear].compactMap { $0 }
    }

    /// `title`, marked as the via's own where the via holds the net it names.
    private static func setNetTitle(_ title: String, via: HorizontalMarker) -> String {
        guard let set = via.netSetID.map(HorizontalCanvasModeSupport.normalizedID),
              via.netID.map(HorizontalCanvasModeSupport.normalizedID) == set else {
            return title
        }
        return "\(title) (set)"
    }

    /// Clear Net, on a via that holds its net; nil on one its copper gives
    /// a net, or none.
    static func clearViaNetProperty(_ via: HorizontalMarker) -> HorizontalSelectionProperty? {
        guard via.netSetID != nil else {
            return nil
        }
        return HorizontalSelectionProperty(id: clearViaNetPropertyID, label: "Clear Net", editor: .action, value: .bool(true))
    }

    /// The via's Net as a choice of the board's nets, where Set Net… could
    /// give it one: its copper reaches no pad. Nil where the net is the
    /// pads' to give, and the row stays read-only. A via on no net offers
    /// None too, which changes nothing, as Horizon's Set via net has no way
    /// to take a net off: Clear Net does that. The net a via holds itself
    /// is marked "(set)" among the choices.
    static func viaNetProperty(
        _ via: HorizontalMarker,
        in board: HorizontalBoard,
        options: () -> [HorizontalSelectionPropertyOption]
    ) -> HorizontalSelectionProperty? {
        let ref = HorizontalSelectableRef(id: via.id, type: .via)
        guard case .available? = BoardSetNet.availability(of: ref, in: board) else {
            return nil
        }
        var choices = options()
        let current = via.netID.map(HorizontalCanvasModeSupport.normalizedID)
        if current == nil {
            choices.insert(HorizontalSelectionPropertyOption(id: "", title: "None"), at: 0)
        }
        guard !choices.isEmpty else {
            return nil
        }
        if let index = choices.firstIndex(where: { $0.id == current && !$0.id.isEmpty }) {
            choices[index].title = setNetTitle(choices[index].title, via: via)
        }
        return HorizontalSelectionProperty(
            id: viaNetPropertyID, label: "Net", editor: .choice(choices), value: .choice(current ?? ""))
    }

    /// An edit of the Locked or Net row, or Clear Net, on `ref`, made on
    /// `board`. Returns whether `propertyID` was one of them, changed or not.
    static func apply(
        _ value: HorizontalSelectionPropertyValue,
        propertyID: String,
        to ref: HorizontalSelectableRef,
        board: inout HorizontalBoard
    ) -> Bool {
        switch (propertyID, value) {
        case (lockedPropertyID, .bool(let locked)) where BoardCopperLock.isLockable(ref):
            BoardCopperLock.setLocked(locked, on: [ref], in: &board)
            return true
        case (viaNetPropertyID, .choice(let netID)) where ref.type == .via:
            if !netID.isEmpty {
                BoardSetNet.setNet(netID, on: [ref], in: &board)
            }
            return true
        case (clearViaNetPropertyID, _) where ref.type == .via:
            BoardSetNet.clearNet(on: [ref], in: &board)
            return true
        default:
            return false
        }
    }
}
