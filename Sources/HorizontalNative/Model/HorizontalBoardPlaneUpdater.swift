import Foundation
import HorizontalPlaneClipper

// Copper-pour generation. The heavy Clipper work runs in the C++ bridge
// (HorizontalClipperBuildPlaneFillEx, which documents the pour pipeline); Swift
// owns rule lookups, obstacle classification and the bbox prefilter,
// board-outline collection, thermal-pad inputs, the priority tier loop, and
// orphan classification.
//
// The pour must match what the board's own tooling would fabricate: a fill that
// differs is not a cosmetic difference but a different board.

// Known simplifications vs the reference (acceptable for a viewer; revisit if the
// pours visibly diverge on real boards):
//  • Per-pad thermal overrides (RuleThermals) are resolved per pad by net, pad
//  UUID, and layer, but component matching uses the board-package instance
//  UUID (all the pad id carries), not the schematic component/part UUID — so
//  rules scoped to a specific component/part won't match in the viewer.
//  • Through-hole package pads use the PAD (not PAD_TH) copper clearance. In the
//  default rule set these are identical; only boards that distinguish them are
//  affected.
//  • Thermal spoke placement uses the pad's center+angle (from its padstack
//  frame) but not its mirror flag, so bottom-side pads with non-symmetric
//  spoke counts/angles may have wrong spoke handedness. 4-spoke (the default)
//  is mirror-symmetric, so the common case is unaffected.
//  • Orphan classification anchors junctions by net only (no layer-overlap test)
//  and pads by net+layer (no THROUGH/TOP/BOTTOM padstack-side test), because
//  the viewer model doesn't carry junction layer spans or padstack types.
enum HorizontalBoardPlaneUpdater {
    private static let twiddle = 5_000.0
    private static let keepoutExtra = 50_000.0
    private static let boardOutlineArcTolerance = 10_000.0
    private static let normalArcTolerance = 2_000.0
    private static let fragmentArcPrecision = 48

    /// A plane already poured in an earlier (higher-priority) tier, kept as an
    /// obstacle for later tiers.
    ///
    /// This is the plane's POURED COPPER, not the outline it was poured from —
    /// see the tier loop for why the distinction changes the result.
    struct PlaneObstacle: Hashable {
        var path: [HorizontalPoint]
        var netID: String?
        var layer: Int
    }

