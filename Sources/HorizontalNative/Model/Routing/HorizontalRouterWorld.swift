import Foundation

/// A flat, Swift-owned snapshot of the board's copper "world" plus a precomputed
/// net×net clearance matrix: everything an interactive router has to reason
/// about, with none of the board model's identity, styling or view state.
///
/// It was built as the seam to a vendored router that has since been removed,
/// and it outlived it deliberately — nothing here is specific to any engine.
/// Extracting the world is most of the work of routing, and this is the input
/// any future router takes. See `docs/push-shove-router.md`.
///
/// Coordinates are board nanometres; layers are Horizontal's copper layer ints
/// (top = 0, inner −1…−8, bottom = −100). Net codes are dense indices assigned
/// here (−1 == no net); the inverse maps let routed results be mapped back to
/// the board's own ids.
struct HorizontalRouterWorld: Equatable {
    /// An existing copper track obstacle. `center != nil` marks an arc.
    struct Track: Equatable {
        var id: Int64
        var from: HorizontalPoint
        var to: HorizontalPoint
        var center: HorizontalPoint?
        var width: Double
        var layer: Int
        var netCode: Int
        var locked: Bool
    }

    /// A pad as an explicit copper polygon spanning [layerMin, layerMax]
    /// (layerMin is the more-negative / bottom-most copper layer).
    struct Solid: Equatable {
        var points: [HorizontalPoint]
        var layerMin: Int
        var layerMax: Int
        var netCode: Int
    }

    struct Via: Equatable {
        var id: Int64
        var pos: HorizontalPoint
        var layerStart: Int // top-most (max horizon layer)
        var layerEnd: Int   // bottom-most (min horizon layer)
        var diameter: Double
        var drill: Double
        var netCode: Int
    }

    /// Board outline / keepout boundary; replicated as locked obstacles on every
    /// copper layer by the adapter.
    struct Contour: Equatable {
        var points: [HorizontalPoint]
        var closed: Bool
    }

    /// An unplated hole — a mounting hole. Not copper, and not on any net, so it
    /// is governed by the copper-to-other rules and can never be same-net with
    /// anything. Routing through one is a drilled-away track.
    struct UnplatedHole: Equatable {
        var position: HorizontalPoint
        var diameter: Double
    }

    /// A keepout region. `keepoutClass` selects its clearance rule, and
    /// `copperPatchTypes` says which kinds of copper it actually excludes — a
    /// keepout may bar planes but permit tracks.
    struct Keepout: Equatable {
        var points: [HorizontalPoint]
        var layerMin: Int
        var layerMax: Int
        var keepoutClass: String
        var copperPatchTypes: [String]
    }

    var tracks: [Track] = []
    var solids: [Solid] = []
    var vias: [Via] = []
    var contours: [Contour] = []
    var unplatedHoles: [UnplatedHole] = []
    var keepouts: [Keepout] = []
    var copperLayerCount: Int = 2

    var netCount: Int = 0
    /// Row-major [a*netCount + b] track-to-track clearance in nm.
    ///
    /// SUPERSEDED for routing by `HorizontalRouterClearances`, and kept only
    /// because it is part of this snapshot's shape. It is track-to-track on ONE
    /// layer, which is wrong in three ways for a router: the rules give vias,
    /// pads and planes their own numbers, they can be scoped per layer, and
    /// non-copper (board edge, unplated holes) lives in a different table
    /// entirely. Reading this where a real clearance is needed under-clears
    /// silently. Ask the resolver.
    var clearanceTable: [Int64] = []
    var defaultClearance: Int64 = Int64(HorizontalRuleClearanceCopper.defaultClearance)
    var edgeClearance: Int64 = Int64(HorizontalRuleClearanceCopper.defaultClearance)

    /// Maps router track/via ids back to Horizon object ids for commit.
    var segmentIDForTrackID: [Int64: String] = [:]
    var markerIDForViaID: [Int64: String] = [:]
    /// Dense net code ↔ normalized Horizon net id.
    var netIDForCode: [Int: String] = [:]
    var codeForNetID: [String: Int] = [:]

    /// Dense net code for a (possibly nil) Horizon net id, or −1 for no net.
    func netCode(for netID: String?) -> Int {
        guard let netID else { return -1 }
        return codeForNetID[HorizontalCanvasModeSupport.normalizedID(netID)] ?? -1
    }
}

