import Foundation

/// Copper that is closer to something than the board's rules allow: two nets'
/// copper, copper and an unplated hole, or copper and the board's edge.
struct HorizontalClearanceFinding: Identifiable, Hashable, Sendable {
    enum Check: String, Hashable, Sendable {
        /// clearance_copper: copper of two nets.
        case copper
        /// clearance_copper_other: copper and an unplated hole.
        case hole
        /// clearance_copper_other: copper and the board's edge.
        case boardEdge = "board_edge"
    }

    /// One side of a finding.
    struct Object: Hashable, Sendable {
        /// What the rule tables call it; a net tie is `.netTie`.
        var type: HorizontalPatchType
        /// The track's, via's, plane's or hole's id; a pad's
        /// "package/pad/pad" path; empty for the board edge.
        var id: String
        /// "Track", "Pad U3.4", "Via", "Plane", "Hole J1", "Board edge".
        var label: String
        /// Lowercased; nil for copper on no net, a hole and the board edge.
        var netID: String?
        /// Nil for no net, and for a net with no name.
        var netName: String?
        /// The component a pad or a package's hole belongs to.
        var componentID: String?

        /// The label and the net, as a finding names it.
        var name: String {
            switch type {
            case .holeNPTH, .boardEdge:
                return label
            default:
                return "\(label) (\(netName ?? (netID == nil ? "no net" : "unnamed net")))"
            }
        }
    }

    var check: Check
    /// The copper; for a copper finding the one whose kind comes first in the
    /// rule tables (a track before a pad, a pad before a plane).
    var first: Object
    var second: Object
    /// Every copper layer where the two are closer than the clearance there,
    /// top first.
    var layers: [Int]
    /// The layer the clearance and rule are for: the one that asks the most.
    var layer: Int
    /// Copper to copper, in nanometres; zero where they touch or overlap.
    var distance: Double
    var clearance: Double
    /// The rule's key in its table; nil where no rule takes the pair and
    /// Horizon's 0.1 mm applies.
    var ruleID: String?
    /// The rule's matches and layer, as the rules window lists it.
    var ruleBrief: String
    /// Copper outside the board, or in a cutout of it: no distance to the
    /// edge says how far.
    var outsideBoard = false
    /// Where the two come closest: between the nearest points of their copper.
    var location: HorizontalPoint
    /// The nearest points themselves, on each side's copper.
    var firstPoint: HorizontalPoint
    var secondPoint: HorizontalPoint

    var id: String { "\(check.rawValue)|\(first.type.jsonString)|\(first.id)|\(second.type.jsonString)|\(second.id)" }

    /// How much closer than allowed.
    var shortfall: Double { clearance - distance }

    var ruleKind: HorizontalBoardRuleKind {
        check == .copper ? .clearanceCopper : .clearanceCopperOther
    }

    var title: String {
        switch check {
        case .copper, .hole:
            return "\(first.name) near \(second.name)"
        case .boardEdge:
            return "\(first.name) near the board edge"
        }
    }

    /// "0.080 mm apart on Top Copper, where the rules ask 0.100 mm".
    var detail: String {
        let place = layers.count == 1
            ? "on \(HorizontalBoardLayers.name(for: layers[0]))"
            : "on \(layers.map(HorizontalBoardLayers.name(for:)).joined(separator: ", "))"
        let apart: String
        if outsideBoard {
            apart = "Outside the board \(place)"
        } else if distance <= 0 {
            apart = "Touching \(place)"
        } else {
            apart = "\(Self.millimetres(distance)) apart \(place)"
        }
        let rule = ruleID == nil ? "no rule, Horizon's" : ruleBrief
        return "\(apart), where the rules ask \(Self.millimetres(clearance)) (\(rule))."
    }

    /// A region to frame to show the finding: its nearest points, with room
    /// round them.
    var region: HorizontalRect {
        let span: Double = hypot(firstPoint.x - secondPoint.x, firstPoint.y - secondPoint.y)
        let margin: Double = max(clearance * 10, 1_500_000, span)
        return HorizontalRouteClearanceProbe.bounds([firstPoint, secondPoint], growth: margin)
    }

    static func millimetres(_ nanometres: Double) -> String {
        String(format: "%.3f mm", nanometres / 1_000_000)
    }
}

/// Horizon's copper clearance checks — board_rules_check_clearance_copper.cpp,
/// and the unplated hole and board edge parts of
/// board_rules_check_clearance_copper_non_copper.cpp — measured on the copper
/// itself rather than by offsetting polygons.
///
/// Every pair of copper objects of two nets on a layer they share is checked
/// against the clearance `HorizontalBoardRules.clearanceCopper(net1:net2:layer:)`
/// gives between their kinds: tracks and net ties, pads, through-hole pads,
/// vias, plated holes and planes' fills. Copper on no net is checked against
/// copper on a net and not against other copper on none, as Horizon's patches
/// for no net are one. A net tie and the copper of a net it ties are not
/// checked. Every copper object is checked against every unplated hole, and
/// against the board's edge, with what `clearanceCopperOther` asks; copper
/// outside the board, or in a cutout, is too close to the edge by any measure.
/// The rules' routing offset is a margin Horizon's router keeps and its check
/// does not, so it isn't checked either.
///
/// One finding is one pair of objects, with every layer the pair is too close
/// on and the numbers for the layer that asks the most. A pad is its shapes on
/// a layer together; a plane is all its fragments. The geometry is the
/// probe's (`HorizontalRouteClearanceProbe`): a track's centreline and width,
/// a via's or hole's disc, a pad's polygon, a fill's paths. A coarse grid per
/// copper layer finds the pairs within the largest clearance the rules give;
/// a fill's paths and the outline are split into short runs, a couple of
/// millimetres across at most, so only the runs near something are measured.
enum HorizontalBoardClearanceCheck {
    /// How much closer than the clearance two objects must be to be reported,
    /// in nanometres: floating point, not geometry. Horizon counts an overlap
    /// of the offset polygons, so copper at exactly the clearance passes.
    static let tolerance = 1.0