    /// Pours every plane on the board.
    ///
    /// `onProgress` reports `(completed, total)` after each individual plane, so
    /// a caller running this off the main thread can drive a determinate
    /// indicator. It is called from whatever thread the pour runs on, once per
    /// plane — a plane is the only granularity available, since a single plane's
    /// clipping is one opaque call into the clipper.
    static func updateAllPlanes(
        in board: HorizontalBoard,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> HorizontalBoard {
        updateAllPlanes(in: board, cache: HorizontalPlanePourCache(), onProgress: onProgress).board
    }

    /// Pours every plane, reusing `cache` for any whose inputs are unchanged.
    ///
    /// Returns the poured board and the cache to hand back next time. Skipping
    /// is per PLANE rather than per layer: two planes can share a layer and
    /// differ in priority, net or settings, and a layer is not the unit anything
    /// is poured in.
    static func updateAllPlanes(
        in board: HorizontalBoard,
        cache: HorizontalPlanePourCache,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> (board: HorizontalBoard, cache: HorizontalPlanePourCache) {
        // Priority decides which plane yields to which where two would overlap,
        // so it has to be an ordering and not a preference: pour ascending, and
        // each tier's copper becomes an obstacle the next must clear. Two planes
        // at the SAME priority never see each other, which is what lets a tier
        // pour concurrently below.
        let byPriority = Dictionary(grouping: board.planes, by: { $0.priority })
        let priorities = byPriority.keys.sorted()

        var resultByID = [String: HorizontalPlane]()
        var accumulatedPlaneObstacles = [PlaneObstacle]()
        var updatedCache = cache
        updatedCache.retain(planeIDs: Set(board.planes.map(\.id)))
        let total = board.planes.count
        var completed = 0

        for priority in priorities {
            let tier = byPriority[priority] ?? []
            let completedBeforeTier = completed
            // One plane of this tier: reuse its fill, or pour it. Reads only
            // `board`, `cache` and the obstacles accumulated by EARLIER tiers,
            // and writes nothing shared — which is what makes the tier
            // parallelisable below.
            let obstacles = accumulatedPlaneObstacles
            let pourOne: @Sendable (HorizontalPlane) -> (plane: HorizontalPlane, signature: Int) = { plane in
                // The obstacles matter to the fingerprint: an earlier tier's
                // fill is an input to this one, so a plane can need re-pouring
                // because a higher-priority plane above it moved, with nothing
                // else on the board having changed.
                let signature = planeInputSignature(
                    for: plane, in: board, planeObstacles: obstacles)
                if let reused = cache.fragments(for: plane.id, signature: signature) {
                    var unchanged = plane
                    unchanged.fragments = reused
                    return (unchanged, signature)
                }
                return (update(plane, in: board, planeObstacles: obstacles), signature)
            }

            // Planes within a tier are independent, so pour them concurrently.
            // Results are collected BY INDEX and consumed in tier order, so the
            // board that comes out does not depend on which thread finished
            // first — the fill has to be reproducible, not merely correct.
            //
            // Tiers themselves stay sequential: each one's fills are obstacles
            // for the next.
            let outcomes: [(plane: HorizontalPlane, signature: Int)]
            if tier.count > 1 {
                let collector = PlaneTierResults(count: tier.count)
                DispatchQueue.concurrentPerform(iterations: tier.count) { index in
                    collector.store(pourOne(tier[index]), at: index)
                    // Progress is reported as planes finish, so the count is
                    // ordered by completion even though the results are not.
                    collector.reportCompletion(onProgress, total: total, base: completedBeforeTier)
                }
                outcomes = collector.ordered()
            } else {
                outcomes = tier.map { plane in
                    let outcome = pourOne(plane)
                    completed += 1
                    onProgress?(completed, total)
                    return outcome
                }
            }
            if tier.count > 1 {
                completed += tier.count
            }
            for outcome in outcomes {
                updatedCache.store(
                    planeID: outcome.plane.id,
                    signature: outcome.signature,
                    fragments: outcome.plane.fragments)
            }
            let poured = outcomes.map(\.plane)
            for plane in poured {
                resultByID[plane.id] = plane
            }
            // After the tier, each poured plane becomes an obstacle for the
            // tiers below it — as the copper it actually POURED, not as the
            // outline it was poured from.
            //
            // The difference is not subtle. A plane's outline is where it was
            // allowed to fill; its fragments are where it did. Everywhere the
            // earlier plane left empty — orphans it discarded, antipad rings,
            // regions its own clearances excluded — is copper-free board that a
            // lower-priority plane may legitimately claim. Using the outline
            // instead would reserve all of it for a plane that never filled it,
            // and the lower plane would pour with holes in it that correspond to
            // no copper on the finished board.
            //
            // Each fragment's outer contour is the obstacle; its holes are
            // already regions the earlier plane did not fill.
            for plane in poured {
                guard let layer = plane.layer else { continue }
                for fragment in plane.fragments {
                    guard let outer = fragment.paths.first, outer.count >= 3 else { continue }
                    accumulatedPlaneObstacles.append(
                        PlaneObstacle(path: outer, netID: plane.netID, layer: layer))
                }
            }
        }

        var updated = board
        updated.planes = board.planes.map { resultByID[$0.id] ?? zeroed($0) }
        return (updated, updatedCache)
    }

    /// A fingerprint of everything `update` reads while pouring ONE plane.
    ///
    /// Scoped by layer where the pour itself is: a plane only clips around
    /// copper on its own layer, so routing on the bottom cannot change a top
    /// fill. Vias and drill holes are deliberately NOT scoped — the pour reads
    /// them for every layer, because a hole goes through the board.
    ///
    /// Anything read but not hashed here becomes a fill that silently stops
    /// matching the board, so this errs towards including too much: the whole
    /// rule set, every junction, and every hole go in regardless of layer.
    static func planeInputSignature(
        for plane: HorizontalPlane,
        in board: HorizontalBoard,
        planeObstacles: [PlaneObstacle] = []
    ) -> Int {
        var hasher = Hasher()

        // The plane's own definition (its fill is the output, so not that).
        hasher.combine(plane.id)
        hasher.combine(plane.netID)
        hasher.combine(plane.polygonID)
        hasher.combine(plane.layer)
        hasher.combine(plane.priority)
        hasher.combine(plane.fillStyle)
        hasher.combine(plane.minWidth)
        hasher.combine(plane.keepOrphans)
        hasher.combine(plane.fallbackPolygon)
        hasher.combine(plane.fromRules)
        hasher.combine(plane.settings)

        // Clearances, thermals and plane settings all resolve through the rules.
        hasher.combine(board.rules)
        hasher.combine(board.netDetails)

        guard let layer = plane.layer else {
            return hasher.finalize()
        }

        // Copper on this plane's layer — plus the board outline, whatever layer
        // it is on, since the pour contracts to it.
        for polygon in board.polygons
        where polygon.layer == layer || polygon.layer == HorizontalBoardLayers.outline {
            hasher.combine(polygon)
        }
        for pad in board.packagePads where pad.layer == layer { hasher.combine(pad) }
        for track in board.tracks where track.layer == layer { hasher.combine(track) }
        for netTie in board.netTies where netTie.layer == layer { hasher.combine(netTie) }
        for line in board.lines where line.layer == layer { hasher.combine(line) }
        for text in board.texts where text.layer == layer { hasher.combine(text) }
        for text in board.packageTexts where text.layer == layer { hasher.combine(text) }
        for keepout in board.keepouts where keepout.applies(toCopperLayer: layer) {
            hasher.combine(keepout)
        }

        // Not layer-scoped: the pour reads every via and every hole whatever
        // layer it is pouring, and junctions anchor orphans by net alone.
        hasher.combine(board.vias)
        hasher.combine(board.viaHoles)
        hasher.combine(board.holes)
        hasher.combine(board.packageHoles)
        hasher.combine(board.junctions)
        hasher.combine(board.junctionNetIDs)

        // Fills poured by earlier tiers on this layer.
        for obstacle in planeObstacles where obstacle.layer == layer {
            hasher.combine(obstacle.path)
            hasher.combine(obstacle.netID)
        }

        return hasher.finalize()
    }

    private static func zeroed(_ plane: HorizontalPlane) -> HorizontalPlane {
        var plane = plane
        plane.fragments = []
        return plane
    }

    private static func update(
        _ plane: HorizontalPlane,
        in board: HorizontalBoard,
        planeObstacles: [PlaneObstacle]
    ) -> HorizontalPlane {
        guard let layer = plane.layer,
              let fallbackPolygon = plane.fallbackPolygon else {
            return zeroed(plane)
        }
        let subject = fallbackPolygon.renderVertices(arcPrecision: fragmentArcPrecision)
        guard subject.count >= 3 else {
            return zeroed(plane)
        }

        let settings = effectiveSettings(for: plane, in: board)
        let mw = max(Double(settings.minWidth), 0)
        let jt = joinType(for: settings.style)
        let planeNet = plane.netID.map { $0.lowercased() }
        let rules = board.rules

        let polyBB = HorizontalRect(points: subject)

        var cutouts = [Cutout]()

        func conflicts(_ netID: String?) -> Bool {
            guard let planeNet, let netID else { return true }
            return netID.lowercased() != planeNet
        }

        // Expand a patch by clearance + mw/2 + epsilon, after a bbox prefilter.
        func addCopperCutout(_ path: [HorizontalPoint], clearance: Int) {
            guard path.count >= 3 else { return }
            let c = Double(clearance)
            if !bboxIntersects(polyBB, points: path, expandedBy: 2 * c) { return }
            cutouts.append(Cutout(
                path: path,
                outset: c + mw / 2 + twiddle,
                joinType: jt,
                arcTolerance: normalArcTolerance))
        }

        // Foreign net-bearing copper polygons. We require a net so that generic
        // drawing polygons (PatchType OTHER in the reference, which excludes
        // OTHER from copper cutouts) don't carve the pour. Plane source polygons
        // and keepouts are handled separately (priority accumulator / keepout
        // loop).
        let planePolygonIDs = Set(board.planes.compactMap { $0.fallbackPolygon.map { normalizedID($0.id) } })
        for polygon in board.polygons
        where polygon.layer == layer
            && polygon.netID != nil
            && conflicts(polygon.netID)
            && !planePolygonIDs.contains(normalizedID(polygon.id)) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: polygon.netID?.lowercased(), layer: layer)
                .clearance(.pad, .plane)
            addCopperCutout(polygon.renderVertices(arcPrecision: fragmentArcPrecision), clearance: clearance)
        }

        for pad in board.packagePads where pad.layer == layer && conflicts(pad.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: pad.netID?.lowercased(), layer: layer)
                .clearance(.pad, .plane)
            addCopperCutout(pad.renderVertices(arcPrecision: fragmentArcPrecision), clearance: clearance)
        }

