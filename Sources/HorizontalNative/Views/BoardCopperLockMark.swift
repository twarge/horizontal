import Foundation

/// The padlock the board canvas draws on locked copper (`BoardCopperLock`),
/// as Horizon marks a locked track and via with one: strokes in board
/// coordinates, upright, for the scene to draw over the copper.
///
/// A track's is 0.7 of its width, Horizon's size for it. Horizon puts one at
/// the track's middle, where Horizontal writes the net's name, so a track
/// carries one a little in from each end instead, and a track too short for
/// two carries one at its middle. A via's sits in the top of its ring, clear
/// of the drill and of the net's name across the via.
enum BoardCopperLockMark {
    /// One padlock: the polylines to stroke, and the stroke's width.
    struct Mark: Equatable {
        var strokes: [[HorizontalPoint]]
        var width: Double
    }

    /// The padlocks on `track`, none unless it is locked.
    static func marks(for track: HorizontalSegment) -> [Mark] {
        guard track.locked, track.width > 0 else {
            return []
        }
        let path = track.pathPoints
        let length = zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
        guard length > 0 else {
            return []
        }
        let size = track.width * 0.7
        // In from the end far enough to clear the end's round cap, and the
        // via or pad that is likely there.
        let inset = max(length / 12, track.width * 1.5)
        let distances = inset * 2 + size < length ? [inset, length - inset] : [length / 2]
        return distances.compactMap { point(along: path, at: $0) }.map { padlock(center: $0, size: size) }
    }

    /// The padlock on `via`, none unless it is locked.
    static func marks(for via: HorizontalMarker) -> [Mark] {
        guard via.locked, via.size > 0 else {
            return []
        }
        let outer = via.size / 2
        // The ring between the drill and the edge; a via with no drill to
        // read is taken to have one of half its size.
        let inner = min(max((via.holeSize ?? via.size / 2) / 2, 0), outer * 0.8)
        let size = (outer - inner) * 0.8
        let center = HorizontalPoint(x: via.position.x, y: via.position.y + (outer + inner) / 2)
        return [padlock(center: center, size: size)]
    }

    /// A padlock `size` tall about `center`: a body, and a shackle over it.
    static func padlock(center: HorizontalPoint, size: Double) -> Mark {
        func at(_ x: Double, _ y: Double) -> HorizontalPoint {
            HorizontalPoint(x: center.x + x * size, y: center.y + y * size)
        }
        let body = [at(-0.36, -0.5), at(0.36, -0.5), at(0.36, 0.04), at(-0.36, 0.04), at(-0.36, -0.5)]
        // The shackle: up from the body, round a half circle, down again.
        let radius = 0.22, top = 0.28
        var shackle = [at(-radius, 0.04)]
        let steps = 8
        for step in 0...steps {
            let angle = Double.pi - Double.pi * Double(step) / Double(steps)
            shackle.append(at(radius * cos(angle), top + radius * sin(angle)))
        }
        shackle.append(at(radius, 0.04))
        return Mark(strokes: [body, shackle], width: size * 0.1)
    }

    private static func distance(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        hypot(b.x - a.x, b.y - a.y)
    }

    /// The point `target` along `path` from its start.
    private static func point(along path: [HorizontalPoint], at target: Double) -> HorizontalPoint? {
        var travelled = 0.0
        for (from, to) in zip(path, path.dropFirst()) {
            let step = distance(from, to)
            if step > 0, travelled + step >= target {
                let fraction = (target - travelled) / step
                return HorizontalPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            }
            travelled += step
        }
        return path.last
    }
}
