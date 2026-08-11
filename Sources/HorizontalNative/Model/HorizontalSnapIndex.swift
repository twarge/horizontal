import Foundation

// A spatial index over the canvas snap targets so cursor snapping is O(1)-ish per
// pointer move instead of an O(n) scan on every move. The old path did TWO linear
// scans of `snapTargets` per `snappedCursor` call (and snappedCursor runs twice
// per body re-render): an exact-match scan that built a `String` key per target,
// and a nearest-within-radius geometric scan. On a dense board, with the trackpad
// pointer keeping the cursor alive, that stalled the (main-thread, on-demand)
// Metal draw loop. This indexes both:
//  • exact match → a dictionary keyed by the rounded integer coordinate (O(1)),
//  • nearest → a uniform hash grid; a small-radius query touches O(1) cells.
//
// The canvas transform is uniform scale + translation (no rotation), so ordering
// by world distance equals ordering by screen distance — the index works entirely
// in world space and the caller passes a world-space radius (30 screen pt / scale).
struct HorizontalSnapIndex {
    static let empty = HorizontalSnapIndex(targets: [])

    private struct Cell: Hashable {
        let x: Int64
        let y: Int64
    }

    /// Cap on cells visited by a single nearest() query before falling back to a
    /// full scan — guards the extreme zoom-out case where the world radius spans a
    /// huge cell range (snapping is irrelevant there anyway).
    private static let cellVisitCap: Int64 = 4096

    private let exact: [Cell: HorizontalPoint]
    private let grid: [Cell: [HorizontalPoint]]
    private let cellSize: Double
    private let allTargets: [HorizontalPoint]

    init(targets: [HorizontalPoint]) {
        allTargets = targets

        var exact = [Cell: HorizontalPoint]()
        exact.reserveCapacity(targets.count)
        for target in targets {
            exact[Self.exactCell(target)] = target
        }
        self.exact = exact

        guard let first = targets.first else {
            grid = [:]
            cellSize = 1
            return
        }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for target in targets {
            minX = min(minX, target.x); maxX = max(maxX, target.x)
            minY = min(minY, target.y); maxY = max(maxY, target.y)
        }
        // Cell size ≈ average inter-target spacing, so a small-radius query lands in
        // O(1) cells each holding ~1 target.
        let diagonal = hypot(maxX - minX, maxY - minY)
        let size = max(1, diagonal / max(1, Double(targets.count).squareRoot()))
        cellSize = size

        var grid = [Cell: [HorizontalPoint]]()
        for target in targets {
            grid[Self.cell(target, size: size), default: []].append(target)
        }
        self.grid = grid
    }

    /// A target at (rounded to integer) the same coordinate as `point`, or nil.
    /// Mirrors the old `pointKey` exact match (`Int64(coord.rounded())`).
    func exactMatch(_ point: HorizontalPoint) -> HorizontalPoint? {
        exact[Self.exactCell(point)]
    }

    /// The target closest to `world` within `radius` world units, or nil. Equivalent
    /// (under the uniform canvas scale) to the old nearest-within-30-screen-points.
    func nearest(to world: HorizontalPoint, within radius: Double) -> HorizontalPoint? {
        guard !allTargets.isEmpty, radius > 0, radius.isFinite else {
            return nil
        }

        // ceil(radius/cellSize) + 1: the extra ring guarantees no target within the
        // radius is missed at a cell boundary.
        let span = Int64((radius / cellSize).rounded(.up)) + 1
        let cx = Int64((world.x / cellSize).rounded(.down))
        let cy = Int64((world.y / cellSize).rounded(.down))

        var nearest: HorizontalPoint?
        var nearestDistance = radius

        let cellsPerAxis = 2 * span + 1
        if span < 0 || cellsPerAxis * cellsPerAxis > Self.cellVisitCap {
            // Extreme radius → scan everything rather than iterate a vast cell range.
            for target in allTargets {
                let distance = hypot(target.x - world.x, target.y - world.y)
                if distance < nearestDistance {
                    nearest = target
                    nearestDistance = distance
                }
            }
            return nearest
        }

        for gx in (cx - span)...(cx + span) {
            for gy in (cy - span)...(cy + span) {
                guard let bucket = grid[Cell(x: gx, y: gy)] else { continue }
                for target in bucket {
                    let distance = hypot(target.x - world.x, target.y - world.y)
                    if distance < nearestDistance {
                        nearest = target
                        nearestDistance = distance
                    }
                }
            }
        }
        return nearest
    }

    private static func exactCell(_ point: HorizontalPoint) -> Cell {
        Cell(x: Int64(point.x.rounded()), y: Int64(point.y.rounded()))
    }

    private static func cell(_ point: HorizontalPoint, size: Double) -> Cell {
        Cell(x: Int64((point.x / size).rounded(.down)), y: Int64((point.y / size).rounded(.down)))
    }
}

/// Memoizes a `HorizontalSnapIndex` so it is rebuilt only when the snap targets
/// actually change — held in `@State` so the index persists across the many body
/// re-renders a moving cursor triggers. The per-call guard is a cheap elementwise
/// array compare (no allocation), versus the old per-call O(n) string/transform
/// scans, so cursor moves no longer rebuild anything.
final class HorizontalSnapIndexCache {
    private var source: [HorizontalPoint] = []
    private var built = false
    private(set) var index = HorizontalSnapIndex.empty

    func index(for targets: [HorizontalPoint]) -> HorizontalSnapIndex {
        if !built || targets != source {
            source = targets
            index = HorizontalSnapIndex(targets: targets)
            built = true
        }
        return index
    }
}
