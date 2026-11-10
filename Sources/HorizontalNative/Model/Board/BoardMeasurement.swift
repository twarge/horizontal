import Foundation

/// A measurement between two points of the board, as Design ▸ Measure
/// Distance shows it: the run across and up, the straight distance and the
/// angle, in millimetres to the micrometre as Horizon writes lengths
/// (`HorizontalLengthText`), the board's units. Y runs up the board, so a
/// positive Δy is up.
struct BoardMeasurement: Equatable {
    var from: HorizontalPoint
    var to: HorizontalPoint

    var dx: Double { to.x - from.x }
    var dy: Double { to.y - from.y }
    var distance: Double { (dx * dx + dy * dy).squareRoot() }

    /// Degrees counter-clockwise from the +x axis, in (−180, 180]; 0 for no
    /// distance at all.
    var angle: Double {
        distance == 0 ? 0 : atan2(dy, dx) * 180 / .pi
    }

    /// "Δx +3.000 mm   Δy −4.000 mm   d 5.000 mm   α −53.1°". A run along
    /// one axis gives that axis alone, as Horizon's measure tool does.
    var text: String {
        let x = "Δx " + HorizontalLengthText.millimetres(dx, signed: true)
        let y = "Δy " + HorizontalLengthText.millimetres(dy, signed: true)
        if dx == 0, dy == 0 {
            return "d " + HorizontalLengthText.millimetres(0)
        }
        if dy == 0 {
            return x
        }
        if dx == 0 {
            return y
        }
        let degrees = abs(angle).formatted(.number.precision(.fractionLength(1)).grouping(.never))
        let signedDegrees = (angle < 0 ? "\u{2212}" : "") + degrees + "°"
        return "\(x)   \(y)   d \(HorizontalLengthText.millimetres(distance))   α \(signedDegrees)"
    }
}

/// The board canvas's measure tool (Design ▸ Measure Distance): a click puts
/// down the first point, the measurement follows the cursor to the second,
/// and a click there holds it; the next click starts another, and Esc or
/// Return leaves the tool. The points are where the canvas snaps the clicks,
/// to the grid and to what is drawn, as its other tools are. It changes
/// nothing on the board, so it works on a locked document too.
struct BoardMeasureState: Equatable {
    var from: HorizontalPoint?
    /// Set by the second click: the measurement stays put until the next.
    var to: HorizontalPoint?
    var cursor: HorizontalPoint?

    mutating func click(at point: HorizontalPoint) {
        if from == nil || to != nil {
            from = point
            to = nil
        } else {
            to = point
        }
        cursor = point
    }

    /// The pointer moved; true when that changes what shows.
    @discardableResult
    mutating func move(to point: HorizontalPoint?) -> Bool {
        guard cursor != point else {
            return false
        }
        cursor = point
        return to == nil
    }

    /// What is measured: from the first point to the second, or to the
    /// cursor while the second is to come.
    var measurement: BoardMeasurement? {
        guard let from, let end = to ?? cursor else {
            return nil
        }
        return BoardMeasurement(from: from, to: end)
    }

    /// What the canvas's readout says.
    var statusText: String {
        guard let measurement else {
            return "Measure: click the first point   Esc leaves the tool"
        }
        let next = to == nil ? "click the second point" : "click to measure again"
        return "Measure: \(measurement.text)   \(next)   Esc leaves the tool"
    }
}
