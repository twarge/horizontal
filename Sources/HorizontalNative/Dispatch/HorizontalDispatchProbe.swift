import Foundation

/// probe_clearance and find_via_sites: questions about copper that is not on
/// the board yet, answered from the board as it is and leaving it alone.
enum HorizontalDispatchProbe {
    typealias Geometry = HorizontalDispatchBoardGeometry
    static let nm = 1_000_000.0

    // MARK: - Shared request parts

    /// A probe with the request's margin_mm, ignore and planes.
    static func probe(_ entry: HorizontalDispatchProjectEntry, _ params: JSONDictionary) throws -> HorizontalBoardProbe {
        let board = try Geometry.board(entry)
        var probe = HorizontalBoardProbe(board: board, items: try Geometry.items(entry),
                                         tiedNets: HorizontalBoardClearanceCheck.tiedNets(of: entry.project))
        probe.margin = (params.double("margin_mm") ?? 0) * nm
        probe.measuresPlanes = params.bool("planes") ?? false
        if let ignore = params["ignore"] as? [String] {
            let known = Set(probe.items.items.map { $0.id.lowercased() })
            for id in ignore {
                // A pad is named by its path; anything else by its id or a
                // short form of it.
                let lowered = id.lowercased()
                if known.contains(lowered) {
                    probe.ignored.insert(lowered)
                } else if let full = try HorizontalDispatchValidation.id(matchingPrefix: id, in: known, kind: "item") {
                    probe.ignored.insert(full)
                } else {
                    throw HorizontalDispatchError.notFound("ignore names \(id), which is no track, via, pad, hole or keepout on the board.")
                }
            }
        }
        return probe
    }

    /// The net a request names, lowercased; nil when it names none.
    static func net(_ params: JSONDictionary, entry: HorizontalDispatchProjectEntry, key: String = "net") throws -> String? {
        guard let reference = params.string(key), !reference.isEmpty else { return nil }
        return try Geometry.netID(reference, entry: entry)
    }

    /// One end of something asked about: a pad, a junction, a via or a point.
    struct Anchor {
        var point: HorizontalPoint
        /// Lowercased; nil where the end names none.
        var netID: String?
        /// The copper layers it can be reached on; nil for any.
        var layers: [Int]?
        /// The end as place_track takes it.
        var end: JSONDictionary
        var label: String
    }

