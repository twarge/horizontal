import Foundation

/// Where a package, padstack or decal editor resolves the pool items it
/// refers to: the padstacks a package's pads use (package-local ones under
/// `<package>/padstacks/` first, then the pool's own, then whatever the
/// library index found across the base pools) and the names the inspector
/// shows for them.
struct HorizontalPoolEditorContext {
    var poolURL: URL
    /// `<pool>/packages/<name>/` for a package editor, nil otherwise.
    var packageDirectoryURL: URL?
    var libraryIndex: HorizontalPoolLibraryIndex

    init(poolURL: URL, packageDirectoryURL: URL? = nil, libraryIndex: HorizontalPoolLibraryIndex = .empty) {
        self.poolURL = poolURL
        self.packageDirectoryURL = packageDirectoryURL
        self.libraryIndex = libraryIndex
    }

    /// The padstack's JSON, in the same order the board loader looks:
    /// package-local, then the pool catalog (which also covers discovered
    /// base pools), then the library index.
    func padstackJSON(id: String) -> JSONDictionary? {
        if let local = packageLocalPadstacks().first(where: { $0.id == id.lowercased() }) {
            return try? JSONHelper.loadDictionary(from: local.url)
        }
        if let json = HorizontalPoolPadstacks.padstack(id: id, poolURL: poolURL) {
            return json
        }
        return libraryIndex.json(.padstack, uuid: id)
    }

    func padstackDisplayName(id: String) -> String? {
        if let local = packageLocalPadstacks().first(where: { $0.id == id.lowercased() }) {
            return local.name
        }
        return HorizontalPoolPadstacks.padstackName(id: id, poolURL: poolURL)
            ?? libraryIndex.name(.padstack, uuid: id)
    }

    /// What "Place Pad" and the pad inspector offer: the package's own
    /// padstacks first, then every pad-type padstack the pool provides.
    func padstackChoices() -> [HorizontalPoolPadstackInfo] {
        var choices = packageLocalPadstacks().map { local in
            HorizontalPoolPadstackInfo(id: local.id, name: local.name, type: local.type, isPackageLocal: true)
        }
        let seen = Set(choices.map(\.id))
        let poolChoices = HorizontalPoolPadstacks.padstacks(
            ofTypes: ["top", "bottom", "through", "mechanical"],
            poolURL: poolURL
        )
        choices.append(contentsOf: poolChoices.filter { !seen.contains($0.id) })
        return choices
    }

    private struct LocalPadstack {
        var id: String
        var name: String
        var type: String
        var url: URL
    }

    private func packageLocalPadstacks() -> [LocalPadstack] {
        guard let directory = packageDirectoryURL?.appendingPathComponent("padstacks", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return files.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let json = try? JSONHelper.loadDictionary(from: url),
                  json.string("type") == "padstack",
                  let uuid = json.string("uuid") else {
                return nil
            }
            return LocalPadstack(
                id: uuid.lowercased(),
                name: json.string("name") ?? url.deletingPathExtension().lastPathComponent,
                type: json.string("padstack_type") ?? "top",
                url: url
            )
        }
        .sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    }
}

// MARK: - Drawing ↔ board

extension HorizontalPoolDrawing {
    /// The junction-referenced lines and arcs resolved to positions, texts
    /// in the board's angle convention, polygons keeping their arc vertices.
    /// Nothing is dropped: an empty text or a two-vertex polygon stays so it
    /// comes back out on save.
    func boardLines() -> [HorizontalSegment] {
        lines.values.compactMap { line in
            guard let from = junctions[line.from], let to = junctions[line.to] else {
                return nil
            }
            return HorizontalSegment(id: line.id, from: from, to: to, width: line.width, layer: line.layer)
        }
    }

