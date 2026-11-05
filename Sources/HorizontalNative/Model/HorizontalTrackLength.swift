import Foundation

/// The lengths Horizon's board reads off its tracks: a straight track from
/// end to end, an arc along its circle, radius times the angle it sweeps
/// (Track::get_length), where `HorizontalSegment.length` sums a 48-chord
/// polyline that falls short of an arc, by a part in twenty thousand on a
/// quarter circle and one in five thousand on a half. That is noise on a
/// drawing and a whole tolerance on a length match, so what is measured for
/// tuning goes through here.
enum HorizontalTrackLength {
    /// A track's length, its arc's exactly.
    static func length(of track: HorizontalSegment) -> Double {
        guard let center = track.center else {
            return hypot(track.to.x - track.from.x, track.to.y - track.from.y)
        }
        return arcLength(from: track.from, to: track.to, centerHint: center, reverse: track.reverse)
    }

    /// An arc's length along the circle its drawing follows: the centre
    /// projected onto the ends' bisector and the sweep from start to end,
    /// anticlockwise unless `reverse`, as `horizonArcPolyline` draws it.
    static func arcLength(from start: HorizontalPoint, to end: HorizontalPoint,
                          centerHint: HorizontalPoint, reverse: Bool) -> Double {
        let center = projectOntoPerpendicularBisector(start, end, centerHint)
        let radius = hypot(start.x - center.x, start.y - center.y)
        guard radius > 0 else {
            return hypot(end.x - start.x, end.y - start.y)
        }
        let a0 = atan2(start.y - center.y, start.x - center.x)
        let a1 = atan2(end.y - center.y, end.x - center.x)
        var sweep = (a1 - a0).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 {
            sweep += 2 * .pi
        }
        if reverse {
            sweep = 2 * .pi - sweep
        }
        return radius * sweep
    }

    /// The length of a net's copper on the board: every track on it, as
    /// Horizon's tuning window adds a net's "all tracks". Vias and pads add
    /// nothing, as there.
    static func routedLength(ofNet netID: String, in tracks: [HorizontalSegment]) -> Double {
        let netID = netID.lowercased()
        return tracks.reduce(0) { total, track in
            track.netID?.lowercased() == netID ? total + length(of: track) : total
        }
    }

    /// Every net's routed length at once, by lowercased net id.
    static func routedLengths(_ tracks: [HorizontalSegment]) -> [String: Double] {
        tracks.reduce(into: [String: Double]()) { lengths, track in
            guard let netID = track.netID?.lowercased() else { return }
            lengths[netID, default: 0] += length(of: track)
        }
    }

    /// Horizon's HUD spacing between two straight tracks running parallel:
    /// the distance between their centrelines (the cross product of the
    /// first's direction with the step to the second's start), as a
    /// magnitude. Nil for an arc, a track of no length, or two that aren't
    /// parallel (Track::is_parallel_to).
    static func spacing(_ first: HorizontalSegment, _ second: HorizontalSegment) -> Double? {
        guard first.center == nil, second.center == nil else { return nil }
        let u = HorizontalPoint(x: first.to.x - first.from.x, y: first.to.y - first.from.y)
        let v = HorizontalPoint(x: second.to.x - second.from.x, y: second.to.y - second.from.y)
        let lengthU = hypot(u.x, u.y)
        guard lengthU > 0, hypot(v.x, v.y) > 0 else { return nil }
        // Integer nanometres: parallel means a cross product of zero, which a
        // track at an odd angle reaches only within rounding.
        let cross = u.x * v.y - u.y * v.x
        guard abs(cross) <= 1e-6 * lengthU * hypot(v.x, v.y) else { return nil }
        let w = HorizontalPoint(x: second.from.x - first.from.x, y: second.from.y - first.from.y)
        return abs(u.x * w.y - u.y * w.x) / lengthU
    }
}

/// What the board inspector says of the selected tracks, Horizon's track
/// HUD (ImpBoard::get_hud_text): how many, on which layers, their total
/// length and, for two running parallel, the spacing between them; with the
/// routed length of their net when they are all on one, and that net's skew
/// against its diff pair partner.
struct HorizontalTrackSelectionSummary: Equatable {
    var count: Int
    var layers: [Int]
    var totalLength: Double
    /// Centreline to centreline, for exactly two parallel tracks.
    var spacing: Double?
    /// Copper to copper: the spacing less half of each width, which is what a
    /// diff pair rule's track gap asks for.
    var gap: Double?
    var netIDs: Set<String>
    /// The one net's every track, when the selection is on one net.
    var netRoutedLength: Double?
    /// That net's partner and its routed length, when it is in a pair.
    var partnerID: String?
    var partnerRoutedLength: Double?

