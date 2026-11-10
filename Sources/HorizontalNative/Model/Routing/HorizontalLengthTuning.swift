import Foundation

/// Horizon's Length Tuning window (TuningWindow): nets to compare, each
/// measured over the tracks it was added with or, with All tracks, over every
/// track on it; one row the reference the others are measured against, and
/// its length the target a tuning tool lengthens to. Lengths are given as
/// delays too, at the velocity factor set (εr is the same thing put the other
/// way, vf = 1/√εr).
///
/// Like Horizon's, the list lives as long as the document is open and isn't
/// saved; the lengths are worked out afresh from the board whenever it
/// changes.
struct HorizontalLengthTuning: Equatable {
    struct Row: Identifiable, Equatable {
        var id = UUID()
        var netID: String
        /// The tracks it was added with, by lowercased id.
        var trackIDs: Set<String>
        /// Measure every track on the net, not only those it was added with.
        var allTracks: Bool
    }

    /// One row measured on the board as it stands.
    struct Measurement: Identifiable, Equatable {
        var id: UUID
        var netID: String
        var netName: String
        var allTracks: Bool
        var isReference: Bool
        /// Nanometres, and the time a signal takes along it.
        var length: Double
        var delayPicoseconds: Double
        /// Against the reference row, when one is chosen: length and delay.
        var lengthDelta: Double?
        var delayDeltaPicoseconds: Double?
        /// Its length over the longest row's, 0 to 1, for the row's bar.
        var fraction: Double
        /// The net's diff pair partner, when it has one.
        var partnerID: String?
    }

    /// Horizon's spin button runs from 22% to 100%, εr from 1 to 20.
    static let velocityFactorRange: ClosedRange<Double> = 0.22...1
    static let relativePermittivityRange: ClosedRange<Double> = 1...20
    /// The speed of light Horizon's window uses, in metres a second.
    static let speedOfLight = 299.79e6

    var rows: [Row] = []
    var referenceRowID: UUID?
    var velocityFactor: Double = 1

    /// εr for the velocity factor: vf = 1/√εr.
    var relativePermittivity: Double {
        get { 1 / (velocityFactor * velocityFactor) }
        set { velocityFactor = (1 / max(newValue, 1e-9).squareRoot()).clamped(to: Self.velocityFactorRange) }
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Horizon's Measure Track and Measure All Tracks: one row for each net
    /// the tracks are on, with those tracks; a track on no net is left out.
    /// A net already listed gets a row of its own again, as there.
    mutating func add(tracks: [HorizontalSegment], allTracks: Bool) {
        var byNet = [String: Set<String>]()
        for track in tracks {
            guard let netID = track.netID?.lowercased() else { continue }
            byNet[netID, default: []].insert(track.id.lowercased())
        }
        for (netID, trackIDs) in byNet.sorted(by: { $0.key < $1.key }) {
            rows.append(Row(netID: netID, trackIDs: trackIDs, allTracks: allTracks))
        }
    }

    mutating func remove(_ ids: Set<UUID>) {
        rows.removeAll { ids.contains($0.id) }
        if let referenceRowID, ids.contains(referenceRowID) {
            self.referenceRowID = nil
        }
    }

    mutating func clear() {
        rows.removeAll()
        referenceRowID = nil
    }

    /// Picks the reference, or takes it away given the one it is.
    mutating func toggleReference(_ id: UUID) {
        referenceRowID = referenceRowID == id ? nil : id
    }

    /// A signal's time along `length` nanometres at the velocity factor.
    func delayPicoseconds(_ length: Double) -> Double {
        (length / 1e9) / (Self.speedOfLight * velocityFactor) * 1e12
    }

    /// The reference row's length, the target a tuning tool takes; nil with
    /// no reference (Horizon's 0).
    func referenceLength(on tracks: [HorizontalSegment]) -> Double? {
        guard let reference = rows.first(where: { $0.id == referenceRowID }) else { return nil }
        return length(of: reference, on: tracks)
    }

    func length(of row: Row, on tracks: [HorizontalSegment]) -> Double {
        if row.allTracks {
            return HorizontalTrackLength.routedLength(ofNet: row.netID, in: tracks)
        }
        // A track deleted since counts for nothing, as in Horizon.
        return tracks.reduce(0) { total, track in
            row.trackIDs.contains(track.id.lowercased()) ? total + HorizontalTrackLength.length(of: track) : total
        }
    }

    /// Every row measured, sorted by net name as Horizon's list is.
    func measurements(tracks: [HorizontalSegment], netDetails: [String: HorizontalNetDetails]) -> [Measurement] {
        let lengths = rows.map { length(of: $0, on: tracks) }
        let longest = lengths.max() ?? 0
        let reference = rows.firstIndex { $0.id == referenceRowID }.map { lengths[$0] }
        var result = zip(rows, lengths).map { row, length -> Measurement in
            let detail = netDetails[row.netID]
            let name = detail.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? String(row.netID.prefix(8))
            return Measurement(
                id: row.id,
                netID: row.netID,
                netName: name,
                allTracks: row.allTracks,
                isReference: row.id == referenceRowID,
                length: length,
                delayPicoseconds: delayPicoseconds(length),
                lengthDelta: reference.map { length - $0 },
                delayDeltaPicoseconds: reference.map { delayPicoseconds(length) - delayPicoseconds($0) },
                fraction: longest > 0 ? length / longest : 0,
                partnerID: detail?.diffpairID
            )
        }
        result.sort { lhs, rhs in
            let order = lhs.netName.localizedStandardCompare(rhs.netName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            // Names Finder's order finds the same by their characters, and
            // rows of one net in the order they were added.
            if lhs.netName != rhs.netName {
                return lhs.netName < rhs.netName
            }
            return (rows.firstIndex { $0.id == lhs.id } ?? 0) < (rows.firstIndex { $0.id == rhs.id } ?? 0)
        }
        return result
    }
}
