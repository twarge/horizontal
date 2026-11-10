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

    /// The via's Net as a choice of the board's nets, where Set Net… could
    /// give it one: its copper reaches no pad. Nil where the net is the
    /// pads' to give, and the row stays read-only. A via on no net offers
    /// None too, which changes nothing, as Horizon's Set via net has no way
    /// to take a net off.
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
        return HorizontalSelectionProperty(
            id: viaNetPropertyID, label: "Net", editor: .choice(choices), value: .choice(current ?? ""))
    }

    /// An edit of the Locked or Net row on `ref`, made on `board`. Returns
    /// whether `propertyID` was one of them, changed or not.
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
        default:
            return false
        }
    }
}
