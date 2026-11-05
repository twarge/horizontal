import Foundation

/// Meander tuning on a board, docs/length-tuning.md's single-track tune: a
/// straight track, the stretch of it from where the tune starts towards the
/// cursor, and cells along it (`HorizontalMeander`) until its net is as long
/// as the target, each as tall as the board leaves room for.
///
/// Built once when a tune starts, as the track tool's router session is: the
/// router's world and index of the board as it stands (`HorizontalRouterWorld`,
/// `HorizontalRouterIndex`), and each slot's room, worked out once and kept,
/// since the slots along a track don't move while the cursor does.
///
/// Room is tested on a cell's swept box, the rectangle it covers from the
/// baseline to its join, corners and legs included, not on its copper. A
/// shorter cell's box lies inside a taller one's, so whether a box is clear
/// only ever changes once as the amplitude grows, and the largest clear one
/// is found by bisection in whole steps. Testing the copper instead isn't
/// monotone (an obstacle between a tall cell's legs is cut by a shorter one's
/// join), and bisection on it would be wrong. The box refuses a cell that
/// could have threaded round an obstacle, which is the right way to be wrong.
///
/// The clearances are the rules' own, with no routing offset: a tune edits a
/// track that is already there, so the margin the router keeps beyond the
/// rules would refuse cells beside copper the track legally passes. Copper of
/// the track's own net is kept out of too, at no clearance, so a meander never
/// folds onto its own pads or tracks, which would short its added length out.
/// What is laid is checked once more on the exact shapes
/// (`violations(on:newTrackIDs:)`).
final class HorizontalMeanderTuner {
    struct Request: Hashable {
        var trackID: String
        /// Where the tune starts on the track, and the cursor, whose place
        /// along the track ends the stretch and whose side of it the cells
        /// go on.
        var anchor: HorizontalPoint
        var cursor: HorizontalPoint
        /// The net's length wanted, nanometres.
        var target: Double
        var settings: HorizontalMeander.Settings
    }

    enum Status: Hashable {
        /// The net is the target's length, to the tolerance.
        case reached
        /// The stretch holds too little: this much is missing.
        case short(Double)
        /// The net is the target's length or longer already; a meander only
        /// lengthens.
        case longEnough
        /// Not a track a tune can take: an arc, or one at an angle none of
        /// the eight directions is.
        case notStraight
        case noTrack
    }

    struct Result: Hashable {
        var request: Request
        var netID: String?
        var layer: Int?
        var lattice: HorizontalMeander.Lattice?
        var plan: HorizontalMeander.Plan
        var pieces: [HorizontalMeander.Piece]
        /// The net's length before and after, every track on it, arcs along
        /// their circles, as the Length Tuning window measures All Tracks.
        var netLength: Double
        var tunedLength: Double
        var status: Status

        var hasCells: Bool { !plan.cells.isEmpty }
    }

    let board: HorizontalBoard
    private let world: HorizontalRouterWorld
    private let index: HorizontalRouterIndex
    private let clearances: HorizontalRouterClearances
    private let netLengths: [String: Double]
    private var caps: [CapKey: Int] = [:]

    private struct CapKey: Hashable {
        var trackID: String
        var start: Int
        var side: Int
        var spacing: Int
        var corner: Int
        var largest: Int
    }

    init(board: HorizontalBoard) {
        self.board = board
        world = HorizontalRouterWorld.extract(from: board)
        index = HorizontalRouterIndex(world: world)
        clearances = HorizontalRouterClearances(world: world, rules: board.rules, includesRoutingOffset: false)
        netLengths = HorizontalTrackLength.routedLengths(board.tracks)
    }

    /// The straight track a tune can take, nearest `point` within `reach`.
    func track(near point: HorizontalPoint, reach: Double, layer: Int? = nil) -> HorizontalSegment? {
        board.tracks
            .filter { $0.center == nil && $0.netID != nil && (layer == nil || $0.layer == layer) }
            .map { ($0, HorizontalRouteClearanceProbe.pointSegmentDistance(point, $0.from, $0.to)) }
            .filter { $0.1 <= reach + $0.0.width / 2 }
            .min { $0.1 < $1.1 }?.0
    }

    /// The net's length now.
    func netLength(_ netID: String?) -> Double {
        netID.map { netLengths[$0.lowercased()] ?? 0 } ?? 0
    }