        for track in board.tracks where track.layer == layer && conflicts(track.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: track.netID?.lowercased(), layer: layer)
                .clearance(.track, .plane)
            addCopperCutout(segmentPath(track), clearance: clearance)
        }

        for netTie in board.netTies where netTie.layer == layer && conflicts(netTie.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: netTie.netID?.lowercased(), layer: layer)
                .clearance(.netTie, .plane)
            addCopperCutout(segmentPath(netTie), clearance: clearance)
        }

        // Copper lines drawn on this layer (net-aware, unlike the old code which
        // cut every line including same-net ones).
        for line in board.lines where line.layer == layer && conflicts(line.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: line.netID?.lowercased(), layer: layer)
                .clearance(.track, .plane)
            addCopperCutout(segmentPath(line), clearance: clearance)
        }

        for via in board.vias where conflicts(via.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: via.netID?.lowercased(), layer: layer)
                .clearance(.via, .plane)
            addCopperCutout(circlePath(center: via.position, diameter: via.size), clearance: clearance)
        }

        // Holes: NPTH always cut (copper-other rule); foreign-net PTH cut.
        for hole in board.allPlaneCutoutHoles {
            let isNPTH = !hole.plated
            if !isNPTH && !conflicts(hole.netID) { continue }
            let clearance = isNPTH
                ? rules.clearanceCopperOther(net: planeNet, layer: layer).clearance(copper: .plane, nonCopper: .holeNPTH)
                : rules.clearanceCopper(net1: planeNet, net2: hole.netID?.lowercased(), layer: layer)
                    .clearance(.holePTH, .plane)
            addCopperCutout(hole.outlinePoints(precision: 40), clearance: clearance)
        }

        // Text cutouts (BBOX-style; we don't have true glyph outlines yet).
        let textClearance = rules.clearanceCopperOther(net: planeNet, layer: layer)
            .clearance(copper: .plane, nonCopper: .text)
        for text in board.texts + board.packageTexts where text.layer == layer {
            let path = text.renderBoundsPoints
            guard path.count >= 3 else { continue }
            let c = Double(textClearance)
            if !bboxIntersects(polyBB, points: path, expandedBy: 2 * c) { continue }
            cutouts.append(Cutout(
                path: path,
                outset: c + mw / 2 + twiddle,
                joinType: jt,
                arcTolerance: normalArcTolerance))
        }

        // Keepouts (always round join, coarser arc tolerance, extra .05mm).
        for keepout in board.keepouts
        where keepout.applies(toCopperLayer: layer) && keepout.copperPatchTypes.contains("plane") {
            let clearance = rules.clearanceCopperKeepout(net: planeNet, keepoutClass: keepout.keepoutClass)
                .clearance(.plane)
            let path = keepout.polygon.renderVertices(arcPrecision: fragmentArcPrecision)
            guard path.count >= 3 else { continue }
            cutouts.append(Cutout(
                path: path,
                outset: Double(clearance) + mw / 2 + keepoutExtra,
                joinType: 0, // round
                arcTolerance: boardOutlineArcTolerance))
        }

        // Higher-priority planes already poured this run become obstacles.
        for obstacle in planeObstacles where obstacle.layer == layer && conflicts(obstacle.netID) {
            let clearance = rules.clearanceCopper(net1: planeNet, net2: obstacle.netID?.lowercased(), layer: layer)
                .clearance(.plane, .plane)
            addCopperCutout(obstacle.path, clearance: clearance)
        }

        // Board outline contract.
        let outlinePaths = board.polygons
            .filter { $0.layer == HorizontalBoardLayers.outline }
            .map { $0.renderVertices(arcPrecision: fragmentArcPrecision) }
            .filter { $0.count >= 3 }
        let boardEdgeClearance = rules.clearanceCopperOther(net: planeNet, layer: layer)
            .clearance(copper: .plane, nonCopper: .boardEdge)
        let boardOutlineContract = Double(boardEdgeClearance) + mw / 2 + twiddle * 2

        // Same-net thermal pads.
        let thermalPads = thermalPads(for: plane, settings: settings, layer: layer, planeNet: planeNet, board: board)

        // Pour.
        let rawFragments = withPlaneFillParams(
            subject: subject,
            minWidth: mw,
            joinType: jt,
            cutouts: cutouts,
            boardOutline: outlinePaths,
            boardOutlineContract: boardOutlineContract,
            thermalPads: thermalPads,
            fillStyle: settings.fillStyle == .hatch ? 1 : 0,
            hatchBorderWidth: Double(settings.hatchBorderWidth),
            hatchLineWidth: Double(settings.hatchLineWidth),
            hatchLineSpacing: Double(settings.hatchLineSpacing)
        ) { paramsPointer in
            HorizontalClipperBuildPlaneFillEx(paramsPointer)
        }
        defer { HorizontalClipperFreeFragments(rawFragments) }

        let anchors = planeAnchors(for: plane, in: board)
        var fragments = fragments(from: rawFragments).map { fragment -> HorizontalPlaneFragment in
            var fragment = fragment
            fragment.orphan = !anchors.contains { fragment.contains($0) }
            return fragment
        }
        if !settings.keepOrphans {
            fragments.removeAll(where: \.orphan)
        }

        var updated = plane
        updated.fragments = fragments
        return updated
    }

    private static func effectiveSettings(for plane: HorizontalPlane, in board: HorizontalBoard) -> HorizontalPlaneSettings {
        if plane.fromRules {
            return board.rules.planeSettings(net: plane.netID?.lowercased(), layer: plane.layer ?? 10000)
        }
        return plane.settings
    }

    private static func joinType(for style: HorizontalPlaneSettings.Style) -> Int32 {
        switch style {
        case .round: return 0
        case .square: return 1
        case .miter: return 2
        }
    }

    private static func thermalPads(
        for plane: HorizontalPlane,
        settings: HorizontalPlaneSettings,
        layer: Int,
        planeNet: String?,
        board: HorizontalBoard
    ) -> [ThermalPad] {
        guard let planeNet else { return [] }
        let rules = board.rules
        // The FROM_PLANE / no-rule-match fallback is the plane's own resolved
        // thermal settings. fromPlane at the plane level has no further source,
        // so treat it (like solid) as a flood.
        let planeThermal = settings.thermalSettings

        // Fast path: with no per-pad thermal rules every pad resolves to the
        // plane's own settings, so a SOLID/from-plane plane has nothing to do.
        if rules.thermalRules.isEmpty {
            switch planeThermal.connectStyle {
            case .solid, .fromPlane: return []
            case .thermal, .none: break
            }
        }

        return board.packagePads.compactMap { pad -> ThermalPad? in
            guard pad.layer == layer, let padNet = pad.netID?.lowercased(), padNet == planeNet else {
                return nil
            }

            // Thermal settings are resolved PER PAD, not once per plane: a
            // thermal rule can name a net, a package and a pad, so two pads on
            // the same plane can legitimately differ — one pad of a connector
            // relieved for hand-soldering while the rest stay solid. Falls back
            // to the plane's own setting when no rule matches.
            let ids = padPackageAndPadUUIDs(from: pad.id)
            let thermal = rules.thermalSettings(
                net: padNet,
                packageID: ids?.packageID ?? "",
                padID: ids?.padID ?? "",
                layer: layer,
                planeThermal: planeThermal)

            let style: Int32
            switch thermal.connectStyle {
            case .thermal: style = 1
            case .none: style = 2
            case .solid, .fromPlane: style = 0
            }
            if style == 0 { return nil } // SOLID floods: nothing to do.

            let path = pad.renderVertices(arcPrecision: fragmentArcPrecision)
            guard path.count >= 3 else { return nil }
            let frame = pad.padLabelFrame
            let center = frame?.center ?? HorizontalRect(points: path).center
            let angle = frame?.angle ?? 0
            return ThermalPad(
                path: path,
                placement: center,
                angle: angle,
                mirror: false,
                connectStyle: style,
                gapWidth: Double(thermal.thermalGapWidth),
                spokeWidth: Double(thermal.thermalSpokeWidth),
                nSpokes: thermal.nSpokes,
                spokeAngle: thermal.angle)
        }
    }

    /// Pad polygon ids are "[panelID/]boardPackageID/pad/padID[/suffix…]" (see
    /// HorizontalBoard's pad-polygon construction). Extract the board-package and
    /// pad UUIDs for per-pad RuleThermals matching.
    private static func padPackageAndPadUUIDs(from id: String) -> (packageID: String, padID: String)? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard let padIndex = parts.firstIndex(of: "pad"),
              padIndex >= 1, padIndex + 1 < parts.count else {
            return nil
        }
        return (String(parts[padIndex - 1]), String(parts[padIndex + 1]))
    }

    // MARK: - Anchors / orphans

    private static func planeAnchors(for plane: HorizontalPlane, in board: HorizontalBoard) -> [HorizontalPoint] {
        guard let planeNetID = plane.netID.map(normalizedID),
              let layer = plane.layer else {
            return []
        }

        var anchors = [HorizontalPoint]()
        for (junctionID, point) in board.junctions
        where board.junctionNetIDs[junctionID].map(normalizedID) == planeNetID {
            anchors.append(point)
        }
        for track in board.tracks where track.layer == layer && track.netID.map(normalizedID) == planeNetID {
            anchors.append(track.from)
            anchors.append(track.to)
        }
        for via in board.vias where via.netID.map(normalizedID) == planeNetID {
            anchors.append(via.position)
        }
        for pad in board.packagePads where pad.netID.map(normalizedID) == planeNetID && pad.layer == layer {
            anchors.append(HorizontalRect(points: pad.renderVertices(arcPrecision: fragmentArcPrecision)).center)
        }
        for hole in board.packageHoles + board.viaHoles where hole.netID.map(normalizedID) == planeNetID {
            anchors.append(hole.position)
        }
        return anchors
    }

    // MARK: - Fragment conversion

    private static func fragments(from raw: HorizontalClipperFragmentList) -> [HorizontalPlaneFragment] {
        guard let rawFragments = raw.fragments, raw.count > 0 else {
            return []
        }

        return (0..<Int(raw.count)).compactMap { fragmentIndex in
            let rawFragment = rawFragments[fragmentIndex]
            guard let rawPaths = rawFragment.paths, rawFragment.count > 0 else {
                return nil
            }

            let paths = (0..<Int(rawFragment.count)).compactMap { pathIndex -> [HorizontalPoint]? in
                let rawPath = rawPaths[pathIndex]
                guard let rawPoints = rawPath.points, rawPath.count >= 3 else {
                    return nil
                }
                let points = (0..<Int(rawPath.count)).map { pointIndex in
                    let point = rawPoints[pointIndex]
                    return HorizontalPoint(x: point.x, y: point.y)
                }
                return points.count >= 3 ? points : nil
            }

            return paths.isEmpty ? nil : HorizontalPlaneFragment(paths: paths, orphan: rawFragment.orphan != 0)
        }
    }

    // MARK: - Obstacle geometry helpers

    private static func segmentPath(_ segment: HorizontalSegment) -> [HorizontalPoint] {
        let halfWidth = max(segment.width / 2, 1)
        let points = segment.pathPoints
        guard points.count > 2 else {
            let vector = segment.to - segment.from
            let normal = HorizontalPoint(x: -vector.y, y: vector.x).normalized
            let offset = normal * halfWidth
            return [
                segment.from + offset,
                segment.to + offset,
                segment.to - offset,
                segment.from - offset
            ]
        }

        let normals = zip(points, points.dropFirst()).map { pair in
            let vector = pair.1 - pair.0
            return HorizontalPoint(x: -vector.y, y: vector.x).normalized
        }
        var left = [HorizontalPoint]()
        var right = [HorizontalPoint]()
        for index in points.indices {
            let previous = index > points.startIndex ? normals[index - 1] : nil
            let next = index < normals.endIndex ? normals[index] : nil
            let normal = ((previous ?? .zero) + (next ?? .zero)).normalized
            let offset = (normal == .zero ? (previous ?? next ?? .zero) : normal) * halfWidth
            left.append(points[index] + offset)
            right.append(points[index] - offset)
        }
        return left + right.reversed()
    }

    private static func circlePath(center: HorizontalPoint, diameter: Double, segments: Int = 32) -> [HorizontalPoint] {
        let radius = max(diameter / 2, 1)
        return (0..<segments).map { index in
            let angle = Double(index) / Double(segments) * Double.pi * 2
            return HorizontalPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius)
        }
    }

    private static func bboxIntersects(_ bb: HorizontalRect, points: [HorizontalPoint], expandedBy expand: Double) -> Bool {
        guard !points.isEmpty else { return false }
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        minX -= expand; minY -= expand; maxX += expand; maxY += expand
        return bb.maxX >= minX && maxX >= bb.minX && bb.maxY >= minY && maxY >= bb.minY
    }

    // MARK: - C marshalling

    private static func withPlaneFillParams<Result>(
        subject: [HorizontalPoint],
        minWidth: Double,
        joinType: Int32,
        cutouts: [Cutout],
        boardOutline: [[HorizontalPoint]],
        boardOutlineContract: Double,
        thermalPads: [ThermalPad],
        fillStyle: Int32,
        hatchBorderWidth: Double,
        hatchLineWidth: Double,
        hatchLineSpacing: Double,
        _ body: (UnsafePointer<HorizontalClipperPlaneFillParams>) -> Result
    ) -> Result {
        let arena = PlaneFillArena()

        let subjectPtr = arena.makePathArray([subject])
        let cutoutPtr = arena.makeCutoutArray(cutouts)
        let outlinePtr = arena.makePathArray(boardOutline)
        let thermalPtr = arena.makeThermalArray(thermalPads)

        var params = HorizontalClipperPlaneFillParams()
        params.subjects = UnsafePointer(subjectPtr)
        params.subjectCount = 1
        params.minWidth = minWidth
        params.joinType = joinType
        params.cutouts = UnsafePointer(cutoutPtr)
        params.cutoutCount = Int32(cutouts.count)
        params.boardOutline = UnsafePointer(outlinePtr)
        params.boardOutlineCount = Int32(boardOutline.count)
        params.hasBoardOutline = boardOutline.isEmpty ? 0 : 1
        params.boardOutlineContract = boardOutlineContract
        params.thermalPads = UnsafePointer(thermalPtr)
        params.thermalPadCount = Int32(thermalPads.count)
        params.fillStyle = fillStyle
        params.hatchBorderWidth = hatchBorderWidth
        params.hatchLineWidth = hatchLineWidth
        params.hatchLineSpacing = hatchLineSpacing

        let result = withUnsafePointer(to: &params) { body($0) }
        arena.free()
        return result
    }
}

