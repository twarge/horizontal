import Foundation

/// The vias a board pins to a net (Horizon's `net_set`), each sorted by
/// what taking its pin off would do.
///
/// A via with no pin takes the net of the copper it joins, its tracks and
/// through them their pads, and follows that copper when the schematic moves
/// its pads to another net. A pinned via holds its net itself and stands on
/// it alone, as a stitching via must. Horizontal used to pin every via it
/// made for a route, so a board it routed has many vias pinned to the very
/// net their pads give them, which then stay behind when a rail moves.
///
/// Horizon's own Place Via pins too, so the file alone can't tell a via
/// pinned by mistake from one the user pinned. Taking pins off is therefore
/// the user's to ask for, and only on a via whose pin changes nothing: its
/// copper, with no pin on it, reaches pads of one net, and that net is the
/// pin. Everything else keeps its pin, and a pin on another net than its
/// pads' is a conflict to report, not to change.
enum HorizontalPinnedVias {
    enum Kind: String, CaseIterable, Sendable {
        /// Its pin is the one net its pads give its copper: unpinned, it
        /// takes that net from its tracks, and follows them to another.
        case follows
        /// Pinned to a net other than the one its pads give its copper.
        case conflict
        /// No track reaches it: a stitching via, whose pin is all the net it
        /// has.
        case stitching
        /// Its tracks reach no pad on a net, so its pin is all that gives
        /// them one.
        case noPad = "no_pad"
        /// Its copper joins several nets, which is a short already: pads of
        /// several, or one and another via pinned to another.
        case short
    }

    struct Via: Equatable, Sendable {
        var id: String
        var position: HorizontalPoint
        /// The net pinned on it, lowercased.
        var pin: String
        var kind: Kind
        /// The nets the pads its copper reaches give it, with no via's pin
        /// counted, lowercased.
        var padNets: Set<String>
        /// The nets other vias on its copper pin, where they aren't its own.
        var otherPins: Set<String>
    }

    struct Review: Equatable, Sendable {
        /// Every pinned via, in the board's order.
        var vias: [Via]

        /// The vias whose pin can come off.
        var following: [Via] { vias.filter { $0.kind == .follows } }
        var conflicts: [Via] { vias.filter { $0.kind == .conflict } }

        func count(_ kind: Kind) -> Int {
            vias.lazy.filter { $0.kind == kind }.count
        }
    }

    /// Each via `board` pins to a net, with what taking the pin off would do.
    static func review(_ board: HorizontalBoard) -> Review {
        let pinned = board.vias.filter { $0.netSetID != nil }
        guard !pinned.isEmpty else {
            return Review(vias: [])
        }
        let runs = HorizontalBoardConnectivity.viaRuns(in: board)
        return Review(vias: pinned.compactMap { via -> Via? in
            guard let pin = via.netSetID.map(normalized) else {
                return nil
            }
            let id = normalized(via.id)
            let run = runs[id]
            let padNets = run?.padNets ?? []
            var otherPins = Set((run?.pins ?? [:]).filter { $0.key != id }.map(\.value))
            otherPins.remove(pin)
            return Via(id: via.id, position: via.position, pin: pin,
                       kind: kind(pin: pin, trackCount: run?.trackCount ?? 0, padNets: padNets, otherPins: otherPins),
                       padNets: padNets, otherPins: otherPins)
        })
    }

    /// What taking `pin` off a via does, from the copper it is part of.
    private static func kind(pin: String, trackCount: Int, padNets: Set<String>, otherPins: Set<String>) -> Kind {
        guard trackCount > 0 else {
            return .stitching
        }
        guard let padNet = padNets.first else {
            return .noPad
        }
        guard padNets.count == 1 else {
            return .short
        }
        guard padNet == pin else {
            return .conflict
        }
        // Its pin matches, but another via pins this copper to another net:
        // unpinned, the via would take the short's no net, not its pads'.
        // It can follow once that conflict is settled.
        return otherPins.isEmpty ? .follows : .short
    }

    private static func normalized(_ id: String) -> String { id.lowercased() }
}
