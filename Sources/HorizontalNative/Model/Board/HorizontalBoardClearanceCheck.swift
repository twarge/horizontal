import Foundation

/// Copper that is closer to something than the board's rules allow: two nets'
/// copper, copper and an unplated hole, the board's edge or a keepout, copper
/// of one net and another kind, or silkscreen and copper the mask leaves bare.
struct HorizontalClearanceFinding: Identifiable, Hashable, Sendable {
    enum Check: String, Hashable, Sendable {
        /// clearance_copper: copper of two nets.
        case copper
        /// clearance_copper_other: copper and an unplated hole.
        case hole
        /// clearance_copper_other: copper and the board's edge.
        case boardEdge = "board_edge"
        /// clearance_copper_keepout: copper and a keepout it is checked against.
        case keepout
        /// clearance_same_net: pads, vias and unplated holes of one net, of
        /// two kinds the rule names.
        case sameNet = "same_net"
        /// clearance_silkscreen_exposed_copper: silkscreen and copper the
        /// solder mask leaves bare on its side.
        case silkscreen
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
            case .holeNPTH, .boardEdge, .other, .text:
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
        switch check {
        case .copper: .clearanceCopper
        case .hole, .boardEdge: .clearanceCopperOther
        case .keepout: .clearanceCopperKeepout
        case .sameNet: .clearanceSameNet
        case .silkscreen: .clearanceSilkscreenExposedCopper
        }
    }

    var title: String {
        switch check {
        case .copper, .hole, .keepout, .sameNet:
            return "\(first.name) near \(second.name)"
        case .boardEdge:
            return "\(first.name) near the board edge"
        case .silkscreen:
            return "\(first.name) near the exposed copper of \(second.name)"
        }
    }

