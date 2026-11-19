import Foundation

/// Clear All Planes (⇧Q) and what it leaves behind. The fills are emptied in
/// memory, never in the files, and the board says so (`planeFillsCleared`) so
/// that they stay empty: the pour that follows an edit, the automatic one or
/// a plane edit's, would put back what was cleared on purpose. Update All
/// Planes (Q) pours them again, and taking its fills ends it
/// (`takePlaneFills`).
///
/// The board carries it rather than the window: a canvas's copy, an undo
/// step's and another window's of the same project all say the same thing
/// as the fills they hold.
extension HorizontalBoard {
    /// Whether Clear All Planes has anything to do: fills to empty, or planes
    /// the next edit would otherwise pour.
    var canClearPlaneFills: Bool {
        !planes.isEmpty && (!planeFillsCleared || planes.contains { !$0.fragments.isEmpty })
    }

    /// Empties every plane's fill, to stay empty until Update All Planes.
    mutating func clearPlaneFills() {
        for index in planes.indices {
            planes[index].fragments = []
        }
        planeFillsCleared = true
    }

    /// Whether this board takes the fills of `result`. With its planes
    /// cleared, only those Update All Planes asked for: a pour that was on
    /// its way when they were cleared, here or in another window, is not
    /// what was asked for last. Q's pour is the one that is an undo step.
    func takesPlaneFills(of result: HorizontalPlanePourResult) -> Bool {
        !planeFillsCleared || result.registersUndo
    }
}