    func boardArcs() -> [HorizontalArc] {
        arcs.values.compactMap { arc in
            guard let from = junctions[arc.from], let to = junctions[arc.to], let center = junctions[arc.center] else {
                return nil
            }
            return HorizontalArc(id: arc.id, from: from, to: to, center: center, width: arc.width, layer: arc.layer)
        }
    }

    func boardPolygons() -> [HorizontalPolygon] {
        polygons.values.map { polygon in
            HorizontalPolygon(
                id: polygon.id,
                polygonVertices: polygon.vertices,
                layer: polygon.layer,
                parameterClass: polygon.parameterClass
            )
        }
    }

    func boardTexts() -> [HorizontalText] {
        texts.values.map { Self.boardText($0) }
    }

    /// The board loader stores a mirrored text's angle as `32768 − file
    /// angle` (`parseAbsoluteText` through `accumulatedText`); the same
    /// convention here so the canvas transforms behave identically.
    static func boardText(_ text: HorizontalPoolText) -> HorizontalText {
        let placement = HorizontalPlacementTransform.identity.accumulatedText(with: text.placement)
        return HorizontalText(
            id: text.id,
            text: text.text,
            position: placement.shift,
            size: text.size,
            layer: text.layer,
            angle: placement.angle,
            mirrored: placement.mirrored,
            width: text.width,
            origin: text.origin,
            font: text.font,
            allowUpsideDown: text.allowUpsideDown,
            fromSmash: text.fromSmash
        )
    }

    static func poolText(_ text: HorizontalText, original: HorizontalPoolText?) -> HorizontalPoolText {
        let fileAngle = text.mirrored ? 32_768 - text.angle : text.angle
        return HorizontalPoolText(
            id: text.id,
            text: text.text,
            placement: HorizontalPlacementTransform(shift: text.position, angle: fileAngle, mirrored: text.mirrored),
            size: text.size,
            width: text.width,
            layer: text.layer ?? original?.layer ?? 0,
            origin: text.origin,
            font: text.font,
            allowUpsideDown: text.allowUpsideDown,
            fromSmash: text.fromSmash
        )
    }

    /// Rebuilds the drawing from board geometry. Junctions are regenerated
    /// from line and arc endpoints by position, keeping an existing
    /// junction's id where one still sits there and minting ids for the rest
    /// — the pattern the sheet applicator uses.
    static func from(
        junctions existingJunctions: [String: HorizontalPoint],
        lines: [HorizontalSegment],
        arcs: [HorizontalArc],
        polygons: [HorizontalPolygon],
        texts: [HorizontalText],
        original: HorizontalPoolDrawing
    ) -> HorizontalPoolDrawing {
        var drawing = HorizontalPoolDrawing()
        var junctionIDsByKey = [String: String]()
        for (id, point) in existingJunctions {
            if junctionIDsByKey[Self.pointKey(point)] == nil {
                junctionIDsByKey[Self.pointKey(point)] = id
            }
        }
        func junctionID(at point: HorizontalPoint) -> String {
            let key = Self.pointKey(point)
            if let id = junctionIDsByKey[key] {
                drawing.junctions[id] = point
                return id
            }
            let id = UUID().uuidString.lowercased()
            junctionIDsByKey[key] = id
            drawing.junctions[id] = point
            return id
        }

        for line in lines {
            drawing.lines[line.id] = HorizontalPoolLine(
                id: line.id,
                from: junctionID(at: line.from),
                to: junctionID(at: line.to),
                width: line.width,
                layer: line.layer ?? 0
            )
        }
        for arc in arcs {
            // A reversed arc is the same file arc with its ends swapped.
            let (from, to) = arc.reverse ? (arc.to, arc.from) : (arc.from, arc.to)
            drawing.arcs[arc.id] = HorizontalPoolArc(
                id: arc.id,
                from: junctionID(at: from),
                to: junctionID(at: to),
                center: junctionID(at: arc.center),
                width: arc.width,
                layer: arc.layer ?? 0
            )
        }
        for polygon in polygons where !polygon.polygonVertices.isEmpty {
            drawing.polygons[polygon.id] = HorizontalPoolPolygon(
                id: polygon.id,
                layer: polygon.layer ?? 0,
                parameterClass: polygon.parameterClass,
                vertices: polygon.polygonVertices
            )
        }
        for text in texts {
            drawing.texts[text.id] = Self.poolText(text, original: original.texts[text.id])
        }
        // Junctions nothing references any more are dropped, as the canvas
        // vacuums them; ones still in use keep their ids.
        return drawing
    }

