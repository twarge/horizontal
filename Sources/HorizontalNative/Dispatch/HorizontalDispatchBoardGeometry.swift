import Foundation

/// Reads of the board's geometry as the checks measure it: pads with their
/// shapes and mask openings, and whatever is near a point. Every number here
/// comes from the shapes `check` uses (`HorizontalBoardItems`), so a caller
/// has no reason to work them out again from the project files.
enum HorizontalDispatchBoardGeometry {
    // MARK: - Shared

    static func board(_ entry: HorizontalDispatchProjectEntry) throws -> HorizontalBoard {
        guard let board = entry.project.board else {
            throw HorizontalDispatchError.notFound("The project has no board.")
        }
        return board
    }

    /// `region` as {min_x_mm, min_y_mm, max_x_mm, max_y_mm}, in nanometres.
    static func region(_ params: JSONDictionary, key: String = "region") throws -> HorizontalRect? {
        guard let value = params[key] else { return nil }
        guard let region = value as? JSONDictionary,
              let minX = region.double("min_x_mm"), let minY = region.double("min_y_mm"),
              let maxX = region.double("max_x_mm"), let maxY = region.double("max_y_mm"), minX <= maxX, minY <= maxY else {
            throw HorizontalDispatchError.invalidParams("\(key) is {\"min_x_mm\", \"min_y_mm\", \"max_x_mm\", \"max_y_mm\"}, the least no more than the most.")
        }
        let scale: Double = 1_000_000
        return HorizontalRect(points: [HorizontalPoint(x: minX * scale, y: minY * scale), HorizontalPoint(x: maxX * scale, y: maxY * scale)])
    }

    /// {"x_mm", "y_mm"} under `key`, in nanometres.
    static func point(_ params: JSONDictionary, key: String) throws -> HorizontalPoint? {
        guard let value = params[key] else { return nil }
        guard let point = value as? JSONDictionary, let x = point.double("x_mm"), let y = point.double("y_mm") else {
            throw HorizontalDispatchError.invalidParams("\(key) is {\"x_mm\", \"y_mm\"}.")
        }
        let scale: Double = 1_000_000
        return HorizontalPoint(x: x * scale, y: y * scale)
    }

    /// `layers` as copper layer numbers; nil for every layer.
    static func layers(_ params: JSONDictionary, board: HorizontalBoard, key: String = "layers") throws -> [Int]? {
        guard let value = params[key] else { return nil }
        guard let list = value as? [Any] else {
            throw HorizontalDispatchError.invalidParams("\(key) is an array of layer numbers; board_info lists them.")
        }
        let known = Set(HorizontalBoardItems.copperLayers(of: board))
        return try list.map { item in
            guard let layer = (item as? NSNumber)?.intValue ?? (item as? Int) else {
                throw HorizontalDispatchError.invalidParams("\(key) is an array of layer numbers; board_info lists them.")
            }
            guard known.contains(layer) || HorizontalBoardLayers.isSilkscreen(layer) else {
                throw HorizontalDispatchError.invalidParams(
                    "Layer \(layer) is not a copper layer of this board (\(known.sorted(by: >).map(String.init).joined(separator: ", "))).")
            }
            return layer
        }
    }

    /// A net of the board by name or id: a block's, or one inside a block
    /// instance as the flattened block names it.
    static func netID(_ reference: String, entry: HorizontalDispatchProjectEntry) throws -> String {
        do {
            return try HorizontalDispatchValidation.net(reference, index: entry.index).id.lowercased()
        } catch let error as HorizontalDispatchError where error.code == .notFound {
            guard let flat = try entry.index.flattenedNetID(reference) else { throw error }
            return flat
        }
    }

