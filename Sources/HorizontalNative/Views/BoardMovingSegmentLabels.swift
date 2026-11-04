import Foundation

/// The net labels of the tracks and net ties a move under way reshapes,
/// written where the move takes them. The scene draws such a track from its
/// moved ends (`boardMetalLineEndpointPatch`), which leaves its label's
/// strokes, kept under the track's ref, at the old middle and angle; a track
/// the move only shifts takes its label along in the same translation, but a
/// turn would carry the label round with it where a rebuilt scene draws it
/// level again. So the label of a track the move stretches, or of any track
/// it moves while a turn is under way, is drawn again from the moved track,
/// as a rebuilt scene would draw it; one a rebuilt scene would not draw (the
/// track now too short for it, the label too small at this zoom) or that
/// would take other strokes than its span holds is hidden until the commit
/// rebuilds the scene.
enum BoardMovingSegmentLabels {
    struct Segment: Equatable {
        var ref: HorizontalSelectableRef
        /// Where the move has taken it.
        var moved: HorizontalSegment
        /// Where its label's strokes are in the resident scene.
        var spans: [BoardMetalTextSpan]
    }

    /// Past this many strokes a move hides the labels it reshapes rather than
    /// lay their strokes out again on every step.
    static let maximumRedrawnStrokes = 20_000

    /// The labelled tracks and net ties of `plan` whose labels the
    /// translation doesn't put where a rebuilt scene would: those `placement`
    /// moves one end of, and with a turn or a flip, all it moves. `segments`
    /// are the board's as the move began, by normalized id, and `textSpans`
    /// the resident scene's text strokes by owner.
    static func reshaped(
        plan: BoardResidentMovePlan,
        placement: HorizontalPlacementTransform,
        segments: [String: HorizontalSegment],
        textSpans: [HorizontalSelectableRef: [BoardMetalTextSpan]]
    ) -> [Segment] {
        let turns = placement.angle != 0 || placement.mirrored
        var reshaped = [Segment]()
        for (ref, move) in plan.segmentMoves where ref.type == .track || ref.type == .boardNetTie {
            guard let spans = textSpans[ref], !spans.isEmpty,
                  let segment = segments[HorizontalCanvasModeSupport.normalizedID(ref.id)] else {
                continue
            }
            if move.isRigid(for: segment), !turns {
                continue
            }
            reshaped.append(Segment(
                ref: ref,
                moved: BoardMovingTrackOutlines.moved(segment, by: move, placement: placement),
                spans: spans
            ))
        }
        return reshaped
    }

    /// What to write over `span`, whose strokes are in `lines` from its
    /// `lineIndex`: `label`'s strokes, at its stroke width, in the style the
    /// scene gave the old ones, or the old ones made transparent when there
    /// is no label, it is smaller than `minimumLabelSize` (the scene's zoom
    /// cull, 0 for none), or
    /// it takes other strokes than the span holds. Nil when the span is not
    /// where it says in `lines`.
    static func patch(
        for span: BoardMetalTextSpan,
        label: HorizontalText?,
        lines: [HorizontalMetalLinePrimitive],
        minimumLabelSize: Double
    ) -> HorizontalMetalLineBufferPatch? {
        guard span.count > 0,
              span.lineIndex >= 0,
              span.lineIndex + span.count <= lines.count,
              lines[span.lineIndex].compositeGroup == span.compositeGroup else {
            return nil
        }
        let style = lines[span.lineIndex]
        if let label, !(minimumLabelSize > 0 && label.size > 0 && label.size < minimumLabelSize) {
            let strokes = HorizontalOutlineTextRenderer.outlineSegments(for: label)
            if strokes.count == span.count {
                return HorizontalMetalLineBufferPatch(
                    compositeGroup: span.compositeGroup,
                    start: span.start,
                    primitives: strokes.map { stroke in
                        var primitive = style
                        primitive.from = stroke.0
                        primitive.to = stroke.1
                        primitive.width = label.width
                        return primitive
                    }
                )
            }
        }
        let transparent = HorizontalMetalRGBA(red: 0, green: 0, blue: 0, alpha: 0)
        return HorizontalMetalLineBufferPatch(
            compositeGroup: span.compositeGroup,
            start: span.start,
            primitives: lines[span.lineIndex..<(span.lineIndex + span.count)].map { primitive in
                var primitive = primitive
                primitive.color = transparent
                return primitive
            }
        )
    }
}
