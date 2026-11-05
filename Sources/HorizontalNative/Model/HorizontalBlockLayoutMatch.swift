import Foundation

/// Which instances of a block are laid out alike on a board, worked out from
/// the board alone: Horizon's files say nothing about it, so nothing is
/// stored and this is found again from each board.
///
/// Two instances of a block are related when one rigid motion, a shift, a
/// turn and maybe a flip to the other side, takes most of one's parts onto
/// the same parts of the other. Each pair has its motion (`Pair.transform`),
/// the parts it takes onto each other (`synced`) and those it doesn't
/// (`differs`). Related instances form classes. An instance's copper is what
/// joins its own pads and nothing outside it (`owned`), and copper that the
/// motion takes onto copper of the other instance corresponds (`copper`).
final class HorizontalBlockLayoutMatch {
    typealias Instance = HorizontalBoardBlockInstances.Instance

    /// One instance's placed parts.
    struct Layout {
        var instance: Instance
        /// Its placed members' packages, by local path.
        var packages: [String: HorizontalPlacement]
        /// Each placed member's pads, pad uuid to centre in the package's
        /// own frame: what tells one footprint from another.
        var pads: [String: [String: HorizontalPoint]]
        /// Its members' board packages, lowercased.
        var packageIDs: Set<String>
        /// The box each placed member's pads cover on the board, by local path.
        var extents = [String: Box]()
    }

    struct Box: Equatable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double