/// Owns every heap allocation handed to the C plane-fill ABI for the duration
/// of a single call, then frees them in `free()`.
private final class PlaneFillArena {
    private var pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>] = []
    private var pathBuffers: [UnsafeMutablePointer<HorizontalClipperPath>] = []
    private var cutoutBuffers: [UnsafeMutablePointer<HorizontalClipperCutout>] = []
    private var thermalBuffers: [UnsafeMutablePointer<HorizontalClipperThermalPad>] = []

    private func makePath(_ points: [HorizontalPoint]) -> HorizontalClipperPath {
        guard !points.isEmpty else {
            return HorizontalClipperPath(points: nil, count: 0)
        }
        let buffer = UnsafeMutablePointer<HorizontalClipperPoint>.allocate(capacity: points.count)
        for (index, point) in points.enumerated() {
            buffer[index] = HorizontalClipperPoint(x: point.x, y: point.y)
        }
        pointBuffers.append(buffer)
        return HorizontalClipperPath(points: buffer, count: Int32(points.count))
    }

    func makePathArray(_ paths: [[HorizontalPoint]]) -> UnsafeMutablePointer<HorizontalClipperPath>? {
        let valid = paths.filter { $0.count >= 3 }
        guard !valid.isEmpty else { return nil }
        let buffer = UnsafeMutablePointer<HorizontalClipperPath>.allocate(capacity: valid.count)
        for (index, path) in valid.enumerated() {
            buffer[index] = makePath(path)
        }
        pathBuffers.append(buffer)
        return buffer
    }

    func makeCutoutArray(_ cutouts: [Cutout]) -> UnsafeMutablePointer<HorizontalClipperCutout>? {
        guard !cutouts.isEmpty else { return nil }
        let buffer = UnsafeMutablePointer<HorizontalClipperCutout>.allocate(capacity: cutouts.count)
        for (index, cutout) in cutouts.enumerated() {
            buffer[index] = HorizontalClipperCutout(
                path: makePath(cutout.path),
                outset: cutout.outset,
                joinType: cutout.joinType,
                arcTolerance: cutout.arcTolerance)
        }
        cutoutBuffers.append(buffer)
        return buffer
    }

    func makeThermalArray(_ pads: [ThermalPad]) -> UnsafeMutablePointer<HorizontalClipperThermalPad>? {
        guard !pads.isEmpty else { return nil }
        let buffer = UnsafeMutablePointer<HorizontalClipperThermalPad>.allocate(capacity: pads.count)
        for (index, pad) in pads.enumerated() {
            buffer[index] = HorizontalClipperThermalPad(
                path: makePath(pad.path),
                placementX: pad.placement.x,
                placementY: pad.placement.y,
                placementAngle: Int32(pad.angle),
                placementMirror: pad.mirror ? 1 : 0,
                connectStyle: pad.connectStyle,
                gapWidth: pad.gapWidth,
                spokeWidth: pad.spokeWidth,
                nSpokes: Int32(pad.nSpokes),
                spokeAngle: Int32(pad.spokeAngle))
        }
        thermalBuffers.append(buffer)
        return buffer
    }

    func free() {
        for buffer in pointBuffers { buffer.deallocate() }
        for buffer in pathBuffers { buffer.deallocate() }
        for buffer in cutoutBuffers { buffer.deallocate() }
        for buffer in thermalBuffers { buffer.deallocate() }
        pointBuffers.removeAll()
        pathBuffers.removeAll()
        cutoutBuffers.removeAll()
        thermalBuffers.removeAll()
    }
}