    func tune(_ request: Request) -> Result {
        let emptyPlan = HorizontalMeander.Plan(cells: [], added: 0, residual: 0, blocked: 0)
        guard let track = board.tracks.first(where: { $0.id.lowercased() == request.trackID.lowercased() }) else {
            return Result(request: request, netID: nil, layer: nil, lattice: nil, plan: emptyPlan, pieces: [],
                          netLength: 0, tunedLength: 0, status: .noTrack)
        }
        // A track on no net is measured alone.
        let length = track.netID == nil ? HorizontalTrackLength.length(of: track) : netLength(track.netID)
        guard track.center == nil, let lattice = HorizontalMeander.lattice(from: track.from, to: track.to) else {
            return Result(request: request, netID: track.netID, layer: track.layer, lattice: nil, plan: emptyPlan,
                          pieces: [], netLength: length, tunedLength: length, status: .notStraight)
        }
        let settings = request.settings
        let needed = request.target - length
        guard needed > max(settings.tolerance, lattice.unit) else {
            let status: Status = needed >= -max(settings.tolerance, lattice.unit) ? .reached : .longEnough
            return Result(request: request, netID: track.netID, layer: track.layer, lattice: lattice, plan: emptyPlan,
                          pieces: [], netLength: length, tunedLength: length, status: status)
        }

        let along = lattice.coordinates(of: request.anchor)
        let towards = lattice.coordinates(of: request.cursor)
        let anchor = min(max(Int(along.u.rounded()), 0), lattice.steps)
        let toward = min(max(Int(towards.u.rounded()), 0), lattice.steps)
        let side = towards.v < 0 ? -1 : 1
        let spacing = max(1, lattice.steps(settings.spacing))
        let corner = min(lattice.steps(settings.cornerSize), spacing / 2)
        let largest = max(1, lattice.steps(settings.amplitude))
        // A cell keeps a spacing and a corner from the track's ends, where it
        // meets a corner, a via or a pad.
        let slots = HorizontalMeander.slots(lattice: lattice, anchor: anchor, toward: toward,
                                            spacing: spacing, corner: corner, margin: spacing + corner)
        let minimum = max(1, lattice.steps(track.width))
        let plan = HorizontalMeander.plan(
            needed: needed, lattice: lattice, slots: slots, settings: settings, side: side,
            minimumAmplitude: minimum
        ) { start, side in
            self.cap(track: track, lattice: lattice, start: start, side: side, spacing: spacing, corner: corner,
                     largest: largest, smallest: minimum)
        }
        let pieces = plan.cells.isEmpty ? [] : HorizontalMeander.pieces(lattice: lattice, cells: plan.cells, corner: settings.corner)
        let tuned = plan.cells.isEmpty
            ? length
            : length - HorizontalTrackLength.length(of: track) + HorizontalMeander.length(of: pieces)
        let missing = request.target - tuned
        let status: Status = missing > max(settings.tolerance, lattice.unit) ? .short(missing) : .reached
        return Result(request: request, netID: track.netID, layer: track.layer, lattice: lattice, plan: plan,
                      pieces: pieces, netLength: length, tunedLength: tuned, status: status)
    }

    /// The largest amplitude, in steps, a cell at `start` on `side` can take,
    /// up to `largest`: the largest whose swept box clears everything but the
    /// track itself; 0 when even `smallest` doesn't.
    private func cap(
        track: HorizontalSegment, lattice: HorizontalMeander.Lattice, start: Int, side: Int,
        spacing: Int, corner: Int, largest: Int, smallest: Int
    ) -> Int {
        let key = CapKey(trackID: track.id.lowercased(), start: start, side: side, spacing: spacing,
                         corner: corner, largest: largest)
        if let known = caps[key] {
            return known
        }
        let found = findCap(track: track, lattice: lattice, start: start, side: side, spacing: spacing,
                            corner: corner, largest: largest, smallest: smallest)
        caps[key] = found
        return found
    }