    /// The net's length less its partner's: what a skew tune takes out.
    var pairSkew: Double? {
        guard let netRoutedLength, let partnerRoutedLength else { return nil }
        return netRoutedLength - partnerRoutedLength
    }

    /// The group buttons that add the tracks to the Length Tuning window,
    /// Horizon's Measure Track and Measure All Tracks.
    static let measureActionID = "measureTracks"
    static let measureAllActionID = "measureAllTracks"
    static let measureActions = [
        HorizontalSelectionPropertyOption(id: measureActionID, title: "Measure"),
        HorizontalSelectionPropertyOption(id: measureAllActionID, title: "Measure All"),
    ]

    /// Whether a property change is Measure (false) or Measure All (true);
    /// nil for any other.
    static func measuresAllTracks(_ propertyID: String) -> Bool? {
        switch propertyID {
        case measureActionID: false
        case measureAllActionID: true
        default: nil
        }
    }

    /// The inspector's rows, under the track group's heading. What a single
    /// track's own rows already say (its length and layer) is left to them.
    func details(layerName: (Int) -> String?, netName: (String) -> String) -> [HorizontalSelectionHUDDetail] {
        var rows = [HorizontalSelectionHUDDetail]()
        if count > 1 {
            let names = layers.compactMap(layerName)
            if !names.isEmpty {
                rows.append(HorizontalSelectionHUDDetail(label: "Layers", value: names.joined(separator: ", ")))
            }
            rows.append(HorizontalSelectionHUDDetail(label: "Total length", value: HorizontalLengthText.millimetres(totalLength)))
        }
        if let spacing {
            rows.append(HorizontalSelectionHUDDetail(label: "Spacing", value: HorizontalLengthText.millimetres(spacing)))
        }
        if let gap {
            rows.append(HorizontalSelectionHUDDetail(label: "Gap", value: HorizontalLengthText.millimetres(gap)))
        }
        if let netRoutedLength {
            rows.append(HorizontalSelectionHUDDetail(label: "Net length", value: HorizontalLengthText.millimetres(netRoutedLength)))
        } else if netIDs.count > 1 {
            rows.append(HorizontalSelectionHUDDetail(label: "Nets", value: netIDs.count.formatted()))
        }
        if let pairSkew, let partnerID {
            rows.append(HorizontalSelectionHUDDetail(
                label: "Pair skew",
                value: "\(HorizontalLengthText.millimetres(pairSkew, signed: true)) vs \(netName(partnerID))"
            ))
        }
        return rows
    }

    init?(selected: [HorizontalSegment], board tracks: [HorizontalSegment], netDetails: [String: HorizontalNetDetails]) {
        guard !selected.isEmpty else { return nil }
        count = selected.count
        layers = Array(Set(selected.compactMap(\.layer))).sorted()
        totalLength = selected.reduce(0) { $0 + HorizontalTrackLength.length(of: $1) }
        if selected.count == 2, let spacing = HorizontalTrackLength.spacing(selected[0], selected[1]) {
            self.spacing = spacing
            gap = spacing - (selected[0].width + selected[1].width) / 2
        }
        netIDs = Set(selected.compactMap { $0.netID?.lowercased() })
        if netIDs.count == 1, selected.allSatisfy({ $0.netID != nil }), let netID = netIDs.first {
            netRoutedLength = HorizontalTrackLength.routedLength(ofNet: netID, in: tracks)
            if let partner = netDetails[netID]?.diffpairID {
                partnerID = partner
                partnerRoutedLength = HorizontalTrackLength.routedLength(ofNet: partner, in: tracks)
            }
        }
    }
}

/// Lengths as Horizon writes them out (dim_to_string): millimetres to the
/// micrometre, which a length match needs and the board's own two places
/// don't give.
enum HorizontalLengthText {
    static func millimetres(_ nanometres: Double, signed: Bool = false) -> String {
        let value = nanometres / 1_000_000
        let text = abs(value).formatted(.number.precision(.fractionLength(3)).grouping(.never)) + " mm"
        guard signed || value < 0 else { return text }
        // Horizon's minus, not a hyphen, and a plus for a signed positive.
        return (value < 0 && text != "0.000 mm" ? "\u{2212}" : (signed ? "+" : "")) + text
    }

    static func picoseconds(_ value: Double, signed: Bool = false) -> String {
        let text = abs(value).formatted(.number.precision(.fractionLength(3)).grouping(.never)) + " ps"
        guard signed || value < 0 else { return text }
        return (value < 0 && text != "0.000 ps" ? "\u{2212}" : (signed ? "+" : "")) + text
    }
}
