import Foundation

/// Spatial index over a `HorizontalRouterWorld`, so the router can ask "what is
/// near here, on this layer" without scanning the board.
///
/// Step 2 of `docs/push-shove-router.md`. The router's inner loop runs per
/// mouse-move, and a linear scan of a few thousand obstacles per query is what
/// makes an interactive router feel attached to the cursor or not.
///
/// Deliberately NOT baking clearance into the stored hulls. Clearance depends on
/// the pair of nets involved, so an obstacle has no single inflated size. The
/// stored hull is the obstacle's own copper; the caller inflates its QUERY by
/// `clearance + itsOwnHalfWidth` instead, which is the same test performed once
/// rather than once per obstacle.
final class HorizontalRouterIndex {
    /// What the index hands back: enough to decide a collision without going
    /// back to the world, plus the way back to it for the ones that matter.
    struct Obstacle {
        enum Kind: Equatable {
            case track(Int)
            case solid(Int)
            case via(Int)
            case unplatedHole(Int)
            case keepout(Int)
            /// One edge of the board outline. Stored per edge because an octagon
            /// around a whole outline is the whole board, and would collide with
            /// everything inside it.
            case boardEdge(contour: Int, edge: Int)
        }

        var kind: Kind
        /// Which clearance rule governs this obstacle. Derived once here so no
        /// caller has to infer it from `kind` and get it wrong.
        var objectClass: HorizontalRouterClearances.ObjectClass
        /// The obstacle's own copper, with no clearance applied.
        var hull: HorizontalOctagon
        var box: HorizontalRect
        /// Inclusive copper layer span. A track occupies one layer; a via or a
        /// through-hole pad occupies several, and must be found from any of them.
        var layerMin: Int
        var layerMax: Int
        var netCode: Int
        var locked: Bool
    }

    private(set) var obstacles: [Obstacle] = []

    private let originX: Double
    private let originY: Double
    private let cellSize: Double
    private let columns: Int
    private let rows: Int
    private var cells: [[Int32]]
    /// Obstacles too large to bucket usefully — a full-board pad or plane would
    /// otherwise be written into every cell it touches. Always visited.
    private var oversized: [Int32] = []

    /// Marks obstacles already handed to the current query, so one spanning
    /// several cells is visited once. A generation counter avoids clearing it.
    private var visitStamp: [UInt32]
    private var generation: UInt32 = 0

    init(world: HorizontalRouterWorld) {
        for (index, track) in world.tracks.enumerated() {
            let hull = HorizontalOctagon(from: track.from, to: track.to, width: track.width)
            obstacles.append(Obstacle(
                kind: .track(index), objectClass: .track,
                hull: hull, box: hull.boundingBox,
                layerMin: track.layer, layerMax: track.layer,
                netCode: track.netCode, locked: track.locked))
        }
        for (index, solid) in world.solids.enumerated() {
            guard let hull = HorizontalOctagon(points: solid.points) else { continue }
            // A pad reaching more than one copper layer is a through-hole pad,
            // which the rules give its own clearance entry.
            let spansLayers = solid.layerMin != solid.layerMax
            obstacles.append(Obstacle(
                kind: .solid(index), objectClass: spansLayers ? .padThroughHole : .pad,
                hull: hull, box: hull.boundingBox,
                layerMin: min(solid.layerMin, solid.layerMax),
                layerMax: max(solid.layerMin, solid.layerMax),
                // A pad is not movable, so it is the shove recursion's base case.
                netCode: solid.netCode, locked: true))
        }
        for (index, via) in world.vias.enumerated() {
            let hull = HorizontalOctagon(center: via.pos, radius: via.diameter / 2)
            obstacles.append(Obstacle(
                kind: .via(index), objectClass: .via,
                hull: hull, box: hull.boundingBox,
                layerMin: min(via.layerStart, via.layerEnd),
                layerMax: max(via.layerStart, via.layerEnd),
                netCode: via.netCode, locked: false))
        }
        for (index, hole) in world.unplatedHoles.enumerated() {
            let hull = HorizontalOctagon(center: hole.position, radius: hole.diameter / 2)
            obstacles.append(Obstacle(
                kind: .unplatedHole(index), objectClass: .holeUnplated,
                hull: hull, box: hull.boundingBox,
                // A drill goes through the board, so it obstructs every layer.
                layerMin: HorizontalBoardLayers.bottomCopper,
                layerMax: HorizontalBoardLayers.topCopper,
                netCode: -1, locked: true))
        }

        for (index, keepout) in world.keepouts.enumerated() {
            // A keepout that does not exclude tracks is not an obstacle to a
            // router laying track; one that bars only planes is common.
            guard keepout.copperPatchTypes.isEmpty
                    || keepout.copperPatchTypes.contains("track") else { continue }
            // A concave keepout is over-approximated by its octagon, so the
            // router avoids more than required. That refuses legal routes rather
            // than allowing illegal ones, which is the right way to be wrong.
            guard let hull = HorizontalOctagon(points: keepout.points) else { continue }
            obstacles.append(Obstacle(
                kind: .keepout(index), objectClass: .keepout(keepout.keepoutClass),
                hull: hull, box: hull.boundingBox,
                layerMin: keepout.layerMin, layerMax: keepout.layerMax,
                netCode: -1, locked: true))
        }

        // The board outline, one obstacle PER EDGE. An octagon around the whole
        // outline is the whole board and would collide with everything inside
        // it; the edges are what copper must actually keep away from.
        for (contourIndex, contour) in world.contours.enumerated() {
            let points = contour.points
            guard points.count >= 2 else { continue }
            let edgeCount = contour.closed ? points.count : points.count - 1
            for edge in 0..<edgeCount {
                let a = points[edge]
                let b = points[(edge + 1) % points.count]
                let hull = HorizontalOctagon(from: a, to: b, width: 0)
                obstacles.append(Obstacle(
                    kind: .boardEdge(contour: contourIndex, edge: edge),
                    objectClass: .boardEdge,
                    hull: hull, box: hull.boundingBox,
                    layerMin: HorizontalBoardLayers.bottomCopper,
                    layerMax: HorizontalBoardLayers.topCopper,
                    netCode: -1, locked: true))
            }
        }

        // Planes are deliberately NOT obstacles. A pour is recomputed from the
        // copper around it, so a plane yields to a new track rather than
        // obstructing it — treating one as an obstacle would make a ground-
        // flooded board unroutable. Horizontal already marks the fills stale
        // after an edit and asks for a re-pour.

        visitStamp = [UInt32](repeating: 0, count: obstacles.count)

        guard !obstacles.isEmpty else {
            originX = 0; originY = 0; cellSize = 1; columns = 1; rows = 1
            cells = [[]]
            return
        }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        var totalSpan = 0.0
        for obstacle in obstacles {
            minX = min(minX, obstacle.box.minX)
            minY = min(minY, obstacle.box.minY)
            maxX = max(maxX, obstacle.box.maxX)
            maxY = max(maxY, obstacle.box.maxY)
            totalSpan += max(obstacle.box.width, obstacle.box.height)
        }

        // Size cells to the average obstacle rather than to the board: too small
        // and a track is written into hundreds of cells, too large and every
        // query returns most of the board.
        let averageSpan = totalSpan / Double(obstacles.count)
        let span = max(maxX - minX, maxY - minY)
        let targetCells = 128.0
        cellSize = max(max(averageSpan, 1), span / targetCells)
        originX = minX
        originY = minY
        columns = max(1, min(512, Int(((maxX - minX) / cellSize).rounded(.up)) + 1))
        rows = max(1, min(512, Int(((maxY - minY) / cellSize).rounded(.up)) + 1))
        cells = [[Int32]](repeating: [], count: columns * rows)

        for (index, obstacle) in obstacles.enumerated() {
            let range = cellRange(for: obstacle.box)
            let touched = (range.maxColumn - range.minColumn + 1) * (range.maxRow - range.minRow + 1)
            // 32 cells is where bucketing stops paying for itself and the
            // obstacle is cheaper to test on every query than to spread.
            if touched > 32 {
                oversized.append(Int32(index))
                continue
            }
            for row in range.minRow...range.maxRow {
                for column in range.minColumn...range.maxColumn {
                    cells[row * columns + column].append(Int32(index))
                }
            }
        }
    }

