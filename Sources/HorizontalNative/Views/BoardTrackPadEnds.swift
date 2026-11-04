import Foundation

/// The track and net tie ends a move leaves where they are: those on a pad.
///
/// Moving a track moves its two ends, and an end on a pad stays on it, as in
/// Horizon, whose move tool carries a track's junctions and never its pads. A
/// track from a pad to a junction swings about the pad; one from pad to pad
/// stays put. A package the selection moves carries the ends on its pads, so
/// a track one of those ends is on isn't moved as a track at all.
///
/// An end is on a pad when it is at a pad's centre
/// (`HorizontalBoard.packagePadPositions`), as the writer tells a pad end from
/// a junction one; a junction or via there stays with it. The centres are
/// keyed once, on the first end asked about, since most moves ask about none.
struct BoardTrackPadEnds {
    private let padPositions: [String: HorizontalPoint]
    private var keys: Set<String>?

    init(padPositions: [String: HorizontalPoint]) {
        self.padPositions = padPositions
    }

    /// Whether a track end at `point` is on a pad, and so stays there.
    mutating func isOnPad(_ point: HorizontalPoint) -> Bool {
        let keys = keys ?? Set(padPositions.values.map(HorizontalCanvasModeSupport.pointKey))
        self.keys = keys
        return keys.contains(HorizontalCanvasModeSupport.pointKey(point))
    }
}
