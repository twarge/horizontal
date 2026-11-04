import Foundation

/// The junction and via points a board move, turn or mirror carries, with
/// what stands on them. Each point is named by where it was on the board
/// before the change, and `apply` moves what stood there once, matched
/// against that board, as the move's preview (`BoardMovePlanner`) matches it.
///
/// The canvas used to move each point as it came to it, finding what stood
/// there on the board it was changing. A via and its junction, both in the
/// selection a track brings with it, then moved twice: the second found the
/// via where the first had put it. So did anything a nudge put where the next
/// point was, such as the far end of a track one grid step long.
struct BoardMovingPoints {
    private struct Point {
        var target: HorizontalPoint
        /// The nets whose copper goes with the point; nil goes with any.
        var netIDs: [String?]
        /// A selected junction's point carries the ends of lines and arcs too.
        var carriesGraphics: Bool
    }

    private var points = [String: Point]()

    var isEmpty: Bool {
        points.isEmpty
    }

    /// `point` goes to `target`, with the copper of `netID` (of any net, when
    /// nil) that stands on it. A point keeps the first target it is given; one
    /// that stays where it is (a via at the centre of a turn) is left alone.
    mutating func add(_ point: HorizontalPoint, to target: HorizontalPoint, netID: String?, carriesGraphics: Bool = false) {
        guard target != point else {
            return
        }
        let key = HorizontalCanvasModeSupport.pointKey(point)
        guard var entry = points[key] else {
            points[key] = Point(target: target, netIDs: [netID], carriesGraphics: carriesGraphics)
            return
        }
        entry.netIDs.append(netID)
        entry.carriesGraphics = entry.carriesGraphics || carriesGraphics
        points[key] = entry
    }

    /// Moves what stood on the points in `original`, the board before the
    /// change, on `board`, the board being changed: the ends of tracks and net
    /// ties, vias with their drills, and junctions, all on the points' nets;
    /// and at a selected junction's point the ends of lines, connection lines
    /// and arcs (an arc's centre too), but those in `graphicsMovedWhole`
    /// (normalized ids), which move on their own. Whatever the change has
    /// moved already stays where it went. The junctions then fold where they
    /// meet, as a move always folded them.
    func apply(from original: HorizontalBoard, to board: inout HorizontalBoard, graphicsMovedWhole: Set<String> = []) {
        guard !points.isEmpty else {
            return
        }

        func copperTarget(_ point: HorizontalPoint, netID: String?) -> HorizontalPoint? {
            guard let entry = points[HorizontalCanvasModeSupport.pointKey(point)],
                  entry.netIDs.contains(where: { Self.netsMatch($0, netID) }) else {
                return nil
            }
            return entry.target
        }

        func graphicTarget(_ point: HorizontalPoint, id: String) -> HorizontalPoint? {
            guard let entry = points[HorizontalCanvasModeSupport.pointKey(point)],
                  entry.carriesGraphics,
                  !graphicsMovedWhole.contains(HorizontalCanvasModeSupport.normalizedID(id)) else {
                return nil
            }
            return entry.target
        }

        // Nothing here adds or removes geometry, so `board` holds what
        // `original` does at the same indices; the id check is a guard.
        func moveEnds(
            _ segments: inout [HorizontalSegment],
            from before: [HorizontalSegment],
            target: (HorizontalSegment, HorizontalPoint) -> HorizontalPoint?
        ) {
            for index in before.indices where index < segments.count && segments[index].id == before[index].id {
                let segment = before[index]
                if segments[index].from == segment.from, let to = target(segment, segment.from) {
                    segments[index].from = to
                }
                if segments[index].to == segment.to, let to = target(segment, segment.to) {
                    segments[index].to = to
                }
            }
        }

        moveEnds(&board.tracks, from: original.tracks) { copperTarget($1, netID: $0.netID) }
        moveEnds(&board.netTies, from: original.netTies) { copperTarget($1, netID: $0.netID) }
        moveEnds(&board.lines, from: original.lines) { graphicTarget($1, id: $0.id) }
        moveEnds(&board.connectionLines, from: original.connectionLines) { graphicTarget($1, id: $0.id) }
        for index in original.arcs.indices where index < board.arcs.count && board.arcs[index].id == original.arcs[index].id {
            let arc = original.arcs[index]
            if board.arcs[index].from == arc.from, let to = graphicTarget(arc.from, id: arc.id) {
                board.arcs[index].from = to
            }
            if board.arcs[index].to == arc.to, let to = graphicTarget(arc.to, id: arc.id) {
                board.arcs[index].to = to
            }
            if board.arcs[index].center == arc.center, let to = graphicTarget(arc.center, id: arc.id) {
                board.arcs[index].center = to
            }
        }

        // A via takes its drill along: the drill is its own hole object,
        // `HorizontalBoard.viaHoleID(ofVia:)`.
        var viaShifts = [String: HorizontalPoint]()
        for index in original.vias.indices where index < board.vias.count && board.vias[index].id == original.vias[index].id {
            let via = original.vias[index]
            guard board.vias[index].position == via.position,
                  let to = copperTarget(via.position, netID: via.netID) else {
                continue
            }
            board.vias[index].position = to
            viaShifts[HorizontalCanvasModeSupport.normalizedID(via.id)] = to - via.position
        }
        if !viaShifts.isEmpty {
            for index in original.viaHoles.indices where index < board.viaHoles.count && board.viaHoles[index].id == original.viaHoles[index].id {
                let hole = original.viaHoles[index]
                guard board.viaHoles[index].position == hole.position,
                      let viaID = HorizontalBoard.viaID(ofViaHole: hole.id),
                      let shift = viaShifts[HorizontalCanvasModeSupport.normalizedID(viaID)] else {
                    continue
                }
                board.viaHoles[index].position = hole.position + shift
            }
        }

        var landed = [String: (point: HorizontalPoint, ids: [String], netID: String?)]()
        for (id, point) in original.junctions {
            guard board.junctions[id] == point,
                  let to = copperTarget(point, netID: original.junctionNetIDs[id]) else {
                continue
            }
            board.junctions[id] = to
            let netID = points[HorizontalCanvasModeSupport.pointKey(point)]?.netIDs.lazy.compactMap { $0 }.first
            landed[HorizontalCanvasModeSupport.pointKey(to), default: (to, [], netID)].ids.append(id)
        }
        for key in landed.keys.sorted() {
            guard let entry = landed[key], let preferredID = entry.ids.min() else {
                continue
            }
            BoardTrackRouting.mergeJunctions(
                at: entry.point,
                preferredID: preferredID,
                netID: board.junctionNetIDs[preferredID] ?? entry.netID,
                board: &board
            )
        }
    }

    private static func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return HorizontalCanvasModeSupport.normalizedID(lhs) == HorizontalCanvasModeSupport.normalizedID(rhs)
    }
}