        init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            (self.minX, self.minY, self.maxX, self.maxY) = (minX, minY, maxX, maxY)
        }

        init?(_ points: [HorizontalPoint]) {
            guard let first = points.first else { return nil }
            var box = Box(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
            for point in points.dropFirst() { box.add(point) }
            self = box
        }

        mutating func add(_ point: HorizontalPoint) {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }

        func union(_ other: Box) -> Box {
            Box(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
        }

        var area: Double { max(maxX - minX, 0) * max(maxY - minY, 0) }

        func overlap(_ other: Box) -> Double {
            max(min(maxX, other.maxX) - max(minX, other.minX), 0) * max(min(maxY, other.maxY) - max(minY, other.minY), 0)
        }
    }

    struct Pair {
        var from: String
        var to: String
        /// Takes `from`'s parts onto `to`'s.
        var transform: HorizontalPlacementTransform
        /// The middle of `from`'s compared parts, for the tolerance.
        var centroid: HorizontalPoint
        /// Parts the motion takes onto each other, by local path.
        var synced: Set<String>
        /// Parts placed in both, with one footprint, that it doesn't.
        var differs: Set<String>
        /// Whether the two count as laid out alike.
        var related: Bool

        /// How far a point of `from` may land from where the motion puts it:
        /// two nanometres, and half an angle unit's arc about the parts'
        /// middle, which a turn at an angle that isn't a whole number of
        /// units moves a part by when its angle is stored rounded.
        func tolerance(at point: HorizontalPoint) -> Double {
            HorizontalBlockLayoutMatch.tolerance(at: point, centroid: centroid)
        }
    }

    /// The copper an instance's pads join and nothing outside it does.
    struct OwnedCopper: Equatable {
        var tracks = Set<String>()
        var vias = Set<String>()
        var junctions = Set<String>()

        var isEmpty: Bool { tracks.isEmpty && vias.isEmpty && junctions.isEmpty }
    }

    /// One instance's copper that the motion of a pair takes onto the
    /// other's, by id (lowercased) both sides.
    struct CopperMap: Equatable {
        struct Track: Equatable {
            var id: String
            /// Whether the counterpart runs the other way, its `to` where
            /// this one's `from` lands.
            var reversed: Bool
        }
        var junctions = [String: String]()
        var tracks = [String: Track]()
        var vias = [String: String]()
    }

    let board: HorizontalBoard
    let instances: HorizontalBoardBlockInstances
    private(set) var layouts = [String: Layout]()
    private var pairs = [String: Pair]()
    /// Related instances, each class in name order, the classes by their
    /// first.
    private(set) var classes = [[String]]()
    private var classIndex = [String: Int]()
    private lazy var graph = CopperGraph(board: board)
    private var ownedCache = [String: OwnedCopper]()
    private var copperCache = [String: CopperMap]()
    private lazy var junctionLayers = board.junctionLayers()

    init(board: HorizontalBoard, instances: HorizontalBoardBlockInstances) {
        self.board = board
        self.instances = instances
        guard !instances.isEmpty else {
            return
        }
        var packagesByComponent = [String: HorizontalPlacement]()
        for package in board.packages {
            if let componentID = package.componentID?.lowercased() {
                packagesByComponent[componentID] = package
            }
        }
        var padBoxes = [String: Box]()
        for pad in board.packagePads {
            guard let package = BoardMovePlanner.packageID(forGeometryID: pad.id), let box = Box(pad.vertices) else { continue }
            padBoxes[package] = padBoxes[package].map { $0.union(box) } ?? box
        }
        var padsByPackage = [String: [String: HorizontalPoint]]()
        for (path, position) in board.packagePadPositions {
            guard let slash = path.firstIndex(of: "/") else { continue }
            padsByPackage[path[..<slash].lowercased(), default: [:]][String(path[path.index(after: slash)...]).lowercased()] = position
        }
        for paths in instances.siblings.values {
            for path in paths {
                guard let instance = instances.instances[path] else { continue }
                var layout = Layout(instance: instance, packages: [:], pads: [:], packageIDs: [])
                for (local, flatID) in instance.members {
                    guard let package = packagesByComponent[flatID] else { continue }
                    layout.packages[local] = package
                    layout.packageIDs.insert(package.id.lowercased())
                    layout.extents[local] = padBoxes[package.id.lowercased()] ?? Box([package.position])
                    let frame = HorizontalBoard.placementTransform(of: package).inverse
                    layout.pads[local] = (padsByPackage[package.id.lowercased()] ?? [:]).mapValues { frame.applying(to: $0) }
                }
                layouts[path] = layout
            }
        }

        var parents = [String: String]()
        func root(_ path: String) -> String {
            var path = path
            while let parent = parents[path], parent != path { path = parent }
            return path
        }
        for (blockID, paths) in instances.siblings.sorted(by: { $0.key < $1.key }) {
            _ = blockID
            for (index, from) in paths.enumerated() {
                for to in paths[(index + 1)...] {
                    guard let a = layouts[from], let b = layouts[to], let pair = Self.fit(a, b) else { continue }
                    pairs[Self.key(from, to)] = pair
                    pairs[Self.key(to, from)] = Self.reversed(pair, layout: b)
                    if pair.related {
                        let (ra, rb) = (root(from), root(to))
                        if ra != rb { parents[rb] = ra }
                    }
                }
            }
        }
        var grouped = [String: [String]]()
        for paths in instances.siblings.values {
            for path in paths where pairs.keys.contains(where: { $0.hasPrefix(path + ">") && pairs[$0]?.related == true }) {
                grouped[root(path), default: []].append(path)
            }
        }
        classes = grouped.values
            .map { $0.compactMap { instances.instances[$0] }.sorted(by: HorizontalBoardBlockInstances.inOrder).map(\.path) }
            .sorted { lhs, rhs in
                guard let l = lhs.first.flatMap({ instances.instances[$0] }), let r = rhs.first.flatMap({ instances.instances[$0] }) else { return false }
                return HorizontalBoardBlockInstances.inOrder(l, r)
            }
        for (index, members) in classes.enumerated() {
            for path in members { classIndex[path] = index }
        }
    }

    // MARK: - Reading it

    /// The pair from one instance to another, related or not; nil where they
    /// have fewer than two parts placed alike to compare.
    func pair(from: String, to: String) -> Pair? {
        pairs[Self.key(from, to)]
    }

    /// The instances laid out like `path`, each related to it directly,
    /// itself left out, in name order: the ones an edit of it reaches.
    func classmates(of path: String) -> [String] {
        guard let index = classIndex[path] else { return [] }
        return classes[index].filter { $0 != path && pairs[Self.key(path, $0)]?.related == true }
    }

    /// The instances (innermost first) of blocks used more than once that a
    /// board package's component is a member of.
    func instances(ofPackage packageID: String) -> [Instance] {
        let id = packageID.lowercased()
        guard let componentID = board.packages.first(where: { $0.id.lowercased() == id })?.componentID else { return [] }
        return instances.syncedInstances(of: componentID)
    }

    /// The copper `path`'s own pads join and nothing outside it does: what
    /// they reach without going through another part's pad, less what
    /// another part's pad reaches without going through one of this
    /// instance's. Floating copper and panel copies belong to no instance.
    func owned(_ path: String) -> OwnedCopper {
        if let cached = ownedCache[path] {
            return cached
        }
        guard let layout = layouts[path] else { return OwnedCopper() }
        let mine = layout.packageIDs
        let starts = graph.padNodes(of: mine)
        let own = graph.reach(from: starts) { !mine.contains($0) }
        let foreign = graph.reach(from: Array(own.blockers)) { mine.contains($0) }
        let result = OwnedCopper(
            tracks: own.tracks.subtracting(foreign.tracks),
            vias: own.vias.subtracting(foreign.vias),
            junctions: own.junctions.subtracting(foreign.junctions)
        )
        ownedCache[path] = result
        return result
    }

    /// `from`'s own copper that the pair's motion takes onto `to`'s own
    /// copper: positions within the pair's tolerance, on the layer the
    /// motion takes it to, at the width a width from the rules leaves free
    /// and with a via's span, padstack or definition. Empty for instances
    /// that aren't related.
    func copper(from: String, to: String) -> CopperMap {
        let key = Self.key(from, to)
        if let cached = copperCache[key] {
            return cached
        }
        guard let pair = pairs[key], pair.related else { return CopperMap() }
        let source = owned(from), target = owned(to)
        let motion = HorizontalBoardMotion(pair.transform, innerLayerCount: max(board.copperLayerCount - 2, 0))
        var map = CopperMap()

        let targetJunctions = PointIndex(board.junctions.filter { target.junctions.contains($0.key.lowercased()) }.map { ($0.key.lowercased(), $0.value) })
        let layers = junctionLayers.reduce(into: [String: Set<Int>]()) { $0[$1.key.lowercased()] = $1.value }
        var usedJunctions = Set<String>()
        for (id, point) in board.junctions.sorted(by: { $0.key < $1.key }) where source.junctions.contains(id.lowercased()) {
            let wanted = Set((layers[id.lowercased()] ?? []).map(motion.layer))
            let landing = motion.point(point)
            let match = targetJunctions.near(landing, within: pair.tolerance(at: point))
                .filter { !usedJunctions.contains($0) && (layers[$0] ?? []) == wanted }
                .min()
            if let match {
                map.junctions[id.lowercased()] = match
                usedJunctions.insert(match)
            }
        }

        let targetTracks = board.tracks.filter { target.tracks.contains($0.id.lowercased()) }
        let trackIndex = PointIndex(targetTracks.flatMap { [($0.id.lowercased(), $0.from), ($0.id.lowercased(), $0.to)] })
        let tracksByID = targetTracks.reduce(into: [String: HorizontalSegment]()) { $0[$1.id.lowercased()] = $1 }
        var usedTracks = Set<String>()
        for track in board.tracks.sorted(by: { $0.id < $1.id }) where source.tracks.contains(track.id.lowercased()) {
            let from = motion.point(track.from), to = motion.point(track.to)
            let tolerance = max(pair.tolerance(at: track.from), pair.tolerance(at: track.to))
            let layer = track.layer.map(motion.layer)
            let candidates = trackIndex.near(from, within: tolerance).filter { !usedTracks.contains($0) }.sorted()
            for candidate in candidates {
                guard let other = tracksByID[candidate], other.layer == layer,
                      Self.sameWidth(track, other) else { continue }
                let forward = Self.distance(other.from, from) <= tolerance && Self.distance(other.to, to) <= tolerance
                let backward = Self.distance(other.to, from) <= tolerance && Self.distance(other.from, to) <= tolerance
                guard forward || backward else { continue }
                if let center = track.center {
                    guard let otherCenter = other.center, Self.distance(motion.point(center), otherCenter) <= tolerance else { continue }
                } else if other.center != nil {
                    continue
                }
                map.tracks[track.id.lowercased()] = CopperMap.Track(id: candidate, reversed: !forward)
                usedTracks.insert(candidate)
                break
            }
        }

        let targetVias = board.vias.filter { target.vias.contains($0.id.lowercased()) }
        let viaIndex = PointIndex(targetVias.map { ($0.id.lowercased(), $0.position) })
        let viasByID = targetVias.reduce(into: [String: HorizontalMarker]()) { $0[$1.id.lowercased()] = $1 }
        var usedVias = Set<String>()
        for via in board.vias.sorted(by: { $0.id < $1.id }) where source.vias.contains(via.id.lowercased()) {
            let landing = motion.point(via.position)
            let wantedLayers = via.copperLayers.map(motion.layer).sorted()
            let match = viaIndex.near(landing, within: pair.tolerance(at: via.position))
                .filter { candidate in
                    guard !usedVias.contains(candidate), let other = viasByID[candidate] else { return false }
                    return other.copperLayers.sorted() == wantedLayers && Self.sameShape(via, other)
                }
                .min()
            if let match {
                map.vias[via.id.lowercased()] = match
                usedVias.insert(match)
            }
        }
        copperCache[key] = map
        return map
    }

    // MARK: - Fitting

    static func key(_ from: String, _ to: String) -> String {
        from + ">" + to
    }

    static func tolerance(at point: HorizontalPoint, centroid: HorizontalPoint) -> Double {
        2 + distance(point, centroid) * Double.pi / 65_536
    }

    static func distance(_ a: HorizontalPoint, _ b: HorizontalPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func wrapped(_ angle: Int) -> Int {
        let wrapped = angle % 65_536
        return wrapped < 0 ? wrapped + 65_536 : wrapped
    }

    /// How far apart two angles are, the short way round.
    private static func angleGap(_ a: Int, _ b: Int) -> Int {
        let gap = wrapped(a - b)
        return min(gap, 65_536 - gap)
    }

    /// The motion that takes most of `a`'s parts onto `b`'s, nil when fewer
    /// than two parts are placed in both with one footprint.
    static func fit(_ a: Layout, _ b: Layout) -> Pair? {
        let comparable = a.packages.keys.filter { key in
            guard let pa = a.packages[key], let pb = b.packages[key],
                  pa.componentDetails?.partID?.lowercased() == pb.componentDetails?.partID?.lowercased(),
                  let padsA = a.pads[key], let padsB = b.pads[key], Set(padsA.keys) == Set(padsB.keys) else { return false }
            return padsA.allSatisfy { pad, point in padsB[pad].map { distance($0, point) <= 10 } ?? false }
        }.sorted { lhs, rhs in
            // By refdes, so where nothing else decides, the first part by name
            // (R1 before R2) is the one kept where it is.
            let l = a.packages[lhs]?.componentDetails?.refdes ?? "", r = a.packages[rhs]?.componentDetails?.refdes ?? ""
            switch l.localizedStandardCompare(r) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs < rhs
            }
        }
        guard comparable.count >= 2 else { return nil }

        let flips = comparable.map { a.packages[$0]!.mirrored != b.packages[$0]!.mirrored }
        let mirrored = flips.filter { $0 }.count * 2 > flips.count
        let sided = comparable.filter { (a.packages[$0]!.mirrored != b.packages[$0]!.mirrored) == mirrored }
        func turn(_ key: String) -> Int {
            let pa = a.packages[key]!, pb = b.packages[key]!
            return wrapped(mirrored ? pb.angle + pa.angle : pb.angle - pa.angle)
        }
        let turns = sided.map(turn)
        guard let angle = turns.max(by: { lhs, rhs in
            let l = turns.filter { angleGap($0, lhs) <= 1 }.count, r = turns.filter { angleGap($0, rhs) <= 1 }.count
            return l != r ? l < r : lhs > rhs
        }) else { return nil }
        let turned = sided.filter { angleGap(turn($0), angle) <= 1 }

        let centroid = comparable.reduce(HorizontalPoint.zero) { sum, key in
            let p = a.packages[key]!.position
            return HorizontalPoint(x: sum.x + p.x / Double(comparable.count), y: sum.y + p.y / Double(comparable.count))
        }
        let linear = HorizontalPlacementTransform(shift: .zero, angle: angle, mirrored: mirrored)
        let residuals = turned.map { key -> (key: String, shift: HorizontalPoint, tolerance: Double) in
            let landed = linear.applying(to: a.packages[key]!.position), target = b.packages[key]!.position
            return (key, HorizontalPoint(x: target.x - landed.x, y: target.y - landed.y),
                    tolerance(at: a.packages[key]!.position, centroid: centroid))
        }
        func cluster(around index: Int) -> [Int] {
            residuals.indices.filter {
                distance(residuals[$0].shift, residuals[index].shift) <= residuals[$0].tolerance + residuals[index].tolerance
            }
        }
        guard let best = residuals.indices.max(by: { lhs, rhs in
            let l = cluster(around: lhs).count, r = cluster(around: rhs).count
            return l != r ? l < r : lhs > rhs
        }) else { return nil }
        let members = cluster(around: best)
        let shift = members.reduce(HorizontalPoint.zero) { sum, index in
            HorizontalPoint(x: sum.x + residuals[index].shift.x / Double(members.count),
                            y: sum.y + residuals[index].shift.y / Double(members.count))
        }
        let transform = HorizontalPlacementTransform(shift: shift.rounded, angle: angle, mirrored: mirrored)

        var synced = Set<String>()
        for key in comparable {
            let pa = a.packages[key]!, pb = b.packages[key]!
            let placed = transform.accumulated(with: HorizontalBoard.placementTransform(of: pa))
            if placed.mirrored == pb.mirrored, angleGap(placed.angle, pb.angle) <= 1,
               distance(placed.shift, pb.position) <= tolerance(at: pa.position, centroid: centroid) {
                synced.insert(key)
            }
        }
        let differs = Set(comparable).subtracting(synced)
        let stacked = !mirrored && ((angle == 0 && distance(shift, .zero) < 1_000) || overlaps(a, b, keys: comparable))
        return Pair(
            from: a.instance.path, to: b.instance.path, transform: transform, centroid: centroid,
            synced: synced, differs: differs,
            related: !stacked && synced.count >= 2 && synced.count * 2 > comparable.count
        )
    }

    /// The pair the other way round: the inverse motion, about where the
    /// first instance's middle lands.
    private static func reversed(_ pair: Pair, layout: Layout) -> Pair {
        Pair(from: pair.to, to: pair.from, transform: pair.transform.inverse.rounded,
             centroid: pair.transform.applying(to: pair.centroid),
             synced: pair.synced, differs: pair.differs, related: pair.related)
    }

    /// Whether two instances on one side sit over each other more than half,
    /// the boxes their parts' pads cover: one stacked on the other, where
    /// which part is which instance's can't be told. On opposite sides one
    /// can sit right under the other.
    private static func overlaps(_ a: Layout, _ b: Layout, keys: [String]) -> Bool {
        func box(_ layout: Layout) -> Box? {
            keys.compactMap { layout.extents[$0] }.reduce(nil) { (box: Box?, next: Box) in box.map { $0.union(next) } ?? next }
        }
        guard let p = box(a), let q = box(b) else { return false }
        let smaller = min(p.area, q.area)
        return smaller > 0 && p.overlap(q) > smaller / 2
    }

    private static func sameWidth(_ a: HorizontalSegment, _ b: HorizontalSegment) -> Bool {
        (a.widthFromRules && b.widthFromRules) || abs(a.width - b.width) < 1
    }

    private static func sameShape(_ a: HorizontalMarker, _ b: HorizontalMarker) -> Bool {
        if a.fromRules && b.fromRules {
            return true
        }
        return a.fromRules == b.fromRules
            && a.definitionID?.lowercased() == b.definitionID?.lowercased()
            && a.padstackID?.lowercased() == b.padstackID?.lowercased()
            && abs(a.size - b.size) < 1
            && abs((a.holeSize ?? 0) - (b.holeSize ?? 0)) < 1
    }
}

