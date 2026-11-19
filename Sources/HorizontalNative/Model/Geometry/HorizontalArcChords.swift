import Foundation

/// How many chords stand in for a circle or an arc, by its size.
///
/// A fixed count suits one size: 32 chords round a 0.6 mm via stay within a
/// micron and a half of it, and round a 10 mm mounting pad they cut 24 µm
/// inside it. A plane poured round those chords then came closer to the real
/// copper than the rules allow, and the clearance check, which measures a via
/// and a hole as the discs they are, said so all the way round.
///
/// So the count follows the radius: enough chords that none strays more than
/// `tolerance` from the curve, and never fewer than the count the caller used
/// to draw with, so small copper is cut as it always was.
enum HorizontalArcChords {
    /// The most a chord may stray from its curve, in nanometres: the arc
    /// tolerance the pour gives Clipper for a round join. The pour keeps
    /// 5 µm more than the clearance (`twiddle`), which covers this and
    /// Clipper's own with a micron to spare.
    static let tolerance = 2_000.0

    /// A circle of a metre across needs under 1600; more is a radius that
    /// isn't one.
    static let most = 4_096

    /// The chords for `sweep` radians of a circle of `radius`, at least
    /// `minimum`. A count beyond the minimum is rounded up to a multiple of
    /// `multiple`: four for a whole circle and two for a half, so a corner
    /// falls on each quarter turn and the outline is as wide and as high as
    /// the curve.
    static func count(radius: Double, sweep: Double = 2 * Double.pi, atLeast minimum: Int = 1,
                      multipleOf multiple: Int = 1, tolerance: Double = HorizontalArcChords.tolerance) -> Int {
        let radius = abs(radius), sweep = abs(sweep)
        guard radius > tolerance, tolerance > 0, sweep > 0, radius.isFinite, sweep.isFinite else {
            return max(minimum, 1)
        }
        // A chord that subtends 2a strays r(1 - cos a) from the curve.
        let step = 2 * acos(1 - tolerance / radius)
        var needed = min(Int((sweep / step).rounded(.up)), most)
        guard needed > minimum else { return max(minimum, 1) }
        if multiple > 1, needed % multiple != 0 {
            needed += multiple - needed % multiple
        }
        return needed
    }
}
