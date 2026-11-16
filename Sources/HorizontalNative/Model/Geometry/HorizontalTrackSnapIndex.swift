import Foundation

/// A straight track the routing cursor snaps to along its length, not only
/// at its ends: its centreline and half its width.
struct HorizontalSnapTrack: Hashable {
    var from: HorizontalPoint
    var to: HorizontalPoint
    var halfWidth: Double
}

/// The tracks a route can start or end on, indexed so the cursor finds the
/// one under it without scanning the board on every pointer move. The ends of
/// tracks are snap points already (`HorizontalSnapIndex`); this is for their
/// middles, which the grid reaches only where a grid point happens to lie on
/// the track.
struct HorizontalTrackSnapIndex {
    static let empty = HorizontalTrackSnapIndex(tracks: [])

    private struct Cell: Hashable {
        let x: Int64
        let y: Int64
    }

    /// A track whose bounds cover more cells than this is kept aside and asked
    /// every time, rather than listed in each of them.
    private static let cellsPerTrackCap: Int64 = 64
    /// As `HorizontalSnapIndex.cellVisitCap`: a query wider than this scans
    /// every track.
    private static let cellVisitCap: Int64 = 4096

    private let tracks: [HorizontalSnapTrack]
    private let grid: [Cell: [Int]]
    private let everywhere: [Int]
    private let cellSize: Double
    private let widestHalfWidth: Double

    init(tracks: [HorizontalSnapTrack]) {
        self.tracks = tracks
        widestHalfWidth = tracks.map(\.halfWidth).max() ?? 0
        guard let first = tracks.first else {
            grid = [:]
            everywhere = []
            cellSize = 1
            return
        }
        var minX = first.from.x, maxX = first.from.x
        var minY = first.from.y, maxY = first.from.y
        for track in tracks {
            minX = min(minX, track.from.x, track.to.x); maxX = max(maxX, track.from.x, track.to.x)
            minY = min(minY, track.from.y, track.to.y); maxY = max(maxY, track.from.y, track.to.y)
        }
        let diagonal = hypot(maxX - minX, maxY - minY)
        let size = max(1, diagonal / max(1, Double(tracks.count).squareRoot()))
        cellSize = size

        var grid = [Cell: [Int]]()
        var everywhere = [Int]()
        for (index, track) in tracks.enumerated() {
            let x0 = Self.cell(min(track.from.x, track.to.x), size), x1 = Self.cell(max(track.from.x, track.to.x), size)
            let y0 = Self.cell(min(track.from.y, track.to.y), size), y1 = Self.cell(max(track.from.y, track.to.y), size)
            guard (x1 - x0 + 1) * (y1 - y0 + 1) <= Self.cellsPerTrackCap else {
                everywhere.append(index)
                continue
            }
            for x in x0...x1 {
                for y in y0...y1 {
                    grid[Cell(x: x, y: y), default: []].append(index)
                }
            }
        }
        self.grid = grid
        self.everywhere = everywhere
    }

    /// Where the cursor goes on the track under `pointer`, or nil where there
    /// is none: a track whose copper the pointer is on, or whose centreline
    /// is within `reach` of it. The nearest such track gives the point: where
    /// it crosses one of the grid lines through `gridPoint`, when that is
    /// within `gridReach` of the pointer, so the point is on the grid in one
    /// axis (and is `gridPoint` itself where that lies on the track); else the
    /// point of the centreline nearest the pointer. Either has whole
    /// coordinates exactly on the line (`HorizontalTrackSnap.wholePoint`).
    func snap(
        pointer: HorizontalPoint,
        gridPoint: HorizontalPoint?,
        reach: Double,
        gridReach: Double
    ) -> HorizontalPoint? {
        guard !tracks.isEmpty, reach.isFinite, reach >= 0 else {
            return nil
        }
        var nearest: HorizontalSnapTrack?
        var nearestDistance = Double.infinity
        func consider(_ index: Int) {
            let track = tracks[index]
            let distance = HorizontalTrackSnap.distance(from: pointer, to: track)
            if distance <= max(track.halfWidth, reach, 1), distance < nearestDistance {
                nearest = track
                nearestDistance = distance
            }
        }
        let radius = max(reach, widestHalfWidth, 1)
        let x0 = Self.cell(pointer.x - radius, cellSize), x1 = Self.cell(pointer.x + radius, cellSize)
        let y0 = Self.cell(pointer.y - radius, cellSize), y1 = Self.cell(pointer.y + radius, cellSize)
        if (x1 - x0 + 1) * (y1 - y0 + 1) > Self.cellVisitCap {
            tracks.indices.forEach(consider)
        } else {
            everywhere.forEach(consider)
            for x in x0...x1 {
                for y in y0...y1 {
                    grid[Cell(x: x, y: y)]?.forEach(consider)
                }
            }
        }
        guard let track = nearest else {
            return nil
        }
        if let gridPoint {
            let onGridLine = HorizontalTrackSnap.gridCrossings(of: track, at: gridPoint)
                .map { (point: $0, distance: ($0 - pointer).length) }
                .filter { $0.distance <= gridReach }
                .min { $0.distance < $1.distance }
            if let onGridLine {
                return onGridLine.point
            }
        }
        let trackReach = max(track.halfWidth, reach, 1)
        if let onLine = HorizontalTrackSnap.wholePoint(near: pointer, from: track.from, to: track.to, reach: trackReach) {
            return onLine
        }
        // Past an end, on its round cap, or on a track at an odd angle with
        // no whole point near: the nearer end, when it is in reach.
        let end = (pointer - track.from).length <= (pointer - track.to).length ? track.from : track.to
        return (pointer - end).length <= trackReach ? end : nil
    }

