import Foundation

/// A finding of the board's rules checks, as the results sidebar, the canvas
/// markers and MCP `check` list them: the clearance check's pairs
/// (`HorizontalClearanceFinding`, which `clearance` carries) and every other
/// check's.
struct HorizontalBoardRuleFinding: Identifiable, Equatable, Sendable {
    enum Level: String, Equatable, Sendable {
        /// What Horizon fails.
        case error
        /// What Horizon warns of.
        case warning
    }

    /// The kind of rule the check belongs to; nil for Horizontal's own checks
    /// of copper (two nets' pads joined, a plane over another net's pad),
    /// which Horizon leaves to its copper clearance check.
    var kind: HorizontalBoardRuleKind?
    var level: Level
    /// Which of the kind's checks, as a short key: "airwire", "not_placed".
    var check: String
    /// What was found, alike for every finding of the check: what MCP groups
    /// them by.
    var title: String
    /// What Horizon says of this one.
    var message: String
    /// Where it is, which rule, what to do about it.
    var detail: String = ""
    var location: HorizontalPoint? = nil
    /// What to frame to show it.
    var region: HorizontalRect? = nil
    var layers: [Int] = []
    /// Lowercased.
    var netIDs: [String] = []
    var netNames: [String] = []
    /// Lowercased.
    var componentIDs: [String] = []
    var refdes: String? = nil
    /// The tracks, vias, holes, planes or polygons it is about.
    var objectIDs: [String] = []
    /// The rule it is against, where the kind holds several.
    var ruleID: String? = nil
    /// One side is a plane, so its net is highlighted though it floods the view.
    var showsPlane = false
    /// The pair, for a clearance finding.
    var clearance: HorizontalClearanceFinding? = nil

    var id: String {
        if let clearance { return clearance.id }
        let place = location.map { "\(Int64($0.x.rounded())),\(Int64($0.y.rounded()))" } ?? ""
        return "\(kind?.rawValue ?? "copper")|\(check)|\(message)|\(objectIDs.joined(separator: ","))|\(place)"
    }

    /// The message and what more there is, as a marker's popover says it.
    var text: String {
        detail.isEmpty ? message : "\(message). \(detail)"
    }

    init(
        kind: HorizontalBoardRuleKind?, level: Level, check: String, title: String, message: String,
        detail: String = "", location: HorizontalPoint? = nil, region: HorizontalRect? = nil, layers: [Int] = [],
        netIDs: [String] = [], netNames: [String] = [], componentIDs: [String] = [], refdes: String? = nil,
        objectIDs: [String] = [], ruleID: String? = nil, showsPlane: Bool = false
    ) {
        self.kind = kind
        self.level = level
        self.check = check
        self.title = title
        self.message = message
        self.detail = detail
        self.location = location
        self.region = region
        self.layers = layers
        self.netIDs = netIDs
        self.netNames = netNames
        self.componentIDs = componentIDs
        self.refdes = refdes
        self.objectIDs = objectIDs
        self.ruleID = ruleID
        self.showsPlane = showsPlane
    }

    /// A clearance finding as one of these: an error between two objects.
    init(_ finding: HorizontalClearanceFinding) {
        self.init(
            kind: finding.ruleKind, level: .error, check: finding.check.rawValue, title: finding.title,
            message: finding.title, detail: finding.detail, location: finding.location, region: finding.region,
            layers: finding.layers,
            netIDs: [finding.first.netID, finding.second.netID].compactMap { $0 },
            netNames: [finding.first.netName, finding.second.netName].compactMap { $0 },
            componentIDs: [finding.first.componentID, finding.second.componentID].compactMap { $0 },
            objectIDs: [finding.first.id, finding.second.id].filter { !$0.isEmpty },
            ruleID: finding.ruleID,
            showsPlane: finding.first.type == .plane || finding.second.type == .plane)
        clearance = finding
    }
}

/// What the board checks read of the design that the board doesn't draw,
/// taken from its block and its file when it loads.
struct HorizontalBoardCheckFacts: Sendable {
    struct Component: Hashable, Sendable {
        var id: String
        var label: String
    }

    /// The block's components that have no part, which no package can stand
    /// for, by refdes.
    var componentsWithoutPart: [Component] = []
    /// The block's net ties.
    var blockNetTies: [HorizontalNetTieDetails] = []
    /// The block net tie each board net tie draws, by the board tie's id;
    /// both lowercased.
    var netTieBlockIDs: [String: String] = [:]
    /// The file's height restrictions (Board::height_restrictions).
    var heightRestrictions: [HorizontalHeightRestriction] = []
    /// There was a block to read, so what it lacks is known to be lacking.
    var hasBlock = false
}

/// A height restriction: a polygon on a package layer, and how tall a
/// package standing in it may be on that side.
struct HorizontalHeightRestriction: Hashable, Sendable {
    var id: String
    /// The polygon in the board's `polygons`, lowercased.
    var polygonID: String
    var height: Double
}

/// Everything the board checks found.
struct HorizontalBoardCheckResults: Sendable {
    var clearance: [HorizontalClearanceFinding]
    var findings: [HorizontalBoardRuleFinding]

    /// Every finding alike, the clearance ones first.
    var all: [HorizontalBoardRuleFinding] {
        clearance.map(HorizontalBoardRuleFinding.init) + findings
    }
}

