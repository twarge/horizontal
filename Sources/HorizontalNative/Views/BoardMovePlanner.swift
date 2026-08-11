import Foundation

/// Pure move-planning logic extracted from `BoardCanvasView`. Stateless and
/// dependency-minimal — each function takes exactly the board geometry it needs
/// (not a whole `HorizontalBoard`), so it is unit-testable without constructing a
/// View or a full board. `BoardCanvasView` delegates to these via thin wrappers,
/// so behavior is unchanged.
///
/// Uses the shared `HorizontalCanvasModeSupport.pointKey` / `normalizedID` so the
/// point/id bucketing matches the rest of the canvas exactly.
enum BoardMovePlanner {
    /// Builds the spatial connectivity index used to decide which geometry moves
    /// together when dragging. Mirrors the former
    /// `BoardCanvasView.boardMoveConnectivityIndex`.
    static func connectivityIndex(
        tracks: [HorizontalSegment],
        netTies: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker],
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole],
        includesPackages: Bool
    ) -> BoardMoveConnectivityIndex {
        var index = BoardMoveConnectivityIndex()

        // Reserve up front so the per-pad/segment inserts on a whole-board move
        // don't repeatedly rehash these dictionaries as they grow.
        let segmentEndpointCount = (tracks.count + netTies.count) * 2
        index.segmentsByRef.reserveCapacity(tracks.count + netTies.count)
        index.segmentEndpointsByPoint.reserveCapacity(segmentEndpointCount)
        index.junctionOwnersByPoint.reserveCapacity(junctions.count)
        index.viaOwnersByPoint.reserveCapacity(vias.count)
        if includesPackages {
            index.packageOwnersByPoint.reserveCapacity(packagePads.count + packageHoles.count)
        }

        func key(_ point: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(point) }

        func addSegmentEndpoint(_ segment: HorizontalSegment, type: HorizontalObjectType, point: HorizontalPoint, movesFrom: Bool) {
            let ref = HorizontalSelectableRef(id: segment.id, type: type, layer: segment.layer)
            index.segmentsByRef[ref] = segment
            index.segmentEndpointsByPoint[key(point), default: []].append(
                BoardMoveSegmentEndpoint(
                    ref: ref,
                    netID: segment.netID,
                    movesFrom: movesFrom
                )
            )
        }

        for track in tracks {
            addSegmentEndpoint(track, type: .track, point: track.from, movesFrom: true)
            addSegmentEndpoint(track, type: .track, point: track.to, movesFrom: false)
        }
        for netTie in netTies {
            addSegmentEndpoint(netTie, type: .boardNetTie, point: netTie.from, movesFrom: true)
            addSegmentEndpoint(netTie, type: .boardNetTie, point: netTie.to, movesFrom: false)
        }

        for (junctionID, junction) in junctions {
            index.junctionOwnersByPoint[key(junction), default: []].append(
                BoardMovePointOwner(
                    ref: HorizontalSelectableRef(id: junctionID, type: .junction),
                    netID: junctionNetIDs[junctionID]
                )
            )
        }

        for via in vias {
            index.viaOwnersByPoint[key(via.position), default: []].append(
                BoardMovePointOwner(ref: HorizontalSelectableRef(id: via.id, type: .via), netID: via.netID)
            )
        }

        if includesPackages {
            // `packageID(forGeometryID:)` already returns a normalized (lowercased)
            // id, so it is used directly as the `packageAnchorsByID` key — the
            // matching lookup in `addPackageMove` normalizes its own input. Skipping
            // a redundant re-lowercase here matters because this runs once per
            // pad/hole on a whole-board move (thousands of geometry ids).
            func addPackageAnchor(packageID: String, point: HorizontalPoint, netID: String?) {
                index.packageAnchorsByID[packageID, default: []].append(
                    BoardMoveConnectionAnchor(point: point, netID: netID)
                )
                index.packageOwnersByPoint[key(point), default: []].append(
                    BoardMovePointOwner(ref: HorizontalSelectableRef(id: packageID, type: .boardPackage), netID: netID)
                )
            }

            for pad in packagePads {
                if let packageID = packageID(forGeometryID: pad.id) {
                    // `pad.vertices` is a computed property that allocates a fresh
                    // `[HorizontalPoint]` on every access; compute the bounding-box
                    // center straight off the stored vertices instead.
                    addPackageAnchor(packageID: packageID, point: boundingCenter(of: pad.polygonVertices), netID: pad.netID)
                }
            }
            for hole in packageHoles {
                if let packageID = packageID(forGeometryID: hole.id) {
                    addPackageAnchor(packageID: packageID, point: hole.position, netID: hole.netID)
                }
            }
        }

        return index
    }

    /// Computes which board geometry moves together (and how) when dragging the
    /// given selection. Mirrors the former `BoardCanvasView.boardResidentMovePlan`.
    static func residentMovePlan(
        for refs: [HorizontalSelectableRef],
        tracks: [HorizontalSegment],
        netTies: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker],
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole]
    ) -> BoardResidentMovePlan {
        var plan = BoardResidentMovePlan()
        var movedConnectionKeys = Set<String>()
        let selectedRefSet = Set(refs)
        let includesPackages = selectedRefSet.contains { $0.type == .boardPackage }
        let connectivity = connectivityIndex(
            tracks: tracks,
            netTies: netTies,
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            vias: vias,
            packagePads: packagePads,
            packageHoles: packageHoles,
            includesPackages: includesPackages
        )

        // Prebuilt normalized-id lookups so per-ref junction/via handling is O(1)
        // instead of a linear `.first(where:)` scan. Those scans made whole-board
        // moves quadratic (junctions alone ~95ms, vias ~23ms on a large board);
        // this mirrors how tracks already use connectivity.segmentsByRef.
        let junctionsByID = Dictionary(
            junctions.map { (HorizontalCanvasModeSupport.normalizedID($0.key), (id: $0.key, point: $0.value)) },
            uniquingKeysWith: { first, _ in first }
        )
        let viasByID = Dictionary(
            vias.map { (HorizontalCanvasModeSupport.normalizedID($0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func ownersAt(_ point: HorizontalPoint, netID: String?, includesPackages: Bool) -> [HorizontalSelectableRef] {
            let key = HorizontalCanvasModeSupport.pointKey(point)
            var owners = [HorizontalSelectableRef]()
            owners += (connectivity.junctionOwnersByPoint[key] ?? [])
                .filter { netsMatch($0.netID, netID) }
                .map(\.ref)
            owners += (connectivity.viaOwnersByPoint[key] ?? [])
                .filter { netsMatch($0.netID, netID) }
                .map(\.ref)
            if includesPackages {
                owners += (connectivity.packageOwnersByPoint[key] ?? [])
                    .filter { netsMatch($0.netID, netID) }
                    .map(\.ref)
            }
            return HorizontalCanvasModeSupport.uniqueRefs(owners)
        }

        func addTranslatedRef(_ ref: HorizontalSelectableRef) {
            let owner = patchOwnerRef(for: ref)
            guard plan.segmentMoves[owner] == nil else {
                return
            }
            plan.translatedRefs.insert(owner)
        }

        func addSegmentMove(
            _ ref: HorizontalSelectableRef,
            from movesFrom: Bool = false,
            to movesTo: Bool = false,
            center movesCenter: Bool = false
        ) {
            guard movesFrom || movesTo || movesCenter else {
                return
            }
            let owner = patchOwnerRef(for: ref)
            var move = plan.segmentMoves[owner] ?? BoardResidentSegmentMove()
            move.movesFrom = move.movesFrom || movesFrom
            move.movesTo = move.movesTo || movesTo
            move.movesCenter = move.movesCenter || movesCenter
            plan.segmentMoves[owner] = move
            plan.translatedRefs.remove(owner)
        }

        func addTrackEndpointMoves(at point: HorizontalPoint, netID: String?) {
            let key = HorizontalCanvasModeSupport.pointKey(point)
            for endpoint in connectivity.segmentEndpointsByPoint[key] ?? [] where netsMatch(endpoint.netID, netID) {
                addSegmentMove(
                    endpoint.ref,
                    from: endpoint.movesFrom,
                    to: !endpoint.movesFrom
                )
            }
        }

        func addConnectionPointMove(at point: HorizontalPoint, netID: String?) {
            let key = HorizontalCanvasModeSupport.pointKey(point)
            guard movedConnectionKeys.insert("\(key):\(netID.map(HorizontalCanvasModeSupport.normalizedID) ?? "")").inserted else {
                return
            }

            addTrackEndpointMoves(at: point, netID: netID)
            for viaOwner in connectivity.viaOwnersByPoint[key] ?? [] where netsMatch(viaOwner.netID, netID) {
                addTranslatedRef(viaOwner.ref)
            }
        }

        func addPackageMove(packageID: String) {
            addTranslatedRef(HorizontalSelectableRef(id: packageID, type: .boardPackage))
            for anchor in connectivity.packageAnchorsByID[HorizontalCanvasModeSupport.normalizedID(packageID)] ?? [] {
                addTrackEndpointMoves(at: anchor.point, netID: anchor.netID)
            }
        }

        func addTrackMove(
            ref: HorizontalSelectableRef,
            in segments: [HorizontalSegment],
            type: HorizontalObjectType
        ) {
            let owner = HorizontalSelectableRef(id: ref.id, type: type, layer: ref.layer)
            guard let segment = connectivity.segmentsByRef[owner]
                    ?? segments.first(where: { HorizontalCanvasModeSupport.normalizedID($0.id) == HorizontalCanvasModeSupport.normalizedID(ref.id) }) else {
                return
            }

            let hasSelectedEndpointOwner = ownersAt(segment.from, netID: segment.netID, includesPackages: includesPackages).contains {
                selectedRefSet.contains($0)
            } || ownersAt(segment.to, netID: segment.netID, includesPackages: includesPackages).contains {
                selectedRefSet.contains($0)
            }
            if hasSelectedEndpointOwner {
                return
            }

            if !ownersAt(segment.from, netID: segment.netID, includesPackages: false).isEmpty {
                addConnectionPointMove(at: segment.from, netID: segment.netID)
            } else {
                addSegmentMove(owner, from: true)
            }
            if !ownersAt(segment.to, netID: segment.netID, includesPackages: false).isEmpty {
                addConnectionPointMove(at: segment.to, netID: segment.netID)
            } else {
                addSegmentMove(owner, to: true)
            }
            if segment.center != nil {
                addSegmentMove(owner, center: true)
            }
        }

        for ref in refs {
            switch ref.type {
            case .boardPackage:
                addPackageMove(packageID: ref.id)
            case .track:
                addTrackMove(ref: ref, in: tracks, type: .track)
            case .boardNetTie:
                addTrackMove(ref: ref, in: netTies, type: .boardNetTie)
            case .boardLine,
                 .connectionLine,
                 .boardArc,
                 .via,
                 .boardHole,
                 .text,
                 .keepout,
                 .dimension,
                 .boardDecal,
                 .polygonArcCenter,
                 .polygonEdge,
                 .polygonVertex,
                 .plane:
                addTranslatedRef(ref)
                if ref.type == .via,
                   let via = viasByID[HorizontalCanvasModeSupport.normalizedID(ref.id)] {
                    addTrackEndpointMoves(at: via.position, netID: via.netID)
                }
            case .junction:
                guard let entry = junctionsByID[HorizontalCanvasModeSupport.normalizedID(ref.id)] else {
                    continue
                }
                addConnectionPointMove(at: entry.point, netID: junctionNetIDs[entry.id])
            case .pad:
                addTranslatedRef(ref)
            case .boardPanel:
                break
            case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .symbolPin:
                plan.unsupportedRefs.insert(ref)
            }
        }

        return plan
    }

    /// The geometry-id segment kinds that separate a package id from the rest of a
    /// board-geometry id like "pkg-uuid/pad/pad-uuid". Hoisted to a static so the
    /// whole-board index build doesn't rebuild this `Set` once per pad/hole.
    private static let packageGeometrySeparators: Set<String> = ["arc", "hole", "line", "pad", "polygon", "text"]

    /// Derives the owning package id from a board-geometry id like
    /// "pkg-uuid/pad/pad-uuid". Mirrors `BoardCanvasView.packageID(forGeometryID:)`.
    static func packageID(forGeometryID geometryID: String) -> String? {
        objectIDPrefix(in: geometryID, separators: packageGeometrySeparators)
    }

    private static func objectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
        // Normalize once, then split into `Substring`s — avoid the former
        // `.map(String.init)` over every component, and because the components are
        // already lowercased the returned prefix needs no second lowercase pass.
        // Membership checks only materialize a `String` for the components actually
        // scanned (the predicate short-circuits at the first separator). This runs
        // once per pad/hole on a whole-board move, so the per-component allocations
        // added up.
        let components = HorizontalCanvasModeSupport.normalizedID(geometryID).split(separator: "/")
        guard let separatorIndex = components.firstIndex(where: { separators.contains(String($0)) }),
              separatorIndex > components.startIndex else {
            return nil
        }
        return components[..<separatorIndex].joined(separator: "/")
    }

    /// Bounding-box center of polygon vertices — matches
    /// `HorizontalRect(points: vertices.map(\.position)).center` but without
    /// allocating the intermediate `[HorizontalPoint]`. Empty vertices map to
    /// `.zero`, mirroring `HorizontalRect.empty.center`.
    private static func boundingCenter(of vertices: [HorizontalPolygonVertex]) -> HorizontalPoint {
        guard let first = vertices.first?.position else {
            return .zero
        }
        var minX = first.x, minY = first.y
        var maxX = first.x, maxY = first.y
        for index in 1..<vertices.count {
            let point = vertices[index].position
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return HorizontalPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// Two nets "match" if either is unset (nil), else equal. Mirrors
    /// `BoardCanvasView.netsMatch`.
    private static func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return HorizontalCanvasModeSupport.normalizedID(lhs) == HorizontalCanvasModeSupport.normalizedID(rhs)
    }

    /// Maps a selectable ref to the ref that owns its renderable patch (so e.g.
    /// a polygon vertex/arc-center collapses to its edge). Mirrors
    /// `BoardCanvasView.boardMetalPatchOwnerRef`.
    private static func patchOwnerRef(for ref: HorizontalSelectableRef) -> HorizontalSelectableRef {
        switch ref.type {
        case .boardPackage, .via:
            return HorizontalSelectableRef(id: ref.id, type: ref.type)
        case .polygonArcCenter, .polygonVertex:
            return HorizontalSelectableRef(id: ref.id, type: .polygonEdge, layer: ref.layer)
        case .track, .boardNetTie, .boardLine, .boardArc, .boardHole, .text, .connectionLine:
            return HorizontalSelectableRef(id: ref.id, type: ref.type, layer: ref.layer)
        case .keepout, .dimension, .boardDecal, .polygonEdge, .plane:
            return HorizontalSelectableRef(id: ref.id, type: ref.type, layer: ref.layer)
        default:
            return ref
        }
    }

    /// Expands a selection to include the endpoint owners (junctions/vias) that a
    /// selected track/net-tie shares, so they drag together. Mirrors the former
    /// `BoardCanvasView.expandedBoardMoveSelection`.
    static func expandedSelection(
        _ refs: [HorizontalSelectableRef],
        tracks: [HorizontalSegment],
        netTies: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker]
    ) -> [HorizontalSelectableRef] {
        var expanded = [HorizontalSelectableRef]()
        for ref in refs {
            switch ref.type {
            case .track:
                expanded.append(ref)
                expanded.append(contentsOf: trackEndpointOwnerRefs(
                    for: ref, in: tracks, junctions: junctions, junctionNetIDs: junctionNetIDs, vias: vias))
            case .boardNetTie:
                expanded.append(ref)
                expanded.append(contentsOf: trackEndpointOwnerRefs(
                    for: ref, in: netTies, junctions: junctions, junctionNetIDs: junctionNetIDs, vias: vias))
            default:
                expanded.append(ref)
            }
        }
        return HorizontalCanvasModeSupport.uniqueRefs(expanded)
    }

    private static func trackEndpointOwnerRefs(
        for ref: HorizontalSelectableRef,
        in segments: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker]
    ) -> [HorizontalSelectableRef] {
        guard let segment = segments.first(where: {
            HorizontalCanvasModeSupport.normalizedID($0.id) == HorizontalCanvasModeSupport.normalizedID(ref.id)
        }) else {
            return []
        }
        return HorizontalCanvasModeSupport.uniqueRefs(
            movableEndpointOwnerRefs(at: segment.from, netID: segment.netID, junctions: junctions,
                                     junctionNetIDs: junctionNetIDs, vias: vias, packages: [],
                                     packagePads: [], packageHoles: [], includesPackages: false)
                + movableEndpointOwnerRefs(at: segment.to, netID: segment.netID, junctions: junctions,
                                           junctionNetIDs: junctionNetIDs, vias: vias, packages: [],
                                           packagePads: [], packageHoles: [], includesPackages: false)
        )
    }

    /// The refs (junctions, vias, packages) that "own" a movable endpoint at a
    /// point on a net. Mirrors `BoardCanvasView.boardMovableEndpointOwnerRefs`.
    static func movableEndpointOwnerRefs(
        at point: HorizontalPoint,
        netID: String?,
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker],
        packages: [HorizontalPlacement],
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole],
        includesPackages: Bool
    ) -> [HorizontalSelectableRef] {
        let key = HorizontalCanvasModeSupport.pointKey(point)
        var refs = [HorizontalSelectableRef]()

        for (junctionID, junction) in junctions where HorizontalCanvasModeSupport.pointKey(junction) == key {
            if let junctionNetID = junctionNetIDs[junctionID], !netsMatch(junctionNetID, netID) {
                continue
            }
            refs.append(HorizontalSelectableRef(id: junctionID, type: .junction))
        }

        for via in vias where HorizontalCanvasModeSupport.pointKey(via.position) == key && netsMatch(via.netID, netID) {
            refs.append(HorizontalSelectableRef(id: via.id, type: .via))
        }

        if includesPackages {
            for package in packages where packageConnectionAnchors(
                packageID: package.id, packagePads: packagePads, packageHoles: packageHoles
            ).contains(where: {
                HorizontalCanvasModeSupport.pointKey($0.point) == key && netsMatch($0.netID, netID)
            }) {
                refs.append(HorizontalSelectableRef(id: package.id, type: .boardPackage))
            }
        }

        return HorizontalCanvasModeSupport.uniqueRefs(refs)
    }

    /// Pad/hole anchor points (with net) belonging to a package. Mirrors
    /// `BoardCanvasView.boardPackageConnectionAnchors` (returns tuples instead of
    /// the View-private MovingConnectionPoint).
    private static func packageConnectionAnchors(
        packageID: String,
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole]
    ) -> [(point: HorizontalPoint, netID: String?)] {
        let normalizedPackageID = HorizontalCanvasModeSupport.normalizedID(packageID)
        func belongsToPackage(_ geometryID: String) -> Bool {
            BoardMovePlanner.packageID(forGeometryID: geometryID).map(HorizontalCanvasModeSupport.normalizedID) == normalizedPackageID
        }
        let padAnchors = packagePads
            .filter { belongsToPackage($0.id) }
            .map { (point: HorizontalRect(points: $0.vertices).center, netID: $0.netID) }
        let holeAnchors = packageHoles
            .filter { belongsToPackage($0.id) }
            .map { (point: $0.position, netID: $0.netID) }
        return padAnchors + holeAnchors
    }
}