    private static func cell(_ value: Double, _ size: Double) -> Int64 {
        Int64((value / size).rounded(.down))
    }
}

enum HorizontalTrackSnap {
    /// How far `point` is from the centreline of `track`.
    static func distance(from point: HorizontalPoint, to track: HorizontalSnapTrack) -> Double {
        let line = track.to - track.from
        let lengthSquared = line.x * line.x + line.y * line.y
        guard lengthSquared > 0 else {
            return (point - track.from).length
        }
        let offset = point - track.from
        let t = min(max((offset.x * line.x + offset.y * line.y) / lengthSquared, 0), 1)
        return (point - HorizontalPoint(x: track.from.x + t * line.x, y: track.from.y + t * line.y)).length
    }

    /// The point of the line `from`–`to` nearest `point`, when `point` is
    /// within `reach` of it and beside it rather than past an end: one with
    /// whole-nanometre coordinates, which is what the file holds, exactly on
    /// the line, so `BoardTrackRouting.pointLiesOnSegment` takes it and a cut
    /// there stays on the track. Such points fall every (dx, dy) / gcd(dx, dy)
    /// along a line whose ends are whole, every nanometre on a straight or
    /// 45° one.
    static func wholePoint(
        near point: HorizontalPoint,
        from: HorizontalPoint,
        to: HorizontalPoint,
        reach: Double
    ) -> HorizontalPoint? {
        let from = (x: Int64(from.x.rounded()), y: Int64(from.y.rounded()))
        let to = (x: Int64(to.x.rounded()), y: Int64(to.y.rounded()))
        let dx = to.x - from.x, dy = to.y - from.y
        let lengthSquared = Double(dx) * Double(dx) + Double(dy) * Double(dy)
        guard lengthSquared > 0 else {
            return nil
        }
        let t = ((point.x - Double(from.x)) * Double(dx) + (point.y - Double(from.y)) * Double(dy)) / lengthSquared
        let nearest = HorizontalPoint(x: Double(from.x) + t * Double(dx), y: Double(from.y) + t * Double(dy))
        guard (0...1).contains(t), (point - nearest).length <= reach else {
            return nil
        }
        var a = abs(dx), b = abs(dy)
        while b != 0 { (a, b) = (b, a % b) }
        let steps = a
        let step = Int64((t * Double(steps)).rounded())
        let onLine = HorizontalPoint(
            x: Double(from.x + step * (dx / steps)),
            y: Double(from.y + step * (dy / steps))
        )
        // A line at an odd angle can have whole points only far apart, or at
        // its ends alone: none near the point is none at all.
        return (point - onLine).length <= reach ? onLine : nil
    }

    /// Where `track` crosses the vertical and the horizontal grid line
    /// through `gridPoint`, at whole coordinates exactly on its centreline:
    /// up to two points, each on the grid in one axis.
    static func gridCrossings(of track: HorizontalSnapTrack, at gridPoint: HorizontalPoint) -> [HorizontalPoint] {
        let from = (x: Int64(track.from.x.rounded()), y: Int64(track.from.y.rounded()))
        let to = (x: Int64(track.to.x.rounded()), y: Int64(track.to.y.rounded()))
        let grid = (x: Int64(gridPoint.x.rounded()), y: Int64(gridPoint.y.rounded()))
        var crossings = [HorizontalPoint]()
        if let y = crossing(at: grid.x, from: from.x, to: to.x, otherFrom: from.y, otherTo: to.y) {
            crossings.append(HorizontalPoint(x: Double(grid.x), y: Double(y)))
        }
        if let x = crossing(at: grid.y, from: from.y, to: to.y, otherFrom: from.x, otherTo: to.x) {
            crossings.append(HorizontalPoint(x: Double(x), y: Double(grid.y)))
        }
        return crossings
    }

    /// The other coordinate of a line where one coordinate is `value`, when
    /// the line spans it and the answer is whole.
    private static func crossing(at value: Int64, from: Int64, to: Int64, otherFrom: Int64, otherTo: Int64) -> Int64? {
        let span = to - from
        guard span != 0, value >= min(from, to), value <= max(from, to) else {
            return nil
        }
        let (product, overflow) = (value - from).multipliedReportingOverflow(by: otherTo - otherFrom)
        guard !overflow, product % span == 0 else {
            return nil
        }
        return otherFrom + product / span
    }
}

/// Memoizes a `HorizontalTrackSnapIndex`, as `HorizontalSnapIndexCache` does
/// the point index: rebuilt only when the tracks change.
final class HorizontalTrackSnapIndexCache {
    private var source: [HorizontalSnapTrack] = []
    private var built = false
    private(set) var index = HorizontalTrackSnapIndex.empty

    func index(for tracks: [HorizontalSnapTrack]) -> HorizontalTrackSnapIndex {
        if !built || tracks != source {
            source = tracks
            index = HorizontalTrackSnapIndex(tracks: tracks)
            built = true
        }
        return index
    }
}