/// One obstacle to subtract, already resolved to its world-space polygon plus
/// the total expand delta / join behavior the pour should apply.
private struct Cutout {
    var path: [HorizontalPoint]
    var outset: Double
    var joinType: Int32
    var arcTolerance: Double
}

private struct ThermalPad {
    var path: [HorizontalPoint]
    var placement: HorizontalPoint
    var angle: Int
    var mirror: Bool
    var connectStyle: Int32 // 1 thermal, 2 none/isolate
    var gapWidth: Double
    var spokeWidth: Double
    var nSpokes: Int
    var spokeAngle: Int
}

private extension HorizontalPlaneFragment {
    func contains(_ point: HorizontalPoint) -> Bool {
        guard let outer = paths.first, pointInPolygon(point, outer) else {
            return false
        }
        return !paths.dropFirst().contains { pointInPolygon(point, $0) }
    }
}

private extension HorizontalBoard {
    var allPlaneCutoutHoles: [HorizontalHole] {
        holes + viaHoles + packageHoles
    }
}

private extension HorizontalKeepout {
    func applies(toCopperLayer layer: Int) -> Bool {
        allCopperLayers || polygon.layer == layer
    }
}

private func pointInPolygon(_ point: HorizontalPoint, _ polygon: [HorizontalPoint]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var isInside = false
    var previous = polygon[polygon.count - 1]
    for current in polygon {
        let crossesY = (current.y > point.y) != (previous.y > point.y)
        if crossesY {
            let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
            if point.x < x {
                isInside.toggle()
            }
        }
        previous = current
    }
    return isInside
}

private func normalizedID(_ id: String) -> String {
    id.lowercased()
}