    static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
    }
}

// MARK: - Synthetic boards

extension HorizontalBoard {
    /// An empty board standing in for a pool item: a three-layer stackup so
    /// every layer the mode offers exists, no nets, no rules.
    static func poolEditorBoard(uuid: String, name: String, url: URL) -> HorizontalBoard {
        let stackup = [
            HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.topCopper, copperThickness: 35_000, substrateThickness: 800_000),
            HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.in1Copper, copperThickness: 35_000, substrateThickness: 800_000),
            HorizontalBoardStackupLayer(layer: HorizontalBoardLayers.bottomCopper, copperThickness: 35_000, substrateThickness: 0),
        ]
        return HorizontalBoard(
            url: url,
            uuid: uuid,
            name: name,
            grid: .boardDefault,
            colors: HorizontalBoardColors(),
            stackupLayers: stackup,
            userLayers: [],
            junctions: [:],
            junctionNetIDs: [:],
            netDetails: [:],
            tracks: [],
            netTies: [],
            lines: [],
            arcs: [],
            connectionLines: [],
            airwires: [],
            polygons: [],
            planes: [],
            keepouts: [],
            dimensions: [],
            decals: [],
            holes: [],
            vias: [],
            viaHoles: [],
            packages: [],
            packagePads: [],
            packageHoles: [],
            packagePolygons: [],
            packageLines: [],
            packageArcs: [],
            packageTexts: [],
            texts: [],
            boardPanels: [],
            physicalBounds: HorizontalRect.emptyContentCanvasRegion,
            bounds: HorizontalRect.emptyContentCanvasRegion,
            poolItemID: uuid
        )
    }

    /// Recomputes the canvas bounds from everything the synthetic board holds.
    mutating func recomputePoolEditorBounds() {
        var points = [HorizontalPoint]()
        points.append(contentsOf: lines.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: arcs.flatMap { $0.polyline(precision: 24) })
        points.append(contentsOf: polygons.flatMap { $0.renderVertices(arcPrecision: 16) })
        points.append(contentsOf: texts.flatMap(\.renderBoundsPoints))
        points.append(contentsOf: packagePads.flatMap(\.vertices))
        points.append(contentsOf: packageHoles.flatMap(\.boundsPoints))
        points.append(contentsOf: holes.flatMap(\.boundsPoints))
        points.append(contentsOf: keepouts.flatMap(\.points))
        points.append(contentsOf: dimensions.flatMap(\.points))
        let rect = HorizontalRect(points: points).padded().orEmptyContentCanvasRegion()
        bounds = rect
        physicalBounds = rect
    }

    /// The pad a baked pad-geometry id belongs to, as the `.pad` selectable
    /// ref id: `<package>/pad/<pad uuid>`.
    static func padRefID(forGeometryID id: String) -> String? {
        let normalized = HorizontalCanvasModeSupport.normalizedID(id)
        guard let marker = normalized.range(of: "/pad/") else {
            return nil
        }
        let padStart = marker.upperBound
        guard let nextSlash = normalized[padStart...].firstIndex(of: "/") else {
            return normalized
        }
        return String(normalized[..<nextSlash])
    }

    /// `<package>/pad/<pad uuid>` for one of this board's pads.
    func padRefID(for pad: HorizontalPad) -> String {
        "\(poolItemID ?? "package")/pad/\(pad.id)".lowercased()
    }

    /// Re-bakes one pad's copper, mask, paste and holes from its padstack —
    /// the same parse the board loader runs, on a one-pad package that
    /// carries this package's own parameter set.
    mutating func rebakePoolPad(id padID: String, context: HorizontalPoolEditorContext) {
        guard let packageID = poolItemID,
              let pad = pads.first(where: { $0.id.lowercased() == padID.lowercased() }) else {
            return
        }
        removeBakedPoolPad(id: padID)
        let packageJSON: JSONDictionary = [
            "uuid": packageID,
            "parameter_set": HorizontalPoolJSON.parameterSetJSON(poolParameterSet),
            "pads": [pad.id: pad.json(original: nil)] as JSONDictionary,
        ]
        let geometry = HorizontalBoard.packagePreviewGeometry(
            packageJSON: packageJSON,
            packageID: packageID,
            poolURL: context.poolURL,
            boardPackageID: packageID,
            nInnerLayers: 1,
            runsParameterProgram: false,
            padstack: context.padstackJSON(id:)
        )
        packagePads.append(contentsOf: geometry.pads)
        packageHoles.append(contentsOf: geometry.holes)
        packagePadPositions.merge(geometry.padPositions) { _, new in new }
    }

    mutating func removeBakedPoolPad(id padID: String) {
        guard let packageID = poolItemID else {
            return
        }
        let prefix = "\(packageID)/pad/\(padID)/".lowercased()
        let positionKey = "\(packageID)/\(padID)".lowercased()
        packagePads.removeAll { HorizontalCanvasModeSupport.normalizedID($0.id).hasPrefix(prefix) }
        packageHoles.removeAll { HorizontalCanvasModeSupport.normalizedID($0.id).hasPrefix(prefix) }
        packagePadPositions = packagePadPositions.filter { $0.key.lowercased() != positionKey }
    }

    /// The baked outline of one padstack shape, on its layer.
    static func bakedShapePolygon(_ shape: HorizontalPadstackShape, padstackID: String) -> HorizontalPolygon {
        let width = shape.params.first ?? 0
        let height = shape.params.count > 1 ? shape.params[1] : width
        let vertices: [HorizontalPoint]
        switch shape.form {
        case .circle:
            vertices = shape.placement.circle(diameter: width, segments: 32)
        case .rectangle:
            vertices = shape.placement.rectangle(width: width, height: height)
        case .obround:
            vertices = shape.placement.obround(width: width, height: height, segments: 12)
        }
        return HorizontalPolygon(
            id: "pad/\(padstackID)/shape/\(shape.id)/layer/\(shape.layer)".lowercased(),
            vertices: vertices,
            layer: shape.layer,
            metadata: ["Shape": shape.form.displayName]
        )
    }

    mutating func rebakePadstackShape(id shapeID: String) {
        guard let padstackID = poolItemID,
              let shape = padstackShapes.first(where: { $0.id.lowercased() == shapeID.lowercased() }) else {
            return
        }
        removeBakedPadstackShape(id: shapeID)
        packagePads.append(Self.bakedShapePolygon(shape, padstackID: padstackID))
    }

    mutating func removeBakedPadstackShape(id shapeID: String) {
        guard let padstackID = poolItemID else {
            return
        }
        let prefix = "pad/\(padstackID)/shape/\(shapeID)/".lowercased()
        packagePads.removeAll { HorizontalCanvasModeSupport.normalizedID($0.id).hasPrefix(prefix) }
    }

    static func shapeRefID(forGeometryID id: String) -> String? {
        let normalized = HorizontalCanvasModeSupport.normalizedID(id)
        guard let marker = normalized.range(of: "/shape/") else {
            return nil
        }
        let start = marker.upperBound
        guard let nextSlash = normalized[start...].firstIndex(of: "/") else {
            return String(normalized[start...])
        }
        return String(normalized[start..<nextSlash])
    }
}

