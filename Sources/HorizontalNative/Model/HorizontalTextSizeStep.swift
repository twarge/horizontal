import Foundation

/// ⌘⇧+ and ⌘⇧−: a text a size bigger or smaller. The sizes are a ladder,
/// 0.1 mm apart below 1 mm and 0.25 mm apart from there up (0.1, 0.2, …,
/// 0.9, 1.0, 1.25, 1.5, …), and a step goes to the next rung up or down, so
/// 0.9 mm goes up to 1.0 mm and 1.0 mm down to 0.9 mm. A size between two
/// rungs, as 1.2 mm, goes to the one in the step's direction (1.25 mm up,
/// 1.0 mm down), so the sizes it gives are always round ones, whole
/// nanometres. All in nanometres, as the files keep them.
enum HorizontalTextSizeStep {
    /// The rungs below 1 mm.
    static let fineStep: Double = 100_000
    /// The rungs from 1 mm up.
    static let coarseStep: Double = 250_000
    /// Where the coarse rungs start.
    static let coarseFrom: Double = 1_000_000
    /// The smallest a step down gives.
    static let smallest: Double = fineStep

    /// A size this close to a rung is on it: a size read from a file or
    /// typed in millimetres may be a hair off.
    private static let tolerance: Double = 0.5

    /// The size a step up (`larger`) or down from `size` gives; nil when a
    /// step down has nowhere to go, at the smallest size or below it.
    static func stepped(_ size: Double, larger: Bool) -> Double? {
        guard size.isFinite else {
            return nil
        }
        if larger {
            let step = size < coarseFrom - tolerance ? fineStep : coarseStep
            return ((size + tolerance) / step).rounded(.down) * step + step
        }
        let step = size > coarseFrom + tolerance ? coarseStep : fineStep
        let next = ((size - tolerance) / step).rounded(.up) * step - step
        return next < smallest - tolerance ? nil : next
    }
}
