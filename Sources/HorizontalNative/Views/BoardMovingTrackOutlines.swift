import Foundation

/// The selected tracks and net ties a move redraws rather than shifts: those
/// it doesn't carry whole, because an end stays where it is, on a pad
/// (`BoardTrackPadEnds`) or on copper the move leaves. The scene draws such a
/// track from its moved ends (`BoardResidentSegmentMove`), so its selection
/// outline is drawn from the same ends and keeps to the copper, where the
/// shift that carries the rest of the selection would slide the box off it. A
/// track neither end of which moves, pad to pad, keeps its outline in place.
struct BoardMovingTrackOutlines {
    struct Track {
        var ref: HorizontalSelectableRef
        /// As it was when the move began.
        var segment: HorizontalSegment
        /// Which of its points the move takes; nil for none.
        var move: BoardResidentSegmentMove?
    }

    var tracks: [Track] = []

    var isEmpty: Bool {
        tracks.isEmpty
    }

    var refs: Set<HorizontalSelectableRef> {
        Set(tracks.map(\.ref))
    }

    /// The widths of the arc tracks among them, by normalized id, for
    /// `BoardTrackSelectionOutline.outline(for:arcWidths:)`.
    var arcWidths: [String: Double] {
        var widths = [String: Double]()
        for track in tracks where track.ref.type == .track && track.segment.center != nil {
            widths[HorizontalCanvasModeSupport.normalizedID(track.segment.id)] = track.segment.width
        }
        return widths
    }

    init() {}

    /// Those of `selectedRefs` that `plan` doesn't carry whole, found in
    /// `board`, the board the move began from. A selection with no track or
    /// net tie never walks the board's.
    init(selectedRefs: [HorizontalSelectableRef], plan: BoardResidentMovePlan, board: HorizontalBoard) {
        let candidates = HorizontalCanvasModeSupport.uniqueRefs(selectedRefs).filter {
            ($0.type == .track || $0.type == .boardNetTie) && !plan.translatedRefs.contains($0)
        }
        guard !candidates.isEmpty else {
            return
        }
        var segments = [HorizontalObjectType: [String: HorizontalSegment]]()
        for (type, list) in [(HorizontalObjectType.track, board.tracks), (.boardNetTie, board.netTies)] {
            let ids = Set(candidates.filter { $0.type == type }.map { HorizontalCanvasModeSupport.normalizedID($0.id) })
            guard !ids.isEmpty else {
                continue
            }
            for segment in list {
                let id = HorizontalCanvasModeSupport.normalizedID(segment.id)
                if ids.contains(id) {
                    segments[type, default: [:]][id] = segment
                }
            }
        }
        for ref in candidates {
            guard let segment = segments[ref.type]?[HorizontalCanvasModeSupport.normalizedID(ref.id)] else {
                continue
            }
            let move = plan.segmentMoves[ref]
            if move?.isRigid(for: segment) == true {
                continue
            }
            tracks.append(Track(ref: ref, segment: segment, move: move))
        }
    }

    /// Their selectables where `placement`, the move so far, has taken their
    /// moving points; `.identity` gives them as they were.
    func selectables(at placement: HorizontalPlacementTransform) -> [HorizontalSelectableRef: [HorizontalSelectable]] {
        var selectables = [HorizontalSelectableRef: [HorizontalSelectable]]()
        for track in tracks {
            let moved = Self.moved(track.segment, by: track.move, placement: placement)
            selectables[track.ref] = HorizontalCanvasModeSupport.segmentSelectables(
                [moved],
                type: track.ref.type,
                convertsArcSegments: true
            )
        }
        return selectables
    }

    /// `segment` with the points `move` takes placed by `placement`, as the
    /// scene draws it (`boardMetalLineEndpointPatch`).
    static func moved(
        _ segment: HorizontalSegment,
        by move: BoardResidentSegmentMove?,
        placement: HorizontalPlacementTransform
    ) -> HorizontalSegment {
        guard let move else {
            return segment
        }
        var moved = segment
        if move.movesFrom {
            moved.from = placement.applying(to: segment.from)
        }
        if move.movesTo {
            moved.to = placement.applying(to: segment.to)
        }
        if move.movesCenter, let center = segment.center {
            moved.center = placement.applying(to: center)
        }
        return moved
    }
}