// MARK: - Package

extension HorizontalPoolPackage {
    /// The package as a board the package editor can drive. Stored polygons
    /// are shown as stored — the parameter program runs only on an explicit
    /// Apply, as upstream does, so a save never bakes courtyard expansion
    /// into the file.
    func makeBoard(context: HorizontalPoolEditorContext) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(
            uuid: uuid,
            name: name,
            url: context.packageDirectoryURL ?? context.poolURL
        )
        board.poolParameterSet = parameterSet
        board.junctions = drawing.junctions
        board.lines = drawing.boardLines()
        board.arcs = drawing.boardArcs()
        board.texts = drawing.boardTexts()
        var polygons = drawing.boardPolygons()
        let polygonsByID = Dictionary(uniqueKeysWithValues: polygons.map { ($0.id.lowercased(), $0) })
        var keepoutPolygonIDs = Set<String>()
        board.keepouts = keepouts.values.compactMap { keepout in
            guard let polygon = polygonsByID[keepout.polygonID.lowercased()] else {
                return nil
            }
            keepoutPolygonIDs.insert(polygon.id.lowercased())
            return HorizontalKeepout(
                id: keepout.id,
                polygonID: keepout.polygonID,
                polygon: polygon,
                keepoutClass: keepout.keepoutClass,
                allCopperLayers: keepout.allCopperLayers,
                exposedCopperOnly: keepout.exposedCopperOnly,
                copperPatchTypes: keepout.copperPatchTypes
            )
        }
        polygons.removeAll { keepoutPolygonIDs.contains($0.id.lowercased()) }
        board.polygons = polygons
        board.dimensions = dimensions.values.map { dimension in
            HorizontalDimension(
                id: dimension.id,
                p0: dimension.p0,
                p1: dimension.p1,
                labelDistance: dimension.labelDistance,
                labelSize: dimension.labelSize,
                mode: dimension.mode
            )
        }
        board.pads = sortedPads
        for pad in board.pads {
            board.rebakePoolPad(id: pad.id, context: context)
        }
        board.recomputePoolEditorBounds()
        return board
    }

    /// The package with every editable collection taken back from the board.
    func applying(board: HorizontalBoard) -> HorizontalPoolPackage {
        var package = self
        let keepoutPolygons = board.keepouts.map { keepout -> HorizontalPolygon in
            var polygon = keepout.polygon
            polygon.id = keepout.polygonID
            return polygon
        }
        package.drawing = HorizontalPoolDrawing.from(
            junctions: board.junctions,
            lines: board.lines,
            arcs: board.arcs,
            polygons: board.polygons + keepoutPolygons,
            texts: board.texts,
            original: drawing
        )
        package.keepouts = Dictionary(uniqueKeysWithValues: board.keepouts.map { keepout in
            (keepout.id, HorizontalPoolKeepout(
                id: keepout.id,
                polygonID: keepout.polygonID,
                keepoutClass: keepout.keepoutClass,
                exposedCopperOnly: keepout.exposedCopperOnly,
                allCopperLayers: keepout.allCopperLayers,
                copperPatchTypes: keepout.copperPatchTypes
            ))
        })
        package.dimensions = Dictionary(uniqueKeysWithValues: board.dimensions.map { dimension in
            (dimension.id, HorizontalPoolDimension(
                id: dimension.id,
                p0: dimension.p0,
                p1: dimension.p1,
                labelDistance: dimension.labelDistance,
                labelSize: dimension.labelSize,
                mode: dimension.mode
            ))
        })
        package.pads = Dictionary(uniqueKeysWithValues: board.pads.map { ($0.id, $0) })
        return package
    }
}