    /// What the finding says of the rule where no rule took the pair:
    /// Horizon's own clearance between copper, none from a keepout.
    var ruleDescription: String {
        guard ruleID == nil, check != .silkscreen else { return ruleBrief }
        return check == .keepout ? "no rule, none asked" : "no rule, Horizon's"
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
        return "\(apart), where the rules ask \(Self.millimetres(clearance)) (\(ruleDescription))."
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
/// The same copper is checked against the keepouts (copper_keepout), against
/// copper of its own net of another kind (same_net), and, where the solder
/// mask leaves it bare, against the silkscreen on its side
/// (silkscreen_exposed_copper); and `connectivityFindings` joins it net by net
/// for Horizon's board connectivity check.
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

    /// `run`, and from the same copper Horizon's board connectivity check
    /// (`connectivityFindings`); nil once `isCancelled` says so.
    static func runWithConnectivity(
        board: HorizontalBoard,
        rules: HorizontalBoardRules? = nil,
        tiedNets: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) -> (clearance: [HorizontalClearanceFinding], connectivity: [HorizontalBoardRuleFinding])? {
        var engine = Engine(board: board, rules: rules ?? board.rules, tiedNets: tiedNets.union(Self.tiedNets(of: board)))
        guard let clearance = engine.run(isCancelled: isCancelled),
              let connectivity = engine.connectivityFindings(isCancelled: isCancelled) else {
            return nil
        }
        return (clearance, connectivity)
    }

    /// Horizon's board connectivity check alone
    /// (board_rules_check_board_connectivity.cpp): each net's copper on the
    /// board, joined where it touches on a layer they share and where plated
    /// holes and vias join layers, with the shorted pads rules' pads joined
    /// too, should be one piece. A net in more than one is an error naming
    /// how many; a plane's fragments are pieces of their own.
    static func connectivityFindings(board: HorizontalBoard, rules: HorizontalBoardRules? = nil) -> [HorizontalBoardRuleFinding] {
        var engine = Engine(board: board, rules: rules ?? board.rules, tiedNets: Self.tiedNets(of: board))
        engine.collect()
        engine.numberNets()
        return engine.connectivityFindings(isCancelled: { false }) ?? []
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

    func contains(_ box: Box) -> Bool {
        box.minX >= minX && box.maxX <= maxX && box.minY >= minY && box.maxY <= maxY
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
    /// Each region's paths as points, for the checks that compare areas.
    var regionOutlines: [[[HorizontalPoint]]] = []
    /// A point of the copper in each region, or of the centreline.
    var probes: [HorizontalPoint] = []
    var elements: Range<Int> = 0..<0
    /// The body's pieces of copper, which the connectivity check joins: a
    /// plane's fragments, one each, and any other body whole. The first one's
    /// number; a plane's fragment k is `firstPiece + k`, and is region k.
    var firstPiece = 0
    var pieceCount = 1

    var isHole: Bool { object.type == .holeNPTH }

    /// Whether `point` is in region `index`.
    func encloses(_ point: HorizontalPoint, region index: Int) -> Bool {
        guard regionBoxes[index].contains(point) else { return false }
        return regions[index].reduce(0) { $0 + ($1.contains(point) ? 1 : 0) } % 2 == 1
    }

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
    /// The piece of copper the run is part of (`Body.firstPiece`).
    var piece = 0
}

/// A keepout as the checks see it: its area, and which copper it keeps out.
private struct Keepout {
    var object: HorizontalClearanceFinding.Object
    var keepoutClass: String
    /// Copper layers, as a body's.
    var layers: UInt64
    /// The kinds of copper it keeps out (Keepout::patch_types_cu).
    var types: Set<HorizontalPatchType>
    var ring: [HorizontalPoint]
    var area: HorizontalBoard.PlanePath
    var box = Box()
    /// Its runs of edges in `Engine.keepoutElements`.
    var elements: Range<Int> = 0..<0
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
    /// How many pieces of copper the bodies make (`Body.firstPiece`).
    var pieceCount = 0
    var from: [HorizontalPoint] = []
    var to: [HorizontalPoint] = []
    /// The board outline's edges, in runs, and the area inside it.
    var outlineElements: [Element] = []
    var outline: [HorizontalBoard.PlanePath] = []
    /// The keepouts copper is checked against, and their edges in runs.
    var keepouts: [Keepout] = []
    var keepoutElements: [Element] = []

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
        regionOutlines: [[[HorizontalPoint]]]? = nil,
        probes: [HorizontalPoint]? = nil,
        pathPieces: [Int]? = nil,
        runLength: Int = .max
    ) {
        guard layers != 0 else { return }
        var body = Body(object: object, net: object.netID, layers: layers, radius: radius)
        body.firstPiece = pieceCount
        body.pieceCount = (pathPieces?.max() ?? 0) + 1
        let first = elements.count
        for (pathIndex, path) in paths.enumerated() where !path.isEmpty {
            let piece = body.firstPiece + (pathPieces?[pathIndex] ?? 0)
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
                elements.append(Element(body: bodies.count, edges: edgeStart..<from.count, box: box, piece: piece))
                body.box.add(box)
            }
        }
        guard elements.count > first else { return }
        pieceCount += body.pieceCount
        body.elements = first..<elements.count
        body.regions = regions
        body.regionOutlines = regionOutlines ?? regionPoints.map { [$0] }
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
                regionOutlines: fragments.map(\.paths),
                probes: fragments.map { $0.paths[0][0] },
                pathPieces: fragments.enumerated().flatMap { index, fragment in
                    [Int](repeating: index, count: fragment.paths.count)
                },
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

        // The keepouts, the board's and its packages', with the layers and
        // kinds of copper each keeps out.
        for keepout in board.keepouts {
            let ring = keepout.polygon.renderVertices(arcPrecision: Self.arcPrecision)
            guard ring.count >= 3 else { continue }
            let layers: UInt64
            if keepout.allCopperLayers {
                layers = all
            } else if let layer = keepout.polygon.layer, let bit = Self.bit(layer) {
                layers = bit
            } else {
                continue
            }
            let package = keepout.id.contains("/keepout/") ? owner(keepout.id) : nil
            var label = refdes(package).map { "Keepout \($0)" } ?? "Keepout"
            if !keepout.keepoutClass.isEmpty {
                label += " (\(keepout.keepoutClass))"
            }
            var shape = Keepout(
                object: .init(type: .other, id: keepout.id, label: label, componentID: package?.componentID?.lowercased()),
                keepoutClass: keepout.keepoutClass, layers: layers,
                types: Set(keepout.copperPatchTypes.compactMap(HorizontalPatchType.init(jsonString:))),
                ring: ring, area: HorizontalBoard.PlanePath(ring))
            let edges = ring.indices.map { (ring[$0], ring[($0 + 1) % ring.count]) }
            let start = keepoutElements.count
            for run in Self.runs(of: edges, length: Self.runLength) {
                let edgeStart = from.count
                for (a, b) in edges[run.edges] {
                    from.append(a)
                    to.append(b)
                }
                keepoutElements.append(Element(body: keepouts.count, edges: edgeStart..<from.count, box: run.box))
                shape.box.add(run.box)
            }
            shape.elements = start..<keepoutElements.count
            keepouts.append(shape)
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
        guard let keepout = keepoutFindings(isCancelled: isCancelled) else { return nil }
        findings += keepout
        guard let sameNet = sameNetFindings(isCancelled: isCancelled) else { return nil }
        findings += sameNet
        guard let silkscreen = silkscreenFindings(isCancelled: isCancelled) else { return nil }
        findings += silkscreen
        let order: [HorizontalClearanceFinding.Check: Int] = [
            .copper: 0, .hole: 1, .boardEdge: 2, .keepout: 3, .sameNet: 4, .silkscreen: 5
        ]
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

// MARK: - Keepouts, same net, silkscreen, connectivity

private extension Engine {
    /// Whether an edge of one run crosses an edge of the other, not merely
    /// touching it: two outlines whose areas overlap though neither has a
    /// corner inside the other, as a plus sign's two bars.
    func cross(_ first: Range<Int>, _ second: Range<Int>) -> Bool {
        for p in first {
            let a = from[p], b = to[p]
            guard a != b else { continue }
            for q in second {
                let c = from[q], d = to[q]
                guard c != d else { continue }
                if Self.properlyCross(a, b, c, d) {
                    return true
                }
            }
        }
        return false
    }

    static func properlyCross(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Bool {
        func turn(_ p: HorizontalPoint, _ q: HorizontalPoint, _ r: HorizontalPoint) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = turn(c, d, a), d2 = turn(c, d, b), d3 = turn(a, b, c), d4 = turn(a, b, d)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Whether segment ab crosses segment cd, ends touching included.
    static func segmentsMeet(_ a: HorizontalPoint, _ b: HorizontalPoint, _ c: HorizontalPoint, _ d: HorizontalPoint) -> Bool {
        HorizontalRouteClearanceProbe.segmentDistance(a, b, c, d) <= HorizontalBoardClearanceCheck.tolerance
    }

    func brief(_ rule: HorizontalRuleClearanceCopperKeepout) -> String {
        let keepouts: String
        switch rule.matchKeepout.mode {
        case .all: keepouts = "all keepouts"
        case .keepoutClass: keepouts = "keepout class \(rule.matchKeepout.keepoutClass.isEmpty ? "(none)" : rule.matchKeepout.keepoutClass)"
        case .component: keepouts = "a component's keepouts"
        }
        return "Copper – keepout clearance: \(names.match(rule.match)) · \(keepouts)"
    }

    func brief(_ rule: HorizontalRuleClearanceSameNet) -> String {
        "Same net clearance: \(names.match(rule.match)) · \(HorizontalRouteRuleNames.layer(rule.layer))"
    }

    // MARK: Keepouts

    /// board_rules_check.cpp's check_clearance_copper_keepout: each kind of
    /// copper a keepout lists, on a layer it keeps out, against the keepout's
    /// area grown by what the first keepout rule taking the copper's net and
    /// the keepout's class asks for that kind; no rule asks nothing, so only
    /// copper inside the keepout is reported then.
    mutating func keepoutFindings(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        guard !keepouts.isEmpty else { return [] }
        let tolerance = HorizontalBoardClearanceCheck.tolerance
        let reach = rules.clearanceCopperKeepoutRules.filter(\.enabled)
            .flatMap(\.clearances.values).map(Double.init).max() ?? 0
        let grid = Grid(boxes: elements.map(\.box))
        var seen = [Int](repeating: -1, count: bodies.count)
        var ruleSlotsByKey = [String: (HorizontalRuleClearanceCopperKeepout, Int)]()
        var findings = [HorizontalClearanceFinding]()
        for (k, keepout) in keepouts.enumerated() {
            if isCancelled() { return nil }
            var near = [Int: Nearest]()
            var candidates = [Int]()
            grid.forEach(overlapping: keepout.box.grown(reach + tolerance)) { e in
                let element = elements[e]
                let i = element.body
                let body = bodies[i]
                guard !body.isHole, body.layers & keepout.layers != 0, keepout.types.contains(body.object.type) else { return }
                if seen[i] != k {
                    seen[i] = k
                    candidates.append(i)
                }
                for r in keepout.elements {
                    let run = keepoutElements[r]
                    guard element.box.gap(to: run.box) <= reach + tolerance else { continue }
                    if let nearer = nearest(element.edges, run.edges, limit: reach + body.radius + tolerance, current: near[i]) {
                        near[i] = nearer
                    }
                }
            }
            for i in candidates {
                let body = bodies[i]
                let key = "\(bodyNets[i])|\(keepout.keepoutClass)"
                let (rule, slot): (HorizontalRuleClearanceCopperKeepout, Int)
                if let cached = ruleSlotsByKey[key] {
                    (rule, slot) = cached
                } else {
                    rule = rules.clearanceCopperKeepout(net: body.net, keepoutClass: keepout.keepoutClass)
                    let slotKey = "keepout|\(rule.id)"
                    slot = slotByRule[slotKey] ?? addSlot(slotKey, id: rule.id, brief: brief(rule))
                    ruleSlotsByKey[key] = (rule, slot)
                }
                let clearance = Double(rule.clearance(body.object.type))
                let requirements = Self.layers(body.layers & keepout.layers).map {
                    Requirement(layer: $0, clearance: clearance, rule: slot)
                }
                // The copper inside the keepout, or the keepout inside it.
                let inside = body.probes.first { keepout.box.contains($0) && keepout.area.contains($0) }
                    ?? keepout.ring.first(where: body.encloses)
                let distance: Double
                let points: (HorizontalPoint, HorizontalPoint)
                let overlaps: Bool
                if let inside {
                    distance = 0
                    points = (inside, inside)
                    overlaps = true
                } else if let nearest = near[i] {
                    let gap = nearest.distance - body.radius
                    distance = max(0, gap)
                    points = surfaces(nearest, body.radius, 0)
                    overlaps = gap < -tolerance
                        || (body.radius == 0 && nearest.distance <= tolerance && crossesKeepout(i, k))
                } else {
                    continue
                }
                if let finding = finding(.keepout, body.object, keepout.object, distance: distance, points: points,
                                         requirements: requirements, overlaps: overlaps) {
                    findings.append(finding)
                }
            }
        }
        return findings
    }

    func crossesKeepout(_ i: Int, _ k: Int) -> Bool {
        for e in bodies[i].elements {
            for r in keepouts[k].elements where elements[e].box.gap(to: keepoutElements[r].box) == 0 {
                if cross(elements[e].edges, keepoutElements[r].edges) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Same net

    /// What the same net rules ask between bodies `i` and `j`, layer by layer:
    /// Horizon takes the least any shared layer's rule asks, and checks the
    /// pair only when every one of those rules names the two kinds.
    mutating func sameNetRequirements(_ i: Int, _ j: Int) -> [Requirement]? {
        let a = bodies[i], b = bodies[j]
        // An unplated hole of a pad's own padstack is that pad's.
        if a.object.type == .holeNPTH || b.object.type == .holeNPTH {
            let hole = a.object.type == .holeNPTH ? a : b
            let other = a.object.type == .holeNPTH ? b : a
            if let pad = Self.padPrefix(hole.object.id), pad == other.object.id.lowercased() {
                return nil
            }
        }
        var asked = [(layer: Int, clearance: Int, slot: Int)]()
        for layer in Self.layers(a.layers & b.layers) {
            let rule = rules.clearanceSameNet(net: a.net, layer: layer)
            guard let clearance = rule.clearance(a.object.type, b.object.type) else { return nil }
            let slotKey = "samenet|\(rule.id)"
            let slot = slotByRule[slotKey] ?? addSlot(slotKey, id: rule.id, brief: brief(rule))
            asked.append((layer, clearance, slot))
        }
        guard let least = asked.min(by: { $0.clearance < $1.clearance }) else { return nil }
        return asked.map { Requirement(layer: $0.layer, clearance: Double(least.clearance), rule: least.slot) }
    }

    /// board_rules_check.cpp's check_clearance_same_net: pads, through-hole
    /// pads, vias and unplated holes of one net (an unplated hole has none,
    /// so it pairs with copper on none), of two kinds, on a layer they
    /// share, against what the same net rules ask between the kinds.
    mutating func sameNetFindings(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        let enabled = rules.clearanceSameNetRules.filter(\.enabled)
        guard !enabled.isEmpty else { return [] }
        let tolerance = HorizontalBoardClearanceCheck.tolerance
        let reach = enabled.flatMap(\.clearances.values).map(Double.init).max() ?? 0
        let kinds: Set<HorizontalPatchType> = [.pad, .padTH, .via, .holeNPTH]
        let members = bodies.indices.filter { kinds.contains(bodies[$0].object.type) }
        let ids = members.flatMap { Array(bodies[$0].elements) }
        guard !ids.isEmpty else { return [] }
        let grid = Grid(boxes: ids.map { elements[$0].box }, ids: ids.map(Int32.init))

        struct SameNetPair {
            var first: Int
            var second: Int
            var requirements: [Requirement]
            var reach: Double
            var nearest: Nearest?
            var insideAt: HorizontalPoint?
        }
        var pairs = [SameNetPair]()
        var pairIndex = [Int: Int]()
        var unchecked = Set<Int>()
        let count = bodies.count
        func candidate(_ i: Int, _ j: Int) -> Bool {
            i != j && bodyNets[i] == bodyNets[j] && bodies[i].object.type != bodies[j].object.type
                && bodies[i].layers & bodies[j].layers != 0
        }
        func pairAt(_ i: Int, _ j: Int) -> Int? {
            let key = min(i, j) * count + max(i, j)
            if let index = pairIndex[key] { return index }
            guard !unchecked.contains(key) else { return nil }
            guard let requirements = sameNetRequirements(i, j) else {
                unchecked.insert(key)
                return nil
            }
            let a = bodies[i], b = bodies[j]
            let swap = (b.object.type.rawValue, b.object.id) < (a.object.type.rawValue, a.object.id)
            pairs.append(SameNetPair(first: swap ? j : i, second: swap ? i : j, requirements: requirements,
                                     reach: requirements.map(\.clearance).max() ?? 0))
            pairIndex[key] = pairs.count - 1
            return pairs.count - 1
        }

        var stamp = [Int](repeating: -1, count: elements.count)
        for (n, e1) in ids.enumerated() {
            if n % 512 == 0, isCancelled() { return nil }
            let element = elements[e1]
            let i = element.body
            grid.forEach(overlapping: element.box.grown(reach + tolerance)) { e2 in
                guard e2 > e1, stamp[e2] != e1 else { return }
                stamp[e2] = e1
                let other = elements[e2]
                let j = other.body
                guard candidate(i, j), let index = pairAt(i, j),
                      element.box.gap(to: other.box) <= pairs[index].reach + tolerance else { return }
                let firstEdges = pairs[index].first == i ? element.edges : other.edges
                let secondEdges = pairs[index].first == i ? other.edges : element.edges
                if let nearer = nearest(firstEdges, secondEdges,
                                        limit: pairs[index].reach + bodies[i].radius + bodies[j].radius + tolerance,
                                        current: pairs[index].nearest) {
                    pairs[index].nearest = nearer
                }
            }
        }
        // A via in a pad, far from the pad's edges, and the like.
        for i in members where !bodies[i].regions.isEmpty {
            var found = Set<Int>()
            grid.forEach(overlapping: bodies[i].box) { e in found.insert(elements[e].body) }
            for j in found.sorted() where candidate(i, j) && bodies[j].box.gap(to: bodies[i].box) == 0 {
                guard let point = bodies[j].probes.first(where: bodies[i].encloses), let index = pairAt(i, j) else { continue }
                pairs[index].insideAt = pairs[index].insideAt ?? point
            }
        }

        var findings = [HorizontalClearanceFinding]()
        for pair in pairs {
            let first = bodies[pair.first], second = bodies[pair.second]
            let distance: Double
            let points: (HorizontalPoint, HorizontalPoint)
            let overlaps: Bool
            if let point = pair.insideAt {
                distance = 0
                points = (point, point)
                overlaps = true
            } else if let nearest = pair.nearest {
                let gap = nearest.distance - first.radius - second.radius
                distance = max(0, gap)
                points = surfaces(nearest, first.radius, second.radius)
                overlaps = gap < -tolerance
                    || (first.radius == 0 && second.radius == 0 && nearest.distance <= tolerance
                        && cross(first.elements.flatMap { elements[$0].edges }, second.elements.flatMap { elements[$0].edges }))
            } else {
                continue
            }
            if let finding = finding(.sameNet, first.object, second.object, distance: distance, points: points,
                                     requirements: pair.requirements, overlaps: overlaps) {
                findings.append(finding)
            }
        }
        return findings
    }

    func cross(_ first: [Int], _ second: [Int]) -> Bool {
        for p in first {
            let a = from[p], b = to[p]
            guard a != b else { continue }
            for q in second {
                let c = from[q], d = to[q]
                if c != d, Self.properlyCross(a, b, c, d) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Silkscreen

    /// One silkscreen object: its strokes, each with `radius` of ink round
    /// it, and for a polygon the area inside.
    struct Silk {
        var object: HorizontalClearanceFinding.Object
        var segments: [(HorizontalPoint, HorizontalPoint)]
        var radius: Double
        var area: HorizontalBoard.PlanePath?
        var box = Box()
    }

    /// Copper the solder mask leaves bare: a piece of one object's copper
    /// inside an opening of its side's mask, with its holes.
    struct Exposed {
        var object: HorizontalClearanceFinding.Object
        var fragment: [[HorizontalPoint]]
        var area: [HorizontalBoard.PlanePath]
        var segments: [(HorizontalPoint, HorizontalPoint)]
        var box = Box()

        func encloses(_ point: HorizontalPoint) -> Bool {
            box.contains(point) && area.filter { $0.contains(point) }.count % 2 == 1
        }
    }

    static func box(_ points: [HorizontalPoint]) -> Box {
        var box = Box()
        for point in points {
            box.add(point)
        }
        return box
    }

    /// The area a stroke of `width` covers between two points, as closely as
    /// the checks that compare areas need: a rectangle with a half-disc on
    /// each end, a disc for a point.
    static func capsule(_ a: HorizontalPoint, _ b: HorizontalPoint, width: Double, segments: Int = 24) -> [HorizontalPoint] {
        let radius = width / 2
        guard radius > 0 else { return [] }
        let dx = b.x - a.x, dy = b.y - a.y
        let heading = dx == 0 && dy == 0 ? 0 : atan2(dy, dx)
        var points = [HorizontalPoint]()
        points.reserveCapacity(2 * segments + 2)
        for (center, start) in [(b, heading - Double.pi / 2), (a, heading + Double.pi / 2)] {
            for step in 0...segments {
                let angle = start + Double(step) / Double(segments) * Double.pi
                points.append(HorizontalPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        return points
    }

    /// A body's copper as areas, one list of paths (filled even-odd) each.
    func areas(of body: Body) -> [[[HorizontalPoint]]] {
        if body.radius > 0 {
            return body.elements.flatMap { e in
                elements[e].edges.map { [Self.capsule(from[$0], to[$0], width: 2 * body.radius)] }
            }
        }
        return body.regionOutlines
    }

    /// Strokes and polygons on `layer` that are not part of a body: the
    /// board's, its packages' and its decals' lines, arcs, polygons and texts.
    func drawn(on layer: Int, packages: [String: HorizontalPlacement]) -> [Silk] {
        func owner(_ id: String) -> String? {
            id.split(separator: "/").first.flatMap { packages[String($0).lowercased()] }.flatMap { $0.label.isEmpty ? nil : $0.label }
        }
        func named(_ what: String, _ id: String) -> String {
            owner(id).map { "\(what) of \($0)" } ?? what
        }
        // A package told to omit its silkscreen draws none of its own; the
        // texts smashed out of it are the board's.
        let omitted = Set(board.packages.filter(\.omitSilkscreen).map { $0.id.lowercased() })
        let silkscreen = HorizontalBoardLayers.isSilkscreen(layer)
        func omits(_ id: String, smashed: Bool = false) -> Bool {
            silkscreen && !smashed && !omitted.isEmpty
                && id.split(separator: "/").first.map { omitted.contains(String($0).lowercased()) } == true
        }
        var objects = [Silk]()
        func add(_ object: HorizontalClearanceFinding.Object, segments: [(HorizontalPoint, HorizontalPoint)],
                 radius: Double, ring: [HorizontalPoint]? = nil) {
            var silk = Silk(object: object, segments: segments, radius: radius,
                            area: ring.map(HorizontalBoard.PlanePath.init))
            for (a, b) in segments {
                silk.box.add(a)
                silk.box.add(b)
            }
            guard !segments.isEmpty else { return }
            silk.box = silk.box.grown(radius)
            objects.append(silk)
        }
        func stroke(_ points: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
            points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
        }
        func ring(_ points: [HorizontalPoint]) -> [(HorizontalPoint, HorizontalPoint)] {
            points.indices.map { (points[$0], points[($0 + 1) % points.count]) }
        }
        let decalLines = board.decals.flatMap(\.lines), decalArcs = board.decals.flatMap(\.arcs)
        let decalPolygons = board.decals.flatMap(\.polygons), decalTexts = board.decals.flatMap(\.texts)
        for line in board.lines + board.packageLines + decalLines where line.layer == layer && !omits(line.id) {
            add(.init(type: .other, id: line.id, label: named(line.center == nil ? "Line" : "Arc", line.id)),
                segments: stroke(line.pathPoints), radius: line.width / 2)
        }
        for arc in board.arcs + board.packageArcs + decalArcs where arc.layer == layer && !omits(arc.id) {
            add(.init(type: .other, id: arc.id, label: named("Arc", arc.id)),
                segments: stroke(arc.polyline(precision: Self.arcPrecision)), radius: arc.width / 2)
        }
        for polygon in board.polygons + board.packagePolygons + decalPolygons where polygon.layer == layer && !omits(polygon.id) {
            let points = polygon.renderVertices(arcPrecision: Self.arcPrecision)
            guard points.count >= 3 else { continue }
            add(.init(type: .other, id: polygon.id, label: named("Polygon", polygon.id)),
                segments: ring(points), radius: 0, ring: points)
        }
        for text in board.texts + board.packageTexts + decalTexts where text.layer == layer && !omits(text.id, smashed: text.fromSmash) {
            let shown = text.text.count > 24 ? String(text.text.prefix(24)) + "…" : text.text
            add(.init(type: .text, id: text.id, label: named("Text \u{201C}\(shown)\u{201D}", text.id)),
                segments: HorizontalOutlineTextRenderer.outlineSegments(for: text), radius: text.width / 2)
        }
        return objects
    }

    /// board_rules_check.cpp's check_clearance_silkscreen_exposed_copper:
    /// on each side, the copper the solder mask leaves bare (pads only, with
    /// the rule's pads_only) against everything on the side's silkscreen,
    /// which must keep the rule's clearance for that side from it. Horizon
    /// takes the top's clearance for the bottom as well; this takes the
    /// bottom's, which is the one the rules window sets for it.
    mutating func silkscreenFindings(isCancelled: () -> Bool) -> [HorizontalClearanceFinding]? {
        let rule = rules.clearanceSilkscreenExposedCopper
        guard rule.enabled else { return [] }
        let tolerance = HorizontalBoardClearanceCheck.tolerance
        let packages = Dictionary(board.packages.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let sides = [
            (copper: HorizontalBoardLayers.topCopper, mask: HorizontalBoardLayers.topMask,
             silk: HorizontalBoardLayers.topSilkscreen, clearance: rule.clearanceTop, side: "top"),
            (copper: HorizontalBoardLayers.bottomCopper, mask: HorizontalBoardLayers.bottomMask,
             silk: HorizontalBoardLayers.bottomSilkscreen, clearance: rule.clearanceBottom, side: "bottom")
        ]
        var findings = [HorizontalClearanceFinding]()
        for side in sides {
            if isCancelled() { return nil }
            guard let bit = Self.bit(side.copper) else { continue }
            let silks = drawn(on: side.silk, packages: packages)
            guard !silks.isEmpty else { continue }
            let openings = HorizontalSilkscreenClipper.maskOpenings(on: side.mask, board: board)
            guard !openings.isEmpty else { continue }
            let openingBoxes = openings.map(Self.box)
            let openingAreas = openings.map(HorizontalBoard.PlanePath.init)
            let openingGrid = Grid(boxes: openingBoxes)
            /// Whether one path of copper lies inside an opening: every corner
            /// in it and no edge crossing one of its edges, which is most pads
            /// in their own opening, and needs no clipping.
            func within(_ path: [HorizontalPoint], _ opening: Int) -> Bool {
                guard openingBoxes[opening].contains(Self.box(path)) else { return false }
                guard path.allSatisfy(openingAreas[opening].contains) else { return false }
                let ring = openings[opening]
                for index in path.indices {
                    let a = path[index], b = path[(index + 1) % path.count]
                    for other in ring.indices where Self.properlyCross(a, b, ring[other], ring[(other + 1) % ring.count]) {
                        return false
                    }
                }
                return true
            }

            var exposed = [Exposed]()
            func expose(_ object: HorizontalClearanceFinding.Object, _ areas: [[[HorizontalPoint]]], within box: Box) {
                var near = Set<Int>()
                openingGrid.forEach(overlapping: box) { o in
                    if openingBoxes[o].gap(to: box) == 0 {
                        near.insert(o)
                    }
                }
                guard !near.isEmpty else { return }
                let sorted = near.sorted()
                let clips = sorted.map { HorizontalBoardRulesCheck.counterClockwise(openings[$0]) }
                let fragments = areas.flatMap { area -> [[[HorizontalPoint]]] in
                    if area.count == 1, sorted.contains(where: { within(area[0], $0) }) {
                        return [area]
                    }
                    return HorizontalPolygonBoolean.apply(.intersection, area, clips, subjectFill: .evenOdd, clipFill: .nonZero)
                }
                for fragment in fragments {
                    var bare = Exposed(object: object, fragment: fragment,
                                       area: fragment.map(HorizontalBoard.PlanePath.init), segments: [])
                    for path in fragment {
                        for index in path.indices {
                            let a = path[index], b = path[(index + 1) % path.count]
                            bare.segments.append((a, b))
                            bare.box.add(a)
                        }
                    }
                    exposed.append(bare)
                }
            }
            for body in bodies where body.layers & bit != 0 && !body.isHole && body.object.type != .holePTH {
                guard !rule.padsOnly || body.object.type == .pad || body.object.type == .padTH else { continue }
                expose(body.object, areas(of: body), within: body.box)
            }
            if !rule.padsOnly {
                // Copper that is no net's: texts, lines and polygons drawn on
                // the copper layer.
                for copper in drawn(on: side.copper, packages: packages) {
                    let areas: [[[HorizontalPoint]]] = copper.area != nil
                        ? [[copper.segments.map(\.0)]]
                        : copper.segments.map { [Self.capsule($0.0, $0.1, width: 2 * copper.radius)] }.filter { !$0[0].isEmpty }
                    expose(copper.object, areas, within: copper.box)
                }
            }
            guard !exposed.isEmpty else { continue }
            let exposedGrid = Grid(boxes: exposed.map { $0.box.grown(side.clearance + tolerance) })
            let slotKey = "silkscreen|\(side.side)"
            let slot = slotByRule[slotKey] ?? addSlot(
                slotKey, id: "",
                brief: "Silkscreen – exposed copper: \(HorizontalClearanceFinding.millimetres(side.clearance)) on the \(side.side) side"
                    + (rule.padsOnly ? ", pads only" : ""))
            let requirement = Requirement(layer: side.silk, clearance: side.clearance, rule: slot)

            // The objects on the silkscreen, a piece of bare copper at a time;
            // one finding a pair of objects, its nearest piece.
            var nearest = [String: (finding: HorizontalClearanceFinding, rank: Double)]()
            var order = [String]()
            for silk in silks {
                if isCancelled() { return nil }
                var near = Set<Int>()
                exposedGrid.forEach(overlapping: silk.box) { near.insert($0) }
                for x in near.sorted() {
                    let bare = exposed[x]
                    let reach = side.clearance + silk.radius + tolerance
                    guard silk.box.gap(to: bare.box) < side.clearance + tolerance else { continue }
                    let within = bare.box.grown(reach)
                    var best: (distance: Double, a: HorizontalPoint, b: HorizontalPoint)?
                    var crossing = false
                    for (a, b) in silk.segments {
                        guard max(0, within.minX - max(a.x, b.x), min(a.x, b.x) - within.maxX) == 0,
                              max(0, within.minY - max(a.y, b.y), min(a.y, b.y) - within.maxY) == 0 else { continue }
                        for (c, d) in bare.segments {
                            let (distance, p, q) = Self.closest(a, b, c, d)
                            if best == nil || distance < best!.distance {
                                best = (distance, p, q)
                            }
                            if silk.radius == 0, distance <= tolerance, !crossing, a != b, c != d {
                                crossing = Self.properlyCross(a, b, c, d)
                            }
                        }
                    }
                    let inside = silk.segments.lazy.map(\.0).first(where: bare.encloses)
                        ?? silk.area.flatMap { area in bare.segments.lazy.map(\.0).first(where: area.contains) }
                    let distance: Double
                    let points: (HorizontalPoint, HorizontalPoint)
                    let overlaps: Bool
                    if let inside {
                        distance = 0
                        points = (inside, inside)
                        overlaps = true
                    } else if let best {
                        let gap = best.distance - silk.radius
                        distance = max(0, gap)
                        let dx = best.b.x - best.a.x, dy = best.b.y - best.a.y
                        let length = (dx * dx + dy * dy).squareRoot()
                        let surface = length > silk.radius
                            ? HorizontalPoint(x: best.a.x + dx * silk.radius / length, y: best.a.y + dy * silk.radius / length)
                            : best.b
                        points = (surface, best.b)
                        overlaps = gap < -tolerance || crossing
                    } else {
                        continue
                    }
                    guard let finding = finding(.silkscreen, silk.object, bare.object, distance: distance, points: points,
                                                requirements: [requirement], overlaps: overlaps) else { continue }
                    let rank = overlaps ? -1 : distance
                    if let kept = nearest[finding.id] {
                        if rank < kept.rank {
                            nearest[finding.id] = (finding, rank)
                        }
                    } else {
                        nearest[finding.id] = (finding, rank)
                        order.append(finding.id)
                    }
                }
            }
            findings += order.map { nearest[$0]!.finding }
        }
        return findings
    }

    // MARK: Connectivity

    /// board_rules_check_board_connectivity.cpp, on the bodies: a net's
    /// pieces of copper join where they touch on a layer they share (a via's
    /// or a plated hole's copper spans its layers, so it joins them), and
    /// where a shorted pads rule joins a package's pads of the net; a net in
    /// more than one piece is an error.
    mutating func connectivityFindings(isCancelled: () -> Bool) -> [HorizontalBoardRuleFinding]? {
        guard rules.checksBoardConnectivity, pieceCount > 0 else { return [] }
        let tolerance = HorizontalBoardClearanceCheck.tolerance
        var parent = Array(0..<pieceCount)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb {
                parent[max(ra, rb)] = min(ra, rb)
            }
        }
        let onNet = bodies.indices.filter { bodies[$0].net != nil && !bodies[$0].isHole }
        let ids = onNet.flatMap { Array(bodies[$0].elements) }
        var grids = [Grid?](repeating: nil, count: 64)
        let used = onNet.reduce(UInt64(0)) { $0 | bodies[$1].layers }
        for bit in 0..<64 where used & (1 << UInt64(bit)) != 0 {
            let layerIDs = ids.filter { bodies[elements[$0].body].layers & (1 << UInt64(bit)) != 0 }
            grids[bit] = Grid(boxes: layerIDs.map { elements[$0].box }, ids: layerIDs.map(Int32.init))
        }

        // Copper that touches.
        var stamp = [Int](repeating: -1, count: elements.count)
        for (n, e1) in ids.enumerated() {
            if n % 512 == 0, isCancelled() { return nil }
            let element = elements[e1]
            let i = element.body
            var rest = bodies[i].layers
            while rest != 0 {
                let bit = rest.trailingZeroBitCount
                rest &= rest - 1
                grids[bit]!.forEach(overlapping: element.box.grown(tolerance)) { e2 in
                    guard e2 > e1, stamp[e2] != e1 else { return }
                    stamp[e2] = e1
                    let other = elements[e2]
                    let j = other.body
                    guard i != j, bodyNets[i] == bodyNets[j], find(element.piece) != find(other.piece),
                          element.box.gap(to: other.box) <= tolerance else { return }
                    let radii = bodies[i].radius + bodies[j].radius
                    if nearest(element.edges, other.edges, limit: radii + tolerance, current: nil) != nil {
                        union(element.piece, other.piece)
                    }
                }
            }
        }
        // Copper inside a pad or a fill, away from its edges.
        for i in onNet where !bodies[i].regions.isEmpty {
            if isCancelled() { return nil }
            let body = bodies[i]
            for region in body.regions.indices {
                let piece = body.firstPiece + (body.pieceCount > 1 ? region : 0)
                var found = Set<Int>()
                var rest = body.layers
                while rest != 0 {
                    let bit = rest.trailingZeroBitCount
                    rest &= rest - 1
                    grids[bit]!.forEach(overlapping: body.regionBoxes[region]) { found.insert($0) }
                }
                var checked = Set<Int>()
                for e in found.sorted() {
                    let j = elements[e].body
                    guard j != i, bodyNets[j] == bodyNets[i], bodies[j].layers & body.layers != 0,
                          checked.insert(j).inserted else { continue }
                    let other = bodies[j]
                    for (index, probe) in other.probes.enumerated() {
                        let otherPiece = other.firstPiece + (other.pieceCount > 1 ? min(index, other.pieceCount - 1) : 0)
                        if find(otherPiece) != find(piece), body.encloses(probe, region: region) {
                            union(otherPiece, piece)
                        }
                    }
                }
            }
        }
        // Pads a shorted pads rule joins inside their part.
        if !rules.shortedPadsRules.isEmpty {
            var padBodies = [String: [Int]]()
            for i in onNet where bodies[i].object.type == .pad || bodies[i].object.type == .padTH {
                padBodies[bodies[i].object.id, default: []].append(i)
            }
            for package in board.packages {
                let prefix = package.id.lowercased() + "/"
                let pads = padBodies.filter { $0.key.hasPrefix(prefix) }
                let byNet = Dictionary(grouping: pads.values.flatMap { $0 }, by: { bodies[$0].net! })
                for (net, members) in byNet.sorted(by: { $0.key < $1.key }) where members.count > 1 {
                    let component = package.componentID ?? package.id
                    guard rules.shortedPads(componentID: component, partID: package.componentDetails?.partID, net: net) != nil else {
                        continue
                    }
                    for member in members.dropFirst() {
                        union(bodies[members[0]].firstPiece, bodies[member].firstPiece)
                    }
                }
            }
        }

        // Each net's groups.
        var groups = [String: [Int: [Int]]]()   // net → root → bodies
        for i in onNet {
            let body = bodies[i]
            for piece in body.firstPiece..<(body.firstPiece + body.pieceCount) {
                groups[body.net!, default: [:]][find(piece), default: []].append(i)
            }
        }
        var findings = [HorizontalBoardRuleFinding]()
        for (net, byRoot) in groups.sorted(by: { $0.key < $1.key }) where byRoot.count > 1 {
            let name = netName(net) ?? "unnamed net"
            // The largest group is the net; the smallest is where to look.
            let ordered = byRoot.values.map { Array(Set($0)).sorted() }.sorted { ($0.count, $0.first ?? 0) < ($1.count, $1.first ?? 0) }
            let smallest = ordered[0]
            var box = Box()
            for i in smallest {
                box.add(bodies[i].box)
            }
            let labels = smallest.prefix(3).map { bodies[$0].object.label }
            let first = bodies[smallest[0]]
            findings.append(HorizontalBoardRuleFinding(
                kind: .boardConnectivity, level: .error, check: "unconnected_groups",
                title: "Net in unconnected groups",
                message: "Net \(name) has \(byRoot.count) unconnected groups",
                detail: "The smallest is \(labels.joined(separator: ", "))\(smallest.count > 3 ? ", …" : "").",
                location: first.probes.first ?? HorizontalPoint(x: (box.minX + box.maxX) / 2, y: (box.minY + box.maxY) / 2),
                region: HorizontalRect(points: [HorizontalPoint(x: box.minX, y: box.minY), HorizontalPoint(x: box.maxX, y: box.maxY)])
                    .expanded(by: 1_500_000),
                netIDs: [net], netNames: [name],
                objectIDs: smallest.prefix(8).map { bodies[$0].object.id }.filter { !$0.isEmpty }))
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
