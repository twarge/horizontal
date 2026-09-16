import Foundation

/// The clearance-aware collision oracle for ONE route request.
///
/// A route request fixes the track's net, width and layer, and with them the
/// clearance it owes every obstacle. So each obstacle's hull, grown by that
/// clearance plus the track's half width, is computed once here and reused for
/// every segment the search tests against it — the search asks the same
/// question of the same obstacle thousands of times per mouse move, and
/// re-deriving the answer each time was most of the router's cost.
///
/// Every "is this segment clear" decision the router makes goes through here,
/// so there is exactly one place where the exemptions and the same-net rule are
/// applied and no two paths can disagree about them.
final class HorizontalRouteCollider {
    let index: HorizontalRouterIndex
    let clearances: HorizontalRouterClearances
    let layer: Int
    let net: Int
    let width: Double
    /// Obstacles the route starts or ends inside — the pads it connects — which
    /// it cannot avoid and must not be stopped by.
    let exempt: Set<Int>
    /// The furthest any obstacle's grown hull can reach beyond its own copper:
    /// the widest clearance on the layer plus the track's half width. Queries
    /// are inflated by this so no obstacle that could matter is missed, and each
    /// candidate is then tested with its own exact hull.
    let reach: Double

    private var hulls: [HorizontalOctagon?]
    private var resolved: [Bool]

    init(
        index: HorizontalRouterIndex,
        clearances: HorizontalRouterClearances,
        layer: Int,
        net: Int,
        width: Double,
        exempt: Set<Int>
    ) {
        self.index = index
        self.clearances = clearances
        self.layer = layer
        self.net = net
        self.width = width
        self.exempt = exempt
        self.reach = clearances.broadPhaseClearance(forTrackOn: net, layer: layer) + width / 2
        self.hulls = [HorizontalOctagon?](repeating: nil, count: index.obstacles.count)
        self.resolved = [Bool](repeating: false, count: index.obstacles.count)
    }