    /// Pairs of nets a net tie joins, as "a|b" with the ids lowercased and
    /// sorted: copper of one is not checked against a net tie of the other.
    static func netPairKey(_ a: String, _ b: String) -> String {
        let a = a.lowercased(), b = b.lowercased()
        return a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    /// The nets each of the board's net ties joins, from the junctions its
    /// ends are on.
    static func tiedNets(of board: HorizontalBoard) -> Set<String> {
        var tied = Set<String>()
        for tie in board.netTies {
            let nets = [tie.netID, tie.fromJunctionID.flatMap { board.junctionNetIDs[$0] },
                        tie.toJunctionID.flatMap { board.junctionNetIDs[$0] }]
                .compactMap { $0?.lowercased() }
            for a in nets {
                for b in nets where a != b {
                    tied.insert(netPairKey(a, b))
                }
            }
        }
        return tied
    }

    /// The findings on `board`, worst first within each check. `rules`
    /// defaults to the board's own; `tiedNets` adds pairs of nets the design's
    /// net ties join (`netPairKey`) to those the board's net ties show.
    /// `isCancelled` is asked now and then, and an empty answer returned once
    /// it says yes.
    static func run(
        board: HorizontalBoard,
        rules: HorizontalBoardRules? = nil,
        tiedNets: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) -> [HorizontalClearanceFinding] {
        var engine = Engine(board: board, rules: rules ?? board.rules, tiedNets: tiedNets.union(Self.tiedNets(of: board)))
        guard let findings = engine.run(isCancelled: isCancelled) else {
            return []
        }
        return findings
    }
}

// MARK: - Engine

private struct Box {
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity

    mutating func add(_ point: HorizontalPoint) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }

    mutating func add(_ box: Box) {
        minX = min(minX, box.minX)
        minY = min(minY, box.minY)
        maxX = max(maxX, box.maxX)
        maxY = max(maxY, box.maxY)
    }

