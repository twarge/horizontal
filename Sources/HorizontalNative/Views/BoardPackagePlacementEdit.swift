import Foundation

/// The inspector's X, Y, Angle and Flipped of packages, as changes of place
/// to make together (`BoardPackageMoves`). Set on one package after another,
/// each read every track on the board again, once for a shift and once a pad
/// for a flip, so setting one on a few hundred selected packages took the
/// square of their number.
enum BoardPackagePlacementEdit {
    /// What setting `propertyID` to `value` does to each package `refs`
    /// name on `board`; nil when the property is none of the four, or the
    /// refs aren't all packages. A package a locked track holds stays where
    /// it is, and as it is (`BoardCopperLock`), and so does one that has the
    /// side asked for already.
    static func changes(
        _ value: HorizontalSelectionPropertyValue,
        propertyID: String,
        of refs: [HorizontalSelectableRef],
        in board: HorizontalBoard
    ) -> [(packageID: String, change: BoardPackageMoves.Change)]? {
        guard refs.allSatisfy({ $0.type == .boardPackage }) else {
            return nil
        }
        let change: (HorizontalPlacement) -> BoardPackageMoves.Change?
        switch (propertyID, value) {
        case ("positionX", .length(let x)):
            change = { .shift(HorizontalPoint(x: x - $0.position.x, y: 0)) }
        case ("positionY", .length(let y)):
            change = { .shift(HorizontalPoint(x: 0, y: y - $0.position.y)) }
        case ("angle", .angle(let angle)):
            change = { _ in .angle(HorizontalCanvasModeSupport.wrappedAngle(angle)) }
        case ("flipped", .bool(let flipped)):
            change = { $0.mirrored == flipped ? nil : .flip }
        default:
            return nil
        }
        let held = BoardCopperLock.held(in: board)
        var positions = BoardObjectPositions(of: board)
        return refs.compactMap { ref in
            guard !held.holds(ref), let index = positions.index(of: ref.id, in: \.packages) else {
                return nil
            }
            return change(board.packages[index]).map { (ref.id, $0) }
        }
    }
}