    /// The board package a read names by its part: a refdes, the component's
    /// uuid (an instance's flat one included, which is what its package
    /// names), the package's own, or eight or more leading digits of either.
    static func package(_ reference: String, entry: HorizontalDispatchProjectEntry) throws -> HorizontalPlacement {
        let board = try board(entry)
        var matches = board.packages.filter {
            $0.label.caseInsensitiveCompare(reference) == .orderedSame || $0.id.caseInsensitiveCompare(reference) == .orderedSame
                || $0.componentID?.caseInsensitiveCompare(reference) == .orderedSame
        }
        if matches.isEmpty, let component = try? HorizontalDispatchValidation.component(reference, index: entry.index) {
            guard let placed = component.boardPlacement?.instanceID.lowercased(), !placed.isEmpty else {
                throw HorizontalDispatchError.notFound("\(component.refdes) is not placed on the board.")
            }
            matches = board.packages.filter { $0.id.lowercased() == placed }
        }
        if matches.isEmpty {
            let ids = board.packages.flatMap { [$0.id] + ($0.componentID.map { [$0] } ?? []) }
            if let id = try HorizontalDispatchValidation.id(matchingPrefix: reference, in: ids, kind: "component") {
                matches = board.packages.filter { $0.id == id || $0.componentID == id }
            }
        }
        guard let first = matches.first else { throw HorizontalDispatchError.notFound("No component \(reference) on the board.") }
        guard matches.count == 1 else {
            throw HorizontalDispatchError.ambiguous("More than one package is \(reference); use its uuid.", candidates: matches.map(\.id))
        }
        return first
    }

    static func xy(_ point: HorizontalPoint) -> [Double] {
        [HorizontalDispatchJSON.mm(point.x), HorizontalDispatchJSON.mm(point.y)]
    }

    static func box(_ rect: HorizontalRect) -> JSONDictionary {
        ["min_x_mm": HorizontalDispatchJSON.mm(rect.minX), "min_y_mm": HorizontalDispatchJSON.mm(rect.minY),
         "max_x_mm": HorizontalDispatchJSON.mm(rect.maxX), "max_y_mm": HorizontalDispatchJSON.mm(rect.maxY)]
    }

    static func meets(_ a: HorizontalRect, _ b: HorizontalRect) -> Bool {
        a.maxX >= b.minX && a.minX <= b.maxX && a.maxY >= b.minY && a.minY <= b.maxY
    }

    /// Whether a shape's copper reaches into `region`.
    static func reaches(_ shape: HorizontalBoardItem.Shape, into region: HorizontalRect) -> Bool {
        let corners = [HorizontalPoint(x: region.minX, y: region.minY), HorizontalPoint(x: region.maxX, y: region.minY),
                       HorizontalPoint(x: region.maxX, y: region.maxY), HorizontalPoint(x: region.minX, y: region.maxY)]
        return HorizontalShapeGap.between(.polygon(corners), shape, limit: 0) != nil
    }

    /// The board's items, built once for a revision of it.
    static func items(_ entry: HorizontalDispatchProjectEntry, silkscreen: Bool = false) throws -> HorizontalBoardItems {
        let key = "\(entry.revision)|\(entry.livePlaneFillRevision)|\(silkscreen)"
        if let cached = entry.cachedBoardItems, cached.key == key { return cached.items }
        let items = HorizontalBoardItems(board: try board(entry), silkscreen: silkscreen)
        entry.cachedBoardItems = (key, items)
        return items
    }

    /// An item as a reply names it: kind, id, label, net, layers, and for a
    /// pad its part.
    static func json(_ item: HorizontalBoardItem, board: HorizontalBoard, copperLayers: [Int]) -> JSONDictionary {
        var json: JSONDictionary = ["kind": item.kind.name, "id": item.id, "label": item.label]
        json["net"] = item.netID as Any? as Any
        json["net_name"] = item.netID.flatMap { board.netDetails[$0]?.name }.flatMap { $0.isEmpty ? nil : $0 } as Any? as Any
        json["layers"] = item.kind == .silkscreen ? [item.layerMin] : copperLayers.filter(item.isOn)
        if case .keepout(let name) = item.kind, !name.isEmpty { json["keepout_class"] = name }
        if let package = item.packageID { json["package"] = package }
        switch item.shape {
        case .path(_, let halfWidth) where item.kind != .boardEdge: json["width_mm"] = HorizontalDispatchJSON.mm(halfWidth * 2)
        case .disc(_, let radius): json["diameter_mm"] = HorizontalDispatchJSON.mm(radius * 2)
        default: break
        }
        return json
    }