/// Ids found by position: a grid of one-micrometre cells, so a point is
/// looked for in its cell and the eight around it.
private struct PointIndex {
    private var cells = [Cell: [(id: String, point: HorizontalPoint)]]()

    private struct Cell: Hashable {
        var x: Int64
        var y: Int64
    }

    private static let size = 1_000.0

    init(_ items: [(String, HorizontalPoint)]) {
        for (id, point) in items {
            cells[Self.cell(point), default: []].append((id, point))
        }
    }

    private static func cell(_ point: HorizontalPoint) -> Cell {
        Cell(x: Int64((point.x / size).rounded(.down)), y: Int64((point.y / size).rounded(.down)))
    }

    /// The ids within `tolerance` of `point`, nearest first; a tolerance
    /// wider than a cell looks wider.
    func near(_ point: HorizontalPoint, within tolerance: Double) -> [String] {
        let reach = Int64((tolerance / Self.size).rounded(.up)) + 1
        let center = Self.cell(point)
        var found = [(id: String, distance: Double)]()
        for dx in -reach...reach {
            for dy in -reach...reach {
                for item in cells[Cell(x: center.x + dx, y: center.y + dy)] ?? [] {
                    let distance = HorizontalBlockLayoutMatch.distance(item.point, point)
                    if distance <= tolerance {
                        found.append((item.id, distance))
                    }
                }
            }
        }
        return found.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.id < $1.id }.map(\.id)
    }
}