extension HorizontalRouterWorld {
    /// Builds the router world from a board snapshot. `clearanceLayer` is the
    /// copper layer the net×net clearance matrix is evaluated on (copper
    /// clearance is layer-independent on most boards); defaults to top copper.
    static func extract(
        from board: HorizontalBoard,
        clearanceLayer: Int = HorizontalBoardLayers.topCopper
    ) -> HorizontalRouterWorld {
        var world = HorizontalRouterWorld()
        world.copperLayerCount = max(board.copperLayerCount, 2)

        // --- Net codes -------------------------------------------------------
        // Dense, deterministic codes over every net id the world references.
        var netIDs = Set(board.netDetails.keys.map(HorizontalCanvasModeSupport.normalizedID))
        for track in board.tracks { if let n = track.netID { netIDs.insert(HorizontalCanvasModeSupport.normalizedID(n)) } }
        for via in board.vias { if let n = via.netID { netIDs.insert(HorizontalCanvasModeSupport.normalizedID(n)) } }
        for pad in board.packagePads { if let n = pad.netID { netIDs.insert(HorizontalCanvasModeSupport.normalizedID(n)) } }
        let sortedNetIDs = netIDs.sorted()
        for (index, netID) in sortedNetIDs.enumerated() {
            world.codeForNetID[netID] = index
            world.netIDForCode[index] = netID
        }
        world.netCount = sortedNetIDs.count

        // --- Clearance matrix ------------------------------------------------
        // names() preserves the dense ordering so the matrix is row-major.
        let names = (0 ..< world.netCount).map { world.netIDForCode[$0] }
        var table = [Int64](repeating: world.defaultClearance, count: world.netCount * world.netCount)
        for a in 0 ..< world.netCount {
            for b in a ..< world.netCount {
                let rule = board.rules.clearanceCopper(net1: names[a], net2: names[b], layer: clearanceLayer)
                let value = Int64(rule.clearance(.track, .track))
                table[a * world.netCount + b] = value
                table[b * world.netCount + a] = value
            }
        }
        world.clearanceTable = table
        world.edgeClearance = Int64(
            board.rules
                .clearanceCopperOther(net: nil, layer: clearanceLayer)
                .clearance(copper: .track, nonCopper: .boardEdge)
        )

        // --- Tracks ----------------------------------------------------------
        var nextTrackID: Int64 = 1
        for track in board.tracks {
            guard let layer = track.layer, HorizontalBoardLayers.isCopper(layer), track.width > 0 else { continue }
            let id = nextTrackID
            nextTrackID += 1
            world.segmentIDForTrackID[id] = track.id
            world.tracks.append(Track(
                id: id,
                from: track.from,
                to: track.to,
                center: track.center,
                width: track.width,
                layer: layer,
                netCode: world.netCode(for: track.netID),
                locked: false
            ))
        }

        // --- Pads (as copper polygons) --------------------------------------
        for pad in board.packagePads {
            let points = pad.renderVertices(arcPrecision: 24)
            guard points.count >= 3 else { continue }
            let layerMin: Int
            let layerMax: Int
            if let layer = pad.layer {
                guard HorizontalBoardLayers.isCopper(layer) else { continue }
                layerMin = layer
                layerMax = layer
            } else {
                // Layer-agnostic pad → through-hole copper on all layers.
                layerMin = HorizontalBoardLayers.bottomCopper
                layerMax = HorizontalBoardLayers.topCopper
            }
            world.solids.append(Solid(
                points: points,
                layerMin: layerMin,
                layerMax: layerMax,
                netCode: world.netCode(for: pad.netID)
            ))
        }

        // --- Vias ------------------------------------------------------------
        var nextViaID: Int64 = 1
        for via in board.vias {
            let layers = via.connectedLayers.isEmpty
                ? BoardTrackRouting.throughViaLayers(copperLayerCount: world.copperLayerCount)
                : via.connectedLayers
            guard let top = layers.max(), let bottom = layers.min() else { continue }
            let id = nextViaID
            nextViaID += 1
            world.markerIDForViaID[id] = via.id
            world.vias.append(Via(
                id: id,
                pos: via.position,
                layerStart: top,
                layerEnd: bottom,
                diameter: via.size,
                drill: via.holeSize ?? (via.size * 0.5),
                netCode: world.netCode(for: via.netID)
            ))
        }

        // --- Unplated holes --------------------------------------------------
        // Board-level and package-level both: a mounting hole drilled through a
        // track removes the track, so the router has to see it whichever object
        // owns it. Plated holes are already covered by their via or pad.
        for hole in board.holes + board.packageHoles where !hole.plated {
            world.unplatedHoles.append(UnplatedHole(
                position: hole.position,
                // A slot's clearance is taken from its longer dimension, which
                // over-covers a round hole by nothing and a slot conservatively.
                diameter: max(hole.diameter, hole.effectiveLength)
            ))
        }

        // --- Keepouts ---------------------------------------------------------
        for keepout in board.keepouts {
            let points = keepout.polygon.renderVertices(arcPrecision: 24)
            guard points.count >= 3 else { continue }
            // `allCopperLayers` keepouts span the stackup; otherwise the polygon's
            // own layer is the only one it applies to.
            let layerMin = keepout.allCopperLayers
                ? HorizontalBoardLayers.bottomCopper
                : (keepout.polygon.layer ?? HorizontalBoardLayers.topCopper)
            let layerMax = keepout.allCopperLayers
                ? HorizontalBoardLayers.topCopper
                : (keepout.polygon.layer ?? HorizontalBoardLayers.topCopper)
            world.keepouts.append(Keepout(
                points: points,
                layerMin: min(layerMin, layerMax),
                layerMax: max(layerMin, layerMax),
                keepoutClass: keepout.keepoutClass,
                copperPatchTypes: keepout.copperPatchTypes
            ))
        }

        // --- Board outline ---------------------------------------------------
        for polygon in board.polygons where polygon.layer == HorizontalBoardLayers.outline {
            let points = polygon.renderVertices(arcPrecision: 24)
            guard points.count >= 2 else { continue }
            world.contours.append(Contour(points: points, closed: true))
        }

        return world
    }
}
