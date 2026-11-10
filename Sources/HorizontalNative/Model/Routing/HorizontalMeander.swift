import Foundation

/// Meander tuning's pattern, as docs/length-tuning.md specifies it, built
/// clean-room from the geometry: a straight run of track, the *baseline*,
/// replaced by a chain of *cells*. In the baseline's frame (u along it, v
/// across, left positive) a cell goes up a leg of height A, the amplitude,
/// across a join of length s, the spacing, and down a leg of A; cells sit a
/// spacing apart along the baseline. One-sided cells make a trombone, cells
/// on alternate sides a serpentine; both add the same length.
///
/// Every corner is a 45° chamfer of size c (c cut from each leg it joins) or
/// an arc of radius r, losing (2 − √2)c or (2 − π/2)r against a square corner,
/// so a cell adds e(A) = 2A − 4k, k the corner's loss. Nothing here is tuned:
/// the numbers are the geometry's.
///
/// Coordinates stay whole nanometres, as the writer needs. The baseline runs
/// in one of the eight routing directions, and everything is laid out on its
/// lattice: whole steps along it and across it, one nanometre each on an
/// axis and √2 nm on a diagonal, where a step is (1, 1). Every point is then
/// whole, a chamfer runs in one of the eight directions too, and an arc's
/// centre is a lattice point.
enum HorizontalMeander {
    enum Corner: String, CaseIterable, Identifiable, Hashable, Sendable {
        case chamfer
        case arc

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chamfer: "45°"
            case .arc: "Arc"
            }
        }

        /// What one corner loses against a square one, per step of its size.
        var loss: Double {
            switch self {
            case .chamfer: 2 - 2.squareRoot()
            case .arc: 2 - .pi / 2
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable, Hashable, Sendable {
        /// Every cell on one side: a trombone.
        case oneSided
        /// Cells on alternate sides: a serpentine.
        case serpentine

        var id: String { rawValue }

        var title: String {
            switch self {
            case .oneSided: "One side"
            case .serpentine: "Serpentine"
            }
        }
    }

    struct Settings: Hashable, Sendable {
        /// The largest amplitude, nanometres, centreline to centreline from the
        /// baseline to a cell's join.
        var amplitude: Double = 1_000_000
        /// Leg centre to leg centre, nanometres. The gap between legs is this
        /// less the track's width.
        var spacing: Double = 600_000
        var corner: Corner = .chamfer
        var style: Style = .oneSided
        /// How close to the target counts as there, nanometres. Moving a
        /// join by a step changes the length by two steps, so nothing finer
        /// than that is reachable.
        var tolerance: Double = 1_000

        /// A corner's size: an arc half the spacing, which rounds a join and
        /// the gap between cells into half circles, a chamfer a quarter.
        var cornerSize: Double {
            corner == .arc ? spacing / 2 : spacing / 4
        }
    }

    /// The baseline's lattice: a whole start point, the step along it and the
    /// step across to its left, and how many steps long it is.
    struct Lattice: Hashable, Sendable {
        var origin: HorizontalPoint
        var stepX: Int
        var stepY: Int
        var steps: Int

        /// The length of a step: 1 nm on an axis, √2 nm on a diagonal.
        var unit: Double {
            stepX != 0 && stepY != 0 ? 2.squareRoot() : 1
        }

        /// The point `u` steps along and `v` steps across, to the left.
        func point(_ u: Int, _ v: Int) -> HorizontalPoint {
            HorizontalPoint(
                x: origin.x + Double(u * stepX - v * stepY),
                y: origin.y + Double(u * stepY + v * stepX)
            )
        }

        /// Where `point` is along and across, in steps, unrounded.
        func coordinates(of point: HorizontalPoint) -> (u: Double, v: Double) {
            let dx = point.x - origin.x, dy = point.y - origin.y
            let norm = Double(stepX * stepX + stepY * stepY)
            return ((dx * Double(stepX) + dy * Double(stepY)) / norm,
                    (-dx * Double(stepY) + dy * Double(stepX)) / norm)
        }

        /// A nanometre length in whole steps, rounded.
        func steps(_ nanometres: Double) -> Int {
            Int((nanometres / unit).rounded())
        }
    }

    /// The lattice of a straight run from `from` to `to`, or nil where its
    /// ends aren't whole nanometres or it runs in none of the eight
    /// directions.
    static func lattice(from: HorizontalPoint, to: HorizontalPoint) -> Lattice? {
        func whole(_ value: Double) -> Int? {
            let rounded = value.rounded()
            return abs(value - rounded) < 1e-6 ? Int(rounded) : nil
        }
        guard let x0 = whole(from.x), let y0 = whole(from.y), let x1 = whole(to.x), let y1 = whole(to.y) else {
            return nil
        }
        let dx = x1 - x0, dy = y1 - y0
        guard dx != 0 || dy != 0, dx == 0 || dy == 0 || abs(dx) == abs(dy) else {
            return nil
        }
        return Lattice(
            origin: HorizontalPoint(x: Double(x0), y: Double(y0)),
            stepX: dx.signum(), stepY: dy.signum(),
            steps: max(abs(dx), abs(dy))
        )
    }

    /// One cell, in steps: its first leg's position along the baseline, the
    /// legs' spacing, the side (+1 left, −1 right), its amplitude and its
    /// corners' size.
    struct Cell: Hashable, Sendable {
        var start: Int
        var spacing: Int
        var side: Int
        var amplitude: Int
        var corner: Int

        /// The baseline it spans, corners included: the first leg's base
        /// corner starts a corner before the leg, the last ends one after.
        var span: ClosedRange<Int> {
            (start - corner)...(start + spacing + corner)
        }
    }

    /// A piece of the meander, in the order the track runs: straight, or an
    /// arc about `center`.
    struct Piece: Hashable, Sendable {
        var from: HorizontalPoint
        var to: HorizontalPoint
        var center: HorizontalPoint?
    }

    /// What a cell of amplitude `amplitude` with corners of `corner` adds to
    /// the track, in nanometres.
    static func addedLength(amplitude: Int, corner: Int, style corners: Corner, unit: Double) -> Double {
        (2 * Double(amplitude) - 4 * corners.loss * Double(corner)) * unit
    }

    /// The meander's pieces from the baseline's start to its end: straight
    /// along it, round each cell, straight on to the end.
    static func pieces(lattice: Lattice, cells: [Cell], corner corners: Corner) -> [Piece] {
        var pieces = [Piece]()
        var cursor = (u: 0, v: 0)
        func straight(_ u: Int, _ v: Int) {
            guard (u, v) != cursor else { return }
            // Running on in the same direction joins the last straight.
            if let last = pieces.last, last.center == nil {
                let a = lattice.coordinates(of: last.from)
                let du0 = cursor.u - Int(a.u.rounded()), dv0 = cursor.v - Int(a.v.rounded())
                let du1 = u - cursor.u, dv1 = v - cursor.v
                if du0 * dv1 == dv0 * du1, du0 * du1 + dv0 * dv1 > 0 {
                    pieces[pieces.count - 1].to = lattice.point(u, v)
                    cursor = (u, v)
                    return
                }
            }
            pieces.append(Piece(from: lattice.point(cursor.u, cursor.v), to: lattice.point(u, v), center: nil))
            cursor = (u, v)
        }
        func turn(to u: Int, _ v: Int, center: (Int, Int)) {
            guard (u, v) != cursor else { return }
            switch corners {
            case .chamfer:
                straight(u, v)
            case .arc:
                pieces.append(Piece(from: lattice.point(cursor.u, cursor.v), to: lattice.point(u, v),
                                    center: lattice.point(center.0, center.1)))
                cursor = (u, v)
            }
        }
        for cell in cells.sorted(by: { $0.start < $1.start }) {
            let a = cell.start, b = cell.start + cell.spacing, k = cell.corner, side = cell.side
            let top = side * cell.amplitude
            straight(a - k, 0)
            turn(to: a, side * k, center: (a - k, side * k))
            straight(a, top - side * k)
            turn(to: a + k, top, center: (a + k, top - side * k))
            straight(b - k, top)
            turn(to: b, top - side * k, center: (b - k, top - side * k))
            straight(b, side * k)
            turn(to: b + k, 0, center: (b + k, side * k))
        }
        straight(lattice.steps, 0)
        return pieces
    }

    /// Where cells may go, nearest `anchor` first, towards `toward`: a cell's
    /// span keeps `margin` steps from either end of the baseline and stays
    /// between the two points. Cells sit a spacing apart, so their starts are
    /// two spacings apart.
    static func slots(lattice: Lattice, anchor: Int, toward: Int, spacing: Int, corner: Int, margin: Int) -> [Int] {
        guard spacing > 0 else { return [] }
        let low = max(min(anchor, toward), margin), high = min(max(anchor, toward), lattice.steps - margin)
        guard high - low >= spacing + 2 * corner else { return [] }
        var starts = [Int]()
        if toward >= anchor {
            var start = low + corner
            while start + spacing + corner <= high {
                starts.append(start)
                start += 2 * spacing
            }
        } else {
            var start = high - corner - spacing
            while start - corner >= low {
                starts.append(start)
                start -= 2 * spacing
            }
        }
        return starts
    }

    /// The cells that make up `needed` nanometres, or as much of it as the
    /// slots allow: the fewest that reach it, all at one amplitude, the most
    /// `cap` allows each and no more than the settings' (in steps, 0 where a
    /// slot can take none on that side), with a step more on as many as make
    /// up the remainder. A one-sided tune takes a slot's other side where its
    /// own allows less; a serpentine alternates, its first cell on `side`.
    ///
    /// The corners are the settings' size; a target too short for one cell
    /// with them is tried with smaller ones, down to square.
    struct Plan: Hashable, Sendable {
        var cells: [Cell]
        /// What the cells add, nanometres.
        var added: Double
        /// `needed` less `added`: within a step of zero when the target is
        /// reached, the length missing when the slots can't hold it.
        var residual: Double
        /// Slots no cell fits in, on either side tried.
        var blocked: Int
    }

    static func plan(
        needed: Double,
        lattice: Lattice,
        slots: [Int],
        settings: Settings,
        side: Int,
        minimumAmplitude: Int,
        cap: (_ start: Int, _ side: Int) -> Int
    ) -> Plan {
        let spacing = max(1, lattice.steps(settings.spacing))
        let largest = max(1, lattice.steps(settings.amplitude))
        let corner0 = min(lattice.steps(settings.cornerSize), spacing / 2)
        var sizes = [corner0]
        for size in [corner0 / 2, corner0 / 4, 1, 0] where size < sizes.last! {
            sizes.append(size)
        }
        var best: Plan?
        for corner in sizes {
            let plan = plan(needed: needed, lattice: lattice, slots: slots, settings: settings, side: side,
                            spacing: spacing, largest: largest, corner: corner,
                            smallest: max(minimumAmplitude, 2 * corner, 1), cap: cap)
            if abs(plan.residual) <= max(settings.tolerance, lattice.unit) {
                return plan
            }
            if best == nil || abs(plan.residual) < abs(best!.residual) {
                best = plan
            }
        }
        return best ?? Plan(cells: [], added: 0, residual: needed, blocked: 0)
    }

    private static func plan(
        needed: Double, lattice: Lattice, slots: [Int], settings: Settings, side preferred: Int,
        spacing: Int, largest: Int, corner: Int, smallest: Int,
        cap: (_ start: Int, _ side: Int) -> Int
    ) -> Plan {
        let unit = lattice.unit
        func added(_ amplitude: Int) -> Double {
            addedLength(amplitude: amplitude, corner: corner, style: settings.corner, unit: unit)
        }
        guard needed > 0, largest >= smallest else {
            return Plan(cells: [], added: 0, residual: needed, blocked: 0)
        }
        // Each slot's side and the most it may take there.
        var usable = [(start: Int, side: Int, cap: Int)]()
        var blocked = 0
        for (index, start) in slots.enumerated() {
            let side = settings.style == .serpentine ? (index % 2 == 0 ? preferred : -preferred) : preferred
            var choice = (side: side, cap: min(largest, cap(start, side)))
            if settings.style == .oneSided, choice.cap < largest {
                let other = min(largest, cap(start, -side))
                if other > choice.cap {
                    choice = (-side, other)
                }
            }
            if choice.cap >= smallest {
                usable.append((start, choice.side, choice.cap))
            } else {
                blocked += 1
            }
        }
        // The fewest cells that reach it.
        var count = 0, reach = 0.0
        while count < usable.count, reach < needed {
            reach += added(usable[count].cap)
            count += 1
        }
        let chosen = Array(usable.prefix(count))
        guard !chosen.isEmpty else {
            return Plan(cells: [], added: 0, residual: needed, blocked: blocked)
        }
        func total(_ ceiling: Int) -> Double {
            chosen.reduce(0) { $0 + added(min(ceiling, $1.cap)) }
        }
        // One amplitude for all: the largest that stays within the target.
        var amplitudes: [Int]
        if total(smallest) > needed {
            // Even the smallest cells overshoot; the fewer that don't, at
            // their caps, undershoot instead.
            let fewer = Array(chosen.dropLast())
            amplitudes = fewer.map(\.cap)
            let cells = zip(fewer, amplitudes).map {
                Cell(start: $0.0.start, spacing: spacing, side: $0.0.side, amplitude: $0.1, corner: corner)
            }
            let sum = amplitudes.reduce(0) { $0 + added($1) }
            return Plan(cells: cells, added: sum, residual: needed - sum, blocked: blocked)
        }
        var low = smallest, high = chosen.map(\.cap).max()!
        while low < high {
            let middle = (low + high + 1) / 2
            if total(middle) <= needed {
                low = middle
            } else {
                high = middle - 1
            }
        }
        amplitudes = chosen.map { min(low, $0.cap) }
        // The remainder a step at a time, two steps of length each, on the
        // cells with room, while a step brings it nearer.
        var sum = amplitudes.reduce(0) { $0 + added($1) }
        var index = 0, passes = 0
        while needed - sum > unit, passes < 4 {
            if amplitudes[index] < chosen[index].cap {
                amplitudes[index] += 1
                sum += 2 * unit
            }
            index += 1
            if index == amplitudes.count {
                index = 0
                passes += 1
            }
        }
        let cells = zip(chosen, amplitudes).map {
            Cell(start: $0.0.start, spacing: spacing, side: $0.0.side, amplitude: $0.1, corner: corner)
        }
        return Plan(cells: cells, added: sum, residual: needed - sum, blocked: blocked)
    }

    /// The pieces' length, arcs along their circles (`HorizontalTrackLength`).
    static func length(of pieces: [Piece]) -> Double {
        pieces.reduce(0) { total, piece in
            guard let center = piece.center else {
                return total + hypot(piece.to.x - piece.from.x, piece.to.y - piece.from.y)
            }
            // A meander's corner is a quarter turn, the minor arc either way.
            let ends = BoardTrackRouting.orientedArc(from: piece.from, to: piece.to, center: center)
            return total + HorizontalTrackLength.arcLength(from: ends.from, to: ends.to, centerHint: center, reverse: false)
        }
    }
}