    /// The region the track's centre line must stay out of to keep its distance
    /// from obstacle `position`, or nil when that obstacle does not constrain
    /// this track at all: an exempt endpoint pad, or copper of the track's own
    /// net, which it is allowed to touch.
    func hull(_ position: Int) -> HorizontalOctagon? {
        if resolved[position] { return hulls[position] }
        resolved[position] = true
        guard !exempt.contains(position) else { return nil }
        let obstacle = index.obstacles[position]
        let clearance = clearances.clearance(
            .track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
        // Same-net copper at zero clearance is what the route connects to. A
        // same-net obstacle that still carries a clearance (a keepout, say)
        // stays an obstacle.
        guard clearance > 0 || obstacle.netCode != net || net < 0 else { return nil }
        // Inflate by the clearance AND the moving track's half width, so the
        // route's centre line staying outside this hull means its copper keeps
        // the full distance.
        let hull = obstacle.hull.inflated(by: clearance + width / 2)
        hulls[position] = hull
        return hull
    }

    /// The obstacles that could constrain anything inside `box`, in obstacle
    /// order, with their hulls resolved. Conservative: a candidate may turn out
    /// to be clear of everything the caller then tests.
    func candidates(in box: HorizontalRect, into result: inout [Int]) {
        result.removeAll(keepingCapacity: true)
        let grown = HorizontalRect(points: [
            HorizontalPoint(x: box.minX - reach, y: box.minY - reach),
            HorizontalPoint(x: box.maxX + reach, y: box.maxY + reach),
        ])
        index.forEachObstacle(overlapping: grown, on: layer) { position, _ in
            if hull(position) != nil {
                result.append(position)
            }
        }
    }

    /// Of `candidates`, those whose grown hull lies within `radius` of `point`
    /// — the only ones a step of that length from the point can touch.
    func candidates(
        _ candidates: [Int], within radius: Double, of point: HorizontalPoint,
        into result: inout [Int]
    ) {
        result.removeAll(keepingCapacity: true)
        let supports = HorizontalOctagon.supports(point)
        for position in candidates {
            if let hull = hulls[position], hull.separation(from: supports) < radius {
                result.append(position)
            }
        }
    }

    /// The first of `candidates` whose grown hull the segment enters, or nil
    /// when the segment is clear of all of them.
    ///
    /// A segment running in one of the eight directions is EXACTLY its own
    /// octagon — the eight half-planes pin it to the line and to its own extent
    /// — so this is a decision rather than an approximation. That is only true
    /// because routes are 45°. `overlaps`, not `intersects`: a route exactly at
    /// its clearance is legal, and a route around an obstacle rides that
    /// boundary by construction.
    func blocker(
        _ a: HorizontalPoint, _ b: HorizontalPoint, among candidates: [Int]
    ) -> Int? {
        let swept = HorizontalOctagon(from: a, to: b, width: 0)
        for position in candidates {
            if let hull = hulls[position], hull.overlaps(swept) {
                return position
            }
        }
        return nil
    }

    /// The first obstacle the segment comes too close to, querying the index
    /// for the segment's own neighbourhood.
    func blocker(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Int? {
        let swept = HorizontalOctagon(from: a, to: b, width: 0)
        var hit: Int?
        index.forEachObstacle(overlapping: swept.inflated(by: reach).boundingBox, on: layer) { position, _ in
            guard hit == nil, let hull = hull(position) else { return }
            if hull.overlaps(swept) {
                hit = position
            }
        }
        return hit
    }

    /// The first place a polyline crosses something it must not, walking it in
    /// order.
    func firstCollision(along points: [HorizontalPoint]) -> (segment: Int, obstacle: Int)? {
        guard points.count > 1 else { return nil }
        for segment in 0..<(points.count - 1) {
            let a = points[segment]
            let b = points[segment + 1]
            guard a != b else { continue }
            if let hit = blocker(a, b) {
                return (segment, hit)
            }
        }
        return nil
    }

    func isClear(_ points: [HorizontalPoint]) -> Bool {
        firstCollision(along: points) == nil
    }
}

/// A* over an octilinear grid: the search behind "route around what is there".
///
/// The greedy walk this replaced detoured around one obstacle at a time and
/// gave up after trying both ways past each. On an open board that is enough;
/// on a real one it completed a few percent of pad-to-pad routes, because the
/// way past a dense component is a sequence of decisions and a greedy walk
/// commits to each before seeing the next. Getting past that ceiling needs a
/// search that can back out, and this is the plainest one that is bounded,
/// complete at its resolution, and deterministic.
///
/// The grid's moves are the eight routing directions, so every path it returns
/// is a legal 45° route; every move is tested exactly against the obstacle
/// hulls, so every path it returns is clear. It is not pretty by itself — it is
/// a staircase — and `HorizontalRouteFinder` pulls it taut afterwards. What it
/// contributes is the guarantee: if a route exists at this resolution and
/// within the budget, it is found.
enum HorizontalRouteGridSearch {
    enum Outcome {
        /// A clear 45° path from `from` to `to`, in grid steps plus the final
        /// elbow onto the target.
        case found([HorizontalPoint])
        /// The search ran out of places to go. Names the obstacle nearest the
        /// target that stopped it, or −1 when nothing did, and says whether the
        /// region it explored reached the edge of its window — if it did, a
        /// wider window might have found a way; if not, the start is enclosed
        /// at this grid's resolution and only a finer one could.
        case unreachable(blocker: Int, reachedWindowEdge: Bool)
        /// The search ran out of budget with the target still unreached.
        case exhausted(blocker: Int)
    }

    /// Whether a popped node tries the direct elbow onto the target. Doing it
    /// on every pop would cost two long segment tests each; instead the first
    /// few pops try (an open board finishes on the first), and after that only
    /// nodes this many cells from the target do.
    private static let earlyGoalTries = 8
    private static let goalReachCells = 16.0

    /// A tie-break, not a rule: a fraction of a step's cost for changing
    /// direction, so that among equally short paths the search prefers the one
    /// with fewer turns. Small enough never to outweigh a materially shorter
    /// route.
    private static let turnPenaltyFraction = 0.05

    /// How much the heuristic is over-weighted. Plain A* expands every node
    /// whose estimated total is below the true route cost — in a dense field,
    /// where the route is much longer than the crow flies, that is an ellipse
    /// of thousands of cells. Weighting the heuristic makes the search greedy
    /// towards the target and bounds the result at this factor of optimal,
    /// which the pulling pass afterwards mostly recovers.
    static let heuristicWeight = 1.5

    private struct Entry {
        var f: Double
        var h: Double
        var cell: Int32
    }

    /// A binary min-heap with a TOTAL order — f, then h, then cell index — so
    /// that two runs over the same board pop nodes in the same order and return
    /// the same route.
    private struct Heap {
        private(set) var entries: [Entry] = []

        var isEmpty: Bool { entries.isEmpty }

        private static func less(_ a: Entry, _ b: Entry) -> Bool {
            if a.f != b.f { return a.f < b.f }
            if a.h != b.h { return a.h < b.h }
            return a.cell < b.cell
        }

        mutating func push(_ entry: Entry) {
            entries.append(entry)
            var child = entries.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.less(entries[child], entries[parent]) else { break }
                entries.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Entry? {
            guard let top = entries.first else { return nil }
            let last = entries.removeLast()
            if !entries.isEmpty {
                entries[0] = last
                var parent = 0
                let count = entries.count
                while true {
                    let left = 2 * parent + 1
                    let right = left + 1
                    var smallest = parent
                    if left < count, Self.less(entries[left], entries[smallest]) { smallest = left }
                    if right < count, Self.less(entries[right], entries[smallest]) { smallest = right }
                    guard smallest != parent else { break }
                    entries.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return top
        }
    }

    /// Searches for a clear 45° path from `from` to `to`.
    ///
    /// The budget bounds the nodes popped, and with them the time: an
    /// interactive router has to answer this frame, and an unreachable target
    /// would otherwise flood the whole window before saying so. It also sets
    /// the grid's pitch and the window's margin.
    static func search(
        from: HorizontalPoint,
        to: HorizontalPoint,
        collider: HorizontalRouteCollider,
        diagonalFirst: Bool,
        budget: HorizontalRouteFinder.Budget
    ) -> Outcome {
        let maxExpansions = budget.maxExpansions
        let finestPitch = budget.finestPitch
        let cellsPerSide = budget.cellsPerSide

        // --- The window and its grid -------------------------------------
        // The window has to let the route leave the endpoints' bounding box:
        // half the route's own extent, and never less than the budget's floor.
        let extent = max(abs(to.x - from.x), abs(to.y - from.y))
        let margin = max(budget.minimumMargin, extent / 2)
        let minX = min(from.x, to.x) - margin
        let minY = min(from.y, to.y) - margin
        let maxX = max(from.x, to.x) + margin
        let maxY = max(from.y, to.y) + margin
        let side = max(maxX - minX, maxY - minY)
        // Whole multiples of the finest pitch, so grid points stay on integer
        // nanometres whenever `from` is.
        let pitch = max(finestPitch, (side / cellsPerSide / finestPitch).rounded(.up) * finestPitch)
        // Anchor the grid on `from`, which is then a grid point exactly; the
        // target need not be, and is reached by an elbow.
        let originX = from.x - ((from.x - minX) / pitch).rounded(.down) * pitch
        let originY = from.y - ((from.y - minY) / pitch).rounded(.down) * pitch
        let columns = Int(((maxX - originX) / pitch).rounded(.down)) + 1
        let rows = Int(((maxY - originY) / pitch).rounded(.down)) + 1
        let cellCount = columns * rows

        @inline(__always) func point(of cell: Int) -> HorizontalPoint {
            HorizontalPoint(
                x: originX + Double(cell % columns) * pitch,
                y: originY + Double(cell / columns) * pitch)
        }
        // Octile distance: the length of the shortest 45° path in open space,
        // which is exactly what the elbow onto the target measures. Admissible
        // and consistent, and tight enough that an open board finishes without
        // wandering.
        @inline(__always) func heuristic(_ p: HorizontalPoint) -> Double {
            let dx = abs(to.x - p.x)
            let dy = abs(to.y - p.y)
            let diagonal = min(dx, dy)
            return (max(dx, dy) - diagonal) + diagonal * 2.0.squareRoot()
        }

        let startColumn = Int(((from.x - originX) / pitch).rounded())
        let startRow = Int(((from.y - originY) / pitch).rounded())
        let start = startRow * columns + startColumn

        // A target nothing can arrive at is the common way a route fails on a
        // dense board — the pad's neighbours leave no gap a track of this width
        // fits through — and it would otherwise cost the whole budget to
        // discover. If no step of one cell in any direction can end on the
        // target, no grid path can either.
        var probeCandidates: [Int] = []
        collider.candidates(
            in: HorizontalOctagon(from: to, to: to, width: 0).inflated(by: pitch).boundingBox,
            into: &probeCandidates)
        var arrivalBlocker = -1
        var arrivalPossible = false
        for direction in HorizontalDirection45.allCases {
            let step = direction.step
            let neighbour = HorizontalPoint(x: to.x + step.x * pitch, y: to.y + step.y * pitch)
            if let hit = collider.blocker(neighbour, to, among: probeCandidates) {
                if arrivalBlocker < 0 { arrivalBlocker = hit }
            } else {
                arrivalPossible = true
                break
            }
        }
        guard arrivalPossible else {
            return .unreachable(blocker: arrivalBlocker, reachedWindowEdge: false)
        }

        // --- The search ---------------------------------------------------
        var gCost = [Double](repeating: .infinity, count: cellCount)
        var parent = [Int32](repeating: -1, count: cellCount)
        var arrivedBy = [Int8](repeating: -1, count: cellCount)
        var closed = [Bool](repeating: false, count: cellCount)
        var heap = Heap()

        // --- Candidates, per block of cells ----------------------------------
        // One index query serves an 8×8 block of cells: the block's box grown
        // by a step covers every move from every cell in it. Per node, the
        // block's list is then screened by distance — a hull further from the
        // node than the longest move cannot be touched by any move — so most
        // nodes test a handful of hulls exactly, and many test none. Querying
        // the index per node was most of the router's cost.
        let blockSize = 8
        let blockColumns = (columns + blockSize - 1) / blockSize
        let blockRows = (rows + blockSize - 1) / blockSize
        var blocks = [[Int]?](repeating: nil, count: blockColumns * blockRows)
        var candidates: [Int] = []
        candidates.reserveCapacity(128)
        var near: [Int] = []
        near.reserveCapacity(16)
        let longestMove = pitch * 2.0.squareRoot()

        gCost[start] = 0
        heap.push(Entry(f: heuristicWeight * heuristic(from), h: heuristic(from), cell: Int32(start)))

        let axialStep = pitch
        let diagonalStep = pitch * 2.0.squareRoot()
        let turnPenalty = pitch * turnPenaltyFraction
        let goalReach = goalReachCells * pitch

        var expansions = 0
        // What to report if the search fails: the obstacle that stopped the
        // node that got nearest the target, which is what the user sees as
        // "in the way".
        var nearestBlockedH = Double.infinity
        var nearestBlocker = -1
        var reachedWindowEdge = false

        while let entry = heap.pop() {
            let cell = Int(entry.cell)
            if closed[cell] { continue }
            closed[cell] = true
            expansions += 1
            if expansions > maxExpansions {
                return .exhausted(blocker: nearestBlocker)
            }

            let p = point(of: cell)
            let h = entry.h

            // The arrival: an elbow from this node onto the target, in the
            // route's own posture or failing that the other.
            if expansions <= earlyGoalTries || h <= goalReach {
                var arrival: [HorizontalPoint]?
                var arrivalHit: Int?
                for posture in [diagonalFirst, !diagonalFirst] {
                    let elbow = HorizontalRoute45.elbow(from: p, to: to, diagonalFirst: posture)
                    if let collision = collider.firstCollision(along: elbow) {
                        if arrivalHit == nil { arrivalHit = collision.obstacle }
                    } else {
                        arrival = elbow
                        break
                    }
                }
                if let arrival {
                    var path: [HorizontalPoint] = []
                    var cursor = cell
                    while cursor >= 0 {
                        path.append(point(of: cursor))
                        cursor = Int(parent[cursor])
                    }
                    path.reverse()
                    path.append(contentsOf: arrival.dropFirst())
                    return .found(path)
                }
                if let arrivalHit, h < nearestBlockedH {
                    nearestBlockedH = h
                    nearestBlocker = arrivalHit
                }
            }

            let column = cell % columns
            let row = cell / columns
            if column == 0 || row == 0 || column == columns - 1 || row == rows - 1 {
                reachedWindowEdge = true
            }
            let blockColumn = column / blockSize
            let blockRow = row / blockSize
            let block = blockRow * blockColumns + blockColumn
            if blocks[block] == nil {
                let x0 = originX + Double(blockColumn * blockSize) * pitch - pitch
                let y0 = originY + Double(blockRow * blockSize) * pitch - pitch
                let x1 = originX + Double((blockColumn + 1) * blockSize) * pitch
                let y1 = originY + Double((blockRow + 1) * blockSize) * pitch
                collider.candidates(
                    in: HorizontalRect(points: [HorizontalPoint(x: x0, y: y0), HorizontalPoint(x: x1, y: y1)]),
                    into: &candidates)
                blocks[block] = candidates
            }
            collider.candidates(blocks[block]!, within: longestMove, of: p, into: &near)
            for direction in HorizontalDirection45.allCases {
                let step = direction.step
                let nextColumn = column + Int(step.x)
                let nextRow = row + Int(step.y)
                guard nextColumn >= 0, nextColumn < columns, nextRow >= 0, nextRow < rows else { continue }
                let next = nextRow * columns + nextColumn
                guard !closed[next] else { continue }
                let q = point(of: next)

                if let hit = collider.blocker(p, q, among: near) {
                    if h < nearestBlockedH {
                        nearestBlockedH = h
                        nearestBlocker = hit
                    }
                    continue
                }

                var cost = gCost[cell] + (direction.isDiagonal ? diagonalStep : axialStep)
                if arrivedBy[cell] >= 0, arrivedBy[cell] != Int8(direction.rawValue) {
                    cost += turnPenalty
                }
                guard cost < gCost[next] else { continue }
                gCost[next] = cost
                parent[next] = Int32(cell)
                arrivedBy[next] = Int8(direction.rawValue)
                let hNext = heuristic(q)
                heap.push(Entry(f: cost + heuristicWeight * hNext, h: hNext, cell: Int32(next)))
            }
        }

        return .unreachable(blocker: nearestBlocker, reachedWindowEdge: reachedWindowEdge)
    }
}