    func grown(_ amount: Double) -> Box {
        Box(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }

    /// How far apart the boxes are; zero where they overlap.
    func gap(to other: Box) -> Double {
        let dx = max(0, other.minX - maxX, minX - other.maxX)
        let dy = max(0, other.minY - maxY, minY - other.maxY)
        return dx == 0 ? dy : dy == 0 ? dx : (dx * dx + dy * dy).squareRoot()
    }

    func contains(_ point: HorizontalPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// One object's copper: runs of edges, each edge a segment with `radius` of
/// copper round it (a track's half width, a via's radius on a zero-length
/// edge, nothing round a pad's or a fill's outline), and for an outline the
/// area inside it.
private struct Body {
    var object: HorizontalClearanceFinding.Object
    var net: String?
    /// Copper layers, one bit each: top, the inner layers, bottom.
    var layers: UInt64
    var radius: Double
    var box = Box()
    /// Areas the copper fills, together: each a set of paths filled even-odd
    /// (a fragment of a fill with its holes, or one pad shape).
    var regions: [[HorizontalBoard.PlanePath]] = []
    /// Each region's box.
    var regionBoxes: [Box] = []
    /// A point of the copper in each region, or of the centreline.
    var probes: [HorizontalPoint] = []
    var elements: Range<Int> = 0..<0

    var isHole: Bool { object.type == .holeNPTH }

    func encloses(_ point: HorizontalPoint) -> Bool {
        guard box.contains(point) else { return false }
        for (paths, box) in zip(regions, regionBoxes) where box.contains(point) {
            var count = 0
            for path in paths where path.contains(point) {
                count += 1
            }
            if count % 2 == 1 {
                return true
            }
        }
        return false
    }
}

/// A run of one body's edges, which the grid indexes.
private struct Element {
    var body: Int
    var edges: Range<Int>
    var box: Box
}

/// A uniform grid of boxes, as the probe's.
private struct Grid {
    private var originX = 0.0
    private var originY = 0.0
    private let cellSize: Double
    private var columns = 1
    private var rows = 1
    private var cells: [[Int32]] = [[]]
    private var oversized: [Int32] = []

    /// `ids` names each box, its index where nil.
    init(boxes: [Box], ids: [Int32]? = nil, cellSize: Double = 1_000_000) {
        self.cellSize = cellSize
        guard !boxes.isEmpty else { return }
        var all = Box()
        for box in boxes {
            all.add(box)
        }
        originX = all.minX
        originY = all.minY
        columns = max(1, min(1024, Int(((all.maxX - all.minX) / cellSize).rounded(.up)) + 1))
        rows = max(1, min(1024, Int(((all.maxY - all.minY) / cellSize).rounded(.up)) + 1))
        cells = [[Int32]](repeating: [], count: columns * rows)
        for (index, box) in boxes.enumerated() {
            let id = ids?[index] ?? Int32(index)
            let range = cellRange(box)
            if (range.maxColumn - range.minColumn + 1) * (range.maxRow - range.minRow + 1) > 4096 {
                oversized.append(id)
                continue
            }
            for row in range.minRow...range.maxRow {
                for column in range.minColumn...range.maxColumn {
                    cells[row * columns + column].append(id)
                }
            }
        }
    }

    private func cellRange(_ box: Box) -> (minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int) {
        func column(_ x: Double) -> Int { min(max(Int(((x - originX) / cellSize).rounded(.down)), 0), columns - 1) }
        func row(_ y: Double) -> Int { min(max(Int(((y - originY) / cellSize).rounded(.down)), 0), rows - 1) }
        return (column(box.minX), column(box.maxX), row(box.minY), row(box.maxY))
    }

    /// Every index whose box may overlap `box`, some more than once.
    func forEach(overlapping box: Box, _ body: (Int) -> Void) {
        for index in oversized {
            body(Int(index))
        }
        let range = cellRange(box)
        for row in range.minRow...range.maxRow {
            for column in range.minColumn...range.maxColumn {
                for index in cells[row * columns + column] {
                    body(Int(index))
                }
            }
        }
    }
}

/// The least distance between two runs of edges: which edges, and how far
/// apart they are before their copper's radii.
private struct Nearest {
    var distance: Double
    var first: Int
    var second: Int
}

private struct Engine {
    /// The most edges in one run of a fill's or the outline's paths.
    static let runLength = 32
    /// The most a run of edges spans, in nanometres.
    static let runExtent = 2_000_000.0
    /// Pads, outlines and fills as the pour tessellates them.
    static let arcPrecision = 48

    let board: HorizontalBoard
    let rules: HorizontalBoardRules
    let tiedNets: Set<String>
    let names: HorizontalRouteRuleNames

    var bodies: [Body] = []
    var elements: [Element] = []
    var from: [HorizontalPoint] = []
    var to: [HorizontalPoint] = []
    /// The board outline's edges, in runs, and the area inside it.
    var outlineElements: [Element] = []
    var outline: [HorizontalBoard.PlanePath] = []

    var bodyNets: [Int32] = []
    var netCount = 0
    var copperRules: [Int: (rule: HorizontalRuleClearanceCopper, slot: Int)] = [:]
    var otherRules: [Int: (rule: HorizontalRuleClearanceCopperOther, slot: Int)] = [:]
    /// The rules the findings name: each one's id (nil for none) and brief.
    var ruleSlots: [(id: String?, brief: String)] = []
    var slotByRule: [String: Int] = [:]

    init(board: HorizontalBoard, rules: HorizontalBoardRules, tiedNets: Set<String>) {
        self.board = board
        self.rules = rules
        self.tiedNets = tiedNets
        names = HorizontalRouteRuleNames(netDetails: rules.netDetails, netClasses: [])
    }

    // MARK: Layers

    /// A copper layer's bit: top, the inner layers in order, bottom.
    static func bit(_ layer: Int) -> UInt64? {
        switch layer {
        case HorizontalBoardLayers.topCopper: return 1
        case HorizontalBoardLayers.bottomCopper: return 1 << 63
        case -62 ... -1: return 1 << UInt64(-layer)
        default: return nil
        }
    }

    static func mask(_ layers: [Int]) -> UInt64 {
        layers.reduce(0) { $0 | (bit($1) ?? 0) }
    }

    /// The layers of `mask`, top first.
    static func layers(_ mask: UInt64) -> [Int] {
        var layers = [Int]()
        var rest = mask
        while rest != 0 {
            let index = rest.trailingZeroBitCount
            rest &= rest - 1
            layers.append(index == 0 ? HorizontalBoardLayers.topCopper : index == 63 ? HorizontalBoardLayers.bottomCopper : -index)
        }
        return layers
    }

    var allCopper: UInt64 {
        Self.mask(BoardTrackRouting.throughViaLayers(copperLayerCount: max(board.copperLayerCount, 2)))
    }

    // MARK: Bodies

    func netName(_ net: String?) -> String? {
        guard let net, let name = board.netDetails[net]?.name, !name.isEmpty else { return nil }
        return name
    }

    /// Adds a body whose copper is `paths` (each closed when `closed`, a
    /// single point a zero-length edge) with `radius` round each edge.
    mutating func add(
        _ object: HorizontalClearanceFinding.Object,
        layers: UInt64,
        radius: Double,
        paths: [[HorizontalPoint]],
        closed: Bool,
        regions: [[HorizontalBoard.PlanePath]] = [],
        regionPoints: [[HorizontalPoint]] = [],
        probes: [HorizontalPoint]? = nil,
        runLength: Int = .max
    ) {
        guard layers != 0 else { return }
        var body = Body(object: object, net: object.netID, layers: layers, radius: radius)
        let first = elements.count
        for path in paths where !path.isEmpty {
            var edges = [(HorizontalPoint, HorizontalPoint)]()
            if path.count == 1 {
                edges.append((path[0], path[0]))
            } else {
                for index in path.indices.dropLast() {
                    edges.append((path[index], path[index + 1]))
                }
                if closed, path.count > 2 {
                    edges.append((path[path.count - 1], path[0]))
                }
            }
            for run in Self.runs(of: edges, length: runLength) {
                let edgeStart = from.count
                for (a, b) in edges[run.edges] {
                    from.append(a)
                    to.append(b)
                }
                let box = run.box.grown(radius)
                elements.append(Element(body: bodies.count, edges: edgeStart..<from.count, box: box))
                body.box.add(box)
            }
        }
        guard elements.count > first else { return }
        body.elements = first..<elements.count
        body.regions = regions
        body.regionBoxes = regionPoints.map { points in
            var box = Box()
            for point in points {
                box.add(point)
            }
            return box
        }
        body.probes = probes ?? [paths.first(where: { !$0.isEmpty })![0]]
        bodies.append(body)
    }

    /// `edges` split into runs of at most `length` edges whose box is at most
    /// `runExtent` across, but for a single edge longer than that: so the
    /// grid finds only the runs near something, and a run along a long
    /// straight edge isn't near everything beside it.
    static func runs(of edges: [(HorizontalPoint, HorizontalPoint)], length: Int) -> [(edges: Range<Int>, box: Box)] {
        var runs = [(edges: Range<Int>, box: Box)]()
        var start = 0
        var box = Box()
        for (index, (a, b)) in edges.enumerated() {
            var grown = box
            grown.add(a)
            grown.add(b)
            if index > start, index - start >= length
                || max(grown.maxX - grown.minX, grown.maxY - grown.minY) > runExtent {
                runs.append((start..<index, box))
                start = index
                grown = Box()
                grown.add(a)
                grown.add(b)
            }
            box = grown
        }
        if start < edges.count {
            runs.append((start..<edges.count, box))
        }
        return runs
    }

    /// "package/pad/pad" of a pad's polygon or hole id.
    static func padPrefix(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[1] == "pad" else { return nil }
        return parts[0...2].joined(separator: "/")
    }

    mutating func collect() {
        let all = allCopper
        let packages = Dictionary(board.packages.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func owner(_ id: String) -> HorizontalPlacement? {
            id.split(separator: "/").first.flatMap { packages[String($0).lowercased()] }
        }
        func refdes(_ package: HorizontalPlacement?) -> String? {
            package.flatMap { $0.label.isEmpty ? nil : $0.label }
        }

        for (segments, type, label) in [(board.tracks, HorizontalPatchType.track, "Track"), (board.netTies, .netTie, "Net tie")] {
            for track in segments {
                guard let layer = track.layer, let bit = Self.bit(layer), track.width > 0 else { continue }
                let net = track.netID?.lowercased()
                add(.init(type: type, id: track.id, label: label, netID: net, netName: netName(net)),
                    layers: bit, radius: track.width / 2, paths: [track.pathPoints], closed: false)
            }
        }

        // A pad whose padstack has a plated hole is a through-hole pad.
        var platedPads = Set<String>()
        for hole in board.packageHoles where hole.plated {
            if let pad = Self.padPrefix(hole.id) {
                platedPads.insert(pad)
            }
        }
        // A pad is its shapes on a layer together, as Horizon's patches are.
        struct PadKey: Hashable { var pad: String; var layers: UInt64 }
        var padOrder = [PadKey]()
        var padShapes = [PadKey: [HorizontalPolygon]]()
        var padNets = [String: String]()
        var padNames = [String: String]()
        for pad in board.packagePads {
            let layers: UInt64
            if let layer = pad.layer {
                guard let bit = Self.bit(layer) else { continue }
                layers = bit
            } else {
                layers = all
            }
            let key = PadKey(pad: Self.padPrefix(pad.id) ?? pad.id.lowercased(), layers: layers)
            if padShapes[key] == nil {
                padOrder.append(key)
            }
            padShapes[key, default: []].append(pad)
            if let net = pad.netID?.lowercased() {
                padNets[key.pad] = net
            }
            if padNames[key.pad] == nil {
                let name = pad.metadata["Pad"] ?? (pad.id.split(separator: "/").dropFirst(2).first.map(String.init) ?? pad.id)
                padNames[key.pad] = refdes(owner(pad.id)).map { "\($0).\(name)" } ?? name
            }
        }
        for key in padOrder {
            let shapes = padShapes[key]!
            let outlines = shapes.map { $0.renderVertices(arcPrecision: Self.arcPrecision) }.filter { $0.count >= 3 }
            guard !outlines.isEmpty else { continue }
            let throughHole = shapes.contains { $0.layer == nil } || platedPads.contains(key.pad)
            let net = shapes.lazy.compactMap { $0.netID?.lowercased() }.first
            add(.init(type: throughHole ? .padTH : .pad, id: key.pad, label: "Pad \(padNames[key.pad] ?? key.pad)",
                      netID: net, netName: netName(net), componentID: owner(key.pad)?.componentID?.lowercased()),
                layers: key.layers, radius: 0, paths: outlines, closed: true,
                regions: outlines.map { [HorizontalBoard.PlanePath($0)] }, regionPoints: outlines, probes: outlines.map { $0[0] })
        }

        for via in board.vias where via.size > 0 {
            let net = via.netID?.lowercased()
            let layers = via.connectedLayers.isEmpty ? all : Self.mask(via.connectedLayers)
            add(.init(type: .via, id: via.id, label: "Via", netID: net, netName: netName(net)),
                layers: layers, radius: via.size / 2, paths: [[via.position]], closed: false)
        }

        for (holes, inPackage) in [(board.holes, false), (board.packageHoles, true)] {
            for hole in holes where hole.diameter > 0 {
                let radius = hole.diameter / 2
                let path: [HorizontalPoint]
                if hole.shape == .slot, hole.effectiveLength > hole.diameter {
                    let transform = HorizontalPlacementTransform(shift: hole.position, angle: hole.angle, mirrored: false)
                    let offset = hole.effectiveLength / 2 - radius
                    path = [transform.applying(to: HorizontalPoint(x: -offset, y: 0)),
                            transform.applying(to: HorizontalPoint(x: offset, y: 0))]
                } else {
                    path = [hole.position]
                }
                let package = inPackage ? owner(hole.id) : nil
                if hole.plated {
                    let pad = Self.padPrefix(hole.id)
                    let net = (hole.netID ?? pad.flatMap { padNets[$0] })?.lowercased()
                    let label = pad.flatMap { padNames[$0] }.map { "Plated hole \($0)" } ?? "Plated hole"
                    add(.init(type: .holePTH, id: hole.id, label: label, netID: net, netName: netName(net),
                              componentID: package?.componentID?.lowercased()),
                        layers: all, radius: radius, paths: [path], closed: false)
                } else {
                    add(.init(type: .holeNPTH, id: hole.id, label: refdes(package).map { "Hole \($0)" } ?? "Hole",
                              componentID: package?.componentID?.lowercased()),
                        layers: all, radius: radius, paths: [path], closed: false)
                }
            }
        }

        for plane in board.planes {
            guard let layer = plane.layer, let bit = Self.bit(layer) else { continue }
            let fragments = plane.fragments.filter { $0.paths.first.map { $0.count >= 3 } ?? false }
            guard !fragments.isEmpty else { continue }
            let net = plane.netID?.lowercased()
            add(.init(type: .plane, id: plane.id, label: "Plane", netID: net, netName: netName(net)),
                layers: bit, radius: 0, paths: fragments.flatMap(\.paths), closed: true,
                regions: fragments.map(\.containmentPaths), regionPoints: fragments.map { $0.paths[0] },
                probes: fragments.map { $0.paths[0][0] },
                runLength: Self.runLength)
        }

        var outlineRings = [[HorizontalPoint]]()
        for polygon in board.polygons where polygon.layer == HorizontalBoardLayers.outline {
            let points = polygon.renderVertices(arcPrecision: Self.arcPrecision)
            if points.count >= 3 {
                outlineRings.append(points)
            }
        }
        outline = outlineRings.map(HorizontalBoard.PlanePath.init)
        for ring in outlineRings {
            let edges = ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) }
            for run in Self.runs(of: edges, length: Self.runLength) {
                let edgeStart = from.count
                for (a, b) in edges[run.edges] {
                    from.append(a)
                    to.append(b)
                }
                outlineElements.append(Element(body: -1, edges: edgeStart..<from.count, box: run.box))
            }
        }
    }

    // MARK: Rules

    /// Each body's net as a small number, -1 for none, for the pair loop and
    /// the rule caches.
    mutating func numberNets() {
        var numbers = [String: Int32]()
        bodyNets = bodies.map { body in
            guard let net = body.net else { return -1 }
            if let number = numbers[net] { return number }
            let number = Int32(numbers.count)
            numbers[net] = number
            return number
        }
        netCount = numbers.count
    }

    /// A new slot in `ruleSlots`, which names a rule once for every finding.
    mutating func addSlot(_ key: String, id: String, brief: String) -> Int {
        ruleSlots.append((id.isEmpty ? nil : id, brief))
        slotByRule[key] = ruleSlots.count - 1
        return ruleSlots.count - 1
    }

    /// The copper clearance rule between bodies `i` and `j` on `layer`, and
    /// its slot.
    mutating func copperRule(_ i: Int, _ j: Int, layer: Int) -> (rule: HorizontalRuleClearanceCopper, slot: Int) {
        // The lookup takes the nets either way round, so the key does too.
        let a = Int(bodyNets[i]) + 1, b = Int(bodyNets[j]) + 1
        let key = (min(a, b) * (netCount + 1) + max(a, b)) << 6 | Self.bit(layer)!.trailingZeroBitCount
        if let cached = copperRules[key] {
            return cached
        }
        let rule = rules.clearanceCopper(net1: bodies[i].net, net2: bodies[j].net, layer: layer)
        let slotKey = "copper|\(rule.id)"
        let cached = (rule, slotByRule[slotKey] ?? addSlot(slotKey, id: rule.id, brief: brief(rule)))
        copperRules[key] = cached
        return cached
    }

    /// The copper-to-other clearance rule for body `i` on `layer`, and its slot.
    mutating func otherRule(_ i: Int, layer: Int) -> (rule: HorizontalRuleClearanceCopperOther, slot: Int) {
        let key = (Int(bodyNets[i]) + 1) << 6 | Self.bit(layer)!.trailingZeroBitCount
        if let cached = otherRules[key] {
            return cached
        }
        let rule = rules.clearanceCopperOther(net: bodies[i].net, layer: layer)
        let slotKey = "other|\(rule.id)"
        let cached = (rule, slotByRule[slotKey] ?? addSlot(slotKey, id: rule.id, brief: brief(rule)))
        otherRules[key] = cached
        return cached
    }

    /// The largest clearance any rule asks between two kinds of copper, or
    /// copper and an unplated hole: how far apart the pair loop looks.
    var reach: Double {
        let copper: [HorizontalPatchType] = [.track, .pad, .padTH, .via, .plane, .holePTH]
        var most = Double(HorizontalRuleClearanceCopper.defaultClearance)
        for rule in rules.clearanceCopperRules where rule.enabled {
            for a in copper {
                for b in copper {
                    most = max(most, Double(rule.clearance(a, b)))
                }
            }
        }
        for rule in rules.clearanceCopperOtherRules where rule.enabled {
            for a in copper {
                most = max(most, Double(rule.clearance(copper: a, nonCopper: .holeNPTH)))
            }
        }
        return most
    }

    func brief(_ rule: HorizontalRuleClearanceCopper) -> String {
        "Copper clearance: \(names.match(rule.match1)) / \(names.match(rule.match2)) · \(HorizontalRouteRuleNames.layer(rule.layer))"
    }

    func brief(_ rule: HorizontalRuleClearanceCopperOther) -> String {
        "Copper – other clearance: \(names.match(rule.match)) · \(HorizontalRouteRuleNames.layer(rule.layer))"
    }

    // MARK: Measuring

    /// What the rules ask of a pair on each layer they share.
    struct Requirement {
        var layer: Int
        var clearance: Double
        /// The rule's slot in `ruleSlots`.
        var rule: Int
    }

    struct Pair {
        var first: Int
        var second: Int
        var check: HorizontalClearanceFinding.Check
        var requirements: [Requirement]
        var reach: Double
        var nearest: Nearest?
        /// Copper of one inside the other, at this point.
        var enclosedAt: HorizontalPoint?
    }

    /// Whether two bodies are checked against each other, and against what.
    mutating func pair(_ i: Int, _ j: Int) -> Pair? {
        let a = bodies[i], b = bodies[j]
        let shared = a.layers & b.layers
        guard shared != 0, !(a.isHole && b.isHole) else { return nil }
        var requirements = [Requirement]()
        if a.isHole || b.isHole {
            let copper = a.isHole ? j : i
            for layer in Self.layers(shared) {
                let (rule, slot) = otherRule(copper, layer: layer)
                requirements.append(Requirement(
                    layer: layer, clearance: Double(rule.clearance(copper: bodies[copper].object.type, nonCopper: .holeNPTH)),
                    rule: slot))
            }
        } else {
            guard a.net != b.net else { return nil }
            if a.object.type == .netTie || b.object.type == .netTie, let netA = a.net, let netB = b.net,
               tiedNets.contains(HorizontalBoardClearanceCheck.netPairKey(netA, netB)) {
                return nil
            }
            for layer in Self.layers(shared) {
                let (rule, slot) = copperRule(i, j, layer: layer)
                requirements.append(Requirement(
                    layer: layer, clearance: Double(rule.clearance(a.object.type, b.object.type)), rule: slot))
            }
        }
        // The copper first, and of two the kind the tables list first.
        let swap = a.isHole || (!b.isHole && (b.object.type.rawValue, b.object.id) < (a.object.type.rawValue, a.object.id))
        var pair = Pair(first: swap ? j : i, second: swap ? i : j,
                        check: a.isHole || b.isHole ? .hole : .copper,
                        requirements: requirements, reach: requirements.map(\.clearance).max() ?? 0)
        // One inside the other, with no edges near each other.
        if let point = a.probes.first(where: b.encloses) ?? b.probes.first(where: a.encloses) {
            pair.enclosedAt = point
        }
        return pair
    }

    /// The nearest two of `first` and `second`'s edges, if nearer than
    /// `limit` (between edges, before radii) and than `current`. The
    /// distance is the probe's.
    func nearest(_ first: Range<Int>, _ second: Range<Int>, limit: Double, current: Nearest?) -> Nearest? {
        var best = min(limit, current?.distance ?? .infinity)
        var found: Nearest?
        from.withUnsafeBufferPointer { from in
            to.withUnsafeBufferPointer { to in
                // Each run's own box, to pass over the other's edges that are
                // nowhere near it.
                var firstBox = Box(), secondBox = Box()
                for p in first {
                    firstBox.add(from[p])
                    firstBox.add(to[p])
                }
                var near = [Int]()
                near.reserveCapacity(second.count)
                for q in second {
                    let c = from[q], d = to[q]
                    secondBox.add(c)
                    secondBox.add(d)
                    if max(0, firstBox.minX - max(c.x, d.x), min(c.x, d.x) - firstBox.maxX) < best,
                       max(0, firstBox.minY - max(c.y, d.y), min(c.y, d.y) - firstBox.maxY) < best {
                        near.append(q)
                    }
                }
                for p in first {
                    let a = from[p], b = to[p]
                    let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
                    guard max(0, secondBox.minX - maxX, minX - secondBox.maxX) < best,
                          max(0, secondBox.minY - maxY, minY - secondBox.maxY) < best else { continue }
                    for q in near {
                        let c = from[q], d = to[q]
                        let dx = max(0, min(c.x, d.x) - maxX, minX - max(c.x, d.x))
                        let dy = max(0, min(c.y, d.y) - maxY, minY - max(c.y, d.y))
                        guard dx < best, dy < best else { continue }
                        let distance = HorizontalRouteClearanceProbe.segmentDistance(a, b, c, d)
                        if distance < best {
                            best = distance
                            found = Nearest(distance: distance, first: p, second: q)
                        }
                    }
                }
            }
        }
        return found
    }

    /// Where the nearest edges come nearest: a point on each.
    func points(_ nearest: Nearest) -> (HorizontalPoint, HorizontalPoint) {
        let (_, a, b) = Self.closest(from[nearest.first], to[nearest.first], from[nearest.second], to[nearest.second])
        return (a, b)
    }

    /// The nearest points of segments ab and cd, and how far apart.
    static func closest(
        _ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint
    ) -> (Double, HorizontalPoint, HorizontalPoint) {
        let rx = b.x - a.x, ry = b.y - a.y
        let sx = d.x - c.x, sy = d.y - c.y
        let denominator = rx * sy - ry * sx
        if denominator != 0 {
            let qx = c.x - a.x, qy = c.y - a.y
            let t = (qx * sy - qy * sx) / denominator
            let u = (qx * ry - qy * rx) / denominator
            if t >= 0, t <= 1, u >= 0, u <= 1 {
                let point = HorizontalPoint(x: a.x + t * rx, y: a.y + t * ry)
                return (0, point, point)
            }
        }
        var best = (Double.infinity, a, a)
        func consider(_ p: HorizontalPoint, on s: HorizontalPoint, _ e: HorizontalPoint, pointFirst: Bool) {
            let q = onSegment(p, s, e)
            let distance = hypot(p.x - q.x, p.y - q.y)
            if distance < best.0 {
                best = pointFirst ? (distance, p, q) : (distance, q, p)
            }
        }
        consider(a, on: c, d, pointFirst: true)
        consider(b, on: c, d, pointFirst: true)
        consider(c, on: a, b, pointFirst: false)
        consider(d, on: a, b, pointFirst: false)
        return best
    }

    /// The point of segment se nearest p.
    static func onSegment(_ p: HorizontalPoint, _ s: HorizontalPoint, _ e: HorizontalPoint) -> HorizontalPoint {
        let dx = e.x - s.x, dy = e.y - s.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return s }
        let t = min(max(((p.x - s.x) * dx + (p.y - s.y) * dy) / lengthSquared, 0), 1)
        return HorizontalPoint(x: s.x + t * dx, y: s.y + t * dy)
    }

    /// The copper's surfaces where the edges come nearest: each edge point
    /// moved its radius toward the other.
    func surfaces(_ nearest: Nearest, _ ra: Double, _ rb: Double) -> (HorizontalPoint, HorizontalPoint) {
        let (a, b) = points(nearest)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > ra + rb else {
            // Touching or overlapping: where the overlap is.
            let t = length > 0 ? min(max((ra + (length - ra - rb) / 2) / length, 0), 1) : 0
            let point = HorizontalPoint(x: a.x + t * dx, y: a.y + t * dy)
            return (point, point)
        }
        return (HorizontalPoint(x: a.x + dx * ra / length, y: a.y + dy * ra / length),
                HorizontalPoint(x: b.x - dx * rb / length, y: b.y - dy * rb / length))
    }

    // MARK: Running

    mutating func run(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        collect()
        numberNets()
        var findings = [HorizontalClearanceFinding]()
        guard let copper = copperFindings(isCancelled: isCancelled) else { return nil }
        findings += copper
        guard let edge = boardEdgeFindings(isCancelled: isCancelled) else { return nil }
        findings += edge
        let order: [HorizontalClearanceFinding.Check: Int] = [.copper: 0, .hole: 1, .boardEdge: 2]
        return findings.sorted { lhs, rhs in
            if lhs.check != rhs.check { return order[lhs.check]! < order[rhs.check]! }
            if lhs.shortfall != rhs.shortfall { return lhs.shortfall > rhs.shortfall }
            return lhs.id < rhs.id
        }
    }

    mutating func copperFindings(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        let reach = self.reach
        // A grid for each copper layer, so an element meets only what shares
        // a layer with it.
        var grids = [Grid?](repeating: nil, count: 64)
        let used = bodies.reduce(UInt64(0)) { $0 | $1.layers }
        for bit in 0..<64 where used & (1 << UInt64(bit)) != 0 {
            let ids = elements.indices.filter { bodies[elements[$0].body].layers & (1 << UInt64(bit)) != 0 }
            grids[bit] = Grid(boxes: ids.map { elements[$0].box }, ids: ids.map(Int32.init))
        }
        var stamp = [Int](repeating: -1, count: elements.count)
        // What the pair loop asks of every candidate, apart from the bodies.
        let layers = bodies.map(\.layers)
        let holes = bodies.map(\.isHole)
        let radii = bodies.map(\.radius)
        let nets = bodyNets
        var pairs = [Pair]()
        var pairIndex = [Int: Int]()
        var unchecked = Set<Int>()
        let count = bodies.count
        func key(_ i: Int, _ j: Int) -> Int { min(i, j) * count + max(i, j) }

        for e1 in elements.indices {
            if e1 % 512 == 0, isCancelled() { return nil }
            let element = elements[e1]
            let i = element.body
            let query = element.box.grown(reach)
            var rest = layers[i]
            while rest != 0 {
                let bit = rest.trailingZeroBitCount
                rest &= rest - 1
                grids[bit]!.forEach(overlapping: query) { e2 in
                    guard e2 > e1, stamp[e2] != e1 else { return }
                    stamp[e2] = e1
                    let other = elements[e2]
                    let j = other.body
                    guard i != j else { return }
                    if holes[i] || holes[j] {
                        guard !(holes[i] && holes[j]) else { return }
                    } else {
                        guard nets[i] != nets[j] else { return }
                    }
                    let gap = element.box.gap(to: other.box)
                    guard gap < reach else { return }
                    let pairKey = key(i, j)
                    let index: Int
                    if let existing = pairIndex[pairKey] {
                        index = existing
                    } else {
                        guard !unchecked.contains(pairKey) else { return }
                        guard let made = self.pair(i, j) else {
                            unchecked.insert(pairKey)
                            return
                        }
                        index = pairs.count
                        pairs.append(made)
                        pairIndex[pairKey] = index
                    }
                    guard gap < pairs[index].reach, pairs[index].enclosedAt == nil else { return }
                    let firstEdges = pairs[index].first == i ? element.edges : other.edges
                    let secondEdges = pairs[index].first == i ? other.edges : element.edges
                    if let nearer = nearest(firstEdges, secondEdges, limit: pairs[index].reach + radii[i] + radii[j],
                                            current: pairs[index].nearest) {
                        pairs[index].nearest = nearer
                    }
                }
            }
        }

        // Copper deep inside a fill of another net, far from any of its edges.
        for p in bodies.indices where bodies[p].object.type == .plane {
            if isCancelled() { return nil }
            let plane = bodies[p]
            for i in bodies.indices where i != p && layers[i] & plane.layers != 0 && (holes[i] || nets[i] != nets[p]) {
                let pairKey = key(i, p)
                guard !unchecked.contains(pairKey), bodies[i].box.gap(to: plane.box) == 0,
                      pairIndex[pairKey].map({ pairs[$0].enclosedAt == nil }) ?? true,
                      let point = bodies[i].probes.first(where: plane.encloses) else { continue }
                if pairIndex[pairKey] == nil {
                    guard let made = pair(i, p) else {
                        unchecked.insert(pairKey)
                        continue
                    }
                    pairIndex[pairKey] = pairs.count
                    pairs.append(made)
                }
                pairs[pairIndex[pairKey]!].enclosedAt = point
            }
        }

        var findings = [HorizontalClearanceFinding]()
        for pair in pairs {
            let first = bodies[pair.first], second = bodies[pair.second]
            let distance: Double
            let points: (HorizontalPoint, HorizontalPoint)
            let overlaps: Bool
            if let point = pair.enclosedAt {
                distance = 0
                points = (point, point)
                overlaps = true
            } else if let nearest = pair.nearest {
                let gap = nearest.distance - first.radius - second.radius
                distance = max(0, gap)
                points = surfaces(nearest, first.radius, second.radius)
                overlaps = gap < -HorizontalBoardClearanceCheck.tolerance
            } else {
                continue
            }
            if let finding = finding(pair.check, first.object, second.object, distance: distance, points: points,
                                     requirements: pair.requirements, overlaps: overlaps) {
                findings.append(finding)
            }
        }
        return findings
    }

    func finding(
        _ check: HorizontalClearanceFinding.Check,
        _ first: HorizontalClearanceFinding.Object,
        _ second: HorizontalClearanceFinding.Object,
        distance: Double,
        points: (HorizontalPoint, HorizontalPoint),
        requirements: [Requirement],
        overlaps: Bool = false,
        outsideBoard: Bool = false
    ) -> HorizontalClearanceFinding? {
        // Copper that overlaps is too close even where the rules ask nothing,
        // as Horizon's intersection of the two has an area.
        let violated = requirements.filter {
            overlaps || outsideBoard || distance < $0.clearance - HorizontalBoardClearanceCheck.tolerance
        }
        guard let worst = violated.max(by: { $0.clearance < $1.clearance }) else { return nil }
        // Of the layers that ask the most, the first.
        let shown = violated.first { $0.clearance == worst.clearance }!
        return HorizontalClearanceFinding(
            check: check, first: first, second: second,
            layers: violated.map(\.layer), layer: shown.layer,
            distance: distance, clearance: shown.clearance,
            ruleID: ruleSlots[shown.rule].id, ruleBrief: ruleSlots[shown.rule].brief,
            outsideBoard: outsideBoard,
            location: HorizontalPoint(x: (points.0.x + points.1.x) / 2, y: (points.0.y + points.1.y) / 2),
            firstPoint: points.0, secondPoint: points.1)
    }

    func insideBoard(_ point: HorizontalPoint) -> Bool {
        outline.reduce(0) { $0 + ($1.contains(point) ? 1 : 0) } % 2 == 1
    }

    mutating func boardEdgeFindings(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        guard !outline.isEmpty else { return [] }
        let grid = Grid(boxes: outlineElements.map(\.box))
        var stamp = [Int](repeating: -1, count: outlineElements.count)
        let edge = HorizontalClearanceFinding.Object(type: .boardEdge, id: "", label: "Board edge")
        var findings = [HorizontalClearanceFinding]()
        for index in bodies.indices where !bodies[index].isHole {
            if index % 256 == 0, isCancelled() { return nil }
            let body = bodies[index]
            var requirements = [Requirement]()
            for layer in Self.layers(body.layers) {
                let (rule, slot) = otherRule(index, layer: layer)
                requirements.append(Requirement(
                    layer: layer, clearance: Double(rule.clearance(copper: body.object.type, nonCopper: .boardEdge)),
                    rule: slot))
            }
            let reach = requirements.map(\.clearance).max() ?? 0
            if let outside = body.probes.first(where: { !insideBoard($0) }) {
                if let finding = finding(.boardEdge, body.object, edge, distance: 0, points: (outside, outside),
                                         requirements: requirements, outsideBoard: true) {
                    findings.append(finding)
                }
                continue
            }
            var best: Nearest?
            for e in body.elements {
                let element = elements[e]
                grid.forEach(overlapping: element.box.grown(reach)) { o in
                    guard stamp[o] != e else { return }
                    stamp[o] = e
                    let run = outlineElements[o]
                    guard element.box.gap(to: run.box) < reach else { return }
                    if let nearer = nearest(element.edges, run.edges, limit: reach + body.radius, current: best) {
                        best = nearer
                    }
                }
            }
            guard let best else { continue }
            let gap = best.distance - body.radius
            if let finding = finding(.boardEdge, body.object, edge, distance: max(0, gap),
                                     points: surfaces(best, body.radius, 0), requirements: requirements,
                                     overlaps: gap < -HorizontalBoardClearanceCheck.tolerance) {
                findings.append(finding)
            }
        }
        return findings
    }
}

extension HorizontalBoardClearanceCheck {
    /// The pairs of nets the design's net ties join (`netPairKey`), from its
    /// top block, which the board's nets are.
    static func tiedNets(of project: HorizontalProject) -> Set<String> {
        guard let top = HorizontalDesignIndex.schematics(of: project).first(where: \.block.isTop) else {
            return []
        }
        var tied = Set<String>()
        for sheet in top.schematic.sheets {
            for tie in sheet.netTieDetails {
                if let primary = tie.primaryID, let secondary = tie.secondaryID {
                    tied.insert(netPairKey(primary, secondary))
                }
            }
        }
        return tied
    }

    /// The findings a rule kind's checks give: the copper table's, or the
    /// copper-to-other table's holes and edge. Nil for a kind this check
    /// doesn't cover.
    static func findings(_ findings: [HorizontalClearanceFinding], for kind: HorizontalBoardRuleKind) -> [HorizontalClearanceFinding]? {
        switch kind {
        case .clearanceCopper: findings.filter { $0.check == .copper }
        case .clearanceCopperOther: findings.filter { $0.check != .copper }
        default: nil
        }
    }
}

extension HorizontalBoardClearanceCheck {
    /// `run`, off the main thread; nil once the calling task is cancelled.
    static func findings(
        board: HorizontalBoard,
        rules: HorizontalBoardRules? = nil,
        tiedNets: Set<String> = []
    ) async -> [HorizontalClearanceFinding]? {
        let task = Task.detached(priority: .userInitiated) {
            run(board: board, rules: rules, tiedNets: tiedNets, isCancelled: { Task.isCancelled })
        }
        let findings = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : findings
    }
}
