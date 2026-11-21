import Foundation

/// Track simplification: two straight tracks that meet end to end and run on
/// along one line are one track. The route tool lays a track per click, so
/// clicks along a line left a track for each, and a via taken out of the
/// middle of a run left the two tracks it stood between.
///
/// Two tracks merge at a point only where nothing else is: both straight and
/// unlocked, on one layer, one net and one width, the only two track ends
/// there, with no net tie end, via, hole or pad centre at the point. The
/// line may run at any angle: the test is the distance of the shared point
/// from the line through the two far ends (`collinearTrackTolerance`), and
/// that the second track goes on from the first rather than back over it.
extension HorizontalBoard {
    /// How far, in nanometres, the point two tracks share may stand off the
    /// line through their far ends for the two to count as one line. Board
    /// coordinates are whole nanometres, so a point cut into a track at any
    /// angle is within about 0.71 of the track's line, and merges back.
    static let collinearTrackTolerance = 1.0

    /// Merges the tracks that meet at each of `points` where they are one
    /// line (see above), point after point, so a run of several comes down
    /// to one. The track earlier in `tracks` is kept, stretched to the other's
    /// far end and onto its junction; the junction at the point goes with the
    /// merge unless a line or arc is still on it. Returns the ids of the
    /// tracks taken off, each with the id of the track that now covers it.
    @discardableResult
    mutating func mergeCollinearTracks(at points: [HorizontalPoint]) -> [String: String] {
        guard !points.isEmpty, tracks.count > 1 else {
            return [:]
        }
        let key = HorizontalBoard.junctionPointKey
        var blocked = Set<String>()
        for tie in netTies {
            blocked.insert(key(tie.from))
            blocked.insert(key(tie.to))
        }
        for via in vias {
            blocked.insert(key(via.position))
        }
        for hole in holes + packageHoles + viaHoles {
            blocked.insert(key(hole.position))
        }
        for pad in packagePadPositions.values {
            blocked.insert(key(pad))
        }
        var heldByGraphics = Set<String>()
        for line in lines {
            heldByGraphics.insert(key(line.from))
            heldByGraphics.insert(key(line.to))
        }
        for arc in arcs {
            for point in [arc.from, arc.to, arc.center] {
                heldByGraphics.insert(key(point))
            }
        }

        var merged = [String: String]()
        var seen = Set<String>()
        for point in points {
            let pointKey = key(point)
            guard seen.insert(pointKey).inserted, !blocked.contains(pointKey) else {
                continue
            }
            // The track ends at the point, each as (track, whether its `from`).
            var ends = [(index: Int, isFrom: Bool)]()
            for index in tracks.indices {
                if key(tracks[index].from) == pointKey {
                    ends.append((index, true))
                }
                if key(tracks[index].to) == pointKey {
                    ends.append((index, false))
                }
                if ends.count > 2 {
                    break
                }
            }
            guard ends.count == 2, ends[0].index != ends[1].index else {
                continue
            }
            let kept = tracks[ends[0].index]
            let gone = tracks[ends[1].index]
            guard HorizontalBoard.tracksAreOneLine(kept, endingAtFrom: ends[0].isFrom, gone, endingAtFrom: ends[1].isFrom) else {
                continue
            }
            let farPoint = ends[1].isFrom ? gone.to : gone.from
            let farJunction = ends[1].isFrom ? gone.toJunctionID : gone.fromJunctionID
            if ends[0].isFrom {
                tracks[ends[0].index].from = farPoint
                tracks[ends[0].index].fromJunctionID = farJunction
            } else {
                tracks[ends[0].index].to = farPoint
                tracks[ends[0].index].toJunctionID = farJunction
            }
            tracks.remove(at: ends[1].index)
            merged[gone.id] = kept.id

            if !heldByGraphics.contains(pointKey) {
                for id in junctions.filter({ key($0.value) == pointKey }).map(\.key) {
                    junctions.removeValue(forKey: id)
                    junctionNetIDs.removeValue(forKey: id)
                }
            }
        }
        // A track kept by one merge and taken off by a later one.
        for (gone, kept) in merged {
            var last = kept
            while let next = merged[last] {
                last = next
            }
            merged[gone] = last
        }
        return merged
    }

    /// `mergeCollinearTracks(at:)` at the ends of the tracks `original`
    /// doesn't have: what a route laid, merged along its own run and into the
    /// copper it carries straight on from.
    @discardableResult
    mutating func mergeCollinearTracks(laidSince original: HorizontalBoard) -> [String: String] {
        let before = Set(original.tracks.map { $0.id.lowercased() })
        let laid = tracks.filter { !before.contains($0.id.lowercased()) }
        return mergeCollinearTracks(at: laid.flatMap { [$0.from, $0.to] })
    }

    /// Whether `a` and `b`, which share the end each names, can be one track:
    /// alike in everything but where they run, and running on along one line.
    private static func tracksAreOneLine(
        _ a: HorizontalSegment, endingAtFrom aFrom: Bool,
        _ b: HorizontalSegment, endingAtFrom bFrom: Bool
    ) -> Bool {
        guard a.center == nil, b.center == nil, !a.locked, !b.locked,
              a.layer == b.layer,
              a.netID?.lowercased() == b.netID?.lowercased(),
              abs(a.width - b.width) < 0.5,
              a.widthFromRules == b.widthFromRules else {
            return false
        }
        // Ends the file puts on two junctions are not joined.
        if let aJunction = aFrom ? a.fromJunctionID : a.toJunctionID,
           let bJunction = bFrom ? b.fromJunctionID : b.toJunctionID,
           aJunction.lowercased() != bJunction.lowercased() {
            return false
        }
        let start = aFrom ? a.to : a.from
        let shared = aFrom ? a.from : a.to
        let end = bFrom ? b.to : b.from
        let incoming = shared - start
        let outgoing = end - shared
        let whole = end - start
        let length = (whole.x * whole.x + whole.y * whole.y).squareRoot()
        guard incoming.x != 0 || incoming.y != 0, outgoing.x != 0 || outgoing.y != 0, length > 0 else {
            return false
        }
        // On along the line, not back over it.
        guard incoming.x * outgoing.x + incoming.y * outgoing.y > 0 else {
            return false
        }
        let cross = whole.x * incoming.y - whole.y * incoming.x
        return abs(cross) / length <= collinearTrackTolerance
    }
}
