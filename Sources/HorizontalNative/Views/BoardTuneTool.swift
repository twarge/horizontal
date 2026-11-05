import Foundation

/// The board canvas's tune tool (Horizon's Tune track, clean-room): a click
/// on a straight track starts a meander there, the cursor's place along the
/// track ends the stretch it may take and its side of the track is the side
/// the cells grow on, and a second click lays it, one undo step. Esc drops
/// the meander under way, and a second Esc ends the tool; Return types the
/// target. The target is the Length Tuning window's reference, or a length
/// typed with Return or in the inspector (`HorizontalBoardToolSettings.tuneTarget`).
///
/// Kept apart from `BoardCanvasView` so what the tool does with a click and a
/// cursor can be tested without a canvas.
struct BoardTuneState {
    /// The board as the tune found it, indexed once (`HorizontalMeanderTuner`).
    var tuner: HorizontalMeanderTuner
    var trackID: String?
    var anchor: HorizontalPoint?
    var cursor: HorizontalPoint?
    var result: HorizontalMeanderTuner.Result?
    /// Why the last click laid nothing.
    var refusal: String?

    init(board: HorizontalBoard) {
        tuner = HorizontalMeanderTuner(board: board)
    }

    var hasStarted: Bool { trackID != nil }

    /// A click: on a straight track before a tune has started, starts one
    /// there; returns false where it found no track to start on.
    @discardableResult
    mutating func start(at point: HorizontalPoint, reach: Double, target: Double?,
                        settings: HorizontalMeander.Settings) -> Bool {
        guard let track = tuner.track(near: point, reach: reach) else {
            refusal = "That is no straight track at a multiple of 45°, on a net."
            return false
        }
        trackID = track.id
        anchor = Self.projection(of: point, onto: track)
        cursor = point
        refusal = nil
        update(target: target, settings: settings)
        return true
    }

    /// The cursor moved.
    mutating func move(to point: HorizontalPoint, target: Double?, settings: HorizontalMeander.Settings) {
        guard cursor != point else { return }
        cursor = point
        update(target: target, settings: settings)
    }

    /// The meander under the cursor, worked out again: for a new cursor, a
    /// new target or new settings.
    mutating func update(target: Double?, settings: HorizontalMeander.Settings) {
        guard let trackID, let anchor, let cursor else {
            result = nil
            return
        }
        guard let target else {
            result = nil
            return
        }
        result = tuner.tune(.init(trackID: trackID, anchor: anchor, cursor: cursor, target: target, settings: settings))
    }

    /// Back to choosing a track, the board as it was.
    mutating func restart() {
        trackID = nil
        anchor = nil
        result = nil
        refusal = nil
    }

    /// The board with the meander under the cursor laid, for drawing: its
    /// tracks and junctions have ids of their own, the same every pass, so
    /// the scene the canvas draws keeps its buckets.
    func preview(of board: HorizontalBoard) -> HorizontalBoard {
        guard let result, result.hasCells else { return board }
        var preview = board
        HorizontalMeanderTuner.lay(result, on: &preview, idPrefix: Self.previewIDPrefix)
        return preview
    }

    static let previewIDPrefix = "tune-preview"

    /// What changes the preview, to key the canvas's caches on.
    var previewSignature: (count: Int, hash: Int64, length: Int64)? {
        guard let result, result.hasCells else { return nil }
        var hasher = Hasher()
        hasher.combine(result.pieces)
        return (result.pieces.count, Int64(truncatingIfNeeded: hasher.finalize()), Int64(result.tunedLength.rounded()))
    }

    /// The canvas's one-line hint.
    var hint: String {
        guard hasStarted, let result else {
            if let refusal {
                return "Tune track: \(refusal)   Esc ends"
            }
            return hasStarted
                ? "Tune track: no target. Set a reference in the Length Tuning window, or Return types one   Esc cancels"
                : "Tune track: click a straight track where the meander starts   Return types the target   Esc ends"
        }
        let net = result.netID.flatMap { tuner.board.netDetails[$0.lowercased()]?.name } ?? "the net"
        let now = HorizontalLengthText.millimetres(result.netLength)
        let target = HorizontalLengthText.millimetres(result.request.target)
        let lays = result.hasCells ? "click lays it" : "nothing to lay"
        return "Tune \(net): \(now) → \(target), \(Self.statusText(result))   \(lays)   Esc cancels"
    }

    /// The inspector's state for the tool.
    func inspectorState(target: Double?, source: HorizontalTuneInspectorState.TargetSource) -> HorizontalTuneInspectorState {
        guard hasStarted, let trackID,
              let track = tuner.board.tracks.first(where: { $0.id.lowercased() == trackID.lowercased() }) else {
            var waiting = HorizontalTuneInspectorState.waiting(target: target, source: source)
            if let refusal {
                waiting.status = refusal
                waiting.isShort = true
            }
            return waiting
        }
        let detail = track.netID.flatMap { tuner.board.netDetails[$0.lowercased()] }
        var state = HorizontalTuneInspectorState(
            netName: detail.map { $0.name.isEmpty ? String($0.id.prefix(8)) : $0.name } ?? "No net",
            layerName: track.layer.map(HorizontalBoardLayers.name(for:)),
            netLength: result?.netLength ?? tuner.netLength(track.netID),
            target: target,
            targetSource: source,
            tunedLength: result?.tunedLength,
            cells: result?.plan.cells.count ?? 0,
            blocked: result?.plan.blocked ?? 0,
            status: result.map(Self.statusText) ?? "No target: set a reference in the Length Tuning window, or type one."
        )
        if let refusal {
            state.status = refusal
            state.isShort = true
        } else if case .short = result?.status {
            state.isShort = true
        } else if result?.status == .notStraight || result?.status == .longEnough {
            state.isShort = true
        }
        return state
    }

    static func statusText(_ result: HorizontalMeanderTuner.Result) -> String {
        switch result.status {
        case .reached:
            return result.hasCells
                ? "reached in \(result.plan.cells.count) cell\(result.plan.cells.count == 1 ? "" : "s")"
                : "at the target already"
        case .short(let missing):
            return "\(HorizontalLengthText.millimetres(missing)) short: drag further along the track, or raise the amplitude"
        case .longEnough:
            return "the net is longer than the target already; a meander only lengthens"
        case .notStraight:
            return "only a straight track at a multiple of 45° can take a meander"
        case .noTrack:
            return "the track is gone"
        }
    }

    /// Where `point` falls on the track, rounded to its lattice.
    static func projection(of point: HorizontalPoint, onto track: HorizontalSegment) -> HorizontalPoint {
        guard let lattice = HorizontalMeander.lattice(from: track.from, to: track.to) else {
            return track.from
        }
        let u = min(max(Int(lattice.coordinates(of: point).u.rounded()), 0), lattice.steps)
        return lattice.point(u, 0)
    }
}
