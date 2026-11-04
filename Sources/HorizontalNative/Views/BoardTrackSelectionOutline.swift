import Foundation

/// How a selected or hovered track is outlined: Horizon's box round it, in
/// place of the dashed line along its middle that a wire or a board line
/// draws. A straight track's box is its selectable's, as long as the track
/// with half its width more at each end and as wide as the track, turned with
/// it (Horizon's `append_line`), so it takes in the round ends. An arc track's
/// selectable is the bounds of its centre line, which the copper overhangs by
/// half the track's width on every side, so its outline is that much larger.
/// The point selectable at a straight track's middle, its grab handle, keeps
/// the outline every point has.
enum BoardTrackSelectionOutline {
    static func outline(
        for selectable: HorizontalSelectable,
        arcWidths: [String: Double]
    ) -> HorizontalCanvasSelectionOutline? {
        guard selectable.ref.type == .track, !selectable.isPoint else {
            return nil
        }
        let margin = (arcWidths[HorizontalCanvasModeSupport.normalizedID(selectable.ref.id)] ?? 0) / 2
        return HorizontalCanvasSelectionOutline(
            points: selectable.corners(expandedByWorld: margin),
            handlePoints: [selectable.center]
        )
    }

    /// The widths of the arc tracks among `refs`, by normalized id, for
    /// `outline(for:arcWidths:)`; empty when none of them is a track, so a
    /// selection without one never walks the board's tracks.
    static func arcWidths(in board: HorizontalBoard, refs: [HorizontalSelectableRef]) -> [String: Double] {
        let ids = Set(refs.filter { $0.type == .track }.map { HorizontalCanvasModeSupport.normalizedID($0.id) })
        guard !ids.isEmpty else {
            return [:]
        }
        var widths = [String: Double]()
        for track in board.tracks where track.center != nil {
            let id = HorizontalCanvasModeSupport.normalizedID(track.id)
            if ids.contains(id) {
                widths[id] = track.width
            }
        }
        return widths
    }
}
