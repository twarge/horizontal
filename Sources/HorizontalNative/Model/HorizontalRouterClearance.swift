import Foundation

/// Resolves the clearance the router must honour between any two things on the
/// board.
///
/// This exists because the router's world snapshot collapsed every clearance to
/// a single track-to-track number evaluated on the top layer, which is wrong in
/// several ways that all produce the same symptom — copper closer than the rules
/// allow, reported by the router as a legal route:
///
///  * **Object class.** The rules distinguish eleven kinds of copper, and a
///    board may well clear a via or a pad differently from a track. Routing past
///    a pad with the track-to-track number under-clears whenever the pad's is
///    larger.
///  * **Layer.** Clearance rules can be scoped to a layer. Resolving them all on
///    top copper gives inner layers the wrong numbers.
///  * **Non-copper.** Board edge, unplated holes and text are not copper and are
///    governed by a different rule table entirely.
///  * **Keepouts** have their own table, keyed by keepout class.
///
/// Same-net copper needs no clearance, and that is decided here rather than by
/// the caller, so every path agrees. Net code −1 means "no net", and is
/// deliberately NOT treated as same-net: two unconnected pieces of copper are
/// not connected to each other, and letting them touch would be a short between
/// whatever they later join.
struct HorizontalRouterClearances {
    /// What a thing is, for clearance purposes. Mirrors the rule tables' own
    /// distinctions rather than the router's obstacle kinds, because it is the
    /// rules that decide which number applies.
    enum ObjectClass: Hashable {
        case track
        /// A pad with copper on one layer.
        case pad
        /// A pad whose copper reaches several layers — a different rule entry.
        case padThroughHole
        case via
        case plane
        case netTie
        /// Plated hole (a via's or a through-hole pad's barrel).
        case holePlated
        /// Unplated hole — a mounting hole. Not copper: governed by the
        /// copper-to-other table.
        case holeUnplated
        case text
        case boardEdge
        case keepout(String)

        /// The rule tables' own vocabulary.
        var patchType: HorizontalPatchType {
            switch self {
            case .track: .track
            case .pad: .pad
            case .padThroughHole: .padTH
            case .via: .via
            case .plane: .plane
            case .netTie: .netTie
            case .holePlated: .holePTH
            case .holeUnplated: .holeNPTH
            case .text: .text
            case .boardEdge: .boardEdge
            case .keepout: .other
            }
        }

        /// Whether this is copper. Copper-to-copper reads one table,
        /// copper-to-anything-else reads another.
        var isCopper: Bool {
            switch self {
            case .track, .pad, .padThroughHole, .via, .plane, .netTie, .holePlated: true
            case .holeUnplated, .text, .boardEdge, .keepout: false
            }
        }
    }

    private let rules: HorizontalBoardRules
    private let netIDForCode: [Int: String]

    init(rules: HorizontalBoardRules, netIDForCode: [Int: String]) {
        self.rules = rules
        self.netIDForCode = netIDForCode
    }

    init(world: HorizontalRouterWorld, rules: HorizontalBoardRules) {
        self.init(rules: rules, netIDForCode: world.netIDForCode)
    }

    private func netID(_ code: Int) -> String? {
        code >= 0 ? netIDForCode[code] : nil
    }

    /// The clearance required between two objects, in board nanometres.
    ///
    /// Order does not matter: the rules are symmetric in the pair, and this
    /// enforces that rather than trusting each caller to pass them the same way
    /// round.
    func clearance(
        _ a: ObjectClass, net aNet: Int,
        _ b: ObjectClass, net bNet: Int,
        on layer: Int
    ) -> Double {
        // Copper of one net may touch itself. Checked before anything else so a
        // track can always reach its own pad.
        if a.isCopper, b.isCopper, aNet >= 0, aNet == bNet {
            return 0
        }

        // A keepout carries its own table, keyed by class rather than by net.
        if case .keepout(let keepoutClass) = a {
            return Double(rules
                .clearanceCopperKeepout(net: netID(bNet), keepoutClass: keepoutClass)
                .clearance(b.patchType))
        }
        if case .keepout(let keepoutClass) = b {
            return Double(rules
                .clearanceCopperKeepout(net: netID(aNet), keepoutClass: keepoutClass)
                .clearance(a.patchType))
        }

        switch (a.isCopper, b.isCopper) {
        case (true, true):
            return Double(rules
                .clearanceCopper(net1: netID(aNet), net2: netID(bNet), layer: layer)
                .clearance(a.patchType, b.patchType))
        case (true, false):
            return Double(rules
                .clearanceCopperOther(net: netID(aNet), layer: layer)
                .clearance(copper: a.patchType, nonCopper: b.patchType))
        case (false, true):
            return Double(rules
                .clearanceCopperOther(net: netID(bNet), layer: layer)
                .clearance(copper: b.patchType, nonCopper: a.patchType))
        case (false, false):
            // Neither is copper, so no copper rule governs the pair and the
            // router has no business keeping them apart.
            return 0
        }
    }

    /// The largest clearance any object on `layer` could require of a track on
    /// `net` — the radius for the router's BROAD phase.
    ///
    /// The index is queried with a hull inflated by this, which is conservative:
    /// it can offer obstacles that turn out to be far enough away. Each candidate
    /// is then tested with its own exact clearance. Inflating by the exact
    /// clearance instead would need a different query per obstacle, and
    /// inflating by one shared number and stopping there would over-clear —
    /// refusing legal routes rather than allowing illegal ones, but refusing all
    /// the same.
    func broadPhaseClearance(forTrackOn net: Int, layer: Int) -> Double {
        var widest = 0.0
        for other in ObjectClass.allBroadPhaseCases {
            // Against every net, because a rule may single one out. Net −1 is
            // included: no-net copper still has to be cleared.
            for code in ([-1] + Array(netIDForCode.keys)) {
                widest = max(widest, clearance(.track, net: net, other, net: code, on: layer))
            }
        }
        return widest
    }
}

extension HorizontalRouterClearances.ObjectClass {
    /// Every class the broad phase has to consider. Keepouts are excluded
    /// because their clearance is keyed by a class name the caller knows and
    /// this does not; a board using them must widen the broad phase itself.
    static let allBroadPhaseCases: [Self] = [
        .track, .pad, .padThroughHole, .via, .plane, .netTie,
        .holePlated, .holeUnplated, .text, .boardEdge,
    ]
}