    private struct CellRange {
        var minColumn: Int
        var maxColumn: Int
        var minRow: Int
        var maxRow: Int
    }

    private func cellRange(for box: HorizontalRect) -> CellRange {
        func column(_ x: Double) -> Int {
            min(max(Int((x - originX) / cellSize), 0), columns - 1)
        }
        func row(_ y: Double) -> Int {
            min(max(Int((y - originY) / cellSize), 0), rows - 1)
        }
        return CellRange(
            minColumn: column(box.minX), maxColumn: column(box.maxX),
            minRow: row(box.minY), maxRow: row(box.maxY)
        )
    }

    /// Visits every obstacle whose bounding box overlaps `box` and whose layer
    /// span includes `layer`.
    ///
    /// A conservative filter, deliberately: it may offer an obstacle whose box
    /// overlaps but whose octagon does not, and the caller makes the exact test.
    /// It must never MISS one — a missed obstacle is a collision the router does
    /// not see, and a board that ships with a short.
    ///
    /// Visits in obstacle order, so a query answers the same way every time.
    func forEachObstacle(
        overlapping box: HorizontalRect,
        on layer: Int,
        _ body: (Int, Obstacle) -> Void
    ) {
        guard !obstacles.isEmpty else { return }
        generation &+= 1
        if generation == 0 {
            // Wrapped: the stamps are meaningless now, so reset them once.
            for index in visitStamp.indices { visitStamp[index] = 0 }
            generation = 1
        }
        let mark = generation

        var candidates: [Int32] = []
        let range = cellRange(for: box)
        for row in range.minRow...range.maxRow {
            for column in range.minColumn...range.maxColumn {
                candidates.append(contentsOf: cells[row * columns + column])
            }
        }
        candidates.append(contentsOf: oversized)
        // Obstacle order, not cell order: the router's output must not depend on
        // how the index happened to bucket things.
        candidates.sort()

        for candidate in candidates {
            let index = Int(candidate)
            guard visitStamp[index] != mark else { continue }
            visitStamp[index] = mark

            let obstacle = obstacles[index]
            guard obstacle.layerMin <= layer, layer <= obstacle.layerMax else { continue }
            guard obstacle.box.maxX >= box.minX, obstacle.box.minX <= box.maxX,
                  obstacle.box.maxY >= box.minY, obstacle.box.minY <= box.maxY else { continue }
            body(index, obstacle)
        }
    }

    /// Every obstacle on `layer` whose copper actually intersects `hull`,
    /// excluding those on `net` — the query the router actually asks.
    ///
    /// `hull` should already carry the clearance and the moving track's half
    /// width, so this is a plain overlap test.
    func obstacles(
        colliding hull: HorizontalOctagon,
        on layer: Int,
        ignoringNet net: Int? = nil
    ) -> [Int] {
        var hits: [Int] = []
        forEachObstacle(overlapping: hull.boundingBox, on: layer) { index, obstacle in
            if let net, obstacle.netCode == net, net >= 0 { return }
            if hull.intersects(obstacle.hull) {
                hits.append(index)
            }
        }
        return hits
    }
}