/// Horizon's board rules checks (BoardRules::check), each kind's as Horizon
/// runs it, measured on the board's own geometry: the clearance families and
/// the connectivity check in `HorizontalBoardClearanceCheck`, and here track
/// width, hole size, preflight, plane fill order, net ties and height
/// restrictions; with Horizontal's own copper checks of copper joining two
/// nets and a plane poured over another net's pad.
enum HorizontalBoardRulesCheck {
    /// Every check on `board`, as `rules` (the board's own by default) stand;
    /// nil once `isCancelled` says so.
    static func run(
        board: HorizontalBoard,
        rules: HorizontalBoardRules? = nil,
        tiedNets: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) -> HorizontalBoardCheckResults? {
        let rules = rules ?? board.rules
        guard let measured = HorizontalBoardClearanceCheck.runWithConnectivity(
            board: board, rules: rules, tiedNets: tiedNets, isCancelled: isCancelled) else {
            return nil
        }
        var findings = measured.connectivity
        findings += copperFindings(board: board)
        findings += trackWidthFindings(board: board, rules: rules)
        findings += holeSizeFindings(board: board, rules: rules)
        if isCancelled() { return nil }
        findings += preflightFindings(board: board, rules: rules)
        findings += planeFillOrderFindings(board: board)
        if isCancelled() { return nil }
        findings += netTieFindings(board: board, rules: rules)
        findings += heightRestrictionFindings(board: board, rules: rules)
        return HorizontalBoardCheckResults(clearance: measured.clearance, findings: sorted(findings))
    }

    /// `run`, off the main thread; nil once the calling task is cancelled.
    static func results(board: HorizontalBoard, tiedNets: Set<String> = []) async -> HorizontalBoardCheckResults? {
        let task = Task.detached(priority: .userInitiated) {
            run(board: board, tiedNets: tiedNets, isCancelled: { Task.isCancelled })
        }
        let results = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : results
    }

