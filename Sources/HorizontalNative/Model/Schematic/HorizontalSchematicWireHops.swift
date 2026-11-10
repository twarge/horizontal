import Foundation

/// Where wires of different nets cross on a sheet, and the hop one of them
/// draws over the other so a crossing never reads as a connection. Horizon
/// draws crossings plain; this is Horizontal's own, behind a preference.
///
/// At each crossing the flatter wire hops, the steeper one runs straight
/// (the lower id hops between two equally steep). A hop is a half circle
/// on the wire's upper side, or its left for a vertical one; crossings
/// closer together than a hop is wide share one, and a crossing near a
/// wire's end gets a smaller hop, or none when there is no room. Wires of
/// one net never hop: where they meet they are joined, and where they
/// merely cross they are the same net anyway.
struct HorizontalSchematicWireHops: Equatable {
    /// Half a hop's width: a little under half the 1.25 mm grid, so hops
    /// over wires one grid step apart stay apart.
    static let radius = 500_000.0

    /// Along each wire that hops, by its id (lowercased), the stretches it
    /// lifts over: distance from its `from` end where the hop starts and
    /// ends, and how high it rises.
    var hopsByLineID: [String: [Hop]] = [:]
    /// Each wire's crossing partners, either way round, by id (lowercased).
    var partnersByLineID: [String: Set<String>] = [:]

    struct Hop: Equatable {
        var start: Double
        var end: Double
        var height: Double
    }

    static let empty = HorizontalSchematicWireHops()

    init() {}

    init(lines: [HorizontalSegment], radius: Double = Self.radius) {
        struct Wire {
            var id: String
            var net: String?
            var from: HorizontalPoint
            var vector: HorizontalPoint
            var length: Double
            var flatness: Double
            var minX: Double
            var maxX: Double
            var minY: Double
            var maxY: Double
        }
        let wires: [Wire] = lines.compactMap { line in
            let vector = line.to - line.from
            let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
            guard length > 0 else { return nil }
            return Wire(
                id: line.id.lowercased(),
                net: line.netID?.lowercased(),
                from: line.from,
                vector: vector,
                length: length,
                flatness: abs(vector.x) / length,
                minX: min(line.from.x, line.to.x),
                maxX: max(line.from.x, line.to.x),
                minY: min(line.from.y, line.to.y),
                maxY: max(line.from.y, line.to.y)
            )
        }
        let order = wires.indices.sorted { wires[$0].minX < wires[$1].minX }
        var crossings = [String: [Double]]()
        for (position, i) in order.enumerated() {
            let a = wires[i]
            for j in order[(position + 1)...] {
                let b = wires[j]
                if b.minX > a.maxX { break }
                guard b.minY <= a.maxY, b.maxY >= a.minY else { continue }
                if let net = a.net, net == b.net { continue }
                let denominator = a.vector.x * b.vector.y - a.vector.y * b.vector.x
                guard denominator != 0 else { continue }
                let offset = b.from - a.from
                let t = (offset.x * b.vector.y - offset.y * b.vector.x) / denominator
                let u = (offset.x * a.vector.y - offset.y * a.vector.x) / denominator
                // Strictly inside both: a wire ending on another is a T,
                // not a crossing.
                let along = t * a.length, alongOther = u * b.length
                guard along > 0.5, along < a.length - 0.5, alongOther > 0.5, alongOther < b.length - 0.5 else { continue }
                let aHops = a.flatness > b.flatness || (a.flatness == b.flatness && a.id < b.id)
                if aHops {
                    crossings[a.id, default: []].append(along)
                } else {
                    crossings[b.id, default: []].append(alongOther)
                }
                partnersByLineID[a.id, default: []].insert(b.id)
                partnersByLineID[b.id, default: []].insert(a.id)
            }
        }

        let lengths = Dictionary(wires.map { ($0.id, $0.length) }) { first, _ in first }
        for (id, distances) in crossings {
            guard let length = lengths[id] else { continue }
            var hops = [Hop]()
            for distance in distances.sorted() {
                // Room for a smaller hop near an end; none when it would be
                // too small to see.
                let rise = min(radius, distance, length - distance)
                guard rise >= radius * 0.25 else { continue }
                let hop = Hop(start: distance - rise, end: distance + rise, height: rise)
                if let last = hops.last, hop.start < last.end + radius * 0.5 {
                    hops[hops.count - 1] = Hop(start: last.start, end: max(last.end, hop.end), height: max(last.height, hop.height))
                } else {
                    hops.append(hop)
                }
            }
            if !hops.isEmpty { hopsByLineID[id] = hops }
        }
    }

    /// The wire drawn with its hops, as one polyline from `from` to `to`.
    /// A wire with none is its two ends.
    static func polyline(for line: HorizontalSegment, hops: [Hop], arcSegments: Int = 12) -> [HorizontalPoint] {
        let vector = line.to - line.from
        let length = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        guard length > 0, !hops.isEmpty else { return [line.from, line.to] }
        let direction = HorizontalPoint(x: vector.x / length, y: vector.y / length)
        // Up for a level wire, left for a vertical one, whichever way the
        // wire was drawn.
        let canonical = direction.x > 0 || (direction.x == 0 && direction.y > 0)
            ? direction : HorizontalPoint(x: -direction.x, y: -direction.y)
        let normal = HorizontalPoint(x: -canonical.y, y: canonical.x)
        func point(_ along: Double, _ rise: Double) -> HorizontalPoint {
            HorizontalPoint(
                x: line.from.x + direction.x * along + normal.x * rise,
                y: line.from.y + direction.y * along + normal.y * rise
            )
        }

        var points = [line.from]
        for hop in hops {
            let width = hop.end - hop.start
            let radius = min(hop.height, width / 2)
            points.append(point(hop.start, 0))
            if width <= 2 * radius + 1 {
                // A half circle over the crossing.
                let center = hop.start + width / 2
                for step in 1..<arcSegments {
                    let angle = Double.pi * (1 - Double(step) / Double(arcSegments))
                    points.append(point(center + cos(angle) * width / 2, sin(angle) * radius))
                }
            } else {
                // A bridge over crossings close together: a quarter circle
                // up, a level run, a quarter circle down.
                let quarter = max(arcSegments / 2, 2)
                for step in 1...quarter {
                    let angle = Double.pi * (1 - Double(step) / Double(quarter) / 2)
                    points.append(point(hop.start + radius + cos(angle) * radius, sin(angle) * radius))
                }
                for step in 0..<quarter {
                    let angle = Double.pi / 2 * (1 - Double(step) / Double(quarter))
                    points.append(point(hop.end - radius + cos(angle) * radius, sin(angle) * radius))
                }
            }
            points.append(point(hop.end, 0))
        }
        points.append(line.to)
        return points
    }
}