    // MARK: - items_near

    static func itemsNear(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try board(entry)
        let at = try point(params, key: "at")
        let region = try region(params)
        guard (at == nil) != (region == nil) else {
            throw HorizontalDispatchError.invalidParams("items_near takes \"at\" with \"radius_mm\", or \"region\": one of them.")
        }
        let radius = (params.double("radius_mm") ?? 1) * 1_000_000
        guard radius >= 0 else { throw HorizontalDispatchError.invalidParams("radius_mm cannot be negative.") }
        let wantedLayers = try layers(params, board: board)
        let silkscreen = params.bool("silkscreen") ?? false
        let catalog = try items(entry, silkscreen: silkscreen)
        let query: HorizontalBoardItem.Shape
        let queryBox: HorizontalRect
        if let at {
            query = .disc(at, radius: 0)
            queryBox = HorizontalRouteClearanceProbe.bounds([at], growth: radius)
        } else if let region {
            query = .polygon([HorizontalPoint(x: region.minX, y: region.minY), HorizontalPoint(x: region.maxX, y: region.minY),
                              HorizontalPoint(x: region.maxX, y: region.maxY), HorizontalPoint(x: region.minX, y: region.maxY)])
            queryBox = region
        } else {
            return [String: Any]()
        }
        // A pad is several polygons and a plane several fragments; each is
        // listed once, at its nearest.
        var found = [String: (json: JSONDictionary, distance: Double)]()
        for index in catalog.indices(overlapping: queryBox) {
            let item = catalog.items[index]
            if item.kind == .silkscreen {
                guard wantedLayers?.contains(item.layerMin) ?? true else { continue }
            } else if let wantedLayers {
                guard wantedLayers.contains(where: item.isOn) else { continue }
            }
            guard let gap = HorizontalShapeGap.between(query, item.shape, limit: at == nil ? 0 : radius) else { continue }
            let key = "\(item.kind.name)|\(item.id)|\(item.layerMin)|\(item.layerMax)"
            if let current = found[key], current.distance <= gap.distance { continue }
            var row = json(item, board: board, copperLayers: catalog.copperLayers)
            if at != nil {
                row["distance_mm"] = HorizontalDispatchJSON.mm(gap.distance)
                row["x_mm"] = HorizontalDispatchJSON.mm(gap.second.x)
                row["y_mm"] = HorizontalDispatchJSON.mm(gap.second.y)
            }
            found[key] = (row, gap.distance)
        }
        let sorted = found.sorted { ($0.value.distance, $0.key) < ($1.value.distance, $1.key) }.map(\.value.json)
        let limit = min(max(params.int("limit") ?? 200, 1), 5000)
        return ["total": sorted.count, "truncated": sorted.count > limit, "items": Array(sorted.prefix(limit)),
                "planes": board.planes.isEmpty ? "none" : "as last poured"] as JSONDictionary
    }

    // MARK: - Pads

    /// One pad of a placed package, from every polygon and hole the board
    /// drew for it.
    struct Pad {
        var package: HorizontalPlacement
        /// "package/pad/pad-id", lowercased.
        var prefix: String
        var padID: String
        var name: String
        var netID: String?
        var copper: [HorizontalPolygon] = []
        var mask: [HorizontalPolygon] = []
        var paste: [HorizontalPolygon] = []
        var holes: [HorizontalHole] = []

        var box: HorizontalRect {
            HorizontalRect(points: copper.flatMap { $0.renderVertices(arcPrecision: 48) })
        }
    }

