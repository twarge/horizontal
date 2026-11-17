import Foundation

/// Whether a shape that is not on the board yet — a via, a track, a pad moved
/// somewhere else — would keep the clearances the rules ask, measured against
/// the board's items as the clearance check measures them.
///
/// This is the inner test of every search that proposes copper: a via site, a
/// path, a channel's capacity. It reads the board and changes nothing.
///
/// Planes' fills are left out unless `measuresPlanes`: a pour gives way to
/// new copper the next time it runs, so a fill is no obstacle to a route,
/// only something the pour will then cut.
struct HorizontalBoardProbe {
    /// A shape to test, as the kind of copper it would be.
    struct Candidate {
        var kind: HorizontalBoardItem.Kind
        /// Lowercased.
        var netID: String?
        var shape: HorizontalBoardItem.Shape

        var item: HorizontalBoardItem {
            let (segments, radius) = shape.edges
            return HorizontalBoardItem(
                kind: kind, id: "", netID: netID, label: "", layerMin: 0, layerMax: 0,
                box: HorizontalRouteClearanceProbe.bounds(segments.flatMap { [$0.0, $0.1] }, growth: radius), shape: shape)
        }
    }

    /// What stands in a candidate's way, or nearest it.
    enum Obstacle: Equatable {
        case item(Int)
        /// Outside the board's outline, or in a cutout of it.
        case outsideBoard
        /// In a box the caller asked to keep out of.
        case avoid(Int)
    }

    struct Measurement {
        var obstacle: Obstacle
        var layer: Int
        /// Copper to copper, in nanometres.
        var gap: Double
        /// What the rules ask, without the probe's margin.
        var required: Double
        var ruleKind: HorizontalBoardRuleKind?
        var ruleID: String?
        var candidatePoint: HorizontalPoint
        var obstaclePoint: HorizontalPoint

        /// How much more than the rules ask.
        var slack: Double { gap - required }
    }

    struct Avoid {
        /// Nil for every layer.
        var layer: Int?
        var box: HorizontalRect

        var shape: HorizontalBoardItem.Shape {
            .polygon([HorizontalPoint(x: box.minX, y: box.minY), HorizontalPoint(x: box.maxX, y: box.minY),
                      HorizontalPoint(x: box.maxX, y: box.maxY), HorizontalPoint(x: box.minX, y: box.maxY)])
        }
    }

    let items: HorizontalBoardItems
    let rules: HorizontalBoardRules
    let tiedNets: Set<String>
    /// The outline's rings; a point inside an odd number is on the board.
    let outline: [[HorizontalPoint]]
    /// The largest clearance any rule asks of anything.
    let largestClearance: Double

    /// Added to what the rules ask.
    var margin = 0.0
    /// Ids of items to treat as gone, lowercased: a track to be ripped up.
    var ignored = Set<String>()
    /// Board packages whose pads, holes and keepouts are treated as gone.
    var ignoredPackages = Set<String>()
    var measuresPlanes = false
    var avoid = [Avoid]()

    init(board: HorizontalBoard, items: HorizontalBoardItems? = nil, tiedNets: Set<String> = []) {
        self.items = items ?? HorizontalBoardItems(board: board)
        rules = board.rules
        self.tiedNets = tiedNets.union(HorizontalBoardClearanceCheck.tiedNets(of: board))
        outline = board.polygons.filter { $0.layer == HorizontalBoardLayers.outline }
            .map { $0.renderVertices(arcPrecision: 48) }.filter { $0.count >= 3 }
        let copper: [HorizontalPatchType] = [.track, .pad, .padTH, .via, .plane, .holePTH, .netTie]
        var most = Double(HorizontalRuleClearanceCopper.defaultClearance)
        for rule in rules.clearanceCopperRules where rule.enabled {
            for a in copper {
                for b in copper { most = max(most, Double(rule.clearance(a, b))) }
            }
        }
        for rule in rules.clearanceCopperOtherRules where rule.enabled {
            for a in copper {
                for b in [HorizontalPatchType.holeNPTH, .boardEdge] { most = max(most, Double(rule.clearance(copper: a, nonCopper: b))) }
            }
        }
        for rule in rules.clearanceCopperKeepoutRules where rule.enabled {
            for a in copper { most = max(most, Double(rule.clearance(a))) }
        }
        largestClearance = most
    }