    static func anchor(_ value: Any?, entry: HorizontalDispatchProjectEntry, key: String) throws -> Anchor {
        guard let json = value as? JSONDictionary else {
            throw HorizontalDispatchError.invalidParams(
                "\(key) is one of {\"component\", \"pad\"}, {\"junction\"}, {\"via\"}, {\"x_mm\", \"y_mm\"} or {\"via_site\": {\"x_mm\", \"y_mm\"}}.")
        }
        let board = try Geometry.board(entry)
        if let reference = json.string("component") {
            guard let padName = json.string("pad") else {
                throw HorizontalDispatchError.invalidParams("\(key) names a component, so it needs a \"pad\" too.")
            }
            let package = try Geometry.package(reference, entry: entry)
            let pads = Geometry.pads(of: board).filter {
                $0.package.id == package.id && ($0.name.caseInsensitiveCompare(padName) == .orderedSame || $0.padID == padName.lowercased())
            }
            guard let pad = pads.first, pads.count == 1,
                  let at = board.packagePadPositions["\(package.id.lowercased())/\(pad.padID)"] else {
                throw HorizontalDispatchError.notFound("\(package.label) has \(pads.isEmpty ? "no" : "more than one") pad \(padName).")
            }
            let through = HorizontalBoardItems.copperLayers(of: board)
            var layers = Set<Int>()
            for polygon in pad.copper {
                if let layer = polygon.layer { layers.insert(layer) } else { layers.formUnion(through) }
            }
            // The end as place_track takes it: by refdes where that names one
            // part, else by the component's uuid — an instance's parts share a
            // refdes with the other instances' until they are annotated.
            let unique = !package.label.isEmpty
                && board.packages.filter { $0.label.caseInsensitiveCompare(package.label) == .orderedSame }.count == 1
            return Anchor(point: at, netID: pad.netID, layers: through.filter(layers.contains),
                          end: ["component": unique ? package.label : (package.componentID ?? package.label), "pad": pad.name],
                          label: "\(package.label).\(pad.name)")
        }
        if let reference = json.string("junction") {
            guard let match = board.junctions.first(where: { $0.key.caseInsensitiveCompare(reference) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No junction \(reference) on the board.")
            }
            // A junction is on the layers of what ends on it: its tracks,
            // and every layer of a via standing on it.
            let id = match.key.lowercased()
            var layers = Set<Int>()
            for track in board.tracks where track.fromJunctionID?.lowercased() == id || track.toJunctionID?.lowercased() == id {
                if let layer = track.layer { layers.insert(layer) }
            }
            for via in board.vias where hypot(via.position.x - match.value.x, via.position.y - match.value.y) < 1 {
                layers.formUnion(via.copperLayers)
            }
            let net = board.junctionNetIDs[match.key]
                ?? board.tracks.first { $0.fromJunctionID?.lowercased() == id || $0.toJunctionID?.lowercased() == id }?.netID
            return Anchor(point: match.value, netID: net?.lowercased(),
                          layers: layers.isEmpty ? nil : HorizontalBoardItems.copperLayers(of: board).filter(layers.contains),
                          end: ["junction": match.key], label: "junction \(match.key.prefix(8))")
        }
        if let reference = json.string("via") {
            guard let via = board.vias.first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame }) else {
                throw HorizontalDispatchError.notFound("No via \(reference) on the board.")
            }
            let point: JSONDictionary = HorizontalDispatchJSON.point(via.position)
            return Anchor(point: via.position, netID: via.netID?.lowercased(), layers: via.copperLayers.sorted(by: >), end: point,
                          label: "via \(via.id.prefix(8))")
        }
        let site = json.dictionary("via_site") ?? json
        guard let x = site.double("x_mm"), let y = site.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams(
                "\(key) is one of {\"component\", \"pad\"}, {\"junction\"}, {\"via\"}, {\"x_mm\", \"y_mm\"} or {\"via_site\": {\"x_mm\", \"y_mm\"}}.")
        }
        let point = HorizontalPoint(x: x * nm, y: y * nm)
        return Anchor(point: point, netID: nil, layers: nil, end: HorizontalDispatchJSON.point(point),
                      label: String(format: "(%.3f, %.3f)", x, y))
    }

    static func viaShape(_ params: JSONDictionary, net: String?, board: HorizontalBoard, need: String) throws -> HorizontalViaShape {
        let diameter = params.double("diameter_mm").map { $0 * nm }, hole = params.double("hole_mm").map { $0 * nm }
        guard let shape = try HorizontalViaShape.resolve(definition: params.string("definition"), diameter: diameter, hole: hole,
                                                         net: net, board: board) else {
            throw HorizontalDispatchError.invalidParams(
                "\(need) needs a via's shape: \"definition\" (a board via definition, by name), or \"diameter_mm\"; no via rule gives this net one.")
        }
        return shape
    }

    // MARK: - Replies

    static func json(_ obstacle: HorizontalBoardProbe.Obstacle, probe: HorizontalBoardProbe, board: HorizontalBoard) -> JSONDictionary {
        switch obstacle {
        case .item(let index):
            return Geometry.json(probe.items.items[index], board: board, copperLayers: probe.items.copperLayers)
        case .outsideBoard:
            return ["kind": "board_edge", "id": "", "label": "Outside the board"]
        case .avoid(let index):
            return ["kind": "avoid", "id": "avoid/\(index)", "label": "A box the request keeps out of"]
        }
    }

    static func json(_ measurement: HorizontalBoardProbe.Measurement, probe: HorizontalBoardProbe, board: HorizontalBoard) -> JSONDictionary {
        var json: JSONDictionary = [
            "item": json(measurement.obstacle, probe: probe, board: board),
            "layer": measurement.layer,
            "distance_mm": HorizontalDispatchJSON.mm(measurement.gap),
            "clearance_mm": HorizontalDispatchJSON.mm(measurement.required),
            "slack_mm": HorizontalDispatchJSON.mm(measurement.slack - probe.margin),
            "x_mm": HorizontalDispatchJSON.mm((measurement.candidatePoint.x + measurement.obstaclePoint.x) / 2),
            "y_mm": HorizontalDispatchJSON.mm((measurement.candidatePoint.y + measurement.obstaclePoint.y) / 2),
        ]
        if let kind = measurement.ruleKind {
            json["rule"] = ["kind": kind.rawValue, "id": measurement.ruleID as Any? as Any] as JSONDictionary
        }
        return json
    }

    /// A candidate on its layers: whether it is clear, the tightest
    /// measurement on each layer, and every one that breaks the rules.
    static func report(_ candidate: HorizontalBoardProbe.Candidate, layers: [Int], probe: HorizontalBoardProbe,
                       board: HorizontalBoard) -> (ok: Bool, json: JSONDictionary) {
        var tightest = [JSONDictionary]()
        var violations = [JSONDictionary]()
        for layer in layers {
            let measured = probe.measurements(candidate, layer: layer, reach: reportReach(probe))
            if let first = measured.first { tightest.append(json(first, probe: probe, board: board)) }
            violations += measured.filter(probe.violates).map { json($0, probe: probe, board: board) }
        }
        return (violations.isEmpty, ["ok": violations.isEmpty, "tightest": tightest, "violations": violations])
    }

    /// How far a reply looks for the nearest thing to name: further than
    /// any clearance, so a candidate that is clear still says what is closest.
    static func reportReach(_ probe: HorizontalBoardProbe) -> Double {
        probe.largestClearance + probe.margin + 500_000
    }

    // MARK: - probe_clearance

    static func probeClearance(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let probe = try probe(entry, params)
        guard let candidates = params["candidates"] as? [JSONDictionary], !candidates.isEmpty else {
            throw HorizontalDispatchError.invalidParams("probe_clearance needs \"candidates\": an array of {\"via\"}, {\"track\"} or {\"component\"} objects.")
        }
        guard candidates.count <= 2000 else {
            throw HorizontalDispatchError.invalidParams("At most 2000 candidates a call; find_via_sites searches a region for via positions.")
        }
        var results = [JSONDictionary]()
        var clear = 0
        for (index, wrapper) in candidates.enumerated() {
            do {
                var result: JSONDictionary
                if let via = wrapper.dictionary("via") {
                    result = try viaCandidate(via, entry: entry, probe: probe, board: board)
                } else if let track = wrapper.dictionary("track") {
                    result = try trackCandidate(track, entry: entry, probe: probe, board: board)
                } else if let component = wrapper.dictionary("component") {
                    result = try componentCandidate(component, entry: entry, probe: probe, board: board)
                } else {
                    throw HorizontalDispatchError.invalidParams("A candidate is {\"via\": …}, {\"track\": …} or {\"component\": …}.")
                }
                result["index"] = index
                if result["ok"] as? Bool == true { clear += 1 }
                results.append(result)
            } catch let error as HorizontalDispatchError {
                throw HorizontalDispatchError(code: error.code, message: "candidates[\(index)]: \(error.message)")
            }
        }
        return ["candidates": results, "clear": clear, "total": results.count,
                "margin_mm": HorizontalDispatchJSON.mm(probe.margin),
                "planes": probe.measuresPlanes ? "measured as last poured" : "not measured: a pour gives way to new copper"] as JSONDictionary
    }

    private static func point(_ json: JSONDictionary) throws -> HorizontalPoint {
        guard let x = json.double("x_mm"), let y = json.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("It needs \"x_mm\" and \"y_mm\".")
        }
        return HorizontalPoint(x: x * nm, y: y * nm)
    }

    private static func viaCandidate(_ json: JSONDictionary, entry: HorizontalDispatchProjectEntry, probe: HorizontalBoardProbe,
                                     board: HorizontalBoard) throws -> JSONDictionary {
        let net = try net(json, entry: entry)
        let shape = try viaShape(json, net: net, board: board, need: "A via candidate")
        let at = try point(json)
        var result = report(HorizontalBoardProbe.via(at: at, diameter: shape.diameter, net: net), layers: shape.layers,
                            probe: probe, board: board).json
        result["kind"] = "via"
        result["diameter_mm"] = HorizontalDispatchJSON.mm(shape.diameter)
        result["layers"] = shape.layers
        result.merge(padContact(at: at, diameter: shape.diameter, net: net, layers: shape.layers, probe: probe, board: board)) { current, _ in current }
        return result
    }

    private static func trackCandidate(_ json: JSONDictionary, entry: HorizontalDispatchProjectEntry, probe: HorizontalBoardProbe,
                                       board: HorizontalBoard) throws -> JSONDictionary {
        let net = try net(json, entry: entry)
        guard let layer = json.int("layer"), probe.items.copperLayers.contains(layer) else {
            throw HorizontalDispatchError.invalidParams("A track candidate needs \"layer\", a copper layer of this board.")
        }
        guard let width = json.double("width_mm"), width > 0 else {
            throw HorizontalDispatchError.invalidParams("A track candidate needs \"width_mm\".")
        }
        guard let raw = json["points_mm"] as? [[Any]], raw.count >= 2 else {
            throw HorizontalDispatchError.invalidParams("A track candidate needs \"points_mm\": two or more [x, y] points.")
        }
        let points = try raw.map { pair -> HorizontalPoint in
            guard pair.count == 2, let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue else {
                throw HorizontalDispatchError.invalidParams("points_mm is a list of [x, y] pairs.")
            }
            return HorizontalPoint(x: x * nm, y: y * nm)
        }
        var result = report(HorizontalBoardProbe.track(points, width: width * nm, net: net), layers: [layer], probe: probe, board: board).json
        result["kind"] = "track"
        result["length_mm"] = HorizontalDispatchJSON.mm(HorizontalRoute45.length(of: points))
        return result
    }

    /// Whether a via of `net` would stand in a pad of its own net, and
    /// whether that joins them: on the pad's centre it does, anywhere else
    /// in or against the pad a track has to.
    static func padContact(at point: HorizontalPoint, diameter: Double, net: String?, layers: [Int], probe: HorizontalBoardProbe,
                           board: HorizontalBoard) -> JSONDictionary {
        guard let index = probe.ownPad(under: point, diameter: diameter, net: net, layers: layers) else { return [:] }
        let item = probe.items.items[index]
        let parts = item.id.split(separator: "/").map(String.init)
        let centre = parts.count >= 3 ? board.packagePadPositions["\(parts[0])/\(parts[2])"] : nil
        let onCentre = centre.map { hypot($0.x - point.x, $0.y - point.y) < 1 } ?? false
        var contact: JSONDictionary = ["in_pad": ["pad": item.label, "id": item.id, "on_center": onCentre] as JSONDictionary]
        if !onCentre {
            contact["needs_link"] = true
        }
        return contact
    }

    // MARK: - A part somewhere else

    /// Where a point of a package placed as `from` is when it is placed as `to`.
    static func moved(_ point: HorizontalPoint, from: HorizontalPlacementTransform, to: HorizontalPlacementTransform) -> HorizontalPoint {
        let offset = HorizontalPoint(x: point.x - from.shift.x, y: point.y - from.shift.y)
        var local = HorizontalPlacementTransform(shift: .zero, angle: -from.angle, mirrored: false).applying(to: offset)
        if from.mirrored { local.x = -local.x }
        return to.applying(to: local)
    }

    static func moved(_ shape: HorizontalBoardItem.Shape, from: HorizontalPlacementTransform, to: HorizontalPlacementTransform)
        -> HorizontalBoardItem.Shape {
        func at(_ point: HorizontalPoint) -> HorizontalPoint { moved(point, from: from, to: to) }
        switch shape {
        case .path(let points, let halfWidth): return .path(points.map(at), halfWidth: halfWidth)
        case .disc(let center, let radius): return .disc(at(center), radius: radius)
        case .polygon(let points): return .polygon(points.map(at))
        case .region(let paths): return .region(paths.map { $0.map(at) })
        }
    }

    private static func componentCandidate(_ json: JSONDictionary, entry: HorizontalDispatchProjectEntry, probe: HorizontalBoardProbe,
                                           board: HorizontalBoard) throws -> JSONDictionary {
        guard let reference = json.string("refdes") ?? json.string("component") else {
            throw HorizontalDispatchError.invalidParams("A component candidate needs \"refdes\".")
        }
        let package = try Geometry.package(reference, entry: entry)
        let id = package.id.lowercased()
        let from = HorizontalPlacementTransform(shift: package.position, angle: package.angle, mirrored: package.mirrored)
        var angle = package.angle
        if let degrees = json.double("angle_deg") {
            angle = Int((degrees / 360 * 65_536).rounded()) % 65_536
            if angle < 0 { angle += 65_536 }
        }
        let shift = HorizontalPoint(x: (json.double("x_mm") ?? package.position.x / nm) * nm,
                                    y: (json.double("y_mm") ?? package.position.y / nm) * nm)
        let to = HorizontalPlacementTransform(shift: shift, angle: angle, mirrored: json.bool("bottom") ?? package.mirrored)
        let flips = to.mirrored != from.mirrored
        let inner = max(board.copperLayerCount - 2, 0)
        func layers(of item: HorizontalBoardItem) -> [Int] {
            let own = probe.items.copperLayers.filter(item.isOn)
            // A pad on one side goes to the other with its part; one on
            // every layer stays on every layer.
            guard flips, own.count == 1 else { return own }
            return own.map { HorizontalBoardLayers.flippedPackageLayer($0, nInnerLayers: inner) }
        }

        var away = probe
        away.ignoredPackages.insert(id)
        var tightest: HorizontalBoardProbe.Measurement?
        var violations = [JSONDictionary]()
        func take(_ candidate: HorizontalBoardProbe.Candidate, _ label: String, layers: [Int], probe: HorizontalBoardProbe) {
            for layer in layers {
                for measurement in probe.measurements(candidate, layer: layer) {
                    if tightest == nil || measurement.slack < (tightest?.slack ?? 0) { tightest = measurement }
                    if probe.violates(measurement) {
                        var row = Self.json(measurement, probe: probe, board: board)
                        row["of"] = label
                        violations.append(row)
                    }
                }
            }
        }

        // The part's pads and holes where it would be.
        var placed = [(candidate: HorizontalBoardProbe.Candidate, label: String, layers: [Int], id: String)]()
        for item in probe.items.items where item.packageID == id {
            guard item.kind == .pad || item.kind == .padThroughHole || item.kind == .hole else { continue }
            let candidate = HorizontalBoardProbe.Candidate(kind: item.kind, netID: item.netID, shape: moved(item.shape, from: from, to: to))
            placed.append((candidate, item.label, layers(of: item), item.id))
            take(candidate, item.label, layers: placed[placed.count - 1].layers, probe: away)
        }

        // The tracks that end on its pads go with them.
        var stretched = [JSONDictionary]()
        var padAt = [String: String]()
        for (path, position) in board.packagePadPositions where path.lowercased().hasPrefix(id + "/") {
            padAt["\(Int64(position.x.rounded())):\(Int64(position.y.rounded()))"] = path.lowercased()
        }
        let names = HorizontalBoardRulesCheck.padNames(board)
        for track in board.tracks {
            guard let layer = track.layer, track.center == nil else { continue }
            var ends = [track.from, track.to]
            var bound = [String]()
            for (index, junction) in [track.fromJunctionID, track.toJunctionID].enumerated() where junction == nil {
                guard let pad = padAt["\(Int64(ends[index].x.rounded())):\(Int64(ends[index].y.rounded()))"] else { continue }
                ends[index] = moved(ends[index], from: from, to: to)
                bound.append(names[pad] ?? pad)
            }
            guard !bound.isEmpty else { continue }
            let label = "Track \(track.id.prefix(8)) on \(bound.joined(separator: ", "))"
            let candidate = HorizontalBoardProbe.track(ends, width: track.width, net: track.netID)
            var without = away
            without.ignored.insert(track.id.lowercased())
            take(candidate, label, layers: [layer], probe: without)
            // And against the part's own pads of other nets, where they would be.
            for pad in placed where pad.layers.contains(layer) {
                let own = candidate.item
                var other = pad.candidate.item
                other.id = pad.id
                guard let required = HorizontalBoardItems.required(own, other, layer: layer, rules: probe.rules, tiedNets: probe.tiedNets),
                      let gap = HorizontalShapeGap.between(candidate.shape, pad.candidate.shape, limit: required.clearance + probe.margin),
                      gap.distance < required.clearance + probe.margin - HorizontalBoardClearanceCheck.tolerance else { continue }
                violations.append(["of": label, "item": ["kind": pad.candidate.kind.name, "id": pad.id, "label": pad.label] as JSONDictionary,
                                   "layer": layer, "distance_mm": HorizontalDispatchJSON.mm(gap.distance),
                                   "clearance_mm": HorizontalDispatchJSON.mm(required.clearance),
                                   "x_mm": HorizontalDispatchJSON.mm(gap.location.x), "y_mm": HorizontalDispatchJSON.mm(gap.location.y)])
            }
            stretched.append(["track": track.id, "pads": bound, "from_mm": HorizontalDispatchJSON.point(ends[0]),
                              "to_mm": HorizontalDispatchJSON.point(ends[1])])
        }

        var result: JSONDictionary = [
            "kind": "component", "refdes": package.label, "package": package.id,
            "ok": violations.isEmpty, "violations": violations, "stretched": stretched,
            "at_mm": HorizontalDispatchJSON.point(shift), "angle_deg": HorizontalDispatchJSON.degrees(to.angle), "bottom": to.mirrored,
        ]
        if let tightest { result["tightest"] = [Self.json(tightest, probe: away, board: board)] }
        result["silkscreen"] = silkscreen(package: package, from: from, to: to, board: board)
        if (result.dictionary("silkscreen")?["ok"] as? Bool) == false { result["ok"] = false }
        result["note"] = "Copper only where a track stays straight between its ends; a dry run of place_component with check measures the board as it would be, pours and silkscreen included."
        return result
    }

    /// The silkscreen rule for a part somewhere else, on the safe side: its
    /// own silkscreen against the mask openings of the rest of the board, and
    /// the rest's silkscreen against its own openings. Copper is bare only
    /// where there is copper in an opening, so a gap to the opening is never
    /// more than the gap the rule measures.
    static func silkscreen(package: HorizontalPlacement, from: HorizontalPlacementTransform, to: HorizontalPlacementTransform,
                           board: HorizontalBoard) -> JSONDictionary {
        let rule = board.rules.clearanceSilkscreenExposedCopper
        guard rule.enabled else { return ["ok": true, "note": "The silkscreen rule is off."] }
        let id = package.id.lowercased()
        let flips = to.mirrored != from.mirrored
        func owned(_ geometryID: String) -> Bool { geometryID.lowercased().hasPrefix(id + "/") }
        func side(_ layer: Int, moved: Bool) -> Bool {
            // true for the bottom
            HorizontalBoardLayers.isBottomSide(layer) != (moved && flips)
        }
        struct Shape { var label: String; var id: String; var bottom: Bool; var shape: HorizontalBoardItem.Shape }
        var ownSilk = [Shape](), otherSilk = [Shape](), ownOpenings = [Shape](), otherOpenings = [Shape]()
        let omitted = HorizontalPackageOmissions(packages: board.packages)
        func silk(_ id: String, _ label: String, _ layer: Int?, _ shape: HorizontalBoardItem.Shape) {
            guard let layer, HorizontalBoardLayers.isSilkscreen(layer), !omitted.omits(id, layer: layer) else { return }
            if owned(id) {
                ownSilk.append(Shape(label: label, id: id, bottom: side(layer, moved: true), shape: moved(shape, from: from, to: to)))
            } else {
                otherSilk.append(Shape(label: label, id: id, bottom: side(layer, moved: false), shape: shape))
            }
        }
        for line in board.lines + board.packageLines {
            silk(line.id, "Silkscreen line", line.layer, .path(line.pathPoints, halfWidth: line.width / 2))
        }
        for arc in board.arcs + board.packageArcs {
            silk(arc.id, "Silkscreen arc", arc.layer, .path(arc.polyline(precision: 48), halfWidth: arc.width / 2))
        }
        for drawn in HorizontalBoardTextExtents.drawnTexts(of: board) {
            silk(drawn.text.id, "Silkscreen text \(drawn.text.text)", drawn.text.layer,
                 .polygon(HorizontalBoardTextExtents.extent(of: drawn.text).corners))
        }
        let names = HorizontalBoardRulesCheck.padNames(board)
        for pad in board.packagePads {
            guard let layer = pad.layer, layer == HorizontalBoardLayers.topMask || layer == HorizontalBoardLayers.bottomMask else { continue }
            let points = pad.renderVertices(arcPrecision: 48)
            guard points.count >= 3 else { continue }
            let parts = pad.id.lowercased().split(separator: "/").map(String.init)
            let label = "Mask opening of pad " + (parts.count >= 3 ? names["\(parts[0])/\(parts[2])"] ?? parts[2] : pad.id)
            if owned(pad.id) {
                ownOpenings.append(Shape(label: label, id: pad.id, bottom: side(layer, moved: true), shape: moved(.polygon(points), from: from, to: to)))
            } else {
                otherOpenings.append(Shape(label: label, id: pad.id, bottom: side(layer, moved: false), shape: .polygon(points)))
            }
        }
        for via in board.vias {
            for layer in [HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomMask] {
                guard let diameter = via.maskDiameter(on: layer), diameter > 0 else { continue }
                otherOpenings.append(Shape(label: "Mask opening of via", id: via.id, bottom: layer == HorizontalBoardLayers.bottomMask,
                                           shape: .disc(via.position, radius: diameter / 2)))
            }
        }
        var close = [JSONDictionary]()
        var least: Double?
        for (silks, openings) in [(ownSilk, otherOpenings), (otherSilk, ownOpenings)] {
            for silk in silks {
                for opening in openings where opening.bottom == silk.bottom {
                    let required = silk.bottom ? rule.clearanceBottom : rule.clearanceTop
                    guard let gap = HorizontalShapeGap.between(silk.shape, opening.shape, limit: required + 500_000) else { continue }
                    least = min(least ?? gap.distance, gap.distance)
                    guard gap.distance < required - HorizontalBoardClearanceCheck.tolerance else { continue }
                    close.append(["silkscreen": ["id": silk.id, "label": silk.label] as JSONDictionary,
                                  "opening": ["id": opening.id, "label": opening.label] as JSONDictionary,
                                  "side": silk.bottom ? "bottom" : "top",
                                  "distance_mm": HorizontalDispatchJSON.mm(gap.distance), "clearance_mm": HorizontalDispatchJSON.mm(required),
                                  "x_mm": HorizontalDispatchJSON.mm(gap.location.x), "y_mm": HorizontalDispatchJSON.mm(gap.location.y)])
                }
            }
        }
        var result: JSONDictionary = ["ok": close.isEmpty, "close": Array(close.prefix(50)),
                                      "measured_to": "mask openings, which is where copper would be bare: no closer than the rule measures"]
        if close.count > 50 { result["close_count"] = close.count }
        if let least { result["least_mm"] = HorizontalDispatchJSON.mm(least) }
        return result
    }

    // MARK: - find_via_sites

    static func findViaSites(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try Geometry.board(entry)
        let probe = try probe(entry, params)
        guard let net = try net(params, entry: entry) else {
            throw HorizontalDispatchError.invalidParams("find_via_sites needs \"net\": the net the via would carry.")
        }
        let shape = try viaShape(params, net: net, board: board, need: "find_via_sites")
        guard let near = try Geometry.point(params, key: "near") else {
            throw HorizontalDispatchError.invalidParams("find_via_sites needs \"near\": {\"x_mm\", \"y_mm\"}.")
        }
        let radius = (params.double("radius_mm") ?? 1) * nm
        let grid = (params.double("grid_mm") ?? 0.025) * nm
        guard grid >= 1_000, radius > 0 else {
            throw HorizontalDispatchError.invalidParams("grid_mm is at least 0.001 and radius_mm more than 0.")
        }
        let steps = Int((radius / grid).rounded(.down))
        let side = 2 * steps + 1
        guard side * side <= 400_000 else {
            throw HorizontalDispatchError.invalidParams(
                "That is \(side * side) positions to test; at most 400000. Use a coarser grid_mm or a smaller radius_mm.")
        }
        let limit = min(max(params.int("limit") ?? 50, 1), 2000)
        // A via in a pad of its net passes every clearance, and round a pad
        // those are the nearest positions there are: listed only when asked
        // for, counted otherwise, so the sites are ones any board can take.
        let viaInPad = params.bool("via_in_pad") ?? false
        var inPad = 0

        struct Link {
            var layer: Int
            var to: Anchor
            var width: Double
            var bends: Int
        }
        var link: Link?
        if let json = params.dictionary("link") {
            guard let layer = json.int("layer"), shape.layers.contains(layer) else {
                throw HorizontalDispatchError.invalidParams("link needs \"layer\", a copper layer the via reaches (\(shape.layers.map(String.init).joined(separator: ", "))).")
            }
            guard let width = json.double("width_mm"), width > 0 else { throw HorizontalDispatchError.invalidParams("link needs \"width_mm\".") }
            let bends = json.int("bends") ?? 1
            guard (0...1).contains(bends) else {
                throw HorizontalDispatchError.invalidParams("link takes bends 0 or 1; find_path finds a way with more.")
            }
            link = Link(layer: layer, to: try anchor(json["to"], entry: entry, key: "link.to"), width: width * nm, bends: bends)
        }
        func linked(_ site: HorizontalPoint) -> [HorizontalPoint]? {
            guard let link else { return [] }
            var routes = [[site, link.to.point]]
            if link.bends >= 1 {
                routes += [true, false].map { HorizontalRoute45.elbow(from: site, to: link.to.point, diagonalFirst: $0) }.filter { $0.count == 3 }
            } else if !(site.x == link.to.point.x || site.y == link.to.point.y
                        || abs(abs(site.x - link.to.point.x) - abs(site.y - link.to.point.y)) < 1) {
                // Straight means along an axis or a diagonal, as tracks run.
                return nil
            }
            return routes.first { probe.firstViolation(HorizontalBoardProbe.track($0, width: link.width, net: net), layer: link.layer) == nil }
        }

        // The net's own vias in reach. No rule keeps a via off copper of its
        // own net, so a second via on one of them would pass every clearance:
        // two holes drilled into each other. A position whose copper would
        // overlap one is therefore no site, and the vias are listed, since
        // the one that stands there is the one to use.
        var standing = [(id: String, centre: HorizontalPoint, radius: Double)]()
        var standingIDs = Set<String>()
        let around = HorizontalRouteClearanceProbe.bounds([near], growth: radius + shape.diameter)
        for index in probe.items.indices(overlapping: around) {
            let item = probe.items.items[index]
            guard item.kind == .via, item.netID == net, !probe.ignored.contains(item.id.lowercased()),
                  case .disc(let centre, let itemRadius) = item.shape, standingIDs.insert(item.id).inserted else { continue }
            standing.append((item.id, centre, itemRadius))
        }
        func onStandingVia(_ point: HorizontalPoint) -> Bool {
            standing.contains { hypot(point.x - $0.centre.x, point.y - $0.centre.y) < $0.radius + shape.diameter / 2 - 1 }
        }

        // Every grid position in the circle, clear on every layer or not.
        var legal = [Bool](repeating: false, count: side * side)
        var blockedNearest: (distance: Double, point: HorizontalPoint)?
        for row in 0..<side {
            for column in 0..<side {
                let dx = Double(column - steps) * grid, dy = Double(row - steps) * grid
                guard dx * dx + dy * dy <= radius * radius else { continue }
                let point = HorizontalPoint(x: near.x + dx, y: near.y + dy)
                let candidate = HorizontalBoardProbe.via(at: point, diameter: shape.diameter, net: net)
                if onStandingVia(point) { continue }
                if shape.layers.allSatisfy({ probe.firstViolation(candidate, layer: $0) == nil }), linked(point) != nil {
                    if !viaInPad, probe.ownPad(under: point, diameter: shape.diameter, net: net, layers: shape.layers) != nil {
                        inPad += 1
                    } else {
                        legal[row * side + column] = true
                    }
                } else {
                    let distance = hypot(dx, dy)
                    if blockedNearest == nil || distance < (blockedNearest?.distance ?? 0) { blockedNearest = (distance, point) }
                }
            }
        }

        // The connected areas of legal positions.
        var region = [Int](repeating: -1, count: side * side)
        var regions = [[Int]]()
        for start in legal.indices where legal[start] && region[start] < 0 {
            var cells = [Int]()
            var pending = [start]
            region[start] = regions.count
            while let cell = pending.popLast() {
                cells.append(cell)
                let row = cell / side, column = cell % side
                for (r, c) in [(row - 1, column), (row + 1, column), (row, column - 1), (row, column + 1)]
                where r >= 0 && r < side && c >= 0 && c < side {
                    let next = r * side + c
                    if legal[next], region[next] < 0 {
                        region[next] = regions.count
                        pending.append(next)
                    }
                }
            }
            regions.append(cells.sorted())
        }
        func position(_ cell: Int) -> HorizontalPoint {
            HorizontalPoint(x: near.x + Double(cell % side - steps) * grid, y: near.y + Double(cell / side - steps) * grid)
        }

        let ranked = legal.indices.filter { legal[$0] }.map { cell -> (cell: Int, distance: Double) in
            let point = position(cell)
            return (cell, hypot(point.x - near.x, point.y - near.y))
        }.sorted { ($0.distance, $0.cell) < ($1.distance, $1.cell) }

        let sites = ranked.prefix(limit).map { entry -> JSONDictionary in
            let point = position(entry.cell)
            let candidate = HorizontalBoardProbe.via(at: point, diameter: shape.diameter, net: net)
            var tightest = [JSONDictionary]()
            var least: Double?
            for layer in shape.layers {
                guard let first = probe.measurements(candidate, layer: layer, reach: reportReach(probe)).first else { continue }
                tightest.append(json(first, probe: probe, board: board))
                least = min(least ?? first.slack, first.slack)
            }
            var site: JSONDictionary = ["x_mm": HorizontalDispatchJSON.mm(point.x), "y_mm": HorizontalDispatchJSON.mm(point.y),
                                        "distance_mm": HorizontalDispatchJSON.mm(entry.distance), "region": region[entry.cell],
                                        "tightest": tightest]
            if let least { site["slack_mm"] = HorizontalDispatchJSON.mm(least - probe.margin) }
            if let route = linked(point), !route.isEmpty { site["link_mm"] = route.map(Geometry.xy) }
            site.merge(padContact(at: point, diameter: shape.diameter, net: net, layers: shape.layers, probe: probe, board: board)) { current, _ in current }
            return site
        }

        var result: JSONDictionary = [
            "total": ranked.count, "truncated": ranked.count > limit, "sites": sites,
            "via": ["diameter_mm": HorizontalDispatchJSON.mm(shape.diameter), "hole_mm": HorizontalDispatchJSON.mm(shape.hole),
                    "layers": shape.layers, "source": shape.source, "definition": shape.definition as Any? as Any] as JSONDictionary,
            "grid_mm": HorizontalDispatchJSON.mm(grid), "margin_mm": HorizontalDispatchJSON.mm(probe.margin),
            "regions": regions.enumerated().map { index, cells -> JSONDictionary in
                let points = cells.map(position)
                // Each row of the area as [y, first x, last x]: its outline at the grid's pitch.
                var rows = [[Double]]()
                var run: (row: Int, first: Int, last: Int)?
                for cell in cells {
                    let row = cell / side, column = cell % side
                    if let current = run, current.row == row, current.last + 1 == column {
                        run?.last = column
                    } else {
                        if let current = run { rows.append(Self.row(current, near: near, steps: steps, grid: grid)) }
                        run = (row, column, column)
                    }
                }
                if let current = run { rows.append(Self.row(current, near: near, steps: steps, grid: grid)) }
                var json: JSONDictionary = ["region": index, "sites": cells.count,
                                            "area_mm2": (Double(cells.count) * grid * grid / (nm * nm) * 1e6).rounded() / 1e6,
                                            "box_mm": Geometry.box(HorizontalRect(points: points))]
                json["rows_mm"] = Array(rows.prefix(400))
                if rows.count > 400 { json["rows_truncated"] = true }
                return json
            },
        ]
        let existing = standing.map { via -> (distance: Double, json: JSONDictionary) in
            let distance = hypot(via.centre.x - near.x, via.centre.y - near.y)
            return (distance, ["id": via.id, "x_mm": HorizontalDispatchJSON.mm(via.centre.x), "y_mm": HorizontalDispatchJSON.mm(via.centre.y),
                               "diameter_mm": HorizontalDispatchJSON.mm(via.radius * 2), "distance_mm": HorizontalDispatchJSON.mm(distance)])
        }.filter { $0.distance <= radius + shape.diameter }.sorted { $0.distance < $1.distance }
        if !existing.isEmpty {
            result["existing_vias"] = existing.map(\.json)
            result["existing_vias_note"] = "Vias of this net already here. A position overlapping one is not a site: end the track on that via instead of placing another."
        }
        if inPad > 0 {
            result["in_pad_sites"] = inPad
            result["in_pad_note"] = "\(inPad) more positions are clear but stand in a pad of the net, where a via draws solder down its hole unless the board is made with filled vias: via_in_pad lists them too."
        }
        if ranked.isEmpty, let miss = blockedNearest {
            // Nothing is legal: what stops the nearest position, layer by layer.
            let candidate = HorizontalBoardProbe.via(at: miss.point, diameter: shape.diameter, net: net)
            var blocked = [JSONDictionary]()
            for layer in shape.layers {
                blocked += probe.measurements(candidate, layer: layer).filter(probe.violates).prefix(3).map { json($0, probe: probe, board: board) }
            }
            var nearest: JSONDictionary = ["x_mm": HorizontalDispatchJSON.mm(miss.point.x), "y_mm": HorizontalDispatchJSON.mm(miss.point.y),
                                           "blocked_by": blocked]
            if blocked.isEmpty, link != nil {
                nearest["note"] = "The via fits here; no link of that width and so few bends reaches the anchor."
            }
            result["nearest_miss"] = nearest
        }
        return result
    }

    private static func row(_ run: (row: Int, first: Int, last: Int), near: HorizontalPoint, steps: Int, grid: Double) -> [Double] {
        [HorizontalDispatchJSON.mm(near.y + Double(run.row - steps) * grid),
         HorizontalDispatchJSON.mm(near.x + Double(run.first - steps) * grid),
         HorizontalDispatchJSON.mm(near.x + Double(run.last - steps) * grid)]
    }
}
