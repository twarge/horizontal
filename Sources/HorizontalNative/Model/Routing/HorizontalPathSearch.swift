import Foundation

/// Finds a legal path for one connection, or says what stands in the way.
///
/// An A* search over a fine octilinear grid, on one copper layer or several
/// joined by vias. Where the interactive router (`HorizontalRouteFinder`)
/// works on octagonal hulls so it can answer every frame, this tests each grid
/// position against the board's exact shapes (`HorizontalBoardProbe`), with
/// the clearance the rules ask of each pair: a slot with five micrometres to
/// spare is a slot, and what it finds is what `check` passes. It is for a
/// caller that can wait a second, not for a cursor.
///
/// It moves nothing and writes nothing. The same request on the same board
/// gives the same path. When there is no path it returns the items that bound
/// what it could reach from each end: the list to consider ripping up.
struct HorizontalPathSearch {
    struct Target {
        var point: HorizontalPoint
        /// The layers it can be reached on; empty for any the search may use.
        var layers: [Int] = []
    }

    struct Request {
        var from: HorizontalPoint
        var fromLayers: [Int] = []
        var targets: [Target]
        /// The copper layers the path may use.
        var layers: [Int]
        var width: Double
        /// Lowercased.
        var net: String?
        /// The via a layer change uses; nil keeps the path on the layer it starts on.
        var via: HorizontalViaShape?
        /// Whether a via the path places may stand in a pad of its net. The
        /// cheapest layer change from a pad is a via in that pad, so without
        /// this every path that leaves a surface pad for another layer would
        /// start with one; a board has to be made for those.
        var viaInPad = false
        var pitch = 25_000.0
        /// How far beyond the ends' box the search may go.
        var window = 2_000_000.0
        /// The most grid positions, over all layers, a request may span.
        var maxCells = 700_000
        var maxExpansions = 1_500_000
        /// What a corner costs, in nanometres of path: a path a little
        /// longer with fewer corners is the better one.
        var bendPenalty = 150_000.0
        /// What a via costs, likewise.
        var viaCost = 2_000_000.0
    }

    /// The path on one layer. A single point where it only passes through:
    /// a via at the very start, or one straight onto another.
    struct Leg {
        var layer: Int
        var points: [HorizontalPoint]
    }

    struct Path {
        var legs: [Leg]
        /// One between each leg and the next: where the path changes layer.
        var vias: [HorizontalPoint]
        /// Which of `vias`, by index, are vias of the net already on the
        /// board: the path changes layer through them and needs none placed.
        var standing: Set<Int> = []
        /// Which of the request's targets it reached.
        var target: Int
        var length: Double
        var bends: Int
    }

    /// One thing bounding what the search could reach.
    struct Blocker {
        var obstacle: HorizontalBoardProbe.Obstacle
        var layer: Int
        /// How many grid positions along the edge of the reached area it
        /// closes: its share of the wall.
        var cells: Int
    }

    enum Outcome {
        case found(Path)
        /// No path within the window. `fromSide` and `toSide` bound what was
        /// reachable from the start and from the targets.
        case blocked(fromSide: [Blocker], toSide: [Blocker], reachedWindowEdge: Bool)
        /// The budget ran out before the search could say either.
        case exhausted(fromSide: [Blocker])
        /// The request spans more grid positions than `maxCells`.
        case tooLarge(cells: Int)
    }

    let probe: HorizontalBoardProbe
    let request: Request

    private let columns: Int
    private let rows: Int
    private let originX: Double
    private let originY: Double
    private let startColumn: Int
    private let startRow: Int
    /// Per layer and cell: 0 unknown, 1 clear, otherwise 2 + the code of what blocks it.
    private var trackState: [Int32]
    private var blockers: [HorizontalBoardProbe.Obstacle] = []
    private var blockerCodes: [String: Int32] = [:]
    /// Per cell: 0 unknown, 1 a via fits, 2 none does.
    private var viaState: [UInt8]
    /// The net's own vias in the window. No rule keeps a via off copper of
    /// its own net, so a new one would pass every clearance standing in one
    /// of these, its hole drilled into the other's: a via fits nowhere it
    /// would overlap one. Where one stands exactly on a grid position the
    /// path changes layer through it instead, for nothing.
    private var standingVias: [(centre: HorizontalPoint, radius: Double, layers: Set<Int>)] = []
    /// `standingVias` by the cell each stands exactly on.
    private var standingAtCell: [Int: Int] = [:]
    /// The positions a via fitted but for standing in a pad of its net,
    /// which `viaInPad` would have allowed.
    private(set) var viasKeptOutOfPads = 0