    func isOnBoard(_ point: HorizontalPoint) -> Bool {
        outline.isEmpty || outline.filter { HorizontalBoardOutlines.contains(point, in: $0) }.count % 2 == 1
    }

    private func skips(_ item: HorizontalBoardItem) -> Bool {
        if item.kind == .silkscreen { return true }
        if item.kind == .plane, !measuresPlanes { return true }
        if !ignored.isEmpty, ignored.contains(item.id.lowercased()) { return true }
        if let package = item.packageID, ignoredPackages.contains(package) { return true }
        return false
    }

    /// The first thing `candidate` would be too close to on `layer`, or nil
    /// when it keeps every clearance there with the margin and `extra` to
    /// spare. `extra` is what a search adds for its own resolution, given the
    /// clearance asked of the pair.
    func firstViolation(_ candidate: Candidate, layer: Int, extra: (Double) -> Double = { _ in 0 }) -> Obstacle? {
        guard let anchor = candidate.shape.anchor else { return nil }
        if !isOnBoard(anchor) { return .outsideBoard }
        let own = candidate.item
        for (index, area) in avoid.enumerated() where area.layer == nil || area.layer == layer {
            if HorizontalShapeGap.between(candidate.shape, area.shape, limit: 0) != nil { return .avoid(index) }
        }
        let reach = largestClearance + margin + extra(largestClearance)
        let query = HorizontalRouteClearanceProbe.bounds([HorizontalPoint(x: own.box.minX, y: own.box.minY),
                                                          HorizontalPoint(x: own.box.maxX, y: own.box.maxY)], growth: reach)
        var found: Obstacle?
        var seen = Set<Int>()
        items.visit(near: query) { index in
            guard found == nil else { return }
            let item = items.items[index]
            guard item.isOn(layer), item.box.maxX >= query.minX, item.box.minX <= query.maxX,
                  item.box.maxY >= query.minY, item.box.minY <= query.maxY, !skips(item), seen.insert(index).inserted,
                  let required = HorizontalBoardItems.required(own, item, layer: layer, rules: rules, tiedNets: tiedNets) else { return }
            let needed = required.clearance + margin + extra(required.clearance)
            // Where nothing is asked, the two still may not touch: a keepout
            // no rule gives a clearance to.
            let limit = max(needed - HorizontalBoardClearanceCheck.tolerance, 0)
            if let gap = HorizontalShapeGap.between(candidate.shape, item.shape, limit: limit), gap.distance < needed || gap.distance <= 0 {
                found = .item(index)
            }
        }
        return found
    }

    /// Everything within `reach` of `candidate` on `layer` that the rules ask
    /// a clearance of, the one with the least to spare first; for each item
    /// its nearest shape.
    func measurements(_ candidate: Candidate, layer: Int, reach: Double? = nil) -> [Measurement] {
        guard let anchor = candidate.shape.anchor else { return [] }
        let own = candidate.item
        var found = [Measurement]()
        if !isOnBoard(anchor) {
            found.append(Measurement(obstacle: .outsideBoard, layer: layer, gap: 0, required: 0, ruleKind: .clearanceCopperOther,
                                     ruleID: nil, candidatePoint: anchor, obstaclePoint: anchor))
        }
        for (index, area) in avoid.enumerated() where area.layer == nil || area.layer == layer {
            if let gap = HorizontalShapeGap.between(candidate.shape, area.shape, limit: 0) {
                found.append(Measurement(obstacle: .avoid(index), layer: layer, gap: 0, required: 0, ruleKind: nil, ruleID: nil,
                                         candidatePoint: gap.first, obstaclePoint: gap.second))
            }
        }
        let reach = reach ?? (largestClearance + margin)
        let query = HorizontalRouteClearanceProbe.bounds([HorizontalPoint(x: own.box.minX, y: own.box.minY),
                                                          HorizontalPoint(x: own.box.maxX, y: own.box.maxY)], growth: reach)
        var best = [String: Measurement]()
        for index in items.indices(overlapping: query) {
            let item = items.items[index]
            guard item.isOn(layer), !skips(item),
                  let required = HorizontalBoardItems.required(own, item, layer: layer, rules: rules, tiedNets: tiedNets),
                  let gap = HorizontalShapeGap.between(candidate.shape, item.shape, limit: reach) else { continue }
            let measurement = Measurement(obstacle: .item(index), layer: layer, gap: gap.distance, required: required.clearance,
                                          ruleKind: required.kind, ruleID: required.ruleID,
                                          candidatePoint: gap.first, obstaclePoint: gap.second)
            let key = "\(item.kind.name)|\(item.id)"
            if let current = best[key], current.slack <= measurement.slack { continue }
            best[key] = measurement
        }
        found += best.sorted { ($0.value.slack, $0.key) < ($1.value.slack, $1.key) }.map(\.value)
        return found
    }

