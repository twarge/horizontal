import Foundation

/// How many tracks fit through a gap: along a line drawn across a corridor,
/// the stretches where a track's centre may lie, and how many tracks of that
/// width each holds side by side.
///
/// The line is walked in small steps and each end of a stretch then found to
/// a twentieth of a micrometre, against the board's exact shapes with the
/// clearance the rules ask (`HorizontalBoardProbe`): the arithmetic a person
/// does by hand between a via and a neighbouring track, done by the engine.
enum HorizontalChannelCapacity {
    struct Gap {
        /// Where a track's centre may lie, from the cut's start, in nanometres.
        var start: Double
        var end: Double
        var from: HorizontalPoint
        var to: HorizontalPoint
        /// Tracks of the width asked that fit side by side.
        var tracks: Int
        /// What closes the stretch at each end; nil where the cut itself ends.
        var before: HorizontalBoardProbe.Obstacle?
        var after: HorizontalBoardProbe.Obstacle?

        var centres: Double { end - start }
    }

    /// The gaps along the cut from `from` to `to` on `layer` for a track of
    /// `width` on `net`. `spacing` is what tracks side by side keep between
    /// them: the rules' track to track clearance unless given.
    static func gaps(probe: HorizontalBoardProbe, from: HorizontalPoint, to: HorizontalPoint, layer: Int, width: Double,
                     net: String?, spacing: Double? = nil) -> [Gap] {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return [] }
        func point(_ distance: Double) -> HorizontalPoint {
            let t = distance / length
            return HorizontalPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        }
        func blocker(_ distance: Double) -> HorizontalBoardProbe.Obstacle? {
            probe.firstViolation(.init(kind: .track, netID: net?.lowercased(), shape: .disc(point(distance), radius: width / 2)), layer: layer)
        }
        let pitch = (spacing ?? Double(probe.rules.clearanceCopper(net1: net, net2: nil, layer: layer).clearance(.track, .track))) + probe.margin + width
        let count = min(max(Int((length / 5_000).rounded(.up)), 1), 20_000)
        let step = length / Double(count)
        /// The boundary between a clear position and a blocked one, to 50 nm.
        func edge(clear: Double, blocked: Double) -> Double {
            var clear = clear, blocked = blocked
            while abs(blocked - clear) > 50 {
                let middle = (clear + blocked) / 2
                if blocker(middle) == nil { clear = middle } else { blocked = middle }
            }
            return clear
        }
        var gaps = [Gap]()
        var open: (start: Double, before: HorizontalBoardProbe.Obstacle?)?
        var previous: (distance: Double, blocker: HorizontalBoardProbe.Obstacle?)?
        for index in 0...count {
            let distance = Double(index) * step
            let here = blocker(distance)
            if here == nil, open == nil {
                if let previous, previous.blocker != nil {
                    open = (edge(clear: distance, blocked: previous.distance), previous.blocker)
                } else {
                    open = (distance, nil)
                }
            } else if let here, let current = open, let previous {
                let end = edge(clear: previous.distance, blocked: distance)
                gaps.append(gap(current.start, end, before: current.before, after: here, point: point, pitch: pitch))
                open = nil
            }
            previous = (distance, here)
        }
        if let current = open {
            gaps.append(gap(current.start, length, before: current.before, after: nil, point: point, pitch: pitch))
        }
        return gaps
    }

    private static func gap(_ start: Double, _ end: Double, before: HorizontalBoardProbe.Obstacle?, after: HorizontalBoardProbe.Obstacle?,
                            point: (Double) -> HorizontalPoint, pitch: Double) -> Gap {
        // One track where its centre has anywhere to be, and another for
        // every pitch of room beyond that; a twentieth of a micrometre is
        // the edges' own precision.
        let tracks = Int(((end - start + 100) / pitch).rounded(.down)) + 1
        return Gap(start: start, end: end, from: point(start), to: point(end), tracks: max(tracks, 1), before: before, after: after)
    }
}