    /// The pads of the board's packages, in package then pad-name order.
    static func pads(of board: HorizontalBoard) -> [Pad] {
        let packages = HorizontalBoardRulesCheck.packagesByID(board)
        var pads = [String: Pad]()
        var order = [String]()
        for polygon in board.packagePads {
            guard let prefix = HorizontalBoardItems.padPrefix(polygon.id) else { continue }
            let parts = prefix.split(separator: "/").map(String.init)
            guard let package = packages[parts[0]] else { continue }
            if pads[prefix] == nil {
                pads[prefix] = Pad(package: package, prefix: prefix, padID: parts[2],
                                   name: polygon.metadata["Pad"] ?? String(parts[2].prefix(8)))
                order.append(prefix)
            }
            if let net = polygon.netID?.lowercased() { pads[prefix]?.netID = net }
            switch polygon.layer {
            case nil: pads[prefix]?.copper.append(polygon)
            case let layer? where HorizontalBoardLayers.isCopper(layer): pads[prefix]?.copper.append(polygon)
            case HorizontalBoardLayers.topMask?, HorizontalBoardLayers.bottomMask?: pads[prefix]?.mask.append(polygon)
            case HorizontalBoardLayers.topPaste?, HorizontalBoardLayers.bottomPaste?: pads[prefix]?.paste.append(polygon)
            default: break
            }
        }
        for hole in board.packageHoles {
            guard let prefix = HorizontalBoardItems.padPrefix(hole.id) else { continue }
            pads[prefix]?.holes.append(hole)
        }
        return order.compactMap { pads[$0] }.sorted {
            let left = $0.package.label.localizedStandardCompare($1.package.label)
            if left != .orderedSame { return left == .orderedAscending }
            if $0.package.id != $1.package.id { return $0.package.id < $1.package.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func json(_ pad: Pad, board: HorizontalBoard, outline: Bool) -> JSONDictionary {
        let copperLayers = HorizontalBoardItems.copperLayers(of: board)
        var layers = Set<Int>()
        for polygon in pad.copper {
            if let layer = polygon.layer { layers.insert(layer) } else { layers.formUnion(copperLayers) }
        }
        let rendered = pad.copper.map { $0.renderVertices(arcPrecision: 48) }.filter { $0.count >= 3 }
        var json: JSONDictionary = [
            "refdes": pad.package.label, "pad": pad.name, "pad_id": pad.padID, "package": pad.package.id,
            "id": pad.prefix,
            "net": pad.netID as Any? as Any,
            "net_name": pad.netID.flatMap { board.netDetails[$0]?.name }.flatMap { $0.isEmpty ? nil : $0 } as Any? as Any,
            "side": pad.package.mirrored ? "bottom" : "top",
            "layers": copperLayers.filter(layers.contains),
            "through_hole": pad.holes.contains(where: \.plated) || pad.copper.contains { $0.layer == nil },
        ]
        if let at = board.packagePadPositions["\(pad.package.id.lowercased())/\(pad.padID)"] {
            json["at_mm"] = HorizontalDispatchJSON.point(at)
        }
        if !rendered.isEmpty {
            json["box_mm"] = box(HorizontalRect(points: rendered.flatMap { $0 }))
        }
        // The padstack's own box, turned as the pad is: what "0.75 × 0.8" means.
        if let frame = pad.copper.compactMap(\.padLabelFrame).max(by: { $0.area < $1.area }) {
            json["shape"] = [
                "width_mm": HorizontalDispatchJSON.mm(frame.halfWidth * 2), "height_mm": HorizontalDispatchJSON.mm(frame.halfHeight * 2),
                "angle_deg": HorizontalDispatchJSON.degrees(frame.angle),
                "rounded": pad.copper.contains { $0.polygonVertices.contains { $0.type == .arc } },
            ] as JSONDictionary
        }
        func outlines(_ polygons: [HorizontalPolygon]) -> [JSONDictionary] {
            polygons.compactMap { polygon -> JSONDictionary? in
                let points = polygon.renderVertices(arcPrecision: 48)
                guard points.count >= 3 else { return nil }
                var row: JSONDictionary = ["box_mm": box(HorizontalRect(points: points))]
                row["layer"] = polygon.layer as Any? as Any
                if outline { row["outline_mm"] = points.map(xy) }
                return row
            }
        }
        if outline { json["copper"] = outlines(pad.copper) }
        // What the silkscreen rule measures to: copper inside this is bare.
        json["mask_opening"] = outlines(pad.mask)
        if let opening = pad.mask.first.map({ HorizontalRect(points: $0.renderVertices(arcPrecision: 48)) }),
           let copper = rendered.first.map({ HorizontalRect(points: $0) }) {
            json["mask_expansion_mm"] = HorizontalDispatchJSON.mm(max(copper.minX - opening.minX, opening.maxX - copper.maxX,
                                                                      copper.minY - opening.minY, opening.maxY - copper.maxY))
        }
        json["holes"] = pad.holes.map { hole -> JSONDictionary in
            var row: JSONDictionary = ["x_mm": HorizontalDispatchJSON.mm(hole.position.x), "y_mm": HorizontalDispatchJSON.mm(hole.position.y),
                                       "diameter_mm": HorizontalDispatchJSON.mm(hole.diameter), "plated": hole.plated]
            if hole.shape == .slot, hole.effectiveLength > hole.diameter {
                row["length_mm"] = HorizontalDispatchJSON.mm(hole.effectiveLength)
                row["angle_deg"] = HorizontalDispatchJSON.degrees(hole.angle)
            }
            return row
        }
        // A via standing in the pad: on its centre it is joined to it, and
        // anywhere else in it only a track joins the two.
        let centre = board.packagePadPositions["\(pad.package.id.lowercased())/\(pad.padID)"]
        json["vias_in_pad"] = board.vias.compactMap { via -> JSONDictionary? in
            guard !Set(via.copperLayers).isDisjoint(with: layers),
                  rendered.contains(where: { HorizontalBoardOutlines.contains(via.position, in: $0) }) else { return nil }
            return ["id": via.id, "net": via.netID?.lowercased() as Any? as Any,
                    "on_center": centre.map { hypot($0.x - via.position.x, $0.y - via.position.y) < 1 } ?? false]
        }
        return json
    }

    static func listPads(_ session: HorizontalDispatchSession, _ params: JSONDictionary) throws -> Any {
        let entry = try session.entry(for: params)
        let board = try board(entry)
        var package: String?
        if let reference = params.string("component"), !reference.isEmpty {
            package = try self.package(reference, entry: entry).id.lowercased()
        }
        let net = try params.string("net").flatMap { $0.isEmpty ? nil : $0 }.map { try netID($0, entry: entry) }
        let layer = params.int("layer")
        let region = try region(params)
        let names = (params["pads"] as? [String]).map { Set($0.map { $0.lowercased() }) }
        let copperLayers = HorizontalBoardItems.copperLayers(of: board)
        let matched = pads(of: board).filter { pad in
            if let package, pad.package.id.lowercased() != package { return false }
            if let net, pad.netID != net { return false }
            if let names, !names.contains(pad.name.lowercased()), !names.contains(pad.padID) { return false }
            if let layer, !pad.copper.contains(where: { $0.layer == nil ? copperLayers.contains(layer) : $0.layer == layer }) { return false }
            if let region, !meets(pad.box, region) { return false }
            return true
        }
        let limit = min(max(params.int("limit") ?? 200, 1), 5000)
        let outline = params.bool("outline") ?? false
        return ["total": matched.count, "truncated": matched.count > limit,
                "pads": matched.prefix(limit).map { json($0, board: board, outline: outline) }] as JSONDictionary
    }

    /// A component's pads, for get_component.
    static func padsJSON(package: String, board: HorizontalBoard, outline: Bool = false) -> [JSONDictionary] {
        pads(of: board).filter { $0.package.id.lowercased() == package.lowercased() }.map { json($0, board: board, outline: outline) }
    }

    // MARK: - Texts

    /// Where each of the board's texts draws, by the id the file gives it;
    /// a package's own text by "package/text/id".
    static func textExtents(_ board: HorizontalBoard) -> [String: HorizontalBoardTextExtents.Extent] {
        var extents = [String: HorizontalBoardTextExtents.Extent]()
        for drawn in HorizontalBoardTextExtents.drawnTexts(of: board) {
            let key = drawn.text.fromSmash || drawn.packageID == nil ? drawn.textID.lowercased() : drawn.text.id.lowercased()
            extents[key] = HorizontalBoardTextExtents.extent(of: drawn.text)
        }
        return extents
    }

    static func json(_ extent: HorizontalBoardTextExtents.Extent) -> JSONDictionary {
        ["box_mm": box(extent.box), "runs": extent.runs]
    }
}