extension HorizontalPoolPackage {
    /// Upstream's "Apply": run the parameter program (courtyard expansion and
    /// the like) over the stored polygons with the package's own parameter
    /// set, keeping the result as the new stored geometry.
    func applyingParameterProgram() -> HorizontalPoolPackage {
        guard !parameterProgram.isEmpty else {
            return self
        }
        var json = self.json()
        HorizontalParameterProgramEvaluator.apply(
            program: parameterProgram,
            parameters: HorizontalPoolJSON.parameterSetJSON(parameterSet),
            to: &json
        )
        return (try? HorizontalPoolPackage(json: json)) ?? self
    }
}

// MARK: - Padstack

extension HorizontalPoolPadstack {
    func makeBoard(context: HorizontalPoolEditorContext) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: uuid, name: name, url: context.poolURL)
        board.polygons = polygons.values.map { polygon in
            HorizontalPolygon(
                id: polygon.id,
                polygonVertices: polygon.vertices,
                layer: polygon.layer,
                parameterClass: polygon.parameterClass
            )
        }
        board.holes = holes.values.map { hole in
            HorizontalHole(
                id: hole.id,
                position: hole.placement.shift,
                diameter: hole.diameter,
                length: hole.length,
                shape: hole.shape,
                angle: hole.placement.angle,
                plated: hole.plated,
                parameterClass: hole.parameterClass
            )
        }
        board.padstackShapes = shapes.values.sorted { $0.id < $1.id }
        for shape in board.padstackShapes {
            board.rebakePadstackShape(id: shape.id)
        }
        board.recomputePoolEditorBounds()
        return board
    }

    func applying(board: HorizontalBoard) -> HorizontalPoolPadstack {
        var padstack = self
        padstack.polygons = Dictionary(uniqueKeysWithValues: board.polygons.compactMap { polygon in
            guard !polygon.polygonVertices.isEmpty else {
                return nil
            }
            return (polygon.id, HorizontalPoolPolygon(
                id: polygon.id,
                layer: polygon.layer ?? 0,
                parameterClass: polygon.parameterClass,
                vertices: polygon.polygonVertices
            ))
        })
        padstack.holes = Dictionary(uniqueKeysWithValues: board.holes.map { hole in
            var model = HorizontalPadstackHole(
                id: hole.id,
                placement: HorizontalPlacementTransform(shift: hole.position, angle: hole.angle, mirrored: false),
                diameter: hole.diameter,
                length: hole.effectiveLength,
                shape: hole.shape,
                plated: hole.plated,
                parameterClass: hole.parameterClass
            )
            model.span = holes[hole.id]?.span
            return (hole.id, model)
        })
        padstack.shapes = Dictionary(uniqueKeysWithValues: board.padstackShapes.map { ($0.id, $0) })
        return padstack
    }

    /// Upstream's "Apply": run the parameter program over the stored shapes,
    /// holes and polygons with the padstack's own parameter set, and keep the
    /// result as the new stored geometry.
    func applyingParameterProgram() -> HorizontalPoolPadstack {
        var json = self.json()
        HorizontalParameterProgramEvaluator.apply(
            program: parameterProgram,
            parameters: HorizontalPoolJSON.parameterSetJSON(parameterSet),
            to: &json
        )
        return (try? HorizontalPoolPadstack(json: json)) ?? self
    }
}

// MARK: - Decal

extension HorizontalPoolDecal {
    func makeBoard(context: HorizontalPoolEditorContext) -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(uuid: uuid, name: name, url: context.poolURL)
        board.junctions = drawing.junctions
        board.lines = drawing.boardLines()
        board.arcs = drawing.boardArcs()
        board.polygons = drawing.boardPolygons()
        board.texts = drawing.boardTexts()
        board.recomputePoolEditorBounds()
        return board
    }

    func applying(board: HorizontalBoard) -> HorizontalPoolDecal {
        var decal = self
        decal.drawing = HorizontalPoolDrawing.from(
            junctions: board.junctions,
            lines: board.lines,
            arcs: board.arcs,
            polygons: board.polygons,
            texts: board.texts,
            original: drawing
        )
        return decal
    }
}
