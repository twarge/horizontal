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
        packageHoles: [HorizontalHole],
        padPositions: [String: HorizontalPoint] = [:]
    ) -> BoardResidentMovePlan {
        var plan = BoardResidentMovePlan()
        var movedConnectionKeys = Set<String>()
        var padEnds = BoardTrackPadEnds(padPositions: padPositions)
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

            // An end on a pad stays there (`BoardTrackPadEnds`), and so does an
            // arc's centre unless both ends move.
            let pinsFrom = padEnds.isOnPad(segment.from)
            let pinsTo = padEnds.isOnPad(segment.to)
            if !pinsFrom {
                if !ownersAt(segment.from, netID: segment.netID, includesPackages: false).isEmpty {
                    addConnectionPointMove(at: segment.from, netID: segment.netID)
                } else {
                    addSegmentMove(owner, from: true)
                }
            }
            if !pinsTo {
                if !ownersAt(segment.to, netID: segment.netID, includesPackages: false).isEmpty {
                    addConnectionPointMove(at: segment.to, netID: segment.netID)
                } else {
                    addSegmentMove(owner, to: true)
                }
            }
            if segment.center != nil, !pinsFrom, !pinsTo {
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
            case .blockSymbolPort, .busLabel, .busRipper, .drawingArc, .drawingLine, .lineNet, .netLabel, .powerSymbol, .schematicBlockSymbol, .schematicNetTie, .schematicSymbol, .padstackShape, .symbolPin:
                plan.unsupportedRefs.insert(ref)
            }
        }

        return plan
    }

    /// The geometry-id segment kinds that separate a package id from the rest of a
    /// board-geometry id like "pkg-uuid/pad/pad-uuid". Hoisted to a static so the
    /// whole-board index build doesn't rebuild this `Set` once per pad/hole.
    private static let packageGeometrySeparators: Set<String> = ["arc", "hole", "keepout", "line", "pad", "polygon", "text"]

    /// Derives the owning package id from a board-geometry id like
    /// "pkg-uuid/pad/pad-uuid", lowercased. The canvas calls this per pad, line
    /// and text on every scene build and every package move, so the common
    /// shape — ASCII, no empty components — is answered from one scan of the
    /// bytes; anything else takes the exact split-and-join path.
    static func packageID(forGeometryID geometryID: String) -> String? {
        var id = geometryID
        let fast: String?? = id.withUTF8 { bytes in
            switch packagePrefixScan(bytes) {
            case .prefix(let length):
                return .some(String(decoding: UnsafeBufferPointer(rebasing: bytes[..<length]), as: UTF8.self).lowercased())
            case .noPrefix:
                return .some(nil)
            case .needsSlowPath:
                return nil
            }
        }
        return fast ?? objectIDPrefix(in: geometryID, separators: packageGeometrySeparators)
    }

    /// `packageID(forGeometryID:) == normalizedPackageID`, without building the
    /// prefix string: the package-geometry loops ask this of every geometry
    /// item on the board for the one package they are moving.
    static func geometryID(_ geometryID: String, belongsToPackage normalizedPackageID: String) -> Bool {
        var id = geometryID
        var candidate = normalizedPackageID
        let fast: Bool? = id.withUTF8 { bytes in
            switch packagePrefixScan(bytes) {
            case .prefix(let length):
                return candidate.withUTF8 { candidateBytes in
                    candidateBytes.count == length
                        && (0..<length).allSatisfy { lowercasedASCII(bytes[$0]) == candidateBytes[$0] }
                }
            case .noPrefix:
                return false
            case .needsSlowPath:
                return nil
            }
        }
        return fast ?? (objectIDPrefix(in: geometryID, separators: packageGeometrySeparators) == normalizedPackageID)
    }

    private enum PackagePrefixScan {
        /// The package id is the first `length` bytes of the geometry id.
        case prefix(Int)
        case noPrefix
        /// Non-ASCII or an empty component: `lowercased()` and `split` could
        /// disagree with a byte scan, so only the exact path will do.
        case needsSlowPath
    }

    private static let packageGeometrySeparatorBytes: [[UInt8]] = packageGeometrySeparators.map { Array($0.utf8) }

    private static func packagePrefixScan(_ bytes: UnsafeBufferPointer<UInt8>) -> PackagePrefixScan {
        var componentStart = 0
        var componentCount = 0
        var previousComponentEnd = 0
        for offset in 0...bytes.count {
            let atEnd = offset == bytes.count
            if !atEnd {
                let byte = bytes[offset]
                if byte >= 0x80 {
                    return .needsSlowPath
                }
                if byte != UInt8(ascii: "/") {
                    continue
                }
            }
            guard offset > componentStart else {
                return .needsSlowPath
            }
            if componentCount > 0, isPackageGeometrySeparator(bytes, from: componentStart, to: offset) {
                return .prefix(previousComponentEnd)
            }
            componentCount += 1
            previousComponentEnd = offset
            componentStart = offset + 1
        }
        return .noPrefix
    }

    private static func isPackageGeometrySeparator(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Bool {
        let length = end - start
        return packageGeometrySeparatorBytes.contains { separator in
            separator.count == length && (0..<length).allSatisfy { lowercasedASCII(bytes[start + $0]) == separator[$0] }
        }
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
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
    /// `BoardCanvasView.expandedBoardMoveSelection`. Those at an end on a pad
    /// (`padPositions`, `BoardTrackPadEnds`) stay with the pad, so are left out.
    static func expandedSelection(
        _ refs: [HorizontalSelectableRef],
        tracks: [HorizontalSegment],
        netTies: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        vias: [HorizontalMarker],
        padPositions: [String: HorizontalPoint] = [:]
    ) -> [HorizontalSelectableRef] {
        var expanded = [HorizontalSelectableRef]()
        var padEnds = BoardTrackPadEnds(padPositions: padPositions)
        // Built at the first track, for all of them: a whole-board selection
        // looked each one up and scanned every junction and via per end.
        var segmentEnds: SegmentEndOwners?
        func endpointOwners(of ref: HorizontalSelectableRef) -> [HorizontalSelectableRef] {
            if segmentEnds == nil {
                segmentEnds = SegmentEndOwners(
                    tracks: tracks, netTies: netTies, junctions: junctions, junctionNetIDs: junctionNetIDs, vias: vias,
                    packages: [], packagePads: [], packageHoles: [], includesPackages: false
                )
            }
            return segmentEnds?.refs(of: ref) { !padEnds.isOnPad($0) } ?? []
        }
        for ref in refs {
            switch ref.type {
            case .track, .boardNetTie:
                expanded.append(ref)
                expanded.append(contentsOf: endpointOwners(of: ref))
            default:
                expanded.append(ref)
            }
        }
        return HorizontalCanvasModeSupport.uniqueRefs(expanded)
    }

    /// The refs (junctions, vias, packages) that "own" a movable endpoint at a
    /// point on a net. A move asking this of many ends builds `EndpointOwners`
    /// (or `SegmentEndOwners`) once instead.
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
        EndpointOwners(
            junctions: junctions, junctionNetIDs: junctionNetIDs, vias: vias,
            packages: packages, packagePads: packagePads, packageHoles: packageHoles,
            includesPackages: includesPackages
        ).refs(at: point, netID: netID)
    }

    /// What `movableEndpointOwnerRefs` finds, filed once by the point each
    /// owner stands on: a junction, a via, and a package at each of its pads'
    /// centres and holes, with their nets. A move asks it of every end of
    /// every selected track; asking `movableEndpointOwnerRefs` instead gathered
    /// every package's anchors from all the pads again for each end, which on
    /// Board C (213 tracks, 26 packages, 768 pads) read 8.5 million pad ids a
    /// Select All nudge, 22 to 88 s in Debug.
    struct EndpointOwners {
        private var ownersByPoint = [String: [BoardMovePointOwner]]()

        init(
            junctions: [String: HorizontalPoint],
            junctionNetIDs: [String: String],
            vias: [HorizontalMarker],
            packages: [HorizontalPlacement],
            packagePads: [HorizontalPolygon],
            packageHoles: [HorizontalHole],
            includesPackages: Bool
        ) {
            func key(_ point: HorizontalPoint) -> String { HorizontalCanvasModeSupport.pointKey(point) }
            // Junctions, then vias, then packages in the board's order, as the
            // refs at a point have always been listed.
            for (junctionID, junction) in junctions {
                ownersByPoint[key(junction), default: []].append(BoardMovePointOwner(
                    ref: HorizontalSelectableRef(id: junctionID, type: .junction), netID: junctionNetIDs[junctionID]
                ))
            }
            for via in vias {
                ownersByPoint[key(via.position), default: []].append(BoardMovePointOwner(
                    ref: HorizontalSelectableRef(id: via.id, type: .via), netID: via.netID
                ))
            }
            guard includesPackages, !packages.isEmpty else {
                return
            }
            var anchorsByPackageID = [String: [(key: String, netID: String?)]]()
            for pad in packagePads {
                if let packageID = BoardMovePlanner.packageID(forGeometryID: pad.id) {
                    anchorsByPackageID[HorizontalCanvasModeSupport.normalizedID(packageID), default: []]
                        .append((key(HorizontalRect(points: pad.vertices).center), pad.netID))
                }
            }
            for hole in packageHoles {
                if let packageID = BoardMovePlanner.packageID(forGeometryID: hole.id) {
                    anchorsByPackageID[HorizontalCanvasModeSupport.normalizedID(packageID), default: []]
                        .append((key(hole.position), hole.netID))
                }
            }
            for package in packages {
                let ref = HorizontalSelectableRef(id: package.id, type: .boardPackage)
                for anchor in anchorsByPackageID[HorizontalCanvasModeSupport.normalizedID(package.id)] ?? [] {
                    ownersByPoint[anchor.key, default: []].append(BoardMovePointOwner(ref: ref, netID: anchor.netID))
                }
            }
        }

        /// The owners at `point` on `netID`, or on no net either side.
        func refs(at point: HorizontalPoint, netID: String?) -> [HorizontalSelectableRef] {
            guard let owners = ownersByPoint[HorizontalCanvasModeSupport.pointKey(point)] else {
                return []
            }
            return HorizontalCanvasModeSupport.uniqueRefs(
                owners.filter { BoardMovePlanner.netsMatch($0.netID, netID) }.map(\.ref)
            )
        }
    }

    /// The owners of a board's track and net tie ends (`EndpointOwners`), for a
    /// move to ask of each segment it is given.
    struct SegmentEndOwners {
        private let tracks: SegmentsByID
        private let netTies: SegmentsByID
        private let owners: EndpointOwners

        init(
            tracks: [HorizontalSegment],
            netTies: [HorizontalSegment],
            junctions: [String: HorizontalPoint],
            junctionNetIDs: [String: String],
            vias: [HorizontalMarker],
            packages: [HorizontalPlacement],
            packagePads: [HorizontalPolygon],
            packageHoles: [HorizontalHole],
            includesPackages: Bool
        ) {
            self.tracks = SegmentsByID(tracks)
            self.netTies = SegmentsByID(netTies)
            owners = EndpointOwners(
                junctions: junctions, junctionNetIDs: junctionNetIDs, vias: vias,
                packages: packages, packagePads: packagePads, packageHoles: packageHoles,
                includesPackages: includesPackages
            )
        }

        /// The owners at the ends of the track or net tie `ref` names that
        /// `includesEnd` keeps, on its net; none for one the board lacks.
        func refs(
            of ref: HorizontalSelectableRef,
            includesEnd: (HorizontalPoint) -> Bool = { _ in true }
        ) -> [HorizontalSelectableRef] {
            guard let segment = (ref.type == .boardNetTie ? netTies : tracks)[ref.id] else {
                return []
            }
            var refs = [HorizontalSelectableRef]()
            for end in [segment.from, segment.to] where includesEnd(end) {
                refs += owners.refs(at: end, netID: segment.netID)
            }
            return HorizontalCanvasModeSupport.uniqueRefs(refs)
        }
    }

    /// Segments by their id, ignoring case, the first of each id as
    /// `first(where:)` finds it.
    private struct SegmentsByID {
        private var segments = [String: HorizontalSegment]()

        init(_ segments: [HorizontalSegment]) {
            self.segments.reserveCapacity(segments.count)
            for segment in segments {
                let id = HorizontalCanvasModeSupport.normalizedID(segment.id)
                if self.segments[id] == nil {
                    self.segments[id] = segment
                }
            }
        }

        subscript(id: String) -> HorizontalSegment? {
            segments[HorizontalCanvasModeSupport.normalizedID(id)]
        }
    }
}