    private static let steps: [(dx: Int, dy: Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

    /// The grid a request is searched on: it stands on the start, so the path
    /// leaves it exactly, and reaches the window beyond the ends' box.
    private struct Grid {
        var columns: Int
        var rows: Int
        var startColumn: Int
        var startRow: Int
        var originX: Double
        var originY: Double

        init(_ request: Request) {
            var minX = request.from.x, maxX = request.from.x, minY = request.from.y, maxY = request.from.y
            for target in request.targets {
                minX = min(minX, target.point.x)
                maxX = max(maxX, target.point.x)
                minY = min(minY, target.point.y)
                maxY = max(maxY, target.point.y)
            }
            let left = Int(((request.from.x - minX + request.window) / request.pitch).rounded(.up))
            let right = Int(((maxX - request.from.x + request.window) / request.pitch).rounded(.up))
            let down = Int(((request.from.y - minY + request.window) / request.pitch).rounded(.up))
            let up = Int(((maxY - request.from.y + request.window) / request.pitch).rounded(.up))
            columns = left + right + 1
            rows = down + up + 1
            startColumn = left
            startRow = down
            originX = request.from.x - Double(left) * request.pitch
            originY = request.from.y - Double(down) * request.pitch
        }
    }

    init(probe: HorizontalBoardProbe, request: Request) {
        self.probe = probe
        self.request = request
        let grid = Grid(request)
        columns = grid.columns
        rows = grid.rows
        startColumn = grid.startColumn
        startRow = grid.startRow
        originX = grid.originX
        originY = grid.originY
        let cells = columns * rows
        let fits = cells * request.layers.count <= request.maxCells
        trackState = [Int32](repeating: 0, count: fits ? cells * request.layers.count : 0)
        viaState = [UInt8](repeating: 0, count: fits ? cells : 0)
        guard fits, let net = request.net else { return }
        let reach = (request.via?.diameter ?? 0) / 2
        var seen = Set<String>()
        let box = HorizontalRouteClearanceProbe.bounds(
            [HorizontalPoint(x: originX, y: originY),
             HorizontalPoint(x: originX + Double(columns - 1) * request.pitch, y: originY + Double(rows - 1) * request.pitch)], growth: reach)
        for index in probe.items.indices(overlapping: box) {
            let item = probe.items.items[index]
            guard item.kind == .via, item.netID == net, !probe.ignored.contains(item.id.lowercased()),
                  case .disc(let centre, let radius) = item.shape, seen.insert(item.id).inserted else { continue }
            let layers = Set(request.layers.filter(item.isOn))
            let column = ((centre.x - originX) / request.pitch).rounded(), row = ((centre.y - originY) / request.pitch).rounded()
            if column >= 0, column < Double(columns), row >= 0, row < Double(rows),
               abs(originX + column * request.pitch - centre.x) < 1, abs(originY + row * request.pitch - centre.y) < 1 {
                standingAtCell[Int(row) * columns + Int(column)] = standingVias.count
            }
            standingVias.append((centre, radius, layers))
        }
    }

    var cellCount: Int { columns * rows * request.layers.count }

    /// The grid positions `request` spans, over all its layers.
    static func cells(spannedBy request: Request) -> Int {
        let grid = Grid(request)
        return grid.columns * grid.rows * request.layers.count
    }

    /// The finest pitch from the request's own up, doubling, at which it
    /// spans no more than its `maxCells`, and no coarser than `coarsest`:
    /// the pitch for a caller that states none. Two ends 40 mm apart are
    /// searched at 50 or 100 µm, where 25 would be refused.
    static func fittedPitch(for request: Request, coarsest: Double) -> Double {
        var fitted = request
        while cells(spannedBy: fitted) > request.maxCells, fitted.pitch * 2 <= coarsest {
            fitted.pitch *= 2
        }
        return fitted.pitch
    }

    private func position(_ cell: Int) -> HorizontalPoint {
        HorizontalPoint(x: originX + Double(cell % columns) * request.pitch, y: originY + Double(cell / columns) * request.pitch)
    }

    private mutating func code(_ obstacle: HorizontalBoardProbe.Obstacle) -> Int32 {
        let key: String
        switch obstacle {
        case .item(let index): key = "i\(index)"
        case .outsideBoard: key = "o"
        case .avoid(let index): key = "a\(index)"
        }
        if let known = blockerCodes[key] { return known }
        blockers.append(obstacle)
        let code = Int32(blockers.count + 1)
        blockerCodes[key] = code
        return code
    }

    /// 1 where a track of the request's width may have its centre at `cell`
    /// on layer number `layer`, else the code of what it would be too close to.
    private mutating func track(_ layer: Int, _ cell: Int) -> Int32 {
        let index = layer * columns * rows + cell
        if trackState[index] != 0 { return trackState[index] }
        let half = request.width / 2
        let step = request.pitch * 2.squareRoot()
        let candidate = HorizontalBoardProbe.Candidate(kind: .track, netID: request.net, shape: .disc(position(cell), radius: half))
        // Two clear positions a step apart leave a sliver between their
        // discs that the track between them covers; this much more at each
        // keeps the sliver clear too.
        let blocked = probe.firstViolation(candidate, layer: request.layers[layer]) { required in
            step * step / (8 * (half + required))
        }
        let state: Int32 = blocked.map { code($0) } ?? 1
        trackState[index] = state
        return state
    }

    private mutating func viaFits(_ cell: Int) -> Bool {
        guard let via = request.via else { return false }
        if viaState[cell] != 0 { return viaState[cell] == 1 }
        let at = position(cell)
        let candidate = HorizontalBoardProbe.via(at: at, diameter: via.diameter, net: request.net)
        var fits = !standingVias.contains { hypot(at.x - $0.centre.x, at.y - $0.centre.y) < $0.radius + via.diameter / 2 - 1 }
            && via.layers.allSatisfy { probe.firstViolation(candidate, layer: $0) == nil }
        if fits, !request.viaInPad, probe.ownPad(under: at, diameter: via.diameter, net: request.net, layers: via.layers) != nil {
            viasKeptOutOfPads += 1
            fits = false
        }
        viaState[cell] = fits ? 1 : 2
        return fits
    }

    /// The layers, by index into the request's, a path on `layer` at `cell`
    /// can change to, and whether through a via of the net that stands there
    /// already rather than one it would place.
    private mutating func layerChanges(from layer: Int, at cell: Int) -> (layers: [Int], standing: Bool) {
        if let index = standingAtCell[cell] {
            let reached = standingVias[index].layers
            guard reached.contains(request.layers[layer]) else { return ([], true) }
            return (request.layers.indices.filter { $0 != layer && reached.contains(request.layers[$0]) }, true)
        }
        guard let via = request.via, via.layers.contains(request.layers[layer]), viaFits(cell) else { return ([], false) }
        return (request.layers.indices.filter { $0 != layer && via.layers.contains(request.layers[$0]) }, false)
    }

    private func octile(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        let dx = abs(a.x - b.x), dy = abs(a.y - b.y)
        return max(dx, dy) + (2.squareRoot() - 1) * min(dx, dy)
    }

    // MARK: - Search

    mutating func run() -> Outcome {
        guard !trackState.isEmpty else { return .tooLarge(cells: cellCount) }
        let cells = columns * rows
        let layerCount = request.layers.count
        let pitch = request.pitch
        let startCell = startRow * columns + startColumn

        // Where each target can be stepped onto: the grid positions round it
        // from which a last short segment to the target itself is clear.
        var goals = [Int: Int]()   // layer * cells + cell → target
        for (targetIndex, target) in request.targets.enumerated() {
            let column = Int(((target.point.x - originX) / pitch).rounded()), row = Int(((target.point.y - originY) / pitch).rounded())
            for r in (row - 1)...(row + 1) where r >= 0 && r < rows {
                for c in (column - 1)...(column + 1) where c >= 0 && c < columns {
                    let cell = r * columns + c
                    let at = position(cell)
                    guard hypot(at.x - target.point.x, at.y - target.point.y) <= pitch * 0.75 else { continue }
                    for (layer, number) in request.layers.enumerated() where target.layers.isEmpty || target.layers.contains(number) {
                        guard goals[layer * cells + cell] == nil else { continue }
                        if at != target.point {
                            let last = HorizontalBoardProbe.track([at, target.point], width: request.width, net: request.net)
                            guard probe.firstViolation(last, layer: number) == nil else { continue }
                        }
                        goals[layer * cells + cell] = targetIndex
                    }
                }
            }
        }

        // Costs are in micrometres: a Float holds those to a hundredth
        // across any board, where nanometres would run out of digits.
        let stateCount = layerCount * cells * 9
        var cost = [Float](repeating: .infinity, count: stateCount)
        var parent = [Int32](repeating: -1, count: stateCount)
        var closed = [Bool](repeating: false, count: stateCount)
        var heap = Heap()
        func heuristic(_ cell: Int) -> Float {
            let at = position(cell)
            var least = Double.greatestFiniteMagnitude
            for target in request.targets { least = min(least, octile(at, target.point)) }
            return Float(least / 1000)
        }
        let startLayers = request.layers.indices.filter { request.fromLayers.isEmpty || request.fromLayers.contains(request.layers[$0]) }
        for layer in startLayers where track(layer, startCell) == 1 {
            let state = (layer * cells + startCell) * 9 + 8
            cost[state] = 0
            heap.push(state, heuristic(startCell))
        }

        var expansions = 0
        var reached: Int?
        var edge = false
        while let state = heap.pop() {
            guard !closed[state] else { continue }
            closed[state] = true
            let node = state / 9, direction = state % 9
            let layer = node / cells, cell = node % cells
            if goals[node] != nil {
                reached = state
                break
            }
            expansions += 1
            if expansions > request.maxExpansions { return .exhausted(fromSide: wall(closed: closed)) }
            let column = cell % columns, row = cell / columns
            if column == 0 || row == 0 || column == columns - 1 || row == rows - 1 { edge = true }
            for (next, step) in Self.steps.enumerated() {
                // No corner sharper than a right angle.
                var turn = 0
                if direction < 8 {
                    turn = abs(next - direction)
                    if turn > 4 { turn = 8 - turn }
                    if turn > 2 { continue }
                }
                let c = column + step.dx, r = row + step.dy
                guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                let nextCell = r * columns + c
                guard track(layer, nextCell) == 1 else { continue }
                let length = (step.dx != 0 && step.dy != 0 ? 2.squareRoot() : 1) * pitch
                let nextState = (layer * cells + nextCell) * 9 + next
                let nextCost = cost[state] + Float((length + Double(turn) * request.bendPenalty / 2) / 1000)
                if nextCost < cost[nextState] {
                    cost[nextState] = nextCost
                    parent[nextState] = Int32(state)
                    heap.push(nextState, nextCost + heuristic(nextCell))
                }
            }
            // A via here, to any other layer it reaches: one the path would
            // place, at a via's cost, or the net's own that stands here.
            let change = layerChanges(from: layer, at: cell)
            for other in change.layers {
                guard track(other, cell) == 1 else { continue }
                let nextState = (other * cells + cell) * 9 + 8
                let nextCost = cost[state] + (change.standing ? 0 : Float(request.viaCost / 1000))
                if nextCost < cost[nextState] {
                    cost[nextState] = nextCost
                    parent[nextState] = Int32(state)
                    heap.push(nextState, nextCost + heuristic(cell))
                }
            }
        }

        guard let reached else {
            return .blocked(fromSide: wall(closed: closed), toSide: targetWall(), reachedWindowEdge: edge)
        }

        // Back from the goal, then forwards as legs of straight runs.
        var chain = [Int]()
        var cursor = Int32(reached)
        while cursor >= 0 {
            chain.append(Int(cursor) / 9)
            cursor = parent[Int(cursor)]
        }
        chain.reverse()
        let targetIndex = goals[chain[chain.count - 1]] ?? 0
        var legs = [Leg]()
        var vias = [HorizontalPoint]()
        var standing = Set<Int>()
        for node in chain {
            let layer = request.layers[node / cells], at = position(node % cells)
            if let last = legs.last, last.layer == layer {
                legs[legs.count - 1].points.append(at)
            } else {
                if !legs.isEmpty {
                    if standingAtCell[node % cells] != nil { standing.insert(vias.count) }
                    vias.append(at)
                }
                legs.append(Leg(layer: layer, points: [at]))
            }
        }
        let target = request.targets[targetIndex].point
        if let last = legs.last?.points.last, last != target { legs[legs.count - 1].points.append(target) }
        var length = 0.0, bends = 0
        for index in legs.indices {
            legs[index].points = Self.straightened(legs[index].points)
            length += HorizontalRoute45.length(of: legs[index].points)
            bends += max(legs[index].points.count - 2, 0)
        }
        return .found(Path(legs: legs, vias: vias, standing: standing, target: targetIndex, length: length, bends: bends))
    }

    /// `points` without the ones on a straight line between their neighbours.
    static func straightened(_ points: [HorizontalPoint]) -> [HorizontalPoint] {
        var result = [HorizontalPoint]()
        for point in points {
            if let last = result.last, last == point { continue }
            while result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                let cross = (b.x - a.x) * (point.y - b.y) - (b.y - a.y) * (point.x - b.x)
                let along = (b.x - a.x) * (point.x - b.x) + (b.y - a.y) * (point.y - b.y)
                guard abs(cross) < 1e-3 * max(hypot(b.x - a.x, b.y - a.y) * hypot(point.x - b.x, point.y - b.y), 1), along > 0 else { break }
                result.removeLast()
            }
            result.append(point)
        }
        return result
    }

    // MARK: - What is in the way

    /// The obstacles the reached positions touch: the wall round what the
    /// search could get to.
    private mutating func wall(closed: [Bool]) -> [Blocker] {
        let cells = columns * rows
        var reachedNodes = Set<Int>()
        for state in closed.indices where closed[state] { reachedNodes.insert(state / 9) }
        return wall(round: reachedNodes, cells: cells)
    }

    private mutating func wall(round nodes: Set<Int>, cells: Int) -> [Blocker] {
        var counts = [Int: Int]()   // layer << 32 | code
        for node in nodes {
            let layer = node / cells, cell = node % cells
            let column = cell % columns, row = cell / columns
            for step in Self.steps where step.dx == 0 || step.dy == 0 {
                let c = column + step.dx, r = row + step.dy
                guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                let state = track(layer, r * columns + c)
                if state > 1 { counts[layer << 32 | Int(state), default: 0] += 1 }
            }
        }
        return counts.map { key, count in
            Blocker(obstacle: blockers[(key & 0xffff_ffff) - 2], layer: request.layers[key >> 32], cells: count)
        }.sorted { ($0.cells, $1.layer) > ($1.cells, $0.layer) }
    }

    /// What bounds the positions reachable from the targets: a flood from
    /// each, through vias too. A target that is itself blocked is bounded by
    /// what blocks it.
    private mutating func targetWall() -> [Blocker] {
        let cells = columns * rows
        var seen = Set<Int>()
        var pending = [Int]()
        var direct = [Blocker]()
        for target in request.targets {
            let column = min(max(Int(((target.point.x - originX) / request.pitch).rounded()), 0), columns - 1)
            let row = min(max(Int(((target.point.y - originY) / request.pitch).rounded()), 0), rows - 1)
            let cell = row * columns + column
            for (layer, number) in request.layers.enumerated() where target.layers.isEmpty || target.layers.contains(number) {
                let state = track(layer, cell)
                if state == 1 {
                    if seen.insert(layer * cells + cell).inserted { pending.append(layer * cells + cell) }
                } else {
                    direct.append(Blocker(obstacle: blockers[Int(state) - 2], layer: number, cells: 1))
                }
            }
        }
        var budget = request.maxExpansions
        while let node = pending.popLast(), budget > 0 {
            budget -= 1
            let layer = node / cells, cell = node % cells
            let column = cell % columns, row = cell / columns
            for step in Self.steps {
                let c = column + step.dx, r = row + step.dy
                guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                let next = layer * cells + r * columns + c
                if track(layer, r * columns + c) == 1, seen.insert(next).inserted { pending.append(next) }
            }
            for other in layerChanges(from: layer, at: cell).layers {
                let next = other * cells + cell
                if track(other, cell) == 1, seen.insert(next).inserted { pending.append(next) }
            }
        }
        return direct + wall(round: seen, cells: cells)
    }

    /// A binary heap of states by estimated cost, ties to the lower state so
    /// the search is the same every time.
    private struct Heap {
        private var items: [(priority: Float, state: Int)] = []

        private func before(_ a: (priority: Float, state: Int), _ b: (priority: Float, state: Int)) -> Bool {
            a.priority != b.priority ? a.priority < b.priority : a.state < b.state
        }

        mutating func push(_ state: Int, _ priority: Float) {
            items.append((priority, state))
            var child = items.count - 1
            while child > 0 {
                let above = (child - 1) / 2
                guard before(items[child], items[above]) else { break }
                items.swapAt(child, above)
                child = above
            }
        }

        mutating func pop() -> Int? {
            guard let first = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var above = 0
                while true {
                    let left = 2 * above + 1, right = left + 1
                    var least = above
                    if left < items.count, before(items[left], items[least]) { least = left }
                    if right < items.count, before(items[right], items[least]) { least = right }
                    guard least != above else { break }
                    items.swapAt(above, least)
                    above = least
                }
            }
            return first.state
        }
    }
}