    /// Kinds in the rules window's order, errors before warnings within one.
    static func sorted(_ findings: [HorizontalBoardRuleFinding]) -> [HorizontalBoardRuleFinding] {
        let order = Dictionary(uniqueKeysWithValues: HorizontalBoardRuleKind.allCases.enumerated().map { ($1, $0) })
        return findings.enumerated().sorted { lhs, rhs in
            let left = lhs.element.kind.map { order[$0]! } ?? -1, right = rhs.element.kind.map { order[$0]! } ?? -1
            if left != right { return left < right }
            if lhs.element.level != rhs.element.level { return lhs.element.level == .error }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: Helpers

    static let tolerance = HorizontalBoardClearanceCheck.tolerance

    static func mm(_ nanometres: Double) -> String {
        HorizontalClearanceFinding.millimetres(nanometres)
    }

    static func netName(_ net: String?, in board: HorizontalBoard) -> String {
        guard let net else { return "no net" }
        let name = board.netDetails[net.lowercased()]?.name ?? ""
        return name.isEmpty ? "unnamed net" : name
    }

    static func region(_ points: [HorizontalPoint], margin: Double = 1_500_000) -> HorizontalRect {
        HorizontalRect(points: points).expanded(by: margin)
    }

    static func packagesByID(_ board: HorizontalBoard) -> [String: HorizontalPlacement] {
        Dictionary(board.packages.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The package an id of package geometry ("package/…") belongs to.
    static func owner(_ id: String, in packages: [String: HorizontalPlacement]) -> HorizontalPlacement? {
        id.split(separator: "/").first.flatMap { packages[String($0).lowercased()] }
    }

    /// "U3.4" for each pad, by its "package/pad" path, lowercased.
    static func padNames(_ board: HorizontalBoard) -> [String: String] {
        let packages = packagesByID(board)
        var names = [String: String]()
        for pad in board.packagePads {
            let parts = pad.id.lowercased().split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[1] == "pad" else { continue }
            let path = "\(parts[0])/\(parts[2])"
            guard names[path] == nil else { continue }
            let name = pad.metadata["Pad"] ?? String(parts[2].prefix(8))
            let refdes = packages[parts[0]].flatMap { $0.label.isEmpty ? nil : $0.label }
            names[path] = refdes.map { "\($0).\(name)" } ?? name
        }
        return names
    }

    /// `path` running counter-clockwise, so shapes filled nonzero add up.
    static func counterClockwise(_ path: [HorizontalPoint]) -> [HorizontalPoint] {
        HorizontalPolygonBoolean.signedArea(path) < 0 ? path.reversed() : path
    }

    /// A fill's paths with its outer contour counter-clockwise and its holes
    /// clockwise, so a set of them filled nonzero leaves the holes open.
    static func oriented(_ fragment: [[HorizontalPoint]]) -> [[HorizontalPoint]] {
        fragment.enumerated().map { index, path in
            let ccw = counterClockwise(path)
            return index == 0 ? ccw : ccw.reversed()
        }
    }

    /// The area a stroke of `width` covers along `points`, one capsule a
    /// segment.
    static func stroke(_ points: [HorizontalPoint], width: Double) -> [[HorizontalPoint]] {
        let pairs = points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
        return pairs.map { capsule($0.0, $0.1, width: width) }.filter { $0.count >= 3 }
    }

    static func capsule(_ a: HorizontalPoint, _ b: HorizontalPoint, width: Double, segments: Int = 32) -> [HorizontalPoint] {
        let radius = width / 2
        guard radius > 0 else { return [] }
        let dx = b.x - a.x, dy = b.y - a.y
        let heading = dx == 0 && dy == 0 ? 0 : atan2(dy, dx)
        var points = [HorizontalPoint]()
        for (center, start) in [(b, heading - Double.pi / 2), (a, heading + Double.pi / 2)] {
            for step in 0...segments {
                let angle = start + Double(step) / Double(segments) * Double.pi
                points.append(HorizontalPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
            }
        }
        return points
    }

    // MARK: Copper

    /// The planes poured over a pad on another net, with the pads: what a
    /// pour made before a pad changed nets leaves, until the plane is poured
    /// again. A pad is under the fill where its centre is.
    static func planesOverPads(_ board: HorizontalBoard) -> [(plane: HorizontalPlane, pads: [HorizontalPolygon])] {
        let pads = board.packagePads.filter { $0.netID != nil && $0.layer != nil }
        let padsByLayer = Dictionary(grouping: pads.indices, by: { pads[$0].layer! })
        var centers = [HorizontalPoint?](repeating: nil, count: pads.count)
        var found = [(plane: HorizontalPlane, pads: [HorizontalPolygon])]()
        for plane in board.planes {
            guard let layer = plane.layer, let planeNet = plane.netID?.lowercased(), !plane.fragments.isEmpty else { continue }
            let boxes = plane.fragments.map { HorizontalRect(points: $0.paths.first ?? []) }
            var covered = [HorizontalPolygon]()
            for index in padsByLayer[layer] ?? [] where pads[index].netID?.lowercased() != planeNet {
                let center = centers[index] ?? HorizontalRect(points: pads[index].renderVertices(arcPrecision: 24)).center
                centers[index] = center
                let inside = zip(plane.fragments, boxes).contains { fragment, box in
                    center.x >= box.minX && center.x <= box.maxX && center.y >= box.minY && center.y <= box.maxY
                        && fragment.containmentPaths.filter { $0.contains(center) }.count % 2 == 1
                }
                if inside {
                    covered.append(pads[index])
                }
            }
            if !covered.isEmpty {
                found.append((plane, covered))
            }
        }
        return found
    }

    /// Horizontal's own copper checks, which need no clearance: tracks and
    /// vias that join pads of two nets, and a plane poured over a pad of
    /// another net. Horizon's copper clearance check finds the copper of
    /// either touching; these say why.
    static func copperFindings(board: HorizontalBoard) -> [HorizontalBoardRuleFinding] {
        let shorts = HorizontalBoardConnectivity.shorts(board)
        let overPads = planesOverPads(board)
        guard !shorts.isEmpty || !overPads.isEmpty else { return [] }
        let names = padNames(board)
        func natural(_ items: [String]) -> [String] {
            items.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        func listed(_ items: [String], most: Int = 4) -> String {
            items.prefix(most).joined(separator: ", ") + (items.count > most ? ", …" : "")
        }
        var findings = [HorizontalBoardRuleFinding]()
        let tracksByID = Dictionary(board.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let viasByID = Dictionary(board.vias.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for short in shorts {
            let nets = short.nets.sorted { netName($0, in: board) < netName($1, in: board) }
            let byNet = Dictionary(grouping: short.pads, by: \.value).mapValues { natural($0.map { names[$0.key] ?? $0.key }) }
            let sides = nets.map { "\(netName($0, in: board)) (\(listed(byNet[$0] ?? [])))" }
            let copper = "\(short.trackIDs.count) track\(short.trackIDs.count == 1 ? "" : "s")"
                + (short.viaIDs.isEmpty ? "" : " and \(short.viaIDs.count) via\(short.viaIDs.count == 1 ? "" : "s")")
            let points = short.trackIDs.compactMap { tracksByID[$0] }.flatMap(\.pathPoints)
                + short.viaIDs.compactMap { viasByID[$0]?.position }
            findings.append(HorizontalBoardRuleFinding(
                kind: nil, level: .error, check: "short", title: "Copper joins two nets",
                message: "Copper joins \(nets.map { netName($0, in: board) }.joined(separator: " and "))",
                detail: "\(copper) join \(sides.joined(separator: " to ")).",
                location: short.position ?? points.first, region: points.isEmpty ? nil : region(points),
                netIDs: nets, netNames: nets.map { netName($0, in: board) },
                objectIDs: short.trackIDs + short.viaIDs))
        }
        for (plane, pads) in overPads {
            let planeNet = plane.netID?.lowercased()
            let covered = natural(Array(Set(pads.map { pad -> String in
                let parts = pad.id.lowercased().split(separator: "/").map(String.init)
                let path = parts.count >= 3 ? "\(parts[0])/\(parts[2])" : pad.id
                return "\(names[path] ?? path) (\(netName(pad.netID, in: board)))"
            })))
            let outline = pads.flatMap { $0.renderVertices(arcPrecision: 24) }
            findings.append(HorizontalBoardRuleFinding(
                kind: nil, level: .error, check: "plane_over_pad", title: "Plane runs over a pad on another net",
                message: "The \(netName(planeNet, in: board)) plane on \(HorizontalBoardLayers.name(for: plane.layer ?? 0)) covers \(listed(covered, most: 6))",
                detail: "It was poured before those pads took their nets, most likely; pouring the planes again clears it.",
                location: outline.first.map { _ in HorizontalRect(points: outline).center }, region: region(outline),
                layers: plane.layer.map { [$0] } ?? [],
                netIDs: ([planeNet] + pads.map { $0.netID?.lowercased() }).compactMap { $0 },
                netNames: [netName(planeNet, in: board)],
                objectIDs: [plane.id], showsPlane: true))
        }
        return findings
    }

    // MARK: Track width

    /// check_track_width: each track against the widths the first enabled
    /// track width rule taking its net gives its layer.
    static func trackWidthFindings(board: HorizontalBoard, rules: HorizontalBoardRules) -> [HorizontalBoardRuleFinding] {
        var findings = [HorizontalBoardRuleFinding]()
        for track in board.tracks {
            guard let layer = track.layer, HorizontalBoardLayers.isCopper(layer),
                  let (rule, widths) = rules.trackWidth(net: track.netID, layer: layer) else { continue }
            let narrow = track.width < widths.min - tolerance
            guard narrow || track.width > widths.max + tolerance else { continue }
            let limit = narrow ? widths.min : widths.max
            let net = netName(track.netID, in: board)
            findings.append(HorizontalBoardRuleFinding(
                kind: .trackWidth, level: .error, check: narrow ? "too_narrow" : "too_wide",
                title: narrow ? "Track narrower than its rule allows" : "Track wider than its rule allows",
                message: "Track width \(mm(track.width)) is \(narrow ? "less" : "greater") than \(mm(limit))",
                detail: "Track of \(net) on \(HorizontalBoardLayers.name(for: layer)); its rule allows \(mm(widths.min)) to \(mm(widths.max)).",
                location: HorizontalPoint(x: (track.from.x + track.to.x) / 2, y: (track.from.y + track.to.y) / 2),
                region: region(track.pathPoints), layers: [layer],
                netIDs: track.netID.map { [$0.lowercased()] } ?? [], netNames: [net],
                objectIDs: [track.id], ruleID: rule.id))
        }
        return findings
    }

    // MARK: Hole size

    /// check_hole_size: every hole — the board's, the vias', the pads' —
    /// against the diameters the first enabled hole size rule taking its net
    /// allows. A slot's diameter is its width.
    static func holeSizeFindings(board: HorizontalBoard, rules: HorizontalBoardRules) -> [HorizontalBoardRuleFinding] {
        guard !rules.holeSizeRules.isEmpty else { return [] }
        let packages = packagesByID(board)
        var padNameCache: [String: String]?
        func padName(_ path: String) -> String? {
            if padNameCache == nil {
                padNameCache = padNames(board)
            }
            return padNameCache?[path]
        }
        var padNets = [String: String]()
        for pad in board.packagePads {
            if let net = pad.netID, let prefix = padPrefix(pad.id) {
                padNets[prefix] = net.lowercased()
            }
        }
        let viaNets = Dictionary(board.vias.map { ($0.id.lowercased(), $0.netID?.lowercased()) }, uniquingKeysWith: { first, _ in first })
        var findings = [HorizontalBoardRuleFinding]()
        func check(_ hole: HorizontalHole, what: String, label: () -> String, net: String?, package: HorizontalPlacement? = nil) {
            guard let rule = rules.holeSize(net: net) else { return }
            let small = hole.diameter < rule.diameterMin - tolerance
            guard small || hole.diameter > rule.diameterMax + tolerance else { return }
            let label = label()
            let componentID = package?.componentID?.lowercased()
            let refdes = package.flatMap { $0.label.isEmpty ? nil : $0.label }
            findings.append(HorizontalBoardRuleFinding(
                kind: .holeSize, level: .error, check: small ? "too_small" : "too_large",
                title: small ? "Hole smaller than its rule allows" : "Hole larger than its rule allows",
                message: "\(what) diameter \(mm(hole.diameter)) is \(small ? "less" : "greater") than \(mm(small ? rule.diameterMin : rule.diameterMax))",
                detail: "\(label) of \(netName(net, in: board)); its rule allows \(mm(rule.diameterMin)) to \(mm(rule.diameterMax)).",
                location: hole.position, region: region(hole.boundsPoints),
                netIDs: net.map { [$0] } ?? [], netNames: [netName(net, in: board)],
                componentIDs: componentID.map { [$0] } ?? [], refdes: refdes,
                objectIDs: [hole.id], ruleID: rule.id))
        }
        for hole in board.holes where hole.diameter > 0 {
            check(hole, what: "Hole", label: { "Hole" }, net: hole.netID?.lowercased())
        }
        for hole in board.viaHoles where hole.diameter > 0 {
            let via = String(hole.id.lowercased().split(separator: "/").first ?? "")
            check(hole, what: "Via", label: { "Via" }, net: (hole.netID?.lowercased()) ?? viaNets[via] ?? nil)
        }
        for hole in board.packageHoles where hole.diameter > 0 {
            let pad = padPrefix(hole.id)
            check(hole, what: pad == nil ? "Hole" : "Pad hole", label: { () -> String in
                      let name = pad.flatMap { path -> String? in
                          let parts = path.split(separator: "/")
                          return padName("\(parts[0])/\(parts[2])")
                      }
                      return name.map { "Pad \($0)" } ?? "Hole"
                  },
                  net: hole.netID?.lowercased() ?? pad.flatMap { padNets[$0] },
                  package: owner(hole.id, in: packages))
        }
        return findings
    }

    /// "package/pad/pad" of a pad's polygon or hole id.
    static func padPrefix(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: "/")
        guard parts.count >= 3, parts[1] == "pad" else { return nil }
        return parts[0...2].joined(separator: "/")
    }

    // MARK: Preflight

    /// check_preflight: airwires (one finding a net here, where Horizon gives
    /// one an airwire), planes with nothing poured, components with no part
    /// and components with no package, a package's own texts moved off its
    /// side's silkscreen, tracks on no net, copper polygons that are neither
    /// plane nor keepout, lines and arcs on the outline layer, and an outline
    /// Horizon can't make a board of.
    static func preflightFindings(board: HorizontalBoard, rules: HorizontalBoardRules) -> [HorizontalBoardRuleFinding] {
        guard rules.checksPreflight else { return [] }
        var findings = [HorizontalBoardRuleFinding]()
        func add(_ level: HorizontalBoardRuleFinding.Level, _ check: String, _ title: String, _ message: String,
                 detail: String = "", at location: HorizontalPoint? = nil, region place: [HorizontalPoint] = [],
                 layers: [Int] = [], nets: [String] = [], components: [String] = [], refdes: String? = nil,
                 objects: [String] = []) {
            findings.append(HorizontalBoardRuleFinding(
                kind: .preflightChecks, level: level, check: check, title: title, message: message, detail: detail,
                location: location, region: place.isEmpty ? location.map { region([$0]) } : region(place),
                layers: layers, netIDs: nets, netNames: nets.map { netName($0, in: board) },
                componentIDs: components, refdes: refdes, objectIDs: objects))
        }

        // Airwires, a net at a time.
        let airwires = Dictionary(grouping: board.airwires, by: { $0.netID?.lowercased() ?? "" })
        for (net, wires) in airwires.sorted(by: { netName($0.key, in: board) < netName($1.key, in: board) }) {
            let name = net.isEmpty ? "no net" : netName(net, in: board)
            let zero = wires.filter { $0.from == $0.to }.count
            let what = wires.count == 1 ? (zero == 1 ? "Zero length airwire" : "Airwire") : "\(wires.count) airwires"
            let ordered = wires.sorted { ($0.from.x, $0.from.y, $0.to.x, $0.to.y) < ($1.from.x, $1.from.y, $1.to.x, $1.to.y) }
            let first = ordered[0]
            add(.error, "airwire", "Airwire", "\(what) of net \(name)",
                detail: wires.count > 1 && zero > 0 ? "\(zero) of zero length." : "",
                at: HorizontalPoint(x: (first.from.x + first.to.x) / 2, y: (first.from.y + first.to.y) / 2),
                region: ordered.flatMap { [$0.from, $0.to] }, nets: net.isEmpty ? [] : [net])
        }

        // A plane keeps only what joins copper of its net, unless it keeps
        // orphans; a net with no copper on the board leaves it nothing to
        // keep, however often it is poured.
        let copperNets = Set(board.packagePads.compactMap { $0.netID?.lowercased() }
            + board.tracks.compactMap { $0.netID?.lowercased() }
            + board.vias.compactMap { $0.netID?.lowercased() })
        for plane in board.planes where plane.fragments.isEmpty {
            let layer = plane.layer.map(HorizontalBoardLayers.name(for:)) ?? "no layer"
            let outline = plane.fallbackPolygon?.vertices ?? []
            let netless = plane.netID.map { !copperNets.contains($0.lowercased()) } ?? false
            add(.error, "plane_no_fragments", "Plane has no fragments",
                "Plane of net \(netName(plane.netID, in: board)) on layer \(layer) has no fragments",
                detail: netless
                    ? "Its net has no pads, tracks or vias on the board, so all the plane pours is orphaned copper, which it doesn't keep; pouring again changes nothing."
                    : "Nothing of it is poured: pour the planes, or the plane's outline holds no copper.",
                at: outline.first, region: outline, layers: plane.layer.map { [$0] } ?? [],
                nets: plane.netID.map { [$0.lowercased()] } ?? [], objects: [plane.id])
        }

        let facts = board.checkFacts
        for component in facts.componentsWithoutPart {
            add(.error, "no_part", "Component has no part", "Component \(component.label) has no part",
                components: [component.id], refdes: component.label)
        }
        let unplaced = board.unplacedObjects.filter { $0.componentID != nil }.map { (id: $0.componentID!, label: $0.label) }
            + facts.componentsWithoutPart.map { (id: $0.id, label: $0.label) }
        for component in unplaced.sorted(by: { $0.label.localizedStandardCompare($1.label) == .orderedAscending }) {
            add(.error, "not_placed", "Component is not placed", "Component \(component.label) is not placed",
                components: [component.id.lowercased()], refdes: component.label)
        }

        let packages = packagesByID(board)
        for text in board.packageTexts where text.fromSmash {
            guard let package = owner(text.id, in: packages), let layer = text.layer else { continue }
            let silkscreen = package.mirrored ? HorizontalBoardLayers.bottomSilkscreen : HorizontalBoardLayers.topSilkscreen
            guard layer != silkscreen else { continue }
            let refdes = package.label.isEmpty ? String(package.id.prefix(8)) : package.label
            add(.warning, "text_layer", "Package text off its silkscreen",
                "Text for \(refdes) should be on layer \(HorizontalBoardLayers.name(for: silkscreen)), but is on \(HorizontalBoardLayers.name(for: layer))",
                at: text.position, layers: [layer], components: package.componentID.map { [$0.lowercased()] } ?? [],
                refdes: refdes, objects: [text.id])
        }

        for track in board.tracks where track.netID == nil {
            let layer = track.layer.map(HorizontalBoardLayers.name(for:)) ?? "no layer"
            add(.error, "track_no_net", "Track has no net", "Track on layer \(layer) has no net",
                at: HorizontalPoint(x: (track.from.x + track.to.x) / 2, y: (track.from.y + track.to.y) / 2),
                region: track.pathPoints, layers: track.layer.map { [$0] } ?? [], objects: [track.id])
        }

        for polygon in board.polygons {
            guard let layer = polygon.layer, HorizontalBoardLayers.isCopper(layer) else { continue }
            add(.error, "copper_polygon", "Copper polygon is not a plane or keepout",
                "Polygon on layer \(HorizontalBoardLayers.name(for: layer)) is not a keepout or a plane",
                at: polygon.vertices.first, region: polygon.vertices, layers: [layer], objects: [polygon.id])
        }

        for line in board.lines where line.layer == HorizontalBoardLayers.outline {
            add(.error, "outline_line", "Line on the outline layer",
                "Line on outline layer. Use polygons to define board outline.",
                at: line.from, region: [line.from, line.to], layers: [HorizontalBoardLayers.outline], objects: [line.id])
        }
        for arc in board.arcs where arc.layer == HorizontalBoardLayers.outline {
            add(.error, "outline_arc", "Arc on the outline layer",
                "Arc on outline layer. Use polygons to define board outline.",
                at: arc.from, region: arc.polyline(precision: 24), layers: [HorizontalBoardLayers.outline], objects: [arc.id])
        }

        for problem in outlineProblems(board) {
            add(problem.level, problem.check, problem.title, problem.message, at: problem.location,
                region: problem.region, layers: [HorizontalBoardLayers.outline], objects: problem.objects)
        }
        return findings
    }

    struct OutlineProblem {
        var level: HorizontalBoardRuleFinding.Level
        var check: String
        var title: String
        var message: String
        var location: HorizontalPoint?
        var region: [HorizontalPoint] = []
        var objects: [String] = []
    }

    /// Board::get_outline_and_errors: the outline layer's polygons, the
    /// board's and its packages' (but a package's that omits its outline),
    /// make a board when there is one, or one enclosing all the others,
    /// which are its holes and cross no other hole; a zero-length edge is
    /// a warning.
    static func outlineProblems(_ board: HorizontalBoard) -> [OutlineProblem] {
        let packages = packagesByID(board)
        let polygons = board.polygons.filter { $0.layer == HorizontalBoardLayers.outline }
            + board.packagePolygons.filter {
                $0.layer == HorizontalBoardLayers.outline && !(owner($0.id, in: packages)?.omitOutline ?? false)
            }
        guard !polygons.isEmpty else {
            return [OutlineProblem(level: .error, check: "no_outline", title: "No board outline", message: "Found no outline polygons")]
        }
        let rings = polygons.map { $0.renderVertices(arcPrecision: 48) }
        func zeroLengthEdges(_ polygon: HorizontalPolygon) -> [OutlineProblem] {
            let vertices = polygon.vertices
            return vertices.indices.compactMap { index in
                vertices[index] == vertices[(index + 1) % vertices.count]
                    ? OutlineProblem(level: .warning, check: "zero_length_edge", title: "Zero-length outline edge",
                                     message: "Zero-length edge", location: vertices[index], objects: [polygon.id])
                    : nil
            }
        }
        guard polygons.count > 1 else {
            return zeroLengthEdges(polygons[0])
        }
        func encloses(_ i: Int, _ j: Int) -> Bool {
            HorizontalPolygonBoolean.difference([rings[j]], [rings[i]]).isEmpty
        }
        let enclosing = polygons.indices.filter { i in polygons.indices.allSatisfy { j in i == j || encloses(i, j) } }
        guard enclosing.count == 1, let outer = enclosing.first else {
            let message = enclosing.isEmpty ? "No outline polygon encloses all others" : "More than one outline polygon encloses all others"
            return [OutlineProblem(level: .error, check: enclosing.isEmpty ? "outline_not_enclosing" : "outline_ambiguous",
                                   title: "Board outline is ambiguous", message: message,
                                   location: rings[0].first, region: rings.flatMap { $0 }, objects: polygons.map(\.id))]
        }
        var problems = [OutlineProblem]()
        let holes = polygons.indices.filter { $0 != outer }
        for (n, i) in holes.enumerated() {
            for j in holes.dropFirst(n + 1) {
                for fragment in HorizontalPolygonBoolean.intersection([rings[i]], [rings[j]]) {
                    problems.append(OutlineProblem(level: .error, check: "holes_intersect", title: "Board cutouts cross",
                                                   message: "Hole intersects other hole", location: fragment[0].first,
                                                   region: fragment[0], objects: [polygons[i].id, polygons[j].id]))
                }
            }
        }
        guard problems.isEmpty else { return problems }
        return polygons.flatMap(zeroLengthEdges)
    }

    // MARK: Plane fill order

    /// check_plane_priorities: on each layer, planes whose outlines overlap
    /// must fill in an order that leaves each its copper. One inside another
    /// must fill first (a lower fill order), and two that cross must not
    /// share one; two identical outlines are a warning.
    static func planeFillOrderFindings(board: HorizontalBoard) -> [HorizontalBoardRuleFinding] {
        struct Outline {
            var plane: HorizontalPlane
            var ring: [HorizontalPoint]
        }
        var byLayer = [Int: [Outline]]()
        for plane in board.planes {
            guard let layer = plane.layer, let polygon = plane.fallbackPolygon else { continue }
            let ring = polygon.renderVertices(arcPrecision: 64)
            if ring.count >= 3 {
                byLayer[layer, default: []].append(Outline(plane: plane, ring: ring))
            }
        }
        var findings = [HorizontalBoardRuleFinding]()
        for (layer, outlines) in byLayer.sorted(by: { $0.key > $1.key }) {
            let ordered = outlines.sorted { $0.plane.id < $1.plane.id }
            let layerName = HorizontalBoardLayers.name(for: layer)
            for (n, a) in ordered.enumerated() {
                for b in ordered.dropFirst(n + 1) {
                    let overlap = HorizontalPolygonBoolean.intersection([a.ring], [b.ring])
                    guard !overlap.isEmpty else { continue }
                    let aEnclosesB = HorizontalPolygonBoolean.difference([b.ring], [a.ring]).isEmpty
                    let bEnclosesA = HorizontalPolygonBoolean.difference([a.ring], [b.ring]).isEmpty
                    let nameA = netName(a.plane.netID, in: board), nameB = netName(b.plane.netID, in: board)
                    var level = HorizontalBoardRuleFinding.Level.error
                    let check: String, title: String, message: String
                    if aEnclosesB && bEnclosesA {
                        level = .warning
                        check = "identical"
                        title = "Plane outlines are identical"
                        message = "Plane outline \(nameA) is identical to plane outline \(nameB) on layer \(layerName)"
                    } else if aEnclosesB || bEnclosesA {
                        let (enclosing, enclosed) = aEnclosesB ? (a, b) : (b, a)
                        guard enclosing.plane.priority <= enclosed.plane.priority else { continue }
                        check = "enclosing_fills_first"
                        title = "Enclosing plane fills before the plane inside it"
                        message = "Plane \(netName(enclosing.plane.netID, in: board)) enclosing plane \(netName(enclosed.plane.netID, in: board)) on layer \(layerName) needs higher fill order than enclosed plane"
                    } else {
                        guard a.plane.priority == b.plane.priority else { continue }
                        check = "same_fill_order"
                        title = "Overlapping planes share a fill order"
                        message = "Plane \(nameA) overlapping plane \(nameB) of fill order \(a.plane.priority) on layer \(layerName)"
                    }
                    let points = overlap.flatMap { $0[0] }
                    findings.append(HorizontalBoardRuleFinding(
                        kind: .plane, level: level, check: check, title: title, message: message,
                        detail: "Fill orders \(a.plane.priority) and \(b.plane.priority); a lower one fills first.",
                        location: HorizontalPolygonBoolean.centroid(of: overlap[0]), region: region(points, margin: 500_000),
                        layers: [layer], netIDs: [a.plane.netID, b.plane.netID].compactMap { $0?.lowercased() },
                        netNames: [nameA, nameB], objectIDs: [a.plane.id, b.plane.id], showsPlane: true))
                }
            }
        }
        return findings
    }

    // MARK: Net ties

    /// The copper of `net` on `layer`, net ties left out, as areas filled
    /// nonzero together: its tracks, pads, vias and fills.
    static func copper(of net: String, on layer: Int, in board: HorizontalBoard) -> [[HorizontalPoint]] {
        var areas = [[HorizontalPoint]]()
        for track in board.tracks where track.layer == layer && track.netID?.lowercased() == net {
            areas += stroke(track.pathPoints, width: track.width).map(counterClockwise)
        }
        for pad in board.packagePads where pad.netID?.lowercased() == net && (pad.layer == nil || pad.layer == layer) {
            let outline = pad.renderVertices(arcPrecision: 48)
            if outline.count >= 3 {
                areas.append(counterClockwise(outline))
            }
        }
        for via in board.vias where via.netID?.lowercased() == net && (via.connectedLayers.isEmpty || via.connectedLayers.contains(layer)) {
            let ring = via.ringOutline(segments: 48)
            if ring.count >= 3 {
                areas.append(counterClockwise(ring))
            }
        }
        for plane in board.planes where plane.layer == layer && plane.netID?.lowercased() == net {
            for fragment in plane.fragments {
                areas += oriented(fragment.paths)
            }
        }
        return areas
    }

    /// check_net_ties: every net tie of the block should be drawn on the
    /// board, and each one drawn should overlap the copper of both its nets
    /// on its layer, once each, by at least the area of a disc as wide as it
    /// (a warning short of that, and for each overlap past the first).
    static func netTieFindings(board: HorizontalBoard, rules: HorizontalBoardRules) -> [HorizontalBoardRuleFinding] {
        guard rules.checksNetTies else { return [] }
        let facts = board.checkFacts
        let blockTies = Dictionary(facts.blockNetTies.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var findings = [HorizontalBoardRuleFinding]()
        if facts.hasBlock {
            let drawn = Set(board.netTies.compactMap { facts.netTieBlockIDs[$0.id.lowercased()] })
            for tie in facts.blockNetTies.sorted(by: { ($0.primaryName, $0.secondaryName) < ($1.primaryName, $1.secondaryName) })
            where !drawn.contains(tie.id.lowercased()) {
                findings.append(HorizontalBoardRuleFinding(
                    kind: .netTies, level: .error, check: "not_on_board", title: "Net tie not on the board",
                    message: "Net tie for nets \(tie.primaryName) and \(tie.secondaryName) not present on board",
                    netIDs: [tie.primaryID, tie.secondaryID].compactMap { $0?.lowercased() },
                    netNames: [tie.primaryName, tie.secondaryName], objectIDs: [tie.id]))
            }
        }
        for tie in board.netTies {
            guard let layer = tie.layer, HorizontalBoardLayers.isCopper(layer), tie.width > 0 else { continue }
            let blockTie = facts.netTieBlockIDs[tie.id.lowercased()].flatMap { blockTies[$0] }
            let nets: [(id: String, name: String)]
            if let blockTie, let primary = blockTie.primaryID, let secondary = blockTie.secondaryID {
                nets = [(primary.lowercased(), blockTie.primaryName), (secondary.lowercased(), blockTie.secondaryName)]
            } else {
                // A tie the block doesn't name: the nets its ends are on.
                let ends = [tie.fromJunctionID, tie.toJunctionID].compactMap { $0.flatMap { board.junctionNetIDs[$0]?.lowercased() } }
                nets = Array(Set(ends)).sorted().map { ($0, netName($0, in: board)) }
            }
            guard !nets.isEmpty else { continue }
            let tieName = nets.count == 2 ? "Net tie for nets \(nets[0].name) and \(nets[1].name)" : "Net tie of \(nets[0].name)"
            let middle = HorizontalPoint(x: (tie.from.x + tie.to.x) / 2, y: (tie.from.y + tie.to.y) / 2)
            let shape = capsule(tie.from, tie.to, width: tie.width)
            let minimumArea = Double.pi * (tie.width / 2) * (tie.width / 2) * 0.99
            for net in nets {
                let overlaps = HorizontalPolygonBoolean.apply(
                    .intersection, [shape], copper(of: net.id, on: layer, in: board), subjectFill: .nonZero, clipFill: .nonZero)
                func finding(_ level: HorizontalBoardRuleFinding.Level, _ check: String, _ title: String, _ message: String,
                             at location: HorizontalPoint, region place: [HorizontalPoint]) -> HorizontalBoardRuleFinding {
                    HorizontalBoardRuleFinding(
                        kind: .netTies, level: level, check: check, title: title, message: message,
                        location: location, region: region(place, margin: max(tie.width * 4, 500_000)), layers: [layer],
                        netIDs: nets.map(\.id), netNames: nets.map(\.name), objectIDs: [tie.id])
                }
                guard !overlaps.isEmpty else {
                    findings.append(finding(.error, "does_not_connect", "Net tie does not reach its net",
                                            "\(tieName) does not connect net \(net.name)", at: middle, region: [tie.from, tie.to]))
                    continue
                }
                for (index, overlap) in overlaps.enumerated() {
                    let at = overlap[0].first ?? middle
                    if overlaps.count > 1 {
                        findings.append(finding(.warning, "connects_more_than_once", "Net tie meets its net more than once",
                                                "\(tieName) connects net \(net.name) more than once (\(index + 1) of \(overlaps.count))",
                                                at: at, region: overlap[0]))
                    }
                    if HorizontalPolygonBoolean.area(fragment: overlap) < minimumArea {
                        findings.append(finding(.warning, "insufficient_area", "Net tie barely meets its net",
                                                "\(tieName) connects net \(net.name) with insufficient area",
                                                at: at, region: overlap[0]))
                    }
                }
            }
        }
        return findings
    }

    // MARK: Height restrictions

    /// check_height_restrictions: a package whose outline on a package layer
    /// overlaps a height restriction on that layer must be no taller there
    /// than it allows, by its 3D model's heights; a package with no outline,
    /// or overlapping one with no model or no height on that side, is a
    /// warning, as is a restriction on any other layer.
    static func heightRestrictionFindings(board: HorizontalBoard, rules: HorizontalBoardRules) -> [HorizontalBoardRuleFinding] {
        let restrictions = board.checkFacts.heightRestrictions
        guard rules.checksHeightRestrictions, !restrictions.isEmpty else { return [] }
        let top = HorizontalBoardLayers.topPackage, bottom = HorizontalBoardLayers.bottomPackage
        var findings = [HorizontalBoardRuleFinding]()
        func refdes(_ package: HorizontalPlacement) -> String {
            package.label.isEmpty ? String(package.id.prefix(8)) : package.label
        }
        func add(_ level: HorizontalBoardRuleFinding.Level, _ check: String, _ title: String, _ message: String,
                 at location: HorizontalPoint?, region place: [HorizontalPoint], layers: [Int] = [],
                 package: HorizontalPlacement? = nil, objects: [String] = []) {
            findings.append(HorizontalBoardRuleFinding(
                kind: .heightRestrictions, level: level, check: check, title: title, message: message,
                location: location, region: place.isEmpty ? location.map { region([$0]) } : region(place), layers: layers,
                componentIDs: package?.componentID.map { [$0.lowercased()] } ?? [],
                refdes: package.map(refdes), objectIDs: objects))
        }

        let packages = packagesByID(board)
        var outlines = [String: (top: [[HorizontalPoint]], bottom: [[HorizontalPoint]])]()
        var polygonsByPackage = [String: [HorizontalPolygon]]()
        for polygon in board.packagePolygons where polygon.layer == top || polygon.layer == bottom {
            if let package = owner(polygon.id, in: packages) {
                polygonsByPackage[package.id.lowercased(), default: []].append(polygon)
            }
        }
        for package in board.packages.sorted(by: { refdes($0).localizedStandardCompare(refdes($1)) == .orderedAscending }) {
            let polygons = polygonsByPackage[package.id.lowercased()] ?? []
            let hasBottom = polygons.contains { $0.layer == bottom }
            let heightBottom = package.model3D?.heightBottom ?? 0
            var entry: (top: [[HorizontalPoint]], bottom: [[HorizontalPoint]]) = ([], [])
            for polygon in polygons {
                let ring = polygon.renderVertices(arcPrecision: 48)
                guard ring.count >= 3 else { continue }
                if polygon.layer == top {
                    entry.top.append(ring)
                    if !hasBottom, heightBottom != 0 {
                        entry.bottom.append(ring)
                    }
                } else {
                    entry.bottom.append(ring)
                }
            }
            if entry.top.isEmpty && entry.bottom.isEmpty {
                add(.warning, "no_package_outline", "Package has no outline",
                    "package \(refdes(package)) has no package outlines", at: package.position, region: [], package: package)
            }
            outlines[package.id.lowercased()] = entry
        }

        let thickness = board.stackupLayers.filter { $0.layer != HorizontalBoardLayers.bottomCopper }
            .reduce(0) { $0 + $1.substrateThickness }
        let polygons = Dictionary(board.polygons.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for restriction in restrictions.sorted(by: { $0.id < $1.id }) {
            guard let polygon = polygons[restriction.polygonID.lowercased()] else { continue }
            let ring = polygon.renderVertices(arcPrecision: 48)
            guard let layer = polygon.layer, layer == top || layer == bottom else {
                add(.warning, "not_package_layer", "Height restriction off the package layers",
                    "ignored height restriction not in package layer", at: polygon.vertices.first, region: ring,
                    objects: [restriction.id])
                continue
            }
            guard ring.count >= 3 else { continue }
            let side = layer == top ? "top" : "bottom"
            for package in board.packages.sorted(by: { refdes($0).localizedStandardCompare(refdes($1)) == .orderedAscending }) {
                guard let entry = outlines[package.id.lowercased()] else { continue }
                let paths = layer == top ? entry.top : entry.bottom
                guard !paths.isEmpty else { continue }
                let overlap = HorizontalPolygonBoolean.apply(.intersection, [ring], paths.map(counterClockwise))
                guard !overlap.isEmpty else { continue }
                guard let model = package.model3D else {
                    add(.warning, "no_model", "Package has no 3D model", "package \(refdes(package)) has no 3D model",
                        at: package.position, region: overlap.flatMap { $0[0] }, layers: [layer], package: package)
                    continue
                }
                let height = layer == top
                    ? model.heightTop - (package.mirrored ? thickness : 0)
                    : model.heightBottom - (package.mirrored ? 0 : thickness)
                if height == 0 {
                    add(.warning, "no_height", "Package has no height on that side",
                        "package \(refdes(package)) has no \(side) height", at: package.position,
                        region: overlap.flatMap { $0[0] }, layers: [layer], package: package)
                    continue
                }
                if height > restriction.height {
                    add(.error, "too_tall", "Package taller than its height restriction",
                        "package \(refdes(package)) \(side) height (\(HorizontalMillimetres.short(height))) exceeds height restriction of \(HorizontalMillimetres.short(restriction.height))",
                        at: package.position, region: overlap.flatMap { $0[0] }, layers: [layer], package: package,
                        objects: [restriction.id])
                }
            }
        }
        return findings
    }
}

/// Millimetres without trailing zeros, as Horizon's dim_to_string_nlz writes
/// a height: "3 mm", "1.25 mm".
enum HorizontalMillimetres {
    static func short(_ nanometres: Double) -> String {
        var text = String(format: "%.3f", nanometres / 1_000_000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) mm"
    }
}