    private func findCap(
        track: HorizontalSegment, lattice: HorizontalMeander.Lattice, start: Int, side: Int,
        spacing: Int, corner: Int, largest: Int, smallest: Int
    ) -> Int {
        guard let layer = track.layer, largest >= smallest else { return 0 }
        let net = world.netCode(for: track.netID)
        let trackID = track.id.lowercased()
        func box(_ amplitude: Int) -> HorizontalOctagon? {
            // From a step off the baseline: copper beyond it on the other side
            // clears the track already, at exactly its clearance.
            let low = start - corner, high = start + spacing + corner
            return HorizontalOctagon(points: [
                lattice.point(low, side), lattice.point(high, side),
                lattice.point(high, side * amplitude), lattice.point(low, side * amplitude),
            ])
        }
        guard let tallest = box(largest) else { return 0 }
        // The hulls the tallest box could meet, each grown by its clearance and
        // half the track's width; a shorter box meets a subset of them.
        let reach = clearances.broadPhaseClearance(forTrackOn: net, layer: layer) + track.width / 2
        var hulls = [HorizontalOctagon]()
        index.forEachObstacle(overlapping: tallest.inflated(by: reach).boundingBox, on: layer) { _, obstacle in
            if case .track(let i) = obstacle.kind, world.tracks.indices.contains(i),
               world.segmentIDForTrackID[world.tracks[i].id]?.lowercased() == trackID {
                return
            }
            let clearance = clearances.clearance(.track, net: net, obstacle.objectClass, net: obstacle.netCode, on: layer)
            hulls.append(obstacle.hull.inflated(by: clearance + track.width / 2))
        }
        func clear(_ amplitude: Int) -> Bool {
            guard let box = box(amplitude) else { return false }
            return !hulls.contains { $0.overlaps(box) }
        }
        if clear(largest) {
            return largest
        }
        guard clear(smallest) else {
            return 0
        }
        var low = smallest, high = largest - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if clear(middle) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    // MARK: - Laying it

    /// The tune laid on `board`: the track replaced by the meander's pieces,
    /// each the track's width, layer, net and width source, joined by
    /// junctions on its layer, its ends on the track's own. An arc runs
    /// from whichever end makes it the minor arc, as Horizon stores one,
    /// with its junctions swapped to match. Returns the new tracks' ids;
    /// none, and the board untouched, where the result has no cells.
    /// `idPrefix` names the new tracks and junctions `<prefix>-track-<n>` and
    /// `<prefix>-junction-<n>`, the same every time, for a preview; without
    /// it they are new uuids.
    @discardableResult
    static func lay(_ result: Result, on board: inout HorizontalBoard, idPrefix: String? = nil) -> [String] {
        guard result.hasCells,
              let index = board.tracks.firstIndex(where: { $0.id.lowercased() == result.request.trackID.lowercased() }) else {
            return []
        }
        let original = board.tracks.remove(at: index)
        var trackIDs = [String]()
        var previousJunction = original.fromJunctionID
        for (position, piece) in result.pieces.enumerated() {
            let isLast = position == result.pieces.count - 1
            let endJunction = isLast
                ? original.toJunctionID
                : BoardTrackRouting.mergeJunctions(at: piece.to, preferredID: idPrefix.map { "\($0)-junction-\(position)" },
                                                   netID: original.netID, layer: original.layer, board: &board)
            var from = piece.from, to = piece.to
            var fromJunction = previousJunction, toJunction = endJunction
            if let center = piece.center {
                let ends = BoardTrackRouting.orientedArc(from: piece.from, to: piece.to, center: center)
                if ends.from != piece.from {
                    swap(&from, &to)
                    swap(&fromJunction, &toJunction)
                }
            }
            let id = idPrefix.map { "\($0)-track-\(position)" } ?? UUID().uuidString.lowercased()
            trackIDs.append(id)
            board.tracks.append(HorizontalSegment(
                id: id, from: from, to: to, width: original.width, layer: original.layer, center: piece.center,
                netID: original.netID, fromJunctionID: fromJunction, toJunctionID: toJunction,
                widthFromRules: original.widthFromRules))
            previousJunction = endJunction
        }
        return trackIDs
    }

    /// What the clearance check finds wrong with the new tracks on `board`,
    /// on the exact shapes (`HorizontalBoardClearanceCheck`), over the copper
    /// around them alone. Planes are left out: a pour is redone round new
    /// copper, as the router treats them, and its old fill isn't an obstacle.
    static func violations(on board: HorizontalBoard, newTrackIDs: [String]) -> [HorizontalClearanceFinding] {
        let ids = Set(newTrackIDs.map { $0.lowercased() })
        let tracks = board.tracks.filter { ids.contains($0.id.lowercased()) }
        guard !tracks.isEmpty else { return [] }
        var region = HorizontalRect(points: tracks.flatMap(\.pathPoints))
        // Wider than any clearance a board asks.
        let margin = 5_000_000.0
        region = HorizontalRect(points: [
            HorizontalPoint(x: region.minX - margin, y: region.minY - margin),
            HorizontalPoint(x: region.maxX + margin, y: region.maxY + margin),
        ])
        func near(_ points: [HorizontalPoint]) -> Bool {
            guard !points.isEmpty else { return false }
            let box = HorizontalRect(points: points)
            return box.maxX >= region.minX && box.minX <= region.maxX && box.maxY >= region.minY && box.minY <= region.maxY
        }
        var local = board
        local.tracks = board.tracks.filter { near($0.pathPoints) }
        local.netTies = board.netTies.filter { near([$0.from, $0.to]) }
        local.vias = board.vias.filter { near([$0.position]) }
        local.packagePads = board.packagePads.filter { near($0.vertices) }
        local.holes = board.holes.filter { near([$0.position]) }
        local.packageHoles = board.packageHoles.filter { near([$0.position]) }
        local.planes = []
        return HorizontalBoardClearanceCheck.run(board: local).filter { finding in
            (ids.contains(finding.first.id.lowercased()) || ids.contains(finding.second.id.lowercased()))
                && finding.first.type != .plane && finding.second.type != .plane
        }
    }
}