/// The board's copper as a graph for flooding: pads, junctions, vias and
/// loose track ends are nodes, tracks are edges, and a via joins whatever is
/// at its point. Panel copies are left out.
private struct CopperGraph {
    struct Edge {
        var track: String
        var other: String
    }

    struct Reach {
        var tracks = Set<String>()
        var vias = Set<String>()
        var junctions = Set<String>()
        /// Pads it stopped at.
        var blockers = Set<String>()
    }

    private var edges = [String: [Edge]]()
    private var links = [String: [String]]()
    /// Each pad node's package, lowercased.
    private var padPackages = [String: String]()
    private var padNodesByPackage = [String: [String]]()

    init(board: HorizontalBoard) {
        var padsAtPoint = [String: [String]]()
        for (path, position) in board.packagePadPositions {
            let node = "p:" + path.lowercased()
            padsAtPoint[HorizontalBoard.junctionPointKey(position), default: []].append(node)
            if let slash = path.firstIndex(of: "/") {
                let package = path[..<slash].lowercased()
                padPackages[node] = package
                padNodesByPackage[package, default: []].append(node)
            }
        }
        for key in padsAtPoint.keys {
            padsAtPoint[key]?.sort()
        }
        func node(_ point: HorizontalPoint, junction: String?, layer: Int?) -> String {
            if let junction, board.junctions[junction] != nil {
                return "j:" + junction.lowercased()
            }
            let key = HorizontalBoard.junctionPointKey(point)
            if let pad = padsAtPoint[key]?.first {
                return pad
            }
            return "f:\(key):\(layer ?? 0)"
        }
        for track in board.tracks where !track.id.contains("/") {
            let from = node(track.from, junction: track.fromJunctionID, layer: track.layer)
            let to = node(track.to, junction: track.toJunctionID, layer: track.layer)
            let id = track.id.lowercased()
            edges[from, default: []].append(Edge(track: id, other: to))
            edges[to, default: []].append(Edge(track: id, other: from))
        }
        let junctionsAtPoint = board.junctionIDsByPoint()
        for via in board.vias where !via.id.contains("/") {
            let viaNode = "v:" + via.id.lowercased()
            let key = HorizontalBoard.junctionPointKey(via.position)
            var joined = (junctionsAtPoint[key] ?? []).map { "j:" + $0.lowercased() }
            joined += padsAtPoint[key] ?? []
            joined += via.copperLayers.map { "f:\(key):\($0)" }
            for other in joined {
                links[viaNode, default: []].append(other)
                links[other, default: []].append(viaNode)
            }
        }
    }

    func padNodes(of packages: Set<String>) -> [String] {
        packages.sorted().flatMap { padNodesByPackage[$0] ?? [] }
    }

    /// What `starts` reach, stopping at a pad whose package `blocks`.
    func reach(from starts: [String], blocks: (String) -> Bool) -> Reach {
        var reach = Reach()
        var seen = Set(starts)
        var queue = starts
        while let node = queue.popLast() {
            if let package = padPackages[node], blocks(package) {
                reach.blockers.insert(node)
                continue
            }
            if node.hasPrefix("v:") {
                reach.vias.insert(String(node.dropFirst(2)))
            } else if node.hasPrefix("j:") {
                reach.junctions.insert(String(node.dropFirst(2)))
            }
            for edge in edges[node] ?? [] {
                reach.tracks.insert(edge.track)
                if seen.insert(edge.other).inserted {
                    queue.append(edge.other)
                }
            }
            for other in links[node] ?? [] where seen.insert(other).inserted {
                queue.append(other)
            }
        }
        return reach
    }
}