    /// Whether a measurement breaks the rules with the probe's margin.
    func violates(_ measurement: Measurement) -> Bool {
        switch measurement.obstacle {
        case .outsideBoard, .avoid: return true
        case .item: return measurement.gap < measurement.required + margin - HorizontalBoardClearanceCheck.tolerance || measurement.gap <= 0
        }
    }

    // MARK: - Candidates

    static func via(at point: HorizontalPoint, diameter: Double, net: String?) -> Candidate {
        Candidate(kind: .via, netID: net?.lowercased(), shape: .disc(point, radius: diameter / 2))
    }

    static func track(_ points: [HorizontalPoint], width: Double, net: String?) -> Candidate {
        Candidate(kind: .track, netID: net?.lowercased(), shape: .path(points, halfWidth: width / 2))
    }
}

/// The shape and reach of a via a tool is asked to consider: a board via
/// definition's, the via rule's for a net, or sizes given outright.
struct HorizontalViaShape {
    var diameter: Double
    var hole: Double
    /// The copper layers it joins, top first.
    var layers: [Int]
    /// The definition it came from, by name; nil for the rules' or its own.
    var definition: String?
    var definitionID: String?
    var source: String

    /// Nil when nothing gives a diameter.
    static func resolve(definition reference: String?, diameter: Double?, hole: Double?, net: String?,
                        board: HorizontalBoard) throws -> HorizontalViaShape? {
        let through = HorizontalBoardItems.copperLayers(of: board)
        if let reference, !reference.isEmpty {
            let matches = board.viaDefinitions.filter {
                $0.id.caseInsensitiveCompare(reference) == .orderedSame || $0.name.caseInsensitiveCompare(reference) == .orderedSame
            }
            guard let found = matches.first, matches.count == 1 else {
                let known = board.viaDefinitions.map(\.name).sorted().joined(separator: ", ")
                throw HorizontalDispatchError.notFound(
                    matches.isEmpty ? "No via definition \(reference). The board has: \(known.isEmpty ? "none" : known)."
                                    : "More than one via definition is called \(reference); use its uuid.")
            }
            guard let size = diameter ?? found.parameters["via_diameter"], size > 0 else {
                throw HorizontalDispatchError.invalidParams("Via definition \(found.name) states no via_diameter; pass diameter_mm.")
            }
            let layers = found.span.map { span in through.filter { $0 <= span.start && $0 >= span.end } } ?? through
            return HorizontalViaShape(diameter: size, hole: hole ?? found.parameters["hole_diameter"] ?? size / 2, layers: layers,
                                      definition: found.name, definitionID: found.id, source: "definition")
        }
        if let diameter, diameter > 0 {
            return HorizontalViaShape(diameter: diameter, hole: hole ?? diameter / 2, layers: through, definition: nil,
                                      definitionID: nil, source: "local")
        }
        if let rule = board.rules.via(net: net), let size = rule.parameterSet["via_diameter"], size > 0 {
            return HorizontalViaShape(diameter: size, hole: hole ?? rule.parameterSet["hole_diameter"] ?? size / 2, layers: through,
                                      definition: nil, definitionID: nil, source: "rules")
        }
        return nil
    }
}
