import Foundation
import HorizontalPlaneClipper

private struct HorizontalBoardPanelLoadResult {
    var panels: [HorizontalBoardPanel]
    var geometry: HorizontalBoardPanelGeometry

    static let empty = HorizontalBoardPanelLoadResult(panels: [], geometry: .empty)
}

private struct HorizontalBoardPanelGeometry {
    var tracks: [HorizontalSegment] = []
    var netTies: [HorizontalSegment] = []
    var lines: [HorizontalSegment] = []
    var arcs: [HorizontalArc] = []
    var connectionLines: [HorizontalSegment] = []
    var airwires: [HorizontalSegment] = []
    var polygons: [HorizontalPolygon] = []
    var planes: [HorizontalPlane] = []
    var keepouts: [HorizontalKeepout] = []
    var dimensions: [HorizontalDimension] = []
    var decals: [HorizontalBoardDecal] = []
    var holes: [HorizontalHole] = []
    var vias: [HorizontalMarker] = []
    var viaHoles: [HorizontalHole] = []
    var packages: [HorizontalPlacement] = []
    var packagePads: [HorizontalPolygon] = []
    var packageHoles: [HorizontalHole] = []
    var packagePolygons: [HorizontalPolygon] = []
    var packageLines: [HorizontalSegment] = []
    var packageArcs: [HorizontalArc] = []
    var packageTexts: [HorizontalText] = []
    var texts: [HorizontalText] = []

    static let empty = HorizontalBoardPanelGeometry()

    mutating func append(_ other: HorizontalBoardPanelGeometry) {
        tracks.append(contentsOf: other.tracks)
        netTies.append(contentsOf: other.netTies)
        lines.append(contentsOf: other.lines)
        arcs.append(contentsOf: other.arcs)
        connectionLines.append(contentsOf: other.connectionLines)
        airwires.append(contentsOf: other.airwires)
        polygons.append(contentsOf: other.polygons)
        planes.append(contentsOf: other.planes)
        keepouts.append(contentsOf: other.keepouts)
        dimensions.append(contentsOf: other.dimensions)
        decals.append(contentsOf: other.decals)
        holes.append(contentsOf: other.holes)
        vias.append(contentsOf: other.vias)
        viaHoles.append(contentsOf: other.viaHoles)
        packages.append(contentsOf: other.packages)
        packagePads.append(contentsOf: other.packagePads)
        packageHoles.append(contentsOf: other.packageHoles)
        packagePolygons.append(contentsOf: other.packagePolygons)
        packageLines.append(contentsOf: other.packageLines)
        packageArcs.append(contentsOf: other.packageArcs)
        packageTexts.append(contentsOf: other.packageTexts)
        texts.append(contentsOf: other.texts)
    }
}

private struct HorizontalExpandedPadstack {
    var json: JSONDictionary
    var parameterSet: JSONDictionary
}

private struct HorizontalParameterProgramEvaluator {
    private static let compileCacheLock = NSLock()
    nonisolated(unsafe) private static var compiledProgramCache = [String: [Token]]()
    nonisolated(unsafe) private static var failedProgramCache = Set<String>()

    private enum Argument {
        case int(Int)
        case string(String)
    }

    private struct Command {
        var name: String
        var arguments: [Argument] = []
    }

    private enum Token {
        case int(Int)
        case command(Command)
    }

    static func apply(program: String?, parameters: JSONDictionary, to json: inout JSONDictionary) {
        guard let program, !program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard let tokens = compiledTokens(for: program) else {
            return
        }

        var stack = [Int]()
        func pop() -> Int? {
            guard let value = stack.popLast() else {
                return nil
            }
            return value
        }

        for token in tokens {
            switch token {
            case .int(let value):
                stack.append(value)
            case .command(let command):
                switch command.name {
                case "dump":
                    continue
                case "get-parameter":
                    guard case .string(let key)? = command.arguments.first,
                          let value = intParameter(key, in: parameters) else {
                        return
                    }
                    stack.append(value)
                case "dup":
                    guard let value = pop() else { return }
                    stack.append(value)
                    stack.append(value)
                case "dupc":
                    guard let b = pop(), let a = pop() else { return }
                    stack.append(a)
                    stack.append(b)
                    stack.append(a)
                    stack.append(b)
                case "swap":
                    guard let b = pop(), let a = pop() else { return }
                    stack.append(b)
                    stack.append(a)
                case "chs":
                    guard let value = pop() else { return }
                    stack.append(-value)
                case "+":
                    guard let b = pop(), let a = pop() else { return }
                    stack.append(a + b)
                case "-":
                    guard let b = pop(), let a = pop() else { return }
                    stack.append(a - b)
                case "*":
                    guard let b = pop(), let a = pop() else { return }
                    stack.append(a * b)
                case "/":
                    guard let b = pop(), let a = pop(), b != 0 else { return }
                    stack.append(a / b)
                case "+xy":
                    guard let c = pop(), let b = pop(), let a = pop() else { return }
                    stack.append(a + c)
                    stack.append(b + c)
                case "-xy":
                    guard let c = pop(), let b = pop(), let a = pop() else { return }
                    stack.append(a - c)
                    stack.append(b - c)
                case "set-shape":
                    guard let pclass = stringArgument(command, at: 0),
                          let form = stringArgument(command, at: 1) else { return }
                    switch form {
                    case "rectangle", "obround":
                        guard let height = pop(), let width = pop() else { return }
                        setShapes(parameterClass: pclass, form: form, params: [width, height], in: &json)
                    case "circle":
                        guard let diameter = pop() else { return }
                        setShapes(parameterClass: pclass, form: form, params: [diameter], in: &json)
                    case "position":
                        guard let y = pop(), let x = pop() else { return }
                        setShapePositions(parameterClass: pclass, x: x, y: y, in: &json)
                    default:
                        return
                    }
                case "set-hole":
                    guard let pclass = stringArgument(command, at: 0),
                          let shape = stringArgument(command, at: 1) else { return }
                    switch shape {
                    case "round":
                        guard let diameter = pop() else { return }
                        setHoles(parameterClass: pclass, shape: shape, diameter: diameter, length: nil, in: &json)
                    case "slot":
                        guard let length = pop(), let diameter = pop() else { return }
                        setHoles(parameterClass: pclass, shape: shape, diameter: diameter, length: length, in: &json)
                    case "position":
                        guard let y = pop(), let x = pop() else { return }
                        setHolePositions(parameterClass: pclass, x: x, y: y, in: &json)
                    default:
                        return
                    }
                case "set-polygon":
                    guard let pclass = stringArgument(command, at: 0),
                          let shape = stringArgument(command, at: 1),
                          let x0 = intArgument(command, at: 2),
                          let y0 = intArgument(command, at: 3) else { return }
                    switch shape {
                    case "rectangle":
                        guard let height = pop(), let width = pop() else { return }
                        setPolygons(parameterClass: pclass, vertices: rectangleVertices(width: width, height: height, x0: x0, y0: y0), in: &json)
                    case "circle":
                        guard let diameter = pop() else { return }
                        setPolygons(parameterClass: pclass, vertices: circleVertices(diameter: diameter, x0: x0, y0: y0), in: &json)
                    default:
                        return
                    }
                case "set-polygon-vertices":
                    guard let pclass = stringArgument(command, at: 0),
                          let count = intArgument(command, at: 1),
                          count > 0,
                          stack.count >= count * 2 else { return }
                    var vertices = [(Int, Int)]()
                    vertices.reserveCapacity(count)
                    for _ in 0..<count {
                        guard let y = pop(), let x = pop() else { return }
                        vertices.append((x, y))
                    }
                    setPolygons(parameterClass: pclass, vertices: vertices, in: &json)
                case "expand-polygon":
                    // <expand> on the stack; <pclass> then coordinate pairs as
                    // command args. Build the polygon, miter-offset it by
                    // `expand`, and replace the matching class's vertices.
                    // Reference: parameter/program_polygon.cpp:98.
                    guard let pclass = stringArgument(command, at: 0),
                          let expand = pop() else { return }
                    var pathPoints = [(Int, Int)]()
                    var argIndex = 1
                    while let x = intArgument(command, at: argIndex),
                          let y = intArgument(command, at: argIndex + 1) {
                        pathPoints.append((x, y))
                        argIndex += 2
                    }
                    guard pathPoints.count >= 3,
                          let expanded = expandPolygon(pathPoints, by: expand) else { return }
                    setPolygons(parameterClass: pclass, vertices: expanded, in: &json)
                default:
                    return
                }
            }
        }
    }

    private static func compiledTokens(for program: String) -> [Token]? {
        compileCacheLock.lock()
        if let cached = compiledProgramCache[program] {
            compileCacheLock.unlock()
            return cached
        }
        if failedProgramCache.contains(program) {
            compileCacheLock.unlock()
            return nil
        }
        compileCacheLock.unlock()

        guard let compiled = compile(program) else {
            compileCacheLock.lock()
            failedProgramCache.insert(program)
            compileCacheLock.unlock()
            return nil
        }

        compileCacheLock.lock()
        compiledProgramCache[program] = compiled
        compileCacheLock.unlock()
        return compiled
    }

    private static func compile(_ program: String) -> [Token]? {
        let rawTokens = program.split { $0.isWhitespace }.map(String.init)
        var tokens = [Token]()
        var argumentMode = false

        for rawToken in rawTokens {
            if rawToken == "[" {
                guard !argumentMode, !tokens.isEmpty else {
                    return nil
                }
                argumentMode = true
                continue
            }
            if rawToken == "]" {
                guard argumentMode else {
                    return nil
                }
                argumentMode = false
                continue
            }

            if argumentMode {
                guard !tokens.isEmpty else {
                    return nil
                }
                let argument: Argument
                if let value = integerToken(rawToken) ?? dimensionToken(rawToken) {
                    argument = .int(value)
                } else if isStringToken(rawToken) || isUUIDToken(rawToken) {
                    argument = .string(rawToken)
                } else {
                    return nil
                }
                guard case .command(var command) = tokens[tokens.count - 1] else {
                    return nil
                }
                command.arguments.append(argument)
                tokens[tokens.count - 1] = .command(command)
            } else if let value = dimensionToken(rawToken) ?? integerToken(rawToken) {
                tokens.append(.int(value))
            } else if isCommandToken(rawToken) {
                tokens.append(.command(Command(name: rawToken)))
            } else {
                return nil
            }
        }

        return argumentMode ? nil : tokens
    }

    private static func integerToken(_ token: String) -> Int? {
        guard wholeMatch(token, #"^[+-]?\d+$"#) else {
            return nil
        }
        return Int(token)
    }

    private static func dimensionToken(_ token: String) -> Int? {
        guard wholeMatch(token, #"^[+-]?(?:\d*\.)?\d+mm$"#) else {
            return nil
        }
        return Double(token.dropLast(2)).map { Int(($0 * 1_000_000.0).rounded()) }
    }

    private static func isStringToken(_ token: String) -> Bool {
        wholeMatch(token, #"^[a-z][a-z-_0-9]*$"#)
    }

    private static func isCommandToken(_ token: String) -> Bool {
        isStringToken(token) || wholeMatch(token, #"^[+\-/*][a-z]*$"#)
    }

    private static func isUUIDToken(_ token: String) -> Bool {
        wholeMatch(token, #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#)
    }

    private static func wholeMatch(_ token: String, _ pattern: String) -> Bool {
        token.range(of: pattern, options: .regularExpression) == token.startIndex..<token.endIndex
    }

    private static func intParameter(_ key: String, in parameters: JSONDictionary) -> Int? {
        parameters.int(key) ?? parameters.double(key).map { Int($0.rounded()) }
    }

    private static func stringArgument(_ command: Command, at index: Int) -> String? {
        guard command.arguments.indices.contains(index),
              case .string(let value) = command.arguments[index] else {
            return nil
        }
        return value
    }

    private static func intArgument(_ command: Command, at index: Int) -> Int? {
        guard command.arguments.indices.contains(index),
              case .int(let value) = command.arguments[index] else {
            return nil
        }
        return value
    }

    private static func setShapes(parameterClass: String, form: String, params: [Int], in json: inout JSONDictionary) {
        mutateMap("shapes", parameterClass: parameterClass, in: &json) { shape in
            shape["form"] = form
            shape["params"] = params
        }
    }

    private static func setShapePositions(parameterClass: String, x: Int, y: Int, in json: inout JSONDictionary) {
        mutateMap("shapes", parameterClass: parameterClass, in: &json) { shape in
            var placement = shape["placement"] as? JSONDictionary ?? [:]
            placement["shift"] = [x, y]
            shape["placement"] = placement
        }
    }

    private static func setHoles(parameterClass: String, shape: String, diameter: Int, length: Int?, in json: inout JSONDictionary) {
        mutateMap("holes", parameterClass: parameterClass, in: &json) { hole in
            hole["shape"] = shape
            hole["diameter"] = diameter
            if let length {
                hole["length"] = length
            }
        }
    }

    private static func setHolePositions(parameterClass: String, x: Int, y: Int, in json: inout JSONDictionary) {
        mutateMap("holes", parameterClass: parameterClass, in: &json) { hole in
            var placement = hole["placement"] as? JSONDictionary ?? [:]
            placement["shift"] = [x, y]
            hole["placement"] = placement
        }
    }

    /// Miter-offsets a closed polygon by `delta` nanometers via Clipper,
    /// returning the single resulting contour, or nil if the offset collapses or
    /// splits the polygon (mirroring the expand-polygon "expand error").
    private static func expandPolygon(_ points: [(Int, Int)], by delta: Int) -> [(Int, Int)]? {
        let input = points.map { HorizontalClipperPoint(x: Double($0.0), y: Double($0.1)) }
        let result = input.withUnsafeBufferPointer { buffer in
            HorizontalClipperOffsetPolygon(buffer.baseAddress, Int32(buffer.count), Double(delta), 2 /* jtMiter */)
        }
        defer { HorizontalClipperFreePath(result) }
        guard let pts = result.points, result.count >= 3 else { return nil }
        return (0..<Int(result.count)).map { index in
            (Int(pts[index].x.rounded()), Int(pts[index].y.rounded()))
        }
    }

    private static func setPolygons(parameterClass: String, vertices: [(Int, Int)], in json: inout JSONDictionary) {
        mutateMap("polygons", parameterClass: parameterClass, in: &json) { polygon in
            polygon["vertices"] = vertices.map { x, y in
                [
                    "position": [x, y],
                    "type": "line",
                    "arc_center": [0, 0],
                    "arc_reverse": false
                ] as JSONDictionary
            }
        }
    }

    private static func mutateMap(
        _ key: String,
        parameterClass: String,
        in json: inout JSONDictionary,
        _ mutate: (inout JSONDictionary) -> Void
    ) {
        var map = json[key] as? [String: Any] ?? [:]
        for itemKey in map.keys {
            guard var item = map[itemKey] as? JSONDictionary,
                  item.string("parameter_class") == parameterClass else {
                continue
            }
            mutate(&item)
            map[itemKey] = item
        }
        json[key] = map
    }

    private static func rectangleVertices(width: Int, height: Int, x0: Int, y0: Int) -> [(Int, Int)] {
        [
            (x0 - width / 2, y0 - height / 2),
            (x0 - width / 2, y0 + height / 2),
            (x0 + width / 2, y0 + height / 2),
            (x0 + width / 2, y0 - height / 2)
        ]
    }

    private static func circleVertices(diameter: Int, x0: Int, y0: Int, precision: Int = 48) -> [(Int, Int)] {
        let radius = Double(diameter) / 2
        return (0..<precision).map { index in
            let angle = Double(index) / Double(precision) * Double.pi * 2
            return (
                x0 + Int((cos(angle) * radius).rounded()),
                y0 + Int((sin(angle) * radius).rounded())
            )
        }
    }
}

struct HorizontalBoard {
    var url: URL
    var uuid: String
    var name: String
    var grid: HorizontalGridSettings
    var colors: HorizontalBoardColors
    var stackupLayers: [HorizontalBoardStackupLayer]
    var userLayers: [HorizontalBoardUserLayer]
    var junctions: [String: HorizontalPoint]
    var junctionNetIDs: [String: String]
    var netDetails: [String: HorizontalNetDetails]
    var rules: HorizontalBoardRules = .empty
    var tracks: [HorizontalSegment]
    var netTies: [HorizontalSegment]
    var lines: [HorizontalSegment]
    var arcs: [HorizontalArc]
    var connectionLines: [HorizontalSegment]
    var airwires: [HorizontalSegment]
    var polygons: [HorizontalPolygon]
    /// Polygon ids the editor has explicitly removed (e.g. converted to a line
    /// loop). `patchPolygons` preserves unknown source entries, so it can't infer
    /// deletion from absence; this set tells it which keys to drop. Transient edit
    /// state — empty after a save+reload (the entry is gone from disk).
    var removedPolygonIDs: Set<String> = []
    var planes: [HorizontalPlane]
    var keepouts: [HorizontalKeepout]
    var dimensions: [HorizontalDimension]
    var decals: [HorizontalBoardDecal]
    var holes: [HorizontalHole]
    var vias: [HorizontalMarker]
    var viaHoles: [HorizontalHole]
    /// Padstack + default geometry for vias the track tool creates. Nil when
    /// the board has no via definition and no existing via to source one from.
    var viaTemplate: HorizontalBoardViaTemplate? = nil
    var packages: [HorizontalPlacement]
    var packagePads: [HorizontalPolygon]
    /// Pad path ("package_uuid/pad_uuid", normalized) → pad center, retained
    /// from parse so interactively drawn tracks can end in a direct pad
    /// connection and the applicator can reverse-map that endpoint to the
    /// `{"pad": path}` reference Track::Connection::serialize emits.
    /// Kept in sync by the package move/mirror/rotate editing paths.
    var packagePadPositions: [String: HorizontalPoint] = [:]
    var packageHoles: [HorizontalHole]
    var packagePolygons: [HorizontalPolygon]
    var packageLines: [HorizontalSegment]
    var packageArcs: [HorizontalArc]
    var packageTexts: [HorizontalText]
    var texts: [HorizontalText]
    var boardPanels: [HorizontalBoardPanel]
    var placeableObjects: [HorizontalUnplacedObject] = []
    var unplacedObjects: [HorizontalUnplacedObject] = []
    var physicalBounds: HorizontalRect
    var bounds: HorizontalRect

    static func load(
        from url: URL,
        blockURL: URL?,
        planesURL: URL?,
        poolURL: URL?,
        visitedProjectURLs: Set<URL> = [],
        diagnostics: inout [HorizontalDiagnostic]
    ) throws -> HorizontalBoard {
        let json = try BoardLoadTimer.measure("HorizontalBoard.load — parse board.json") {
            try JSONHelper.loadDictionary(from: url)
        }
        let grid = HorizontalGridSettings.load(from: json, fileURL: url, defaultGrid: .boardDefault)
        let colors = parseBoardColors(from: json.dictionary("colors"))
        let stackupLayers = parseStackupLayers(from: json.dictionaryMap("stackup"))
        let userLayers = parseUserLayers(from: json.dictionaryMap("user_layers"))
        let junctions = parseJunctions(from: json)
        let junctionNetIDs = parseJunctionNetIDs(from: json)
        let packageMap = json.dictionaryMap("packages")
        let blockMetadata = loadBlockMetadata(from: blockURL, poolURL: poolURL, diagnostics: &diagnostics)
        let ownPackages = BoardLoadTimer.measure("HorizontalBoard.load — parse placements") {
            parsePlacements(
                from: packageMap,
                componentInfo: blockMetadata.components,
                poolURL: poolURL
            )
        }
        let packagePositions = Dictionary(uniqueKeysWithValues: ownPackages.map { (normalizedID($0.id), $0.position) })
        let nInnerLayers = json.int("n_inner_layers") ?? 0
        let boardTexts = json.dictionaryMap("texts")
        let boardParameterSet = boardRuleParameterSet(from: json.dictionary("rules"))
        let boardRules = HorizontalBoardRules(rules: json.dictionary("rules"), netDetails: blockMetadata.netDetails)
        let packageGeometry = BoardLoadTimer.measure("HorizontalBoard.load — parsePackageGeometry") {
            parsePackageGeometry(
                from: packageMap,
                poolURL: poolURL,
                componentInfo: blockMetadata.components,
                boardTexts: boardTexts,
                titleValues: blockMetadata.titleValues,
                nInnerLayers: nInnerLayers,
                boardParameterSet: boardParameterSet,
                diagnostics: &diagnostics
            )
        }
        var ownTracks = parseBoardTracks(
            from: json.dictionaryMap("tracks"),
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            packagePositions: packagePositions,
            packagePadPositions: packageGeometry.padPositions,
            packagePadNetIDs: packageGeometry.padNetIDs
        )
        let ownNetTies = parseBoardNetTies(
            from: json.dictionaryMap("net_ties"),
            junctions: junctions,
            junctionNetIDs: junctionNetIDs
        )
        let ownLines = parseBoardLines(
            from: json.dictionaryMap("lines"),
            junctions: junctions
        )
        let ownArcs = parseBoardArcs(
            from: json.dictionaryMap("arcs"),
            junctions: junctions
        )
        let ownConnectionLines = parseConnectionLines(
            from: json.dictionaryMap("connection_lines"),
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            packagePositions: packagePositions,
            packagePadPositions: packageGeometry.padPositions,
            packagePadNetIDs: packageGeometry.padNetIDs
        )
        let ownDimensions = parseDimensions(from: json.dictionaryMap("dimensions"))
        let ownDecals = parseBoardDecals(
            from: json.dictionaryMap("decals"),
            poolURL: poolURL,
            nInnerLayers: nInnerLayers,
            diagnostics: &diagnostics
        )
        let allPolygons = parsePolygons(from: json.dictionaryMap("polygons"))
        let polygonsByID = Dictionary(uniqueKeysWithValues: allPolygons.map { (normalizedID($0.id), $0) })
        let ownPlanes = BoardLoadTimer.measure("HorizontalBoard.load — parsePlanes") {
            parsePlanes(
                from: json.dictionaryMap("planes"),
                polygonsByID: polygonsByID,
                planesURL: planesURL,
                diagnostics: &diagnostics
            )
        }
        let ownKeepouts = parseKeepouts(
            from: json.dictionaryMap("keepouts"),
            polygonsByID: polygonsByID,
            diagnostics: &diagnostics
        )
        let planePolygonIDs = Set(ownPlanes.map { normalizedID($0.polygonID) })
        let keepoutPolygonIDs = Set(ownKeepouts.map { normalizedID($0.polygonID) })
        let ownPolygons = allPolygons.filter {
            !planePolygonIDs.contains(normalizedID($0.id))
                && !keepoutPolygonIDs.contains(normalizedID($0.id))
        }
        let ownHoles = parseBoardHoles(from: json.dictionaryMap("holes"), poolURL: poolURL)
        let viaDefinitions = parseViaDefinitions(from: json.dictionary("rules"))
        let viaTemplate = parseViaTemplate(
            viasMap: json.dictionaryMap("vias"),
            viaDefinitions: viaDefinitions
        )
        var ownVias = parseVias(
            from: json.dictionaryMap("vias"),
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            viaDefinitions: viaDefinitions,
            nInnerLayers: nInnerLayers
        )
        var ownViaHoles = parseViaHoles(
            from: json.dictionaryMap("vias"),
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            viaDefinitions: viaDefinitions
        )
        let boardConnectivity = BoardLoadTimer.measure("HorizontalBoard.load — resolveBoardConnectivity") {
            resolveBoardConnectivity(
                tracks: ownTracks,
                vias: ownVias,
                viaHoles: ownViaHoles,
                packagePads: packageGeometry.pads,
                packagePadPositions: packageGeometry.padPositions,
                copperLayers: boardCopperLayers(tracks: ownTracks, pads: packageGeometry.pads),
                anchors: boardNetAnchors(
                    junctions: junctions,
                    junctionNetIDs: junctionNetIDs,
                    packagePadPositions: packageGeometry.padPositions,
                    packagePadNetIDs: packageGeometry.padNetIDs,
                    packagePads: packageGeometry.pads,
                    packageHoles: packageGeometry.holes,
                    copperLayers: boardCopperLayers(tracks: ownTracks, pads: packageGeometry.pads)
                )
            )
        }
        ownTracks = boardConnectivity.tracks
        ownVias = boardConnectivity.vias
        ownViaHoles = boardConnectivity.viaHoles
        let ownAirwires = BoardLoadTimer.measure("HorizontalBoard.load — generateAirwires") {
            generateAirwires(
                junctions: junctions,
                junctionNetIDs: junctionNetIDs,
                packagePadPositions: packageGeometry.padPositions,
                packagePadNetIDs: packageGeometry.padNetIDs,
                tracks: ownTracks,
                netTies: ownNetTies,
                vias: ownVias
            )
        }
        let linkedPackageTextIDs = packageTextIDs(from: packageMap)
        let ownTexts = parseTexts(
            from: boardTexts,
            excluding: linkedPackageTextIDs,
            context: BoardTextContext(titleValues: blockMetadata.titleValues)
        )
        let boardPanelResult = loadBoardPanels(
            from: json.dictionaryMap("board_panels"),
            includedBoards: json.dictionaryMap("included_boards"),
            baseURL: url.deletingLastPathComponent(),
            visitedProjectURLs: visitedProjectURLs,
            diagnostics: &diagnostics
        )
        let panelGeometry = boardPanelResult.geometry
        let packages = ownPackages + panelGeometry.packages
        let tracks = ownTracks + panelGeometry.tracks
        let netTies = ownNetTies + panelGeometry.netTies
        let lines = ownLines + panelGeometry.lines
        let arcs = ownArcs + panelGeometry.arcs
        let connectionLines = ownConnectionLines + panelGeometry.connectionLines
        let airwires = ownAirwires + panelGeometry.airwires
        let polygons = ownPolygons + panelGeometry.polygons
        let planes = ownPlanes + panelGeometry.planes
        let keepouts = ownKeepouts + panelGeometry.keepouts
        let dimensions = ownDimensions + panelGeometry.dimensions
        let decals = ownDecals + panelGeometry.decals
        let holes = ownHoles + panelGeometry.holes
        let vias = ownVias + panelGeometry.vias
        let viaHoles = ownViaHoles + panelGeometry.viaHoles
        let packagePads = packageGeometry.pads + panelGeometry.packagePads
        let packageHoles = packageGeometry.holes + panelGeometry.packageHoles
        let packagePolygons = packageGeometry.polygons + panelGeometry.packagePolygons
        let packageLines = packageGeometry.lines + panelGeometry.packageLines
        let packageArcs = packageGeometry.arcs + panelGeometry.packageArcs
        let packageTexts = packageGeometry.texts + panelGeometry.packageTexts
        let texts = ownTexts + panelGeometry.texts

        var points = [HorizontalPoint]()
        points.append(contentsOf: junctions.values)
        points.append(contentsOf: packages.map(\.position))
        points.append(contentsOf: texts.flatMap(\.renderBoundsPoints))
        points.append(contentsOf: holes.flatMap(\.boundsPoints))
        points.append(contentsOf: vias.flatMap(\.boundsPoints))
        points.append(contentsOf: viaHoles.flatMap(\.boundsPoints))
        points.append(contentsOf: tracks.flatMap(\.pathPoints))
        points.append(contentsOf: connectionLines.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: airwires.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: netTies.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: arcs.flatMap { $0.polyline(precision: 24) })
        points.append(contentsOf: polygons.flatMap { $0.renderVertices(arcPrecision: 24) })
        points.append(contentsOf: planes.flatMap(\.points))
        points.append(contentsOf: keepouts.flatMap(\.points))
        points.append(contentsOf: dimensions.flatMap(\.points))
        points.append(contentsOf: decals.flatMap(\.points))
        points.append(contentsOf: packagePads.flatMap { $0.renderVertices(arcPrecision: 24) })
        points.append(contentsOf: packagePolygons.flatMap { $0.renderVertices(arcPrecision: 24) })
        points.append(contentsOf: packageLines.flatMap { [$0.from, $0.to] })
        points.append(contentsOf: packageArcs.flatMap { $0.polyline(precision: 24) })
        points.append(contentsOf: packageTexts.flatMap(\.renderBoundsPoints))
        points.append(contentsOf: packageHoles.flatMap(\.boundsPoints))
        let physicalPoints = boardPhysicalBoundsPoints(
            lines: lines,
            arcs: arcs,
            polygons: polygons,
            panels: boardPanelResult.panels
        )
        let physicalBounds = HorizontalRect(points: physicalPoints.isEmpty ? points : physicalPoints)
        let placeableObjects = boardPlaceableObjects(componentInfo: blockMetadata.components)

        return HorizontalBoard(
            url: url,
            uuid: json.string("uuid") ?? "unknown-board",
            name: json.string("name") ?? url.deletingPathExtension().lastPathComponent,
            grid: grid,
            colors: colors,
            stackupLayers: stackupLayers,
            userLayers: userLayers,
            junctions: junctions,
            junctionNetIDs: junctionNetIDs,
            netDetails: blockMetadata.netDetails,
            rules: boardRules,
            tracks: tracks,
            netTies: netTies,
            lines: lines,
            arcs: arcs,
            connectionLines: connectionLines,
            airwires: airwires,
            polygons: polygons,
            planes: planes,
            keepouts: keepouts,
            dimensions: dimensions,
            decals: decals,
            holes: holes,
            vias: vias,
            viaHoles: viaHoles,
            viaTemplate: viaTemplate,
            packages: packages,
            packagePads: packagePads,
            packagePadPositions: packageGeometry.padPositions,
            packageHoles: packageHoles,
            packagePolygons: packagePolygons,
            packageLines: packageLines,
            packageArcs: packageArcs,
            packageTexts: packageTexts,
            texts: texts,
            boardPanels: boardPanelResult.panels,
            placeableObjects: placeableObjects,
            unplacedObjects: unplacedBoardObjects(
                placeableObjects: placeableObjects,
                placedPackages: packages
            ),
            physicalBounds: physicalBounds,
            bounds: HorizontalRect(points: points).padded().orEmptyContentCanvasRegion()
        )
    }

    var totalSubstrateThickness: Double {
        stackupLayers
            .filter { $0.layer != HorizontalBoardLayers.bottomCopper }
            .reduce(0) { $0 + $1.substrateThickness }
    }

    var copperLayerCount: Int {
        stackupLayers.filter { HorizontalBoardLayers.isCopper($0.layer) }.count
    }

    var topPackageCount: Int {
        packages.filter { !$0.mirrored }.count
    }

    var bottomPackageCount: Int {
        packages.filter(\.mirrored).count
    }

    var topPadCount: Int {
        packagePads.filter { $0.layer == HorizontalBoardLayers.topCopper }.count
    }

    var bottomPadCount: Int {
        packagePads.filter { $0.layer == HorizontalBoardLayers.bottomCopper }.count
    }

    var topPadArea: Double {
        packagePads.filter { $0.layer == HorizontalBoardLayers.topCopper }.reduce(0) { $0 + $1.area }
    }

    var bottomPadArea: Double {
        packagePads.filter { $0.layer == HorizontalBoardLayers.bottomCopper }.reduce(0) { $0 + $1.area }
    }

    var totalTrackLength: Double {
        tracks.reduce(0) { $0 + $1.length }
    }

    var topTrackLength: Double {
        tracks.filter { $0.layer == HorizontalBoardLayers.topCopper }.reduce(0) { $0 + $1.length }
    }

    var innerTrackLength: Double {
        tracks.filter { track in
            guard let layer = track.layer else {
                return false
            }
            return HorizontalBoardLayers.isCopper(layer)
                && layer != HorizontalBoardLayers.topCopper
                && layer != HorizontalBoardLayers.bottomCopper
        }.reduce(0) { $0 + $1.length }
    }

    var bottomTrackLength: Double {
        tracks.filter { $0.layer == HorizontalBoardLayers.bottomCopper }.reduce(0) { $0 + $1.length }
    }

    var planeFragmentCount: Int {
        planes.reduce(0) { $0 + $1.renderFragments.count }
    }

    var totalPlaneArea: Double {
        planes.reduce(0) { total, plane in
            total + plane.renderFragments.reduce(0) { $0 + $1.area }
        }
    }

    var totalKeepoutArea: Double {
        keepouts.reduce(0) { $0 + $1.polygon.area }
    }

    var totalNetTieLength: Double {
        netTies.reduce(0) { $0 + $1.length }
    }

    var totalConnectionLength: Double {
        connectionLines.reduce(0) { $0 + $1.length }
    }

    var drillCount: Int {
        holes.count + viaHoles.count + packageHoles.count
    }

    var platedHoleCount: Int {
        allHoles.filter(\.plated).count
    }

    var unplatedHoleCount: Int {
        allHoles.filter { !$0.plated }.count
    }

    private var allHoles: [HorizontalHole] {
        holes + viaHoles + packageHoles
    }

    private static func parseBoardColors(from json: JSONDictionary?) -> HorizontalBoardColors {
        HorizontalBoardColors(
            silkscreen: parseRGBColor(from: json?.dictionary("silkscreen")),
            solderMask: parseRGBColor(from: json?.dictionary("solder_mask")),
            substrate: parseRGBColor(from: json?.dictionary("substrate"))
        )
    }

    private static func parseRGBColor(from json: JSONDictionary?) -> HorizontalRGBColor? {
        guard let json,
              let red = json.double("r"),
              let green = json.double("g"),
              let blue = json.double("b") else {
            return nil
        }

        return HorizontalRGBColor(red: red, green: green, blue: blue)
    }

    private static func parseStackupLayers(from map: [String: JSONDictionary]) -> [HorizontalBoardStackupLayer] {
        map.compactMap { key, item in
            guard let layer = Int(key) else {
                return nil
            }

            return HorizontalBoardStackupLayer(
                layer: layer,
                copperThickness: item.double("thickness") ?? 0,
                substrateThickness: item.double("substrate_thickness") ?? 0
            )
        }
        .sorted { stackupSortKey($0.layer) < stackupSortKey($1.layer) }
    }

    private static func stackupSortKey(_ layer: Int) -> Int {
        if layer == HorizontalBoardLayers.topCopper {
            return 0
        }
        if layer == HorizontalBoardLayers.bottomCopper {
            return 10_000
        }
        return abs(layer)
    }

    private static func parseUserLayers(from map: [String: JSONDictionary]) -> [HorizontalBoardUserLayer] {
        map.compactMap { key, item in
            guard let id = Int(key) else {
                return nil
            }
            let colorLayer = item.int("id_color") ?? id

            return HorizontalBoardUserLayer(
                id: id,
                colorLayer: colorLayer,
                name: item.string("name") ?? "User Layer \(id - HorizontalBoardLayers.firstUserLayer)",
                type: item.string("type") ?? "documentation",
                position: item.double("position")
            )
        }
        .sorted { lhs, rhs in
            if let lhsPosition = lhs.position, let rhsPosition = rhs.position, lhsPosition != rhsPosition {
                return lhsPosition < rhsPosition
            }
            return lhs.id < rhs.id
        }
    }

    private static func parseJunctions(from json: JSONDictionary) -> [String: HorizontalPoint] {
        json.dictionaryMap("junctions").reduce(into: [String: HorizontalPoint]()) { result, item in
            if let point = item.value.point("position") {
                result[item.key] = point
            }
        }
    }

    private static func parseJunctionNetIDs(from json: JSONDictionary) -> [String: String] {
        json.dictionaryMap("junctions").reduce(into: [String: String]()) { result, item in
            if let netID = item.value.string("net").map(normalizedID) {
                result[item.key] = netID
            }
        }
    }

    private static func parsePlacements(
        from map: [String: JSONDictionary],
        componentInfo: [String: BoardComponentInfo],
        poolURL: URL?
    ) -> [HorizontalPlacement] {
        var packageCache = [String: JSONDictionary]()
        var partPackageIDCache = [String: String]()
        var missingPartPackageIDs = Set<String>()
        var packageModelMapCache = [String: [String: JSONDictionary]]()
        var partModelIDCache = [String: String]()
        var missingPartModelIDs = Set<String>()
        var package3DModelCache = [String: HorizontalPackage3DModel]()
        var missingPackage3DModels = Set<String>()
        var modelFileURLCache = [String: URL]()
        var missingModelFileURLs = Set<String>()
        return map.compactMap { id, item -> HorizontalPlacement? in
            guard let placement = item.dictionary("placement"),
                  let position = placement.point("shift") else {
                return nil
            }

            let componentID = item.string("component").map(normalizedID)
            let componentLabel = componentID
                .flatMap { componentInfo[$0]?.displayLabel }
                .flatMap(nonEmpty)
            let component = componentID.flatMap { componentInfo[$0] }
            let packageModel = poolURL.flatMap { poolURL -> (packageID: String, modelID: String, model: HorizontalPackage3DModel)? in
                resolvedPackage3DModel(
                    for: item,
                    component: component,
                    poolURL: poolURL,
                    packageCache: &packageCache,
                    partPackageIDCache: &partPackageIDCache,
                    missingPartPackageIDs: &missingPartPackageIDs,
                    packageModelMapCache: &packageModelMapCache,
                    partModelIDCache: &partModelIDCache,
                    missingPartModelIDs: &missingPartModelIDs,
                    package3DModelCache: &package3DModelCache,
                    missingPackage3DModels: &missingPackage3DModels,
                    modelFileURLCache: &modelFileURLCache,
                    missingModelFileURLs: &missingModelFileURLs
                )
            }
            return HorizontalPlacement(
                id: id,
                position: position,
                angle: placement.int("angle") ?? 0,
                mirrored: item.bool("flip") ?? placement.bool("mirror") ?? false,
                label: componentLabel ?? item.string("component") ?? String(id.prefix(8)),
                componentID: componentID,
                componentDetails: componentID.flatMap { componentInfo[$0]?.details },
                packageID: packageModel?.packageID,
                modelID: packageModel?.modelID,
                model3D: packageModel?.model,
                smashed: item.bool("smashed") ?? false,
                omitSilkscreen: item.bool("omit_silkscreen") ?? false,
                omitOutline: item.bool("omit_outline") ?? false,
                fixed: item.bool("fixed") ?? false
            )
        }
    }

    private static func loadBoardPanels(
        from map: [String: JSONDictionary],
        includedBoards: [String: JSONDictionary],
        baseURL: URL,
        visitedProjectURLs: Set<URL>,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> HorizontalBoardPanelLoadResult {
        guard !map.isEmpty else {
            return .empty
        }

        let includedProjects = includedBoards.reduce(into: [String: String]()) { result, item in
            if let projectFilename = item.value.string("project_filename") {
                result[normalizedID(item.key)] = projectFilename
            }
        }

        var result = HorizontalBoardPanelLoadResult.empty
        var projectCache = [URL: HorizontalProject]()
        var missingIncludedBoardIDs = Set<String>()

        for (panelID, item) in map.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard let includedBoardID = item.string("included_board") else {
                continue
            }

            guard let projectFilename = includedProjects[normalizedID(includedBoardID)] else {
                missingIncludedBoardIDs.insert(includedBoardID)
                continue
            }

            guard let placement = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                diagnostics.append(HorizontalDiagnostic(message: "Could not read placement for board panel \(String(panelID.prefix(8)))."))
                continue
            }

            let projectURL = baseURL.appendingPathComponent(projectFilename).standardizedFileURL
            do {
                let project: HorizontalProject
                if let cachedProject = projectCache[projectURL] {
                    project = cachedProject
                } else {
                    project = try HorizontalProject.load(
                        from: projectURL,
                        visitedProjectURLs: visitedProjectURLs
                    )
                    projectCache[projectURL] = project
                    diagnostics.append(
                        contentsOf: project.diagnostics.map {
                            HorizontalDiagnostic(message: "\(project.displayTitle): \($0.message)")
                        }
                    )
                }

                guard let childBoard = project.board else {
                    diagnostics.append(HorizontalDiagnostic(message: "Included project \(projectFilename) has no board."))
                    continue
                }

                let omitOutline = item.bool("omit_outline") ?? false
                let panel = HorizontalBoardPanel(
                    id: panelID,
                    includedBoardID: includedBoardID,
                    projectFilename: projectFilename,
                    boardName: childBoard.name,
                    placement: placement,
                    omitOutline: omitOutline,
                    bounds: transformed(childBoard.physicalBounds, placement: placement)
                )
                result.panels.append(panel)
                result.geometry.append(
                    transformedPanelGeometry(
                        from: childBoard,
                        panelID: panelID,
                        placement: placement,
                        omitOutline: omitOutline
                    )
                )
            } catch {
                diagnostics.append(HorizontalDiagnostic(message: "Could not load included board \(projectFilename): \(error.localizedDescription)"))
            }
        }

        if !missingIncludedBoardIDs.isEmpty {
            diagnostics.append(HorizontalDiagnostic(message: "Could not resolve \(missingIncludedBoardIDs.count) included board references."))
        }

        return result
    }

    private static func transformedPanelGeometry(
        from board: HorizontalBoard,
        panelID: String,
        placement: HorizontalPlacementTransform,
        omitOutline: Bool
    ) -> HorizontalBoardPanelGeometry {
        var geometry = HorizontalBoardPanelGeometry.empty
        geometry.tracks = board.tracks.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.netTies = board.netTies.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.lines = board.lines.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.arcs = board.arcs.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.connectionLines = board.connectionLines.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.airwires = board.airwires.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.polygons = board.polygons
            .filter { !(omitOutline && isBoardOutlineLayer($0.layer)) }
            .map { transformed($0, panelID: panelID, placement: placement) }
        geometry.planes = board.planes.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.keepouts = board.keepouts.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.dimensions = board.dimensions.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.decals = board.decals.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.holes = board.holes.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.vias = board.vias.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.viaHoles = board.viaHoles.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packages = board.packages.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packagePads = board.packagePads.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packageHoles = board.packageHoles.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packagePolygons = board.packagePolygons.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packageLines = board.packageLines.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packageArcs = board.packageArcs.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.packageTexts = board.packageTexts.map { transformed($0, panelID: panelID, placement: placement) }
        geometry.texts = board.texts.map { transformed($0, panelID: panelID, placement: placement) }
        return geometry
    }

    private static func boardPhysicalBoundsPoints(
        lines: [HorizontalSegment],
        arcs: [HorizontalArc],
        polygons: [HorizontalPolygon],
        panels: [HorizontalBoardPanel]
    ) -> [HorizontalPoint] {
        lines
            .filter { isBoardOutlineLayer($0.layer) }
            .flatMap { [$0.from, $0.to] }
            + arcs
            .filter { isBoardOutlineLayer($0.layer) }
            .flatMap { $0.polyline(precision: 24) }
            + polygons
            .filter { isBoardOutlineLayer($0.layer) }
            .flatMap { $0.renderVertices(arcPrecision: 24) }
            + panels.flatMap { panel in
                [
                    HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.minY),
                    HorizontalPoint(x: panel.bounds.minX, y: panel.bounds.maxY),
                    HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.minY),
                    HorizontalPoint(x: panel.bounds.maxX, y: panel.bounds.maxY)
                ]
            }
    }

    private static func transformed(_ rect: HorizontalRect, placement: HorizontalPlacementTransform) -> HorizontalRect {
        HorizontalRect(
            points: [
                HorizontalPoint(x: rect.minX, y: rect.minY),
                HorizontalPoint(x: rect.minX, y: rect.maxY),
                HorizontalPoint(x: rect.maxX, y: rect.minY),
                HorizontalPoint(x: rect.maxX, y: rect.maxY)
            ].map(placement.applying)
        )
    }

    private static func transformed(
        _ segment: HorizontalSegment,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalSegment {
        HorizontalSegment(
            id: prefixed(segment.id, panelID: panelID),
            from: placement.applying(to: segment.from),
            to: placement.applying(to: segment.to),
            width: segment.width,
            layer: segment.layer,
            center: segment.center.map { placement.applying(to: $0) },
            reverse: segment.reverse != placement.mirrored,
            netID: segment.netID
        )
    }

    private static func transformed(
        _ arc: HorizontalArc,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalArc {
        HorizontalArc(
            id: prefixed(arc.id, panelID: panelID),
            from: placement.applying(to: arc.from),
            to: placement.applying(to: arc.to),
            center: placement.applying(to: arc.center),
            width: arc.width,
            layer: arc.layer,
            reverse: arc.reverse != placement.mirrored,
            netID: arc.netID
        )
    }

    private static func transformed(
        _ marker: HorizontalMarker,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalMarker {
        HorizontalMarker(
            id: prefixed(marker.id, panelID: panelID),
            position: placement.applying(to: marker.position),
            size: marker.size,
            holeSize: marker.holeSize,
            layer: marker.layer,
            connectedLayers: marker.connectedLayers,
            netID: marker.netID
        )
    }

    private static func transformed(
        _ hole: HorizontalHole,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalHole {
        HorizontalHole(
            id: prefixed(hole.id, panelID: panelID),
            position: placement.applying(to: hole.position),
            diameter: hole.diameter,
            length: hole.length,
            shape: hole.shape,
            angle: placement.accumulated(with: HorizontalPlacementTransform(shift: hole.position, angle: hole.angle, mirrored: false)).angle,
            plated: hole.plated,
            netID: hole.netID
        )
    }

    private static func transformed(
        _ polygon: HorizontalPolygon,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalPolygon {
        HorizontalPolygon(
            id: prefixed(polygon.id, panelID: panelID),
            polygonVertices: polygon.polygonVertices.map {
                $0.transformed(placement.applying, flipsArcReverse: placement.mirrored)
            },
            layer: polygon.layer,
            netID: polygon.netID,
            metadata: polygon.metadata,
            // Compose the pad-label placement with the panel placement so
            // panelised boards keep the intrinsic label frame instead of
            // dropping back to the polygon-edge heuristic.
            padLabelFrame: polygon.padLabelFrame.map { frame in
                let composed = placement.accumulated(
                    with: HorizontalPlacementTransform(
                        shift: frame.center,
                        angle: frame.angle,
                        mirrored: frame.mirrored
                    )
                )
                return PadLabelFrameDescriptor(
                    center: composed.shift,
                    halfWidth: frame.halfWidth,
                    halfHeight: frame.halfHeight,
                    angle: composed.angle,
                    mirrored: composed.mirrored
                )
            }
        )
    }

    private static func transformed(
        _ plane: HorizontalPlane,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalPlane {
        HorizontalPlane(
            id: prefixed(plane.id, panelID: panelID),
            netID: plane.netID,
            polygonID: prefixed(plane.polygonID, panelID: panelID),
            layer: plane.layer,
            priority: plane.priority,
            fillStyle: plane.fillStyle,
            minWidth: plane.minWidth,
            keepOrphans: plane.keepOrphans,
            fragments: plane.fragments.map { fragment in
                HorizontalPlaneFragment(
                    paths: fragment.paths.map { $0.map(placement.applying) },
                    orphan: fragment.orphan
                )
            },
            fallbackPolygon: plane.fallbackPolygon.map { transformed($0, panelID: panelID, placement: placement) },
            fromRules: plane.fromRules,
            settings: plane.settings
        )
    }

    private static func transformed(
        _ keepout: HorizontalKeepout,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalKeepout {
        HorizontalKeepout(
            id: prefixed(keepout.id, panelID: panelID),
            polygonID: prefixed(keepout.polygonID, panelID: panelID),
            polygon: transformed(keepout.polygon, panelID: panelID, placement: placement),
            keepoutClass: keepout.keepoutClass,
            allCopperLayers: keepout.allCopperLayers,
            exposedCopperOnly: keepout.exposedCopperOnly,
            copperPatchTypes: keepout.copperPatchTypes
        )
    }

    private static func transformed(
        _ dimension: HorizontalDimension,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalDimension {
        transformedDimension(
            dimension,
            id: prefixed(dimension.id, panelID: panelID),
            placement: placement
        )
    }

    private static func transformedDimension(
        _ dimension: HorizontalDimension,
        id: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalDimension {
        let geometry = dimension.measurementGeometry
        let p0 = placement.applying(to: geometry.p0Projected)
        let p1 = placement.applying(to: geometry.p1Projected)
        let localNormalPoint = geometry.p0Projected + geometry.normal
        let transformedNormal = (placement.applying(to: localNormalPoint) - p0).normalized
        let placedDimension = HorizontalDimension(
            id: id,
            p0: p0,
            p1: p1,
            labelDistance: dimension.labelDistance,
            labelSize: dimension.labelSize,
            mode: .distance
        )
        let normal = placedDimension.measurementGeometry.normal
        let sameSide = transformedNormal.x * normal.x + transformedNormal.y * normal.y >= 0

        return HorizontalDimension(
            id: id,
            p0: p0,
            p1: p1,
            labelDistance: sameSide ? dimension.labelDistance : -dimension.labelDistance,
            labelSize: dimension.labelSize,
            mode: .distance
        )
    }

    private static func transformed(
        _ decal: HorizontalBoardDecal,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalBoardDecal {
        HorizontalBoardDecal(
            id: prefixed(decal.id, panelID: panelID),
            decalID: decal.decalID,
            name: decal.name,
            polygons: decal.polygons.map { transformed($0, panelID: panelID, placement: placement) },
            lines: decal.lines.map { transformed($0, panelID: panelID, placement: placement) },
            arcs: decal.arcs.map { transformed($0, panelID: panelID, placement: placement) },
            texts: decal.texts.map { transformed($0, panelID: panelID, placement: placement) }
        )
    }

    private static func transformed(
        _ text: HorizontalText,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalText {
        let childPlacement = HorizontalPlacementTransform(
            shift: text.position,
            angle: text.angle,
            mirrored: text.mirrored
        )
        let textPlacement = placement.accumulatedText(with: childPlacement)
        return HorizontalText(
            id: prefixed(text.id, panelID: panelID),
            text: text.text,
            position: textPlacement.shift,
            size: text.size,
            layer: text.layer,
            netID: text.netID,
            angle: textPlacement.angle,
            mirrored: textPlacement.mirrored,
            width: text.width,
            origin: text.origin,
            font: text.font,
            allowUpsideDown: text.allowUpsideDown,
            centered: text.centered
        )
    }

    private static func transformed(
        _ package: HorizontalPlacement,
        panelID: String,
        placement: HorizontalPlacementTransform
    ) -> HorizontalPlacement {
        let childPlacement = HorizontalPlacementTransform(
            shift: package.position,
            angle: package.angle,
            mirrored: package.mirrored
        )
        let packagePlacement = placement.accumulated(with: childPlacement)
        return HorizontalPlacement(
            id: prefixed(package.id, panelID: panelID),
            position: packagePlacement.shift,
            angle: packagePlacement.angle,
            mirrored: packagePlacement.mirrored,
            label: package.label,
            componentID: package.componentID,
            componentDetails: package.componentDetails,
            packageID: package.packageID,
            modelID: package.modelID,
            model3D: package.model3D
        )
    }

    private static func prefixed(_ id: String, panelID: String) -> String {
        "\(panelID)/\(id)"
    }

    private static func isBoardOutlineLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return HorizontalBoardLayers.isOutline(layer)
    }

    private static func isBoardSilkscreenLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return HorizontalBoardLayers.isSilkscreen(layer)
    }

    private static func parseBoardTracks(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        packagePositions: [String: HorizontalPoint],
        packagePadPositions: [String: HorizontalPoint],
        packagePadNetIDs: [String: String]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item in
            guard let from = endpointPoint(
                item.dictionary("from"),
                junctions: junctions,
                packagePositions: packagePositions,
                packagePadPositions: packagePadPositions
            ),
                  let to = endpointPoint(
                    item.dictionary("to"),
                    junctions: junctions,
                    packagePositions: packagePositions,
                    packagePadPositions: packagePadPositions
                  ) else {
                return nil
            }

            return HorizontalSegment(
                id: id,
                from: from,
                to: to,
                width: item.double("width") ?? 0,
                layer: item.int("layer"),
                center: item.point("center"),
                netID: item.string("net").map(normalizedID)
                    ?? endpointNetID(item.dictionary("from"), junctionNetIDs: junctionNetIDs, packagePadNetIDs: packagePadNetIDs)
                    ?? endpointNetID(item.dictionary("to"), junctionNetIDs: junctionNetIDs, packagePadNetIDs: packagePadNetIDs)
            )
        }
    }

    /// Net seeds, keyed by LAYER NODE rather than by bare coordinate.
    ///
    /// A pad only seeds the layers it actually has copper on. Seeding every
    /// layer at its coordinate is what let a bottom track inherit a top pad's
    /// net — see `HorizontalCopperConnectivity`.
    private static func boardNetAnchors(
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        packagePadPositions: [String: HorizontalPoint],
        packagePadNetIDs: [String: String],
        packagePads: [HorizontalPolygon],
        packageHoles: [HorizontalHole],
        copperLayers: [Int]
    ) -> [String: Set<String>] {
        var anchors = [String: Set<String>]()

        func add(_ point: HorizontalPoint, layer: Int, netID: String?) {
            guard let netID else {
                return
            }
            anchors[HorizontalCopperConnectivity.node(point, layer: layer), default: []]
                .insert(normalizedID(netID))
        }

        /// Objects with no layer of their own — junctions, drill holes — span
        /// the stackup, so their net applies to every copper layer they meet.
        func addSpanning(_ point: HorizontalPoint, netID: String?) {
            for layer in copperLayers {
                add(point, layer: layer, netID: netID)
            }
        }

        for (junctionID, point) in junctions {
            addSpanning(point, netID: junctionNetIDs[junctionID])
        }
        for pad in packagePads where pad.layer.map(HorizontalBoardLayers.isCopper) == true {
            add(
                HorizontalRect(points: pad.renderVertices(arcPrecision: 24)).center,
                layer: pad.layer ?? HorizontalBoardLayers.topCopper,
                netID: pad.netID
            )
        }
        // A drawn track snaps to the pad's placement centre, which need not be
        // the centroid of any one shape, so seed that coordinate on each copper
        // layer the pad actually occupies.
        let padLayers = padCopperLayersByPath(packagePads)
        for (padPath, point) in packagePadPositions {
            for layer in padLayers[padPath] ?? [] {
                add(point, layer: layer, netID: packagePadNetIDs[padPath])
            }
        }
        for hole in packageHoles {
            addSpanning(hole.position, netID: hole.netID)
        }

        return anchors
    }

    /// The copper layers this board actually uses. Derived from the geometry
    /// rather than the stackup so a spanning object only ever joins layers that
    /// carry copper; top and bottom are always included because a via reaches
    /// them whether or not anything is routed there yet.
    private static func boardCopperLayers(
        tracks: [HorizontalSegment],
        pads: [HorizontalPolygon]
    ) -> [Int] {
        var layers: Set<Int> = [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper]
        for track in tracks {
            if let layer = track.layer, HorizontalBoardLayers.isCopper(layer) { layers.insert(layer) }
        }
        for pad in pads {
            if let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) { layers.insert(layer) }
        }
        return layers.sorted()
    }

    /// "package/pad" path -> the copper layers that pad has shapes on. A
    /// through-hole pad spans several; an SMD pad has exactly one.
    private static func padCopperLayersByPath(_ pads: [HorizontalPolygon]) -> [String: Set<Int>] {
        var result = [String: Set<Int>]()
        for pad in pads {
            guard let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) else { continue }
            let parts = pad.id.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[1] == "pad" else { continue }
            result[parts[0] + "/" + parts[2], default: []].insert(layer)
        }
        return result
    }

    private static func resolveBoardConnectivity(
        tracks: [HorizontalSegment],
        vias: [HorizontalMarker],
        viaHoles: [HorizontalHole],
        packagePads: [HorizontalPolygon],
        packagePadPositions: [String: HorizontalPoint],
        copperLayers: [Int],
        anchors: [String: Set<String>]
    ) -> (tracks: [HorizontalSegment], vias: [HorizontalMarker], viaHoles: [HorizontalHole]) {
        var resolvedTracks = tracks
        var resolvedVias = vias
        var resolvedViaHoles = viaHoles
        var graph = HorizontalCopperConnectivity()
        var trackIndicesByPoint = [String: [Int]]()
        var viaIndicesByPoint = [String: [Int]]()
        var viaHoleIndicesByPoint = [String: [Int]]()
        var allPointKeys = Set<String>()

        for (index, track) in resolvedTracks.enumerated() {
            // A track lives on exactly one layer; data with none is treated as
            // spanning rather than dropped, so it keeps its old behaviour.
            let layers = track.layer.map { [$0] } ?? copperLayers
            for layer in layers {
                let fromKey = HorizontalCopperConnectivity.node(track.from, layer: layer)
                let toKey = HorizontalCopperConnectivity.node(track.to, layer: layer)
                graph.connect(fromKey, toKey)
                trackIndicesByPoint[fromKey, default: []].append(index)
                trackIndicesByPoint[toKey, default: []].append(index)
                allPointKeys.insert(fromKey)
                allPointKeys.insert(toKey)
            }
        }

        // Vias and drill holes are what legitimately tie layers together at one
        // coordinate.
        for (index, via) in resolvedVias.enumerated() {
            // A blind or buried via spans only its own layers; an empty list
            // means a plain through-hole via.
            let listed = via.connectedLayers.filter(HorizontalBoardLayers.isCopper)
            let spanned = listed.isEmpty ? copperLayers : listed
            graph.join(spanned, at: via.position)
            for layer in spanned {
                let key = HorizontalCopperConnectivity.node(via.position, layer: layer)
                viaIndicesByPoint[key, default: []].append(index)
                allPointKeys.insert(key)
            }
        }

        for (index, hole) in resolvedViaHoles.enumerated() {
            graph.join(copperLayers, at: hole.position)
            for layer in copperLayers {
                let key = HorizontalCopperConnectivity.node(hole.position, layer: layer)
                viaHoleIndicesByPoint[key, default: []].append(index)
                allPointKeys.insert(key)
            }
        }

        // One physical pad is one electrical object even when its copper spans
        // several layers, so tie its shapes (and its placement centre, which is
        // where drawn tracks land) together.
        let padLayers = padCopperLayersByPath(packagePads)
        var padNodesByPath = [String: [String]]()
        for pad in packagePads {
            guard let layer = pad.layer, HorizontalBoardLayers.isCopper(layer) else { continue }
            let parts = pad.id.split(separator: "/").map(String.init)
            guard parts.count >= 3, parts[1] == "pad" else { continue }
            let center = HorizontalRect(points: pad.renderVertices(arcPrecision: 24)).center
            padNodesByPath[parts[0] + "/" + parts[2], default: []]
                .append(HorizontalCopperConnectivity.node(center, layer: layer))
        }
        for (padPath, point) in packagePadPositions {
            for layer in padLayers[padPath] ?? [] {
                padNodesByPath[padPath, default: []]
                    .append(HorizontalCopperConnectivity.node(point, layer: layer))
            }
        }
        for nodes in padNodesByPath.values {
            graph.join(nodes)
            allPointKeys.formUnion(nodes)
        }

        let neighbors = graph.neighbors
        allPointKeys.formUnion(anchors.keys)
        var visited = Set<String>()
        for startKey in allPointKeys where !visited.contains(startKey) {
            var stack = [startKey]
            var componentTrackIndices = Set<Int>()
            var componentViaIndices = Set<Int>()
            var componentViaHoleIndices = Set<Int>()
            var componentNetIDs = Set<String>()
            visited.insert(startKey)

            while let key = stack.popLast() {
                componentNetIDs.formUnion(anchors[key] ?? [])

                for index in trackIndicesByPoint[key] ?? [] {
                    componentTrackIndices.insert(index)
                    if let netID = resolvedTracks[index].netID {
                        componentNetIDs.insert(normalizedID(netID))
                    }
                }
                for index in viaIndicesByPoint[key] ?? [] {
                    componentViaIndices.insert(index)
                    if let netID = resolvedVias[index].netID {
                        componentNetIDs.insert(normalizedID(netID))
                    }
                }
                for index in viaHoleIndicesByPoint[key] ?? [] {
                    componentViaHoleIndices.insert(index)
                    if let netID = resolvedViaHoles[index].netID {
                        componentNetIDs.insert(normalizedID(netID))
                    }
                }

                for nextKey in neighbors[key] ?? [] where !visited.contains(nextKey) {
                    visited.insert(nextKey)
                    stack.append(nextKey)
                }
            }

            guard componentNetIDs.count == 1,
                  let netID = componentNetIDs.first else {
                continue
            }

            for index in componentTrackIndices where resolvedTracks[index].netID == nil {
                resolvedTracks[index].netID = netID
            }
            for index in componentViaIndices where resolvedVias[index].netID == nil {
                resolvedVias[index].netID = netID
            }
            for index in componentViaHoleIndices where resolvedViaHoles[index].netID == nil {
                resolvedViaHoles[index].netID = netID
            }
        }

        return (resolvedTracks, resolvedVias, resolvedViaHoles)
    }

    private static func generateAirwires(
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        packagePadPositions: [String: HorizontalPoint],
        packagePadNetIDs: [String: String],
        tracks: [HorizontalSegment],
        netTies: [HorizontalSegment],
        vias: [HorizontalMarker]
    ) -> [HorizontalSegment] {
        var nodesByNet = [String: [BoardAirwireNode]]()

        func add(_ point: HorizontalPoint, netID: String?) {
            guard let netID = netID.map(normalizedID) else {
                return
            }
            nodesByNet[netID, default: []].append(BoardAirwireNode(point: point))
        }

        for (junctionID, point) in junctions {
            add(point, netID: junctionNetIDs[junctionID])
        }
        for (padPath, point) in packagePadPositions {
            add(point, netID: packagePadNetIDs[padPath])
        }
        for via in vias {
            add(via.position, netID: via.netID)
        }

        var fixedSegmentsByNet = [String: [HorizontalSegment]]()
        func addFixedSegments(_ segments: [HorizontalSegment]) {
            for segment in segments {
                guard let netID = segment.netID.map(normalizedID) else {
                    continue
                }
                fixedSegmentsByNet[netID, default: []].append(segment)
            }
        }
        addFixedSegments(tracks)
        addFixedSegments(netTies)

        var airwires = [HorizontalSegment]()

        for netID in nodesByNet.keys.sorted() {
            guard let nodes = nodesByNet[netID], nodes.count > 1 else {
                continue
            }

            var disjointSet = BoardAirwireDisjointSet(count: nodes.count)
            var nodeIndicesByPoint = [String: [Int]]()
            for (index, node) in nodes.enumerated() {
                nodeIndicesByPoint[pointKey(node.point), default: []].append(index)
            }

            for indices in nodeIndicesByPoint.values where indices.count > 1 {
                for index in indices.dropFirst() {
                    _ = disjointSet.union(indices[0], index)
                }
            }

            for segment in fixedSegmentsByNet[netID] ?? [] {
                guard let fromIndices = nodeIndicesByPoint[pointKey(segment.from)],
                      let toIndices = nodeIndicesByPoint[pointKey(segment.to)] else {
                    continue
                }

                for fromIndex in fromIndices {
                    for toIndex in toIndices {
                        _ = disjointSet.union(fromIndex, toIndex)
                    }
                }
            }

            for edge in minimumAirwireEdges(nodes: nodes, disjointSet: &disjointSet) {
                guard edge.weightSquared > 0 else {
                    continue
                }

                airwires.append(
                    HorizontalSegment(
                        id: "airwire/\(netID)/\(airwires.count + 1)",
                        from: nodes[edge.from].point,
                        to: nodes[edge.to].point,
                        width: 0,
                        layer: nil,
                        netID: netID
                    )
                )
            }
        }

        return airwires
    }

    private static func minimumAirwireEdges(
        nodes: [BoardAirwireNode],
        disjointSet: inout BoardAirwireDisjointSet
    ) -> [BoardAirwireCandidate] {
        var componentIndicesByRoot = [Int: Int]()
        var componentNodes = [[Int]]()
        var nodeComponent = Array(repeating: 0, count: nodes.count)

        for index in nodes.indices {
            let root = disjointSet.find(index)
            let componentIndex: Int
            if let existing = componentIndicesByRoot[root] {
                componentIndex = existing
            } else {
                componentIndex = componentNodes.count
                componentIndicesByRoot[root] = componentIndex
                componentNodes.append([])
            }
            nodeComponent[index] = componentIndex
            componentNodes[componentIndex].append(index)
        }

        guard componentNodes.count > 1 else {
            return []
        }

        var visited = Array(repeating: false, count: componentNodes.count)
        var bestByComponent = Array<BoardAirwireCandidate?>(repeating: nil, count: componentNodes.count)
        var edges = [BoardAirwireCandidate]()
        edges.reserveCapacity(componentNodes.count - 1)

        func updateCandidates(from sourceComponent: Int) {
            for sourceNode in componentNodes[sourceComponent] {
                let sourcePoint = nodes[sourceNode].point
                for targetNode in nodes.indices {
                    let targetComponent = nodeComponent[targetNode]
                    guard targetComponent != sourceComponent,
                          !visited[targetComponent] else {
                        continue
                    }

                    let fromNode = min(sourceNode, targetNode)
                    let toNode = max(sourceNode, targetNode)
                    let weightSquared = squaredDistance(sourcePoint, nodes[targetNode].point)
                    let candidate = BoardAirwireCandidate(
                        from: fromNode,
                        to: toNode,
                        targetComponent: targetComponent,
                        weightSquared: weightSquared
                    )
                    if isBetterAirwireCandidate(candidate, than: bestByComponent[targetComponent]) {
                        bestByComponent[targetComponent] = candidate
                    }
                }
            }
        }

        visited[0] = true
        updateCandidates(from: 0)

        while edges.count < componentNodes.count - 1 {
            var next: BoardAirwireCandidate?
            for component in componentNodes.indices where !visited[component] {
                guard let candidate = bestByComponent[component] else {
                    continue
                }
                if isBetterAirwireCandidate(candidate, than: next) {
                    next = candidate
                }
            }

            guard let next else {
                break
            }

            visited[next.targetComponent] = true
            edges.append(next)
            updateCandidates(from: next.targetComponent)
        }

        return edges
    }

    private static func isBetterAirwireCandidate(_ candidate: BoardAirwireCandidate, than current: BoardAirwireCandidate?) -> Bool {
        guard let current else {
            return true
        }
        if candidate.weightSquared != current.weightSquared {
            return candidate.weightSquared < current.weightSquared
        }
        if candidate.from != current.from {
            return candidate.from < current.from
        }
        return candidate.to < current.to
    }

    private static func squaredDistance(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func parseBoardNetTies(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }

            return HorizontalSegment(
                id: id,
                from: from,
                to: to,
                width: item.double("width") ?? 0,
                layer: item.int("layer"),
                netID: item.string("net").map(normalizedID)
                    ?? junctionNetIDs[fromID]
                    ?? junctionNetIDs[toID]
            )
        }
    }

    private static func parseBoardLines(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item -> HorizontalSegment? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }

            return HorizontalSegment(
                id: id,
                from: from,
                to: to,
                width: item.double("width") ?? 0,
                layer: item.int("layer")
            )
        }
    }

    private static func parseBoardArcs(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint]
    ) -> [HorizontalArc] {
        map.compactMap { id, item -> HorizontalArc? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                return nil
            }

            return HorizontalArc(
                id: id,
                from: from,
                to: to,
                center: center,
                width: item.double("width") ?? 0,
                layer: item.int("layer")
            )
        }
    }

    private static func parseConnectionLines(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        packagePositions: [String: HorizontalPoint],
        packagePadPositions: [String: HorizontalPoint],
        packagePadNetIDs: [String: String]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item in
            guard let from = endpointPoint(
                item.dictionary("from"),
                junctions: junctions,
                packagePositions: packagePositions,
                packagePadPositions: packagePadPositions
            ),
                  let to = endpointPoint(
                    item.dictionary("to"),
                    junctions: junctions,
                    packagePositions: packagePositions,
                    packagePadPositions: packagePadPositions
                  ),
                  from != to else {
                return nil
            }

            return HorizontalSegment(
                id: id,
                from: from,
                to: to,
                width: 0,
                layer: nil,
                netID: item.string("net").map(normalizedID)
                    ?? endpointNetID(item.dictionary("from"), junctionNetIDs: junctionNetIDs, packagePadNetIDs: packagePadNetIDs)
                    ?? endpointNetID(item.dictionary("to"), junctionNetIDs: junctionNetIDs, packagePadNetIDs: packagePadNetIDs)
            )
        }
    }

    private static func parseDimensions(from map: [String: JSONDictionary]) -> [HorizontalDimension] {
        map.compactMap { id, item in
            guard let p0 = item.point("p0"),
                  let p1 = item.point("p1"),
                  let labelDistance = item.double("label_distance"),
                  let modeValue = item.string("mode"),
                  let mode = HorizontalDimensionMode(rawValue: modeValue) else {
                return nil
            }

            return HorizontalDimension(
                id: id,
                p0: p0,
                p1: p1,
                labelDistance: labelDistance,
                labelSize: item.double("label_size") ?? 1_500_000,
                mode: mode
            )
        }
    }

    private static func parseBoardDecals(
        from map: [String: JSONDictionary],
        poolURL: URL?,
        nInnerLayers: Int,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [HorizontalBoardDecal] {
        guard !map.isEmpty else {
            return []
        }

        guard let poolURL else {
            diagnostics.append(HorizontalDiagnostic(message: "Project has board decals but no pool directory was available."))
            return []
        }

        var cache = [String: JSONDictionary]()
        var missingIDs = Set<String>()
        let decals = map.compactMap { id, item -> HorizontalBoardDecal? in
            guard let decalID = item.string("decal").map(normalizedID),
                  let placement = HorizontalPlacementTransform(json: item.dictionary("placement"), mirrorOverride: item.bool("flip")) else {
                return nil
            }

            guard let decalJSON = loadDecal(decalID, poolURL: poolURL, cache: &cache) else {
                missingIDs.insert(decalID)
                return nil
            }

            return parseSingleBoardDecal(
                id: id,
                decalID: decalID,
                boardDecal: item,
                decalJSON: decalJSON,
                placement: placement,
                nInnerLayers: nInnerLayers
            )
        }

        if !missingIDs.isEmpty {
            diagnostics.append(HorizontalDiagnostic(message: "Could not resolve \(missingIDs.count) board decal files from the project pool."))
        }

        return decals
    }

    private static func parseSingleBoardDecal(
        id: String,
        decalID: String,
        boardDecal: JSONDictionary,
        decalJSON: JSONDictionary,
        placement: HorizontalPlacementTransform,
        nInnerLayers: Int
    ) -> HorizontalBoardDecal {
        let scale = boardDecal.double("scale") ?? 1
        let flipped = boardDecal.bool("flip") ?? placement.mirrored
        let renderPlacement = HorizontalPlacementTransform(
            shift: placement.shift,
            angle: flipped ? -placement.angle : placement.angle,
            mirrored: flipped
        )
        let transform: (HorizontalPoint) -> HorizontalPoint = { point in
            renderPlacement.applying(to: point * scale)
        }
        let layerTransform: (Int?) -> Int? = { layer in
            packageLayer(layer, flipped: flipped, nInnerLayers: nInnerLayers)
        }
        let junctions = parseJunctions(from: decalJSON).mapValues(transform)

        return HorizontalBoardDecal(
            id: id,
            decalID: decalID,
            name: decalJSON.string("name") ?? String(decalID.prefix(8)),
            polygons: parseDecalPolygons(
                from: decalJSON.dictionaryMap("polygons"),
                decalID: id,
                transform: transform,
                flipsArcReverse: flipped,
                layerTransform: layerTransform
            ),
            lines: parseDecalLines(
                from: decalJSON.dictionaryMap("lines"),
                decalID: id,
                junctions: junctions,
                scale: scale,
                layerTransform: layerTransform
            ),
            arcs: parseDecalArcs(
                from: decalJSON.dictionaryMap("arcs"),
                decalID: id,
                junctions: junctions,
                scale: scale,
                reverse: flipped,
                layerTransform: layerTransform
            ),
            texts: parseDecalTexts(
                from: decalJSON.dictionaryMap("texts"),
                decalID: id,
                placement: renderPlacement,
                scale: scale,
                layerTransform: layerTransform
            )
        )
    }

    private static func parseDecalPolygons(
        from map: [String: JSONDictionary],
        decalID: String,
        transform: (HorizontalPoint) -> HorizontalPoint,
        flipsArcReverse: Bool,
        layerTransform: (Int?) -> Int?
    ) -> [HorizontalPolygon] {
        map.compactMap { id, item in
            let vertices = parsePolygonVertexList(
                from: item.dictionaryArray("vertices"),
                transform: transform,
                flipsArcReverse: flipsArcReverse
            )
            guard vertices.count >= 2 else {
                return nil
            }

            return HorizontalPolygon(id: "\(decalID)/polygon/\(id)", polygonVertices: vertices, layer: layerTransform(item.int("layer")))
        }
    }

    private static func parseDecalLines(
        from map: [String: JSONDictionary],
        decalID: String,
        junctions: [String: HorizontalPoint],
        scale: Double,
        layerTransform: (Int?) -> Int?
    ) -> [HorizontalSegment] {
        map.compactMap { id, item -> HorizontalSegment? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }

            return HorizontalSegment(
                id: "\(decalID)/line/\(id)",
                from: from,
                to: to,
                width: (item.double("width") ?? 0) * scale,
                layer: layerTransform(item.int("layer"))
            )
        }
    }

    private static func parseDecalArcs(
        from map: [String: JSONDictionary],
        decalID: String,
        junctions: [String: HorizontalPoint],
        scale: Double,
        reverse: Bool,
        layerTransform: (Int?) -> Int?
    ) -> [HorizontalArc] {
        map.compactMap { id, item -> HorizontalArc? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                return nil
            }

            return HorizontalArc(
                id: "\(decalID)/arc/\(id)",
                from: from,
                to: to,
                center: center,
                width: (item.double("width") ?? 0) * scale,
                layer: layerTransform(item.int("layer")),
                reverse: reverse
            )
        }
    }

    private static func parseDecalTexts(
        from map: [String: JSONDictionary],
        decalID: String,
        placement: HorizontalPlacementTransform,
        scale: Double,
        layerTransform: (Int?) -> Int?
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard let text = item.string("text"),
                  let textTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return nil
            }

            let scaledTextTransform = HorizontalPlacementTransform(
                shift: textTransform.shift * scale,
                angle: textTransform.angle,
                mirrored: textTransform.mirrored
            )
            let transformed = placement.accumulatedText(with: scaledTextTransform)
            return HorizontalText(
                id: "\(decalID)/text/\(id)",
                text: text,
                position: transformed.shift,
                size: (item.double("size") ?? 1_000_000) * scale,
                layer: layerTransform(item.int("layer")),
                angle: transformed.angle,
                mirrored: transformed.mirrored,
                width: (item.double("width") ?? 0) * scale,
                origin: item.horizonTextOrigin(),
                font: item.horizonTextFont(),
                allowUpsideDown: item.bool("allow_upside_down") ?? false
            )
        }
    }

    private static func parsePolygons(from map: [String: JSONDictionary]) -> [HorizontalPolygon] {
        map.compactMap { id, item in
            let vertices = parsePolygonVertexList(from: item.dictionaryArray("vertices"))
            guard vertices.count >= 2 else {
                return nil
            }
            return HorizontalPolygon(id: id, polygonVertices: vertices, layer: item.int("layer"))
        }
    }

    private static func parsePlanes(
        from map: [String: JSONDictionary],
        polygonsByID: [String: HorizontalPolygon],
        planesURL: URL?,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [HorizontalPlane] {
        guard !map.isEmpty else {
            return []
        }

        let fragmentsByPlaneID = loadPlaneFragments(from: planesURL, diagnostics: &diagnostics)
        if fragmentsByPlaneID.isEmpty, planesURL == nil {
            diagnostics.append(HorizontalDiagnostic(message: "Project does not declare planes_filename; showing plane source polygons."))
        }

        return map.compactMap { id, item in
            guard let polygonID = item.string("polygon") else {
                return nil
            }

            let fallbackPolygon = polygonsByID[normalizedID(polygonID)]
            let settings = item.dictionary("settings")
            let planeSettings = HorizontalPlaneSettings(json: settings)
            return HorizontalPlane(
                id: id,
                netID: item.string("net").map(normalizedID),
                polygonID: polygonID,
                layer: fallbackPolygon?.layer,
                priority: item.int("priority") ?? 0,
                fillStyle: settings?.string("fill_style") ?? item.string("fill_style") ?? "solid",
                minWidth: settings?.double("min_width") ?? 0,
                keepOrphans: settings?.bool("keep_orphans") ?? false,
                fragments: fragmentsByPlaneID[normalizedID(id)] ?? [],
                fallbackPolygon: fallbackPolygon,
                fromRules: item.bool("from_rules") ?? true,
                settings: planeSettings
            )
        }
        .sorted { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.priority < rhs.priority
        }
    }

    private static func loadPlaneFragments(
        from planesURL: URL?,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [String: [HorizontalPlaneFragment]] {
        BoardLoadTimer.measure("loadPlaneFragments") {
            guard let planesURL else {
                return [:]
            }

            do {
                let data = try BoardLoadTimer.measure("loadPlaneFragments: load data") {
                    try Data(contentsOf: planesURL)
                }
                let typedResult = try? BoardLoadTimer.measure("loadPlaneFragments: decode typed") {
                    try decodePlaneFragments(from: data)
                }
                if let result = typedResult {
                    return result
                }

                let json = try BoardLoadTimer.measure("loadPlaneFragments: load JSON fallback") {
                    let object = try JSONSerialization.jsonObject(with: data, options: [])
                    guard let dictionary = object as? JSONDictionary else {
                        throw HorizontalJSONError.invalidRoot(planesURL)
                    }
                    return dictionary
                }
                let result = BoardLoadTimer.measure("loadPlaneFragments: parse fragments fallback") {
                    json.dictionaryMap("planes").reduce(into: [String: [HorizontalPlaneFragment]]()) { result, item in
                        result[normalizedID(item.key)] = parsePlaneFragments(from: item.value)
                    }
                }
                return result
            } catch {
                diagnostics.append(HorizontalDiagnostic(message: "Could not load \(planesURL.lastPathComponent): \(error.localizedDescription). Showing plane source polygons."))
                return [:]
            }
        }
    }

    private static func decodePlaneFragments(from data: Data) throws -> [String: [HorizontalPlaneFragment]] {
        let document = try JSONDecoder().decode(PlaneFragmentsDocument.self, from: data)
        var result = [String: [HorizontalPlaneFragment]]()
        result.reserveCapacity(document.planes.count)

        for (planeID, plane) in document.planes {
            let fragments = plane.fragments.compactMap { fragment -> HorizontalPlaneFragment? in
                let paths = fragment.paths.filter { $0.count >= 3 }
                guard !paths.isEmpty else {
                    return nil
                }
                return HorizontalPlaneFragment(paths: paths, orphan: fragment.orphan)
            }
            result[normalizedID(planeID)] = fragments
        }
        return result
    }

    private static func parsePlaneFragments(from json: JSONDictionary) -> [HorizontalPlaneFragment] {
        let rawFragments = json.dictionaryArray("fragments")
        var result = [HorizontalPlaneFragment]()
        result.reserveCapacity(rawFragments.count)

        for fragment in rawFragments {
            let paths = parsePlanePaths(fragment["paths"])
            if !paths.isEmpty {
                result.append(HorizontalPlaneFragment(paths: paths, orphan: fragment.bool("orphan") ?? false))
            }
        }
        return result
    }

    private static func parsePlanePaths(_ value: Any?) -> [[HorizontalPoint]] {
        guard let rawPaths = value as? [Any] else {
            return []
        }

        var paths = [[HorizontalPoint]]()
        paths.reserveCapacity(rawPaths.count)

        for rawPath in rawPaths {
            guard let rawPoints = rawPath as? [Any], rawPoints.count >= 3 else {
                continue
            }

            var points = [HorizontalPoint]()
            points.reserveCapacity(rawPoints.count)
            for rawPoint in rawPoints {
                guard let coordinate = rawPoint as? [Any], coordinate.count >= 2 else {
                    continue
                }

                points.append(
                    HorizontalPoint(
                        x: JSONHelper.doubleValue(coordinate[0]),
                        y: JSONHelper.doubleValue(coordinate[1])
                    )
                )
            }

            if points.count >= 3 {
                paths.append(points)
            }
        }
        return paths
    }

    private static func parseKeepouts(
        from map: [String: JSONDictionary],
        polygonsByID: [String: HorizontalPolygon],
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [HorizontalKeepout] {
        var missingPolygonIDs = Set<String>()
        let keepouts = map.compactMap { id, item -> HorizontalKeepout? in
            guard let polygonID = item.string("polygon") else {
                return nil
            }

            guard let polygon = polygonsByID[normalizedID(polygonID)] else {
                missingPolygonIDs.insert(polygonID)
                return nil
            }

            return HorizontalKeepout(
                id: id,
                polygonID: polygonID,
                polygon: polygon,
                keepoutClass: item.string("keepout_class") ?? "",
                allCopperLayers: item.bool("all_cu_layers") ?? false,
                exposedCopperOnly: item.bool("exposed_cu_only") ?? false,
                copperPatchTypes: item["patch_types_cu"] as? [String] ?? []
            )
        }

        if !missingPolygonIDs.isEmpty {
            diagnostics.append(HorizontalDiagnostic(message: "Could not resolve \(missingPolygonIDs.count) keepout polygons."))
        }

        return keepouts
    }

    private static func parseBoardHoles(from map: [String: JSONDictionary], poolURL: URL?) -> [HorizontalHole] {
        map.flatMap { id, item -> [HorizontalHole] in
            guard let placement = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return []
            }

            if let padstackID = item.string("padstack"),
               let poolURL,
               let padstackJSON = loadPoolPadstack(padstackID, poolURL: poolURL) {
                let holes = padstackHoles(
                    padstackJSON,
                    idPrefix: id,
                    transform: placement,
                    parameterSet: item.dictionary("parameter_set")
                )
                return holes.enumerated().map { index, hole in
                    var hole = hole
                    hole.id = holes.count == 1 ? id : "\(id)/hole/\(index + 1)"
                    hole.netID = item.string("net").map(normalizedID)
                    return hole
                }
            }

            guard let diameter = holeDiameter(for: item, parameterSet: item.dictionary("parameter_set")) else {
                return []
            }

            let length = holeLength(for: item, parameterSet: item.dictionary("parameter_set"), diameter: diameter)
            return [HorizontalHole(
                id: id,
                position: placement.shift,
                diameter: diameter,
                length: length,
                shape: holeShape(for: item, length: length, diameter: diameter),
                angle: placement.angle,
                plated: item.bool("plated") ?? false
            )]
        }
    }

    private static func parseVias(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        viaDefinitions: [String: JSONDictionary],
        nInnerLayers: Int
    ) -> [HorizontalMarker] {
        map.compactMap { id, item in
            guard let junctionID = item.string("junction"),
                  let position = junctions[junctionID] else {
                return nil
            }

            let parameterSet = viaParameterSet(for: item, viaDefinitions: viaDefinitions)
            return HorizontalMarker(
                id: id,
                position: position,
                size: parameterSet?.double("via_diameter") ?? 450_000,
                holeSize: parameterSet?.double("hole_diameter"),
                layer: nil,
                connectedLayers: viaConnectedLayers(
                    for: item,
                    viaDefinitions: viaDefinitions,
                    nInnerLayers: nInnerLayers
                ),
                netID: item.string("net_set").map(normalizedID)
                    ?? item.string("net").map(normalizedID)
                    ?? junctionNetIDs[junctionID]
            )
        }
    }

    private static func parseViaHoles(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        viaDefinitions: [String: JSONDictionary]
    ) -> [HorizontalHole] {
        map.compactMap { id, item in
            let parameterSet = viaParameterSet(for: item, viaDefinitions: viaDefinitions)
            guard let junctionID = item.string("junction"),
                  let position = junctions[junctionID],
                  let diameter = parameterSet?.double("hole_diameter") else {
                return nil
            }

            return HorizontalHole(
                id: "\(id)/hole",
                position: position,
                diameter: diameter,
                length: diameter,
                shape: .round,
                plated: true,
                netID: item.string("net_set").map(normalizedID)
                    ?? item.string("net").map(normalizedID)
                    ?? junctionNetIDs[junctionID]
            )
        }
    }

    /// Harvests a usable via template: prefer a via definition (carries the
    /// pool padstack + default parameters), else clone an existing via's
    /// padstack + parameter_set. Deterministic (sorted) so repeated loads agree.
    private static func parseViaTemplate(
        viasMap: [String: JSONDictionary],
        viaDefinitions: [String: JSONDictionary]
    ) -> HorizontalBoardViaTemplate? {
        if let key = viaDefinitions.keys.sorted().first,
           let definition = viaDefinitions[key],
           let padstack = definition.string("padstack") {
            let parameters = definition.dictionary("parameters")
            return HorizontalBoardViaTemplate(
                padstackID: padstack,
                diameter: parameters?.double("via_diameter") ?? 500_000,
                holeDiameter: parameters?.double("hole_diameter") ?? 200_000
            )
        }
        for key in viasMap.keys.sorted() {
            guard let via = viasMap[key], let padstack = via.string("padstack") else {
                continue
            }
            let parameters = via.dictionary("parameter_set")
            return HorizontalBoardViaTemplate(
                padstackID: padstack,
                diameter: parameters?.double("via_diameter") ?? 500_000,
                holeDiameter: parameters?.double("hole_diameter") ?? 200_000
            )
        }
        return nil
    }

    private static func parseViaDefinitions(from rules: JSONDictionary?) -> [String: JSONDictionary] {
        rules?
            .dictionary("via_definitions")?
            .dictionaryMap("via_definitions")
            .reduce(into: [String: JSONDictionary]()) { result, item in
                result[normalizedID(item.key)] = item.value
            } ?? [:]
    }

    private static func viaParameterSet(
        for via: JSONDictionary,
        viaDefinitions: [String: JSONDictionary]
    ) -> JSONDictionary? {
        var parameters = via.string("definition")
            .map(normalizedID)
            .flatMap { viaDefinitions[$0]?.dictionary("parameters") } ?? [:]

        for (key, value) in via.dictionary("parameter_set") ?? [:] {
            parameters[key] = value
        }

        return parameters.isEmpty ? nil : parameters
    }

    private static func viaConnectedLayers(
        for via: JSONDictionary,
        viaDefinitions: [String: JSONDictionary],
        nInnerLayers: Int
    ) -> [Int] {
        let span = via.dictionary("span")
            ?? via.string("definition").map(normalizedID).flatMap { viaDefinitions[$0]?.dictionary("span") }
        let start = span?.int("start") ?? HorizontalBoardLayers.topCopper
        let end = span?.int("end") ?? HorizontalBoardLayers.bottomCopper
        let lower = min(start, end)
        let upper = max(start, end)
        return boardCopperLayers(nInnerLayers: nInnerLayers).filter { layer in
            lower <= layer && layer <= upper
        }
    }

    private static func boardCopperLayers(nInnerLayers: Int) -> [Int] {
        let innerLayers = nInnerLayers > 0 ? (1...nInnerLayers).map { -$0 } : []
        return [HorizontalBoardLayers.topCopper]
            + innerLayers
            + [HorizontalBoardLayers.bottomCopper]
    }

    private static func parseTexts(
        from map: [String: JSONDictionary],
        excluding excludedIDs: Set<String> = [],
        context: BoardTextContext = BoardTextContext()
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard !excludedIDs.contains(normalizedID(id)) else {
                return nil
            }

            return parseAbsoluteText(id: id, item: item, context: context)
        }
    }

    private static func parseAbsoluteText(
        id: String,
        item: JSONDictionary,
        context: BoardTextContext
    ) -> HorizontalText? {
        guard let placement = HorizontalPlacementTransform(json: item.dictionary("placement")),
              let text = item.string("text") else {
            return nil
        }

        let substitutedText = substituteText(text, context: context)
        guard !substitutedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let textPlacement = HorizontalPlacementTransform.identity.accumulatedText(with: placement)
        return HorizontalText(
            id: id,
            text: substitutedText,
            position: textPlacement.shift,
            size: item.double("size") ?? 1_000_000,
            layer: item.int("layer"),
            angle: textPlacement.angle,
            mirrored: textPlacement.mirrored,
            width: item.double("width") ?? 0,
            origin: item.horizonTextOrigin(),
            font: item.horizonTextFont(),
            allowUpsideDown: item.bool("allow_upside_down") ?? false
        )
    }

    private static func parsePackageGeometry(
        from packageMap: [String: JSONDictionary],
        poolURL: URL?,
        componentInfo: [String: BoardComponentInfo],
        boardTexts: [String: JSONDictionary],
        titleValues: [String: String],
        nInnerLayers: Int,
        boardParameterSet: JSONDictionary,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> HorizontalPackageGeometry {
        guard !packageMap.isEmpty else {
            return .empty
        }

        guard let poolURL else {
            return .empty
        }

        guard !componentInfo.isEmpty else {
            return .empty
        }

        var result = HorizontalPackageGeometry.empty
        let boardTextsByID = BoardLoadTimer.measure("package geometry: index board texts") {
            boardTexts.reduce(into: [String: JSONDictionary]()) { result, item in
                result[normalizedID(item.key)] = item.value
            }
        }
        var packageCache = [String: JSONDictionary]()
        var padstackCache = [String: JSONDictionary]()
        var missingPadstackCache = Set<String>()
        var expandedPadstackCache = [String: HorizontalExpandedPadstack]()
        var padstackShapeTemplateCache = [String: PadstackShapeGeometry]()
        var partPadGatePinPathCache = [String: [String: String]]()
        var missingPartPadGatePinPaths = Set<String>()
        var partPackageIDCache = [String: String]()
        var missingPartPackageIDs = Set<String>()
        var missingPackageIDs = Set<String>()

        for (boardPackageID, boardPackage) in packageMap {
            guard let componentID = boardPackage.string("component").map(normalizedID),
                  let component = componentInfo[componentID],
                  let partID = component.partID else {
                continue
            }

            guard let placement = HorizontalPlacementTransform(
                json: boardPackage.dictionary("placement"),
                mirrorOverride: boardPackage.bool("flip")
            ) else {
                continue
            }

            guard let packageSelection = BoardLoadTimer.measure("package geometry: resolve package", {
                resolvedBoardPackage(
                    for: partID,
                    boardPackage: boardPackage,
                    poolURL: poolURL,
                    cache: &packageCache,
                    partPackageIDCache: &partPackageIDCache,
                    missingPartPackageIDs: &missingPartPackageIDs
                )
            }) else {
                if let packageID = boardPackage.string("alternate_package").map(normalizedID)
                    ?? resolvePackageID(
                        for: partID,
                        poolURL: poolURL,
                        cache: &partPackageIDCache,
                        missingCache: &missingPartPackageIDs
                    ) {
                    missingPackageIDs.insert(packageID)
                }
                continue
            }

            result.append(
                BoardLoadTimer.measure("package geometry: parse single package") {
                    parseSinglePackageGeometry(
                        boardPackageID: boardPackageID,
                        packageID: packageSelection.packageID,
                        boardPackage: boardPackage,
                        packageJSON: packageSelection.packageJSON,
                        packageTransform: placement,
                        component: component,
                        boardTexts: boardTextsByID,
                        titleValues: titleValues,
                        poolURL: poolURL,
                        nInnerLayers: nInnerLayers,
                        boardParameterSet: boardParameterSet,
                        padstackCache: &padstackCache,
                        missingPadstackCache: &missingPadstackCache,
                        expandedPadstackCache: &expandedPadstackCache,
                        padstackShapeTemplateCache: &padstackShapeTemplateCache,
                        partPadGatePinPathCache: &partPadGatePinPathCache,
                        missingPartPadGatePinPaths: &missingPartPadGatePinPaths
                    )
                }
            )
        }

        if !missingPackageIDs.isEmpty {
            diagnostics.append(HorizontalDiagnostic(message: "Could not resolve \(missingPackageIDs.count) package footprint files from the project pool."))
        }

        return result
    }

    private static func loadBlockMetadata(
        from blockURL: URL?,
        poolURL: URL?,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> BoardBlockMetadata {
        guard let blockURL else {
            return BoardBlockMetadata()
        }

        do {
            return try parseBlockMetadata(from: blockURL, poolURL: poolURL)
        } catch {
            diagnostics.append(HorizontalDiagnostic(message: "Could not load board metadata from \(blockURL.lastPathComponent): \(error.localizedDescription)"))
            return BoardBlockMetadata()
        }
    }

    private static func parseBlockMetadata(from blockURL: URL, poolURL: URL?) throws -> BoardBlockMetadata {
        let json = try JSONHelper.loadDictionary(from: blockURL)
        var packageCache = [String: JSONDictionary]()
        var partDetailsCache = [String: PartDetails]()
        var missingPartDetails = Set<String>()
        let components = json.dictionaryMap("components").reduce(into: [String: BoardComponentInfo]()) { result, item in
            let value = item.value
            let componentID = normalizedID(item.key)
            let partID = value.string("part").map(normalizedID)
            let partDetails = partID.flatMap { partID in
                poolURL.flatMap {
                    loadPartDetails(
                        partID,
                        poolURL: $0,
                        packageCache: &packageCache,
                        detailsCache: &partDetailsCache,
                        missingDetails: &missingPartDetails
                    )
                }
            }
            let componentValue = partDetails?.value ?? value.string("value") ?? ""
            let componentInfo = BoardComponentInfo(
                partID: partID,
                refdes: value.string("refdes") ?? "",
                value: componentValue,
                noPopulate: value.bool("nopopulate") ?? false,
                connections: parseConnectionNetIDs(from: value.dictionaryMap("connections")),
                details: HorizontalComponentDetails(
                    componentID: componentID,
                    refdes: value.string("refdes") ?? "",
                    value: componentValue,
                    partID: partID,
                    noPopulate: value.bool("nopopulate") ?? false,
                    mpn: partDetails?.mpn,
                    manufacturer: partDetails?.manufacturer,
                    packageName: partDetails?.packageName,
                    description: partDetails?.description,
                    datasheet: partDetails?.datasheet
                )
            )
            result[componentID] = componentInfo
        }
        let netClassNames = parseNetClassNames(from: json.dictionaryMap("net_classes"))
        let netDetails = json.dictionaryMap("nets").reduce(into: [String: HorizontalNetDetails]()) { result, item in
            let netID = normalizedID(item.key)
            let netClassID = item.value.string("net_class").map(normalizedID)
            result[netID] = HorizontalNetDetails(
                id: netID,
                name: item.value.string("name") ?? String(item.key.prefix(8)),
                netClassID: netClassID,
                netClassName: netClassID.flatMap { netClassNames[$0] },
                isPower: item.value.bool("is_power") ?? false,
                isPort: item.value.bool("is_port") ?? false,
                portDirection: item.value.string("port_direction"),
                powerSymbolStyle: item.value.string("power_symbol_style")
            )
        }

        return BoardBlockMetadata(
            components: components,
            netDetails: netDetails,
            titleValues: parseProjectMeta(from: json.dictionary("project_meta"))
        )
    }

    private static func parseProjectMeta(from json: JSONDictionary?) -> [String: String] {
        guard let json else {
            return [:]
        }

        return json.reduce(into: [String: String]()) { result, item in
            guard let value = stringValue(item.value) else {
                return
            }
            result[item.key] = value
        }
    }

    private static func parseNetClassNames(from map: [String: JSONDictionary]) -> [String: String] {
        map.reduce(into: [String: String]()) { result, item in
            if let name = item.value.string("name").flatMap(nonEmpty) {
                result[normalizedID(item.key)] = name
            }
        }
    }

    private static func poolAttribute(_ value: Any?, inherited: String? = nil) -> (value: String?, inherited: Bool) {
        if let value = value as? [Any], value.count >= 2 {
            let inherits = value[0] as? Bool == true
            if inherits {
                return (inherited, true)
            }
            return (nonEmpty(stringValue(value[1])), false)
        }

        return (nonEmpty(value.flatMap(stringValue)), false)
    }

    private static func poolAttributeString(_ value: Any?, inherited: String? = nil) -> String? {
        poolAttribute(value, inherited: inherited).value
    }

    private static func parseConnectionNetIDs(from map: [String: JSONDictionary]) -> [String: String] {
        map.reduce(into: [String: String]()) { result, connection in
            if let netID = connection.value.string("net").map(normalizedID) {
                result[normalizedUUIDPath(connection.key)] = netID
            }
        }
    }

    private static let zeroUUID = "00000000-0000-0000-0000-000000000000"
    private static let legacyModelUUID = "96c366ee-a963-41a0-9cc8-54c646979695"

    private static func resolvedPackage3DModel(
        for boardPackage: JSONDictionary,
        component: BoardComponentInfo?,
        poolURL: URL,
        packageCache: inout [String: JSONDictionary],
        partPackageIDCache: inout [String: String],
        missingPartPackageIDs: inout Set<String>,
        packageModelMapCache: inout [String: [String: JSONDictionary]],
        partModelIDCache: inout [String: String],
        missingPartModelIDs: inout Set<String>,
        package3DModelCache: inout [String: HorizontalPackage3DModel],
        missingPackage3DModels: inout Set<String>,
        modelFileURLCache: inout [String: URL],
        missingModelFileURLs: inout Set<String>
    ) -> (packageID: String, modelID: String, model: HorizontalPackage3DModel)? {
        guard let component,
              let partID = component.partID else {
            return nil
        }

        let packageID = boardPackage.string("alternate_package").map(normalizedID)
            ?? resolvePackageID(
                for: partID,
                poolURL: poolURL,
                cache: &partPackageIDCache,
                missingCache: &missingPartPackageIDs
            )
        guard let packageID,
              let packageJSON = loadPackage(packageID, poolURL: poolURL, cache: &packageCache) else {
            return nil
        }

        let modelMap = BoardLoadTimer.measure("placements: package 3D model map") {
            package3DModelMap(
                for: packageID,
                packageJSON: packageJSON,
                cache: &packageModelMapCache
            )
        }
        guard !modelMap.isEmpty else {
            return nil
        }

        let alternateSingleModelID: String?
        if boardPackage.string("alternate_package") != nil,
           modelMap.count == 1 {
            alternateSingleModelID = modelMap.keys.first
        } else {
            alternateSingleModelID = nil
        }

        let partModelID = BoardLoadTimer.measure("placements: resolve part model") {
            resolvePartModelID(
                for: partID,
                poolURL: poolURL,
                cache: &partModelIDCache,
                missingCache: &missingPartModelIDs
            )
        }
        let candidateModelIDs = [
            boardPackage.string("model").map(normalizedID),
            alternateSingleModelID,
            partModelID,
            packageJSON.string("default_model").map(normalizedID),
            modelMap.keys.min()
        ]

        for candidateModelID in candidateModelIDs {
            guard let modelID = candidateModelID,
                  !isZeroUUID(modelID),
                  let modelJSON = modelMap[modelID],
                  let model = BoardLoadTimer.measure("placements: parse 3D model", {
                    parsePackage3DModel(
                        modelID,
                        from: modelJSON,
                        poolURL: poolURL,
                        cacheKey: "\(packageID)/\(modelID)",
                        modelCache: &package3DModelCache,
                        missingModelCache: &missingPackage3DModels,
                        modelFileURLCache: &modelFileURLCache,
                        missingModelFileURLs: &missingModelFileURLs
                    )
                  }) else {
                continue
            }
            return (packageID, modelID, model)
        }

        return nil
    }

    private static func package3DModelMap(
        for packageID: String,
        packageJSON: JSONDictionary,
        cache: inout [String: [String: JSONDictionary]]
    ) -> [String: JSONDictionary] {
        let packageID = normalizedID(packageID)
        if let cached = cache[packageID] {
            return cached
        }

        let modelMap = package3DModelMap(from: packageJSON)
        cache[packageID] = modelMap
        return modelMap
    }

    private static func package3DModelMap(from packageJSON: JSONDictionary) -> [String: JSONDictionary] {
        var modelMap = packageJSON.dictionaryMap("models").reduce(into: [String: JSONDictionary]()) { result, item in
            result[normalizedID(item.key)] = item.value
        }

        if modelMap.isEmpty,
           let legacyFilename = packageJSON.string("model_filename").flatMap(nonEmpty) {
            modelMap[legacyModelUUID] = [
                "filename": legacyFilename,
                "x": 0,
                "y": 0,
                "z": 0,
                "roll": 0,
                "pitch": 0,
                "yaw": 0
            ]
        }

        return modelMap
    }

    private static func parsePackage3DModel(
        _ modelID: String,
        from modelJSON: JSONDictionary,
        poolURL: URL,
        cacheKey: String,
        modelCache: inout [String: HorizontalPackage3DModel],
        missingModelCache: inout Set<String>,
        modelFileURLCache: inout [String: URL],
        missingModelFileURLs: inout Set<String>
    ) -> HorizontalPackage3DModel? {
        if let cached = modelCache[cacheKey] {
            return cached
        }
        guard !missingModelCache.contains(cacheKey) else {
            return nil
        }

        guard let filename = modelJSON.string("filename").flatMap(nonEmpty),
              let fileURL = modelFileURL(
                filename: filename,
                poolURL: poolURL,
                cache: &modelFileURLCache,
                missingCache: &missingModelFileURLs
              ) else {
            missingModelCache.insert(cacheKey)
            return nil
        }

        let model = HorizontalPackage3DModel(
            id: modelID,
            filename: filename,
            fileURL: fileURL,
            x: modelJSON.double("x") ?? 0,
            y: modelJSON.double("y") ?? 0,
            z: modelJSON.double("z") ?? 0,
            roll: modelJSON.int("roll") ?? 0,
            pitch: modelJSON.int("pitch") ?? 0,
            yaw: modelJSON.int("yaw") ?? 0,
            heightTop: modelJSON.double("height_top") ?? 0,
            heightBottom: modelJSON.double("height_bot") ?? 0
        )
        modelCache[cacheKey] = model
        return model
    }

    private static func modelFileURL(
        filename: String,
        poolURL: URL,
        cache: inout [String: URL],
        missingCache: inout Set<String>
    ) -> URL? {
        let cacheKey = "\(poolURL.path)\u{0}\(filename)"
        if let cached = cache[cacheKey] {
            return cached
        }
        guard !missingCache.contains(cacheKey) else {
            return nil
        }

        guard let fileURL = modelFileURL(filename: filename, poolURL: poolURL) else {
            missingCache.insert(cacheKey)
            return nil
        }

        cache[cacheKey] = fileURL
        return fileURL
    }

    private static func modelFileURL(filename: String, poolURL: URL) -> URL? {
        let candidateURL: URL
        if filename.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: filename)
        } else {
            candidateURL = filename
                .split(separator: "/")
                .reduce(poolURL) { url, component in
                    url.appendingPathComponent(String(component))
                }
        }

        return existingFileURL(candidateURL)
    }

    private static func resolvePartModelID(
        for partID: String,
        poolURL: URL,
        visited: Set<String> = []
    ) -> String? {
        var cache = [String: String]()
        var missingCache = Set<String>()
        return resolvePartModelID(
            for: partID,
            poolURL: poolURL,
            cache: &cache,
            missingCache: &missingCache,
            visited: visited
        )
    }

    private static func resolvePartModelID(
        for partID: String,
        poolURL: URL,
        cache: inout [String: String],
        missingCache: inout Set<String>,
        visited: Set<String> = []
    ) -> String? {
        let partID = normalizedID(partID)
        if let cached = cache[partID] {
            return cached
        }
        guard !missingCache.contains(partID),
              !visited.contains(partID),
              let partJSON = loadPart(partID, poolURL: poolURL) else {
            missingCache.insert(partID)
            return nil
        }

        if partJSON.bool("inherit_model") ?? true,
           let basePartID = partJSON.string("base") {
            guard let modelID = resolvePartModelID(
                for: basePartID,
                poolURL: poolURL,
                cache: &cache,
                missingCache: &missingCache,
                visited: visited.union([partID])
            ) else {
                missingCache.insert(partID)
                return nil
            }
            cache[partID] = modelID
            return modelID
        }

        guard let modelID = partJSON.string("model").map(normalizedID) else {
            missingCache.insert(partID)
            return nil
        }

        cache[partID] = modelID
        return modelID
    }

    private static func isZeroUUID(_ id: String) -> Bool {
        normalizedID(id) == zeroUUID
    }

    private static func loadPartPadNetIDs(
        partID: String,
        component: BoardComponentInfo,
        poolURL: URL,
        cache: inout [String: [String: String]],
        missingCache: inout Set<String>
    ) -> [String: String] {
        guard !component.connections.isEmpty else {
            return [:]
        }

        let padGatePinPaths = loadPartPadGatePinPaths(
            partID: partID,
            poolURL: poolURL,
            cache: &cache,
            missingCache: &missingCache
        )

        return padGatePinPaths.reduce(into: [String: String]()) { result, item in
            if let netID = component.connections[item.value] {
                result[item.key] = netID
            }
        }
    }

    private static func loadPartPadGatePinPaths(
        partID: String,
        poolURL: URL,
        cache: inout [String: [String: String]],
        missingCache: inout Set<String>,
        visited: Set<String> = []
    ) -> [String: String] {
        let partID = normalizedID(partID)
        if let cached = cache[partID] {
            return cached
        }
        guard !missingCache.contains(partID) else {
            return [:]
        }
        guard !visited.contains(partID) else {
            return [:]
        }

        guard let partJSON = loadPart(partID, poolURL: poolURL) else {
            missingCache.insert(partID)
            return [:]
        }

        let basePartID = partJSON.string("base")
        var result = basePartID.map {
            loadPartPadGatePinPaths(
                partID: $0,
                poolURL: poolURL,
                cache: &cache,
                missingCache: &missingCache,
                visited: visited.union([partID])
            )
        } ?? [:]

        if basePartID == nil {
            partJSON.dictionaryMap("pad_map").forEach { item in
                guard let gateID = item.value.string("gate"),
                      let pinID = item.value.string("pin") else {
                    return
                }

                let padName = item.value.string("pad") ?? item.key
                let gatePinPath = normalizedUUIDPath("\(gateID)/\(pinID)")
                result[normalizedID(padName)] = gatePinPath
            }
        }

        cache[partID] = result
        return result
    }

    private static func loadPart(_ partID: String, poolURL: URL) -> JSONDictionary? {
        let candidatePartURL = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(normalizedID(partID)).json")

        guard let partURL = existingFileURL(candidatePartURL) else {
            return nil
        }

        return try? JSONHelper.loadDictionary(from: partURL)
    }

    private static func loadPartDetails(
        _ partID: String,
        poolURL: URL,
        packageCache: inout [String: JSONDictionary],
        detailsCache: inout [String: PartDetails],
        missingDetails: inout Set<String>
    ) -> PartDetails? {
        let partID = normalizedID(partID)
        if let cached = detailsCache[partID] {
            return cached
        }
        guard !missingDetails.contains(partID),
              let partJSON = loadPart(partID, poolURL: poolURL) else {
            missingDetails.insert(partID)
            return nil
        }

        let baseDetails = partJSON.string("base").flatMap {
            loadPartDetails(
                $0,
                poolURL: poolURL,
                packageCache: &packageCache,
                detailsCache: &detailsCache,
                missingDetails: &missingDetails
            )
        }
        let packageID = baseDetails == nil ? partJSON.string("package").map(normalizedID) : nil
        let packageName = packageID
            .flatMap { loadPackage($0, poolURL: poolURL, cache: &packageCache) }?
            .string("name")
            ?? baseDetails?.packageName
        let mpn = poolAttributeString(partJSON["MPN"], inherited: baseDetails?.mpn)
        let valueAttribute = poolAttribute(partJSON["value"], inherited: baseDetails?.value)

        let details = PartDetails(
            value: resolvedPartValue(
                valueAttribute.value,
                inheritedFromBase: valueAttribute.inherited,
                mpn: mpn,
                baseDetails: baseDetails
            ),
            mpn: mpn,
            manufacturer: poolAttributeString(partJSON["manufacturer"], inherited: baseDetails?.manufacturer),
            packageName: packageName,
            description: poolAttributeString(partJSON["description"], inherited: baseDetails?.description),
            datasheet: poolAttributeString(partJSON["datasheet"], inherited: baseDetails?.datasheet)
        )
        detailsCache[partID] = details
        return details
    }

    private static func resolvedPartValue(
        _ value: String?,
        inheritedFromBase: Bool,
        mpn: String?,
        baseDetails: PartDetails?
    ) -> String? {
        if inheritedFromBase,
           let value = nonEmpty(value),
           let baseMPN = nonEmpty(baseDetails?.mpn),
           value == baseMPN,
           let mpn = nonEmpty(mpn),
           mpn != baseMPN {
            return mpn
        }

        return nonEmpty(value) ?? nonEmpty(mpn)
    }

    private static func resolvePackageID(
        for partID: String,
        poolURL: URL
    ) -> String? {
        var cache = [String: String]()
        var missingCache = Set<String>()
        return resolvePackageID(
            for: partID,
            poolURL: poolURL,
            cache: &cache,
            missingCache: &missingCache
        )
    }

    private static func resolvePackageID(
        for partID: String,
        poolURL: URL,
        cache: inout [String: String],
        missingCache: inout Set<String>,
        visited: Set<String> = []
    ) -> String? {
        let partID = normalizedID(partID)
        if let cached = cache[partID] {
            return cached
        }
        guard !missingCache.contains(partID),
              !visited.contains(partID) else {
            return nil
        }

        let candidatePartURL = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(partID).json")

        guard let partURL = existingFileURL(candidatePartURL) else {
            missingCache.insert(partID)
            return nil
        }

        guard let partJSON = try? JSONHelper.loadDictionary(from: partURL) else {
            missingCache.insert(partID)
            return nil
        }

        if let basePartID = partJSON.string("base") {
            guard let packageID = resolvePackageID(
                for: normalizedID(basePartID),
                poolURL: poolURL,
                cache: &cache,
                missingCache: &missingCache,
                visited: visited.union([normalizedID(partID)])
            ) else {
                missingCache.insert(partID)
                return nil
            }
            cache[partID] = packageID
            return packageID
        }

        if let packageID = partJSON.string("package") {
            let packageID = normalizedID(packageID)
            cache[partID] = packageID
            return packageID
        }

        missingCache.insert(partID)
        return nil
    }

    private static func resolvedBoardPackage(
        for partID: String,
        boardPackage: JSONDictionary,
        poolURL: URL,
        cache: inout [String: JSONDictionary],
        partPackageIDCache: inout [String: String],
        missingPartPackageIDs: inout Set<String>
    ) -> (packageID: String, packageJSON: JSONDictionary)? {
        guard let primaryPackageID = resolvePackageID(
                for: partID,
                poolURL: poolURL,
                cache: &partPackageIDCache,
                missingCache: &missingPartPackageIDs
              ),
              let primaryPackageJSON = loadPackage(primaryPackageID, poolURL: poolURL, cache: &cache) else {
            return nil
        }

        guard let alternatePackageID = boardPackage.string("alternate_package").map(normalizedID) else {
            return (primaryPackageID, primaryPackageJSON)
        }

        guard let alternatePackageJSON = loadPackage(alternatePackageID, poolURL: poolURL, cache: &cache),
              let remappedPackageJSON = remappedAlternatePackage(
                primaryPackageID: primaryPackageID,
                primaryPackageJSON: primaryPackageJSON,
                alternatePackageID: alternatePackageID,
                alternatePackageJSON: alternatePackageJSON,
                poolURL: poolURL
              ) else {
            return (primaryPackageID, primaryPackageJSON)
        }

        return (alternatePackageID, remappedPackageJSON)
    }

    private static func remappedAlternatePackage(
        primaryPackageID: String,
        primaryPackageJSON: JSONDictionary,
        alternatePackageID: String,
        alternatePackageJSON: JSONDictionary,
        poolURL: URL
    ) -> JSONDictionary? {
        let primaryPads = primaryPackageJSON.dictionaryMap("pads")
        let alternatePads = alternatePackageJSON.dictionaryMap("pads")
        var primaryPadIDsByName = [String: String]()
        var padstackMechanical = [String: Bool]()

        for (padID, pad) in primaryPads {
            guard !isMechanicalPad(pad, packageID: primaryPackageID, poolURL: poolURL, cache: &padstackMechanical) else {
                continue
            }
            guard let padName = pad.string("name").flatMap(nonEmpty),
                  primaryPadIDsByName[padName] == nil else {
                return nil
            }
            primaryPadIDsByName[padName] = normalizedID(padID)
        }

        var alternatePadNames = Set<String>()
        var remappedPads = [String: Any]()

        for (padID, pad) in alternatePads {
            if isMechanicalPad(pad, packageID: alternatePackageID, poolURL: poolURL, cache: &padstackMechanical) {
                remappedPads[normalizedID(padID)] = pad
                continue
            }

            guard let padName = pad.string("name").flatMap(nonEmpty),
                  alternatePadNames.insert(padName).inserted,
                  let primaryPadID = primaryPadIDsByName[padName] else {
                return nil
            }

            remappedPads[primaryPadID] = pad
        }

        guard Set(primaryPadIDsByName.keys) == alternatePadNames else {
            return nil
        }

        var packageJSON = alternatePackageJSON
        packageJSON["pads"] = remappedPads
        return packageJSON
    }

    private static func isMechanicalPad(
        _ pad: JSONDictionary,
        packageID: String,
        poolURL: URL,
        cache: inout [String: Bool]
    ) -> Bool {
        guard let padstackID = pad.string("padstack").map(normalizedID) else {
            return false
        }

        let cacheKey = "\(normalizedID(packageID))/\(padstackID)"
        if let cached = cache[cacheKey] {
            return cached
        }

        let isMechanical = loadPadstack(padstackID, packageID: packageID, poolURL: poolURL)?
            .string("padstack_type") == "mechanical"
        cache[cacheKey] = isMechanical
        return isMechanical
    }

    private static func boardRuleParameterSet(from rules: JSONDictionary?) -> JSONDictionary {
        let parameters = rules?.dictionary("parameters") ?? [:]
        return [
            "courtyard_expansion": parameters.int("courtyard_expansion") ?? 250_000,
            "paste_mask_contraction": parameters.int("paste_mask_contraction") ?? 0,
            "solder_mask_expansion": parameters.int("solder_mask_expansion") ?? 100_000,
            "via_solder_mask_expansion": parameters.int("via_solder_mask_expansion") ?? 100_000,
            "hole_solder_mask_expansion": parameters.int("hole_solder_mask_expansion") ?? 100_000
        ]
    }

    private static func resolvedPackageParameterSet(
        packageJSON: JSONDictionary,
        boardParameterSet: JSONDictionary
    ) -> JSONDictionary {
        var parameters = packageJSON.dictionary("parameter_set") ?? [:]
        let fixed = stringSet(packageJSON["parameters_fixed"])
        copyParameters(
            from: boardParameterSet,
            to: &parameters,
            keys: [
                "courtyard_expansion",
                "solder_mask_expansion",
                "paste_mask_contraction",
                "hole_solder_mask_expansion"
            ],
            fixed: fixed
        )
        return parameters
    }

    private static func resolvedPadParameterSet(
        padJSON: JSONDictionary,
        packageParameterSet: JSONDictionary
    ) -> JSONDictionary {
        var parameters = padJSON.dictionary("parameter_set") ?? [:]
        copyParameters(
            from: packageParameterSet,
            to: &parameters,
            keys: [
                "solder_mask_expansion",
                "paste_mask_contraction",
                "hole_solder_mask_expansion"
            ],
            fixed: stringSet(padJSON["parameters_fixed"])
        )
        return parameters
    }

    private static func resolvedPadstackParameterSet(
        padstackJSON: JSONDictionary,
        padParameterSet: JSONDictionary
    ) -> JSONDictionary {
        var parameters = padstackJSON.dictionary("parameter_set") ?? [:]
        copyParameters(
            from: padParameterSet,
            to: &parameters,
            keys: [
                "pad_height",
                "pad_width",
                "pad_diameter",
                "solder_mask_expansion",
                "paste_mask_contraction",
                "hole_diameter",
                "hole_length",
                "courtyard_expansion",
                "via_diameter",
                "hole_solder_mask_expansion",
                "via_solder_mask_expansion",
                "hole_annular_ring",
                "corner_radius"
            ],
            fixed: []
        )
        return parameters
    }

    private static func copyParameters(
        from source: JSONDictionary,
        to destination: inout JSONDictionary,
        keys: [String],
        fixed: Set<String>
    ) {
        for key in keys where !fixed.contains(key) {
            if let value = source[key] {
                destination[key] = value
            }
        }
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        Set((value as? [Any])?.compactMap { $0 as? String } ?? [])
    }

    private static func loadPackage(
        _ packageID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let packageID = normalizedID(packageID)
        if let cached = cache[packageID] {
            return cached
        }

        guard let packageDirectory = packageDirectory(for: packageID, poolURL: poolURL) else {
            return nil
        }

        let packageURL = packageDirectory.appendingPathComponent("package.json")

        guard let packageJSON = try? JSONHelper.loadDictionary(from: packageURL) else {
            return nil
        }

        cache[packageID] = packageJSON
        return packageJSON
    }

    private static func loadDecal(
        _ decalID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let decalID = normalizedID(decalID)
        if let cached = cache[decalID] {
            return cached
        }

        let decalURL = poolURL
            .appendingPathComponent("decals")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(decalID).json")

        guard let existingURL = existingFileURL(decalURL),
              let decalJSON = try? JSONHelper.loadDictionary(from: existingURL) else {
            return nil
        }

        cache[decalID] = decalJSON
        return decalJSON
    }

    private static func parseSinglePackageGeometry(
        boardPackageID: String,
        packageID: String,
        boardPackage: JSONDictionary,
        packageJSON: JSONDictionary,
        packageTransform: HorizontalPlacementTransform,
        component: BoardComponentInfo,
        boardTexts: [String: JSONDictionary],
        titleValues: [String: String],
        poolURL: URL,
        nInnerLayers: Int,
        boardParameterSet: JSONDictionary,
        padstackCache: inout [String: JSONDictionary],
        missingPadstackCache: inout Set<String>,
        expandedPadstackCache: inout [String: HorizontalExpandedPadstack],
        padstackShapeTemplateCache: inout [String: PadstackShapeGeometry],
        partPadGatePinPathCache: inout [String: [String: String]],
        missingPartPadGatePinPaths: inout Set<String>
    ) -> HorizontalPackageGeometry {
        var expandedPackageJSON = packageJSON
        let packageParameterSet = BoardLoadTimer.measure("package geometry: resolve package parameters") {
            resolvedPackageParameterSet(
                packageJSON: packageJSON,
                boardParameterSet: boardParameterSet
            )
        }
        BoardLoadTimer.measure("package geometry: apply package parameter program") {
            HorizontalParameterProgramEvaluator.apply(
                program: expandedPackageJSON.string("parameter_program"),
                parameters: packageParameterSet,
                to: &expandedPackageJSON
            )
        }

        let localJunctions = BoardLoadTimer.measure("package geometry: parse package junctions") {
            parseJunctions(from: expandedPackageJSON)
        }
        let transformedJunctions = BoardLoadTimer.measure("package geometry: transform package junctions") {
            localJunctions.mapValues(packageTransform.applying)
        }
        let padNetIDsByName = BoardLoadTimer.measure("package geometry: resolve pad net map") {
            component.partID.map {
                loadPartPadNetIDs(
                    partID: $0,
                    component: component,
                    poolURL: poolURL,
                    cache: &partPadGatePinPathCache,
                    missingCache: &missingPartPadGatePinPaths
                )
            } ?? [:]
        }
        let packagePads = BoardLoadTimer.measure("package geometry: parse package pads") {
            parsePackagePads(
                from: expandedPackageJSON.dictionaryMap("pads"),
                boardPackageID: boardPackageID,
                packageID: packageID,
                packageTransform: packageTransform,
                padNetIDsByName: padNetIDsByName,
                poolURL: poolURL,
                nInnerLayers: nInnerLayers,
                packageParameterSet: packageParameterSet,
                padstackCache: &padstackCache,
                missingPadstackCache: &missingPadstackCache,
                expandedPadstackCache: &expandedPadstackCache,
                padstackShapeTemplateCache: &padstackShapeTemplateCache
            )
        }
        // omit_silkscreen / omit_outline are NOT filtered at load — all package
        // geometry (and silk text) is loaded and the metal render gates it by the
        // package's flags so the toggles work live. The loader still drops the
        // package's own silk *text* for a `smashed` package (its editable
        // from-smash copies render instead); omit_silkscreen additionally hides
        // non-smashed silk text at render time.
        return HorizontalPackageGeometry(
            pads: packagePads.pads,
            polygons: BoardLoadTimer.measure("package geometry: parse package polygons") {
                parsePackagePolygons(
                    from: expandedPackageJSON.dictionaryMap("polygons"),
                    boardPackageID: boardPackageID,
                    packageTransform: packageTransform,
                    omitSilkscreen: false,
                    omitOutline: false,
                    nInnerLayers: nInnerLayers
                )
            },
            lines: BoardLoadTimer.measure("package geometry: parse package lines") {
                parsePackageLines(
                    from: expandedPackageJSON.dictionaryMap("lines"),
                    boardPackageID: boardPackageID,
                    junctions: transformedJunctions,
                    flipped: packageTransform.mirrored,
                    omitSilkscreen: false,
                    nInnerLayers: nInnerLayers
                )
            },
            arcs: BoardLoadTimer.measure("package geometry: parse package arcs") {
                parsePackageArcs(
                    from: expandedPackageJSON.dictionaryMap("arcs"),
                    boardPackageID: boardPackageID,
                    junctions: transformedJunctions,
                    flipped: packageTransform.mirrored,
                    omitSilkscreen: false,
                    nInnerLayers: nInnerLayers
                )
            },
            texts: BoardLoadTimer.measure("package geometry: parse package texts") {
                packageTexts(
                    from: boardPackage,
                    boardPackageID: boardPackageID,
                    packageJSON: expandedPackageJSON,
                    packageTransform: packageTransform,
                    component: component,
                    boardTexts: boardTexts,
                    titleValues: titleValues,
                    omitSilkscreen: false,
                    nInnerLayers: nInnerLayers
                )
            },
            holes: packagePads.holes,
            padPositions: packagePads.positions,
            padNetIDs: packagePads.netIDs
        )
    }

    private static func parsePackagePolygons(
        from map: [String: JSONDictionary],
        boardPackageID: String,
        packageTransform: HorizontalPlacementTransform,
        omitSilkscreen: Bool,
        omitOutline: Bool,
        nInnerLayers: Int
    ) -> [HorizontalPolygon] {
        map.compactMap { id, item in
            let layer = packageLayer(item.int("layer"), flipped: packageTransform.mirrored, nInnerLayers: nInnerLayers)
            guard !(omitSilkscreen && isBoardSilkscreenLayer(layer)),
                  !(omitOutline && isBoardOutlineLayer(layer)) else {
                return nil
            }

            let vertices = parsePolygonVertexList(
                from: item.dictionaryArray("vertices"),
                transform: packageTransform.applying,
                flipsArcReverse: packageTransform.mirrored
            )

            guard vertices.count >= 2 else {
                return nil
            }

            return HorizontalPolygon(
                id: "\(boardPackageID)/polygon/\(id)",
                polygonVertices: vertices,
                layer: layer
            )
        }
    }

    private static func parsePackageLines(
        from map: [String: JSONDictionary],
        boardPackageID: String,
        junctions: [String: HorizontalPoint],
        flipped: Bool,
        omitSilkscreen: Bool,
        nInnerLayers: Int
    ) -> [HorizontalSegment] {
        map.compactMap { id, item -> HorizontalSegment? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }
            let layer = packageLayer(item.int("layer"), flipped: flipped, nInnerLayers: nInnerLayers)
            guard !(omitSilkscreen && isBoardSilkscreenLayer(layer)) else {
                return nil
            }

            return HorizontalSegment(
                id: "\(boardPackageID)/line/\(id)",
                from: from,
                to: to,
                width: item.double("width") ?? 0,
                layer: layer
            )
        }
    }

    private static func parsePackageArcs(
        from map: [String: JSONDictionary],
        boardPackageID: String,
        junctions: [String: HorizontalPoint],
        flipped: Bool,
        omitSilkscreen: Bool,
        nInnerLayers: Int
    ) -> [HorizontalArc] {
        map.compactMap { id, item -> HorizontalArc? in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                return nil
            }

            let layer = packageLayer(item.int("layer"), flipped: flipped, nInnerLayers: nInnerLayers)
            guard !(omitSilkscreen && isBoardSilkscreenLayer(layer)) else {
                return nil
            }

            return HorizontalArc(
                id: "\(boardPackageID)/arc/\(id)",
                from: from,
                to: to,
                center: center,
                width: item.double("width") ?? 0,
                layer: layer,
                reverse: flipped
            )
        }
    }

    private static func parsePackageTexts(
        from map: [String: JSONDictionary],
        boardPackageID: String,
        packageTransform: HorizontalPlacementTransform,
        context: BoardTextContext,
        omitSilkscreen: Bool,
        nInnerLayers: Int
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard let text = item.string("text"),
                  let textTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return nil
            }
            let layer = packageLayer(item.int("layer"), flipped: packageTransform.mirrored, nInnerLayers: nInnerLayers)
            guard !(omitSilkscreen && isBoardSilkscreenLayer(layer)) else {
                return nil
            }

            let substitutedText = substituteText(text, context: context)
            guard !substitutedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let transformed = packageTransform.accumulatedText(with: textTransform)
            return HorizontalText(
                id: "\(boardPackageID)/text/\(id)",
                text: substitutedText,
                position: transformed.shift,
                size: item.double("size") ?? 1_000_000,
                layer: layer,
                angle: transformed.angle,
                mirrored: transformed.mirrored,
                width: item.double("width") ?? 0,
                origin: item.horizonTextOrigin(),
                font: item.horizonTextFont(),
                allowUpsideDown: item.bool("allow_upside_down") ?? false
            )
        }
    }

    private static func packageTexts(
        from boardPackage: JSONDictionary,
        boardPackageID: String,
        packageJSON: JSONDictionary,
        packageTransform: HorizontalPlacementTransform,
        component: BoardComponentInfo,
        boardTexts: [String: JSONDictionary],
        titleValues: [String: String],
        omitSilkscreen: Bool,
        nInnerLayers: Int
    ) -> [HorizontalText] {
        let context = BoardTextContext(component: component, titleValues: titleValues)
        let smashed = boardPackage.bool("smashed") == true
        let packageTexts = parsePackageTexts(
            from: packageJSON.dictionaryMap("texts"),
            boardPackageID: boardPackageID,
            packageTransform: packageTransform,
            context: context,
            omitSilkscreen: omitSilkscreen || smashed,
            nInnerLayers: nInnerLayers
        )

        if smashed {
            let smashedTexts: [HorizontalText] = packageTextIDs(from: boardPackage).compactMap { textID in
                guard let textJSON = boardTexts[normalizedID(textID)] else {
                    return nil
                }

                return parseAbsoluteText(
                    id: "\(boardPackageID)/text/\(textID)",
                    item: textJSON,
                    context: context
                )
                .flatMap { text in
                    guard !(omitSilkscreen && isBoardSilkscreenLayer(text.layer)) else {
                        return nil
                    }
                    var smashedText = text
                    smashedText.fromSmash = true
                    return smashedText
                }
            }

            return packageTexts + smashedTexts
        }

        return packageTexts
    }

    /// Re-derives a placed package's own silk texts from the pool — used by
    /// Unsmash to restore the package silk after the editable from-smash copies
    /// are removed. Reads the pool package by the placement's already-resolved
    /// `packageID` and re-applies the refdes/value substitution from
    /// `componentDetails`, so no board JSON or load-time context is needed.
    /// (Package-parameter substitution in text — rare — is not re-applied.)
    static func packageSilkTexts(
        for placement: HorizontalPlacement,
        poolURL: URL,
        copperLayerCount: Int
    ) -> [HorizontalText] {
        // `placement.packageID` is only populated as a 3D-model side-effect, so
        // fall back to resolving the package from the part for footprints without
        // a 3D model.
        guard let packageID = placement.packageID
            ?? placement.componentDetails?.partID.flatMap({ resolvePackageID(for: $0, poolURL: poolURL) }) else {
            return []
        }
        var cache = [String: JSONDictionary]()
        guard let packageJSON = loadPackage(packageID, poolURL: poolURL, cache: &cache) else {
            return []
        }
        let component = BoardComponentInfo(
            partID: placement.componentDetails?.partID,
            refdes: placement.componentDetails?.refdes ?? "",
            value: placement.componentDetails?.value ?? "",
            noPopulate: placement.componentDetails?.noPopulate ?? false,
            connections: [:],
            details: placement.componentDetails
        )
        return parsePackageTexts(
            from: packageJSON.dictionaryMap("texts"),
            boardPackageID: placement.id,
            packageTransform: HorizontalPlacementTransform(
                shift: placement.position,
                angle: placement.angle,
                mirrored: placement.mirrored
            ),
            context: BoardTextContext(component: component, titleValues: [:]),
            omitSilkscreen: false,
            nInnerLayers: max(copperLayerCount - 2, 0)
        )
    }

    private static func packageTextIDs(from packageMap: [String: JSONDictionary]) -> Set<String> {
        packageMap.reduce(into: Set<String>()) { result, item in
            for textID in packageTextIDs(from: item.value) {
                result.insert(normalizedID(textID))
            }
        }
    }

    private static func packageTextIDs(from package: JSONDictionary) -> [String] {
        package["texts"] as? [String] ?? []
    }

    private static func parsePackagePads(
        from map: [String: JSONDictionary],
        boardPackageID: String,
        packageID: String,
        packageTransform: HorizontalPlacementTransform,
        padNetIDsByName: [String: String],
        poolURL: URL,
        nInnerLayers: Int,
        packageParameterSet: JSONDictionary,
        padstackCache: inout [String: JSONDictionary],
        missingPadstackCache: inout Set<String>,
        expandedPadstackCache: inout [String: HorizontalExpandedPadstack],
        padstackShapeTemplateCache: inout [String: PadstackShapeGeometry]
    ) -> (pads: [HorizontalPolygon], holes: [HorizontalHole], positions: [String: HorizontalPoint], netIDs: [String: String]) {
        var pads = [HorizontalPolygon]()
        var holes = [HorizontalHole]()
        var positions = [String: HorizontalPoint]()
        var netIDs = [String: String]()
        var padMetadataParameterCache = [String: [String: String]]()

        for (padID, item) in map {
            guard let padTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                continue
            }

            let transformed = packageTransform.accumulated(with: padTransform)
            let padPath = normalizedUUIDPath("\(boardPackageID)/\(padID)")
            let netID = padNetIDsByName[normalizedID(padID)]
            positions[padPath] = transformed.shift
            if let netID {
                netIDs[padPath] = netID
            }
            let padParameterSet = BoardLoadTimer.measure("package pads: resolve pad parameters") {
                resolvedPadParameterSet(
                    padJSON: item,
                    packageParameterSet: packageParameterSet
                )
            }
            let padstackID = item.string("padstack")
            var expandedPadstackKey: String?
            var padstackJSON = BoardLoadTimer.measure("package pads: load padstack") {
                padstackID.flatMap {
                    loadPadstack(
                        $0,
                        packageID: packageID,
                        poolURL: poolURL,
                        cache: &padstackCache,
                        missingCache: &missingPadstackCache
                    )
                }
            }
            let padstackParameterSet: JSONDictionary?
            if let padstackID,
               let loadedPadstackJSON = padstackJSON {
                let cacheKey = expandedPadstackCacheKey(
                    packageID: packageID,
                    padstackID: padstackID,
                    padParameterSet: padParameterSet
                )
                expandedPadstackKey = cacheKey
                if let cached = expandedPadstackCache[cacheKey] {
                    padstackJSON = cached.json
                    padstackParameterSet = cached.parameterSet
                } else {
                    let expanded = BoardLoadTimer.measure("package pads: expand padstack") {
                        expandedPadstack(
                            loadedPadstackJSON,
                            padParameterSet: padParameterSet
                        )
                    }
                    padstackJSON = expanded.json
                    padstackParameterSet = expanded.parameterSet
                    expandedPadstackCache[cacheKey] = expanded
                }
            } else {
                padstackParameterSet = nil
            }
            let effectiveParameterSet = padstackParameterSet ?? padParameterSet
            let padMetadata = BoardLoadTimer.measure("package pads: metadata") {
                Self.padMetadata(
                    padID: padID,
                    item: item,
                    parameterSet: effectiveParameterSet,
                    parameterCache: &padMetadataParameterCache
                )
            }
            let padHoles = BoardLoadTimer.measure("package pads: holes") {
                padstackHoles(
                    padstackJSON,
                    boardPackageID: boardPackageID,
                    padID: padID,
                    padTransform: transformed,
                    parameterSet: effectiveParameterSet
                )
            }
            if padHoles.isEmpty,
               let diameter = effectiveParameterSet.double("hole_diameter") {
                let length = holeLength(for: [:], parameterSet: effectiveParameterSet, diameter: diameter)
                holes.append(
                    HorizontalHole(
                        id: "\(boardPackageID)/pad/\(padID)/hole",
                        position: transformed.shift,
                        diameter: diameter,
                        length: length,
                        // Synthesized fallback when no padstack JSON is available; there's
                        // no explicit `shape` to consult here, unlike the `holeShape(...)`
                        // path used by parseBoardHoles/padstackHoles. length > diameter is
                        // the only signal we have.
                        shape: length > diameter ? .slot : .round,
                        angle: transformed.angle,
                        plated: true,
                        netID: netID
                    )
                )
            } else {
                holes.append(contentsOf: padHoles.map { hole in
                    var hole = hole
                    hole.netID = netID
                    return hole
                })
            }

            let padstackLayer = packageLayer(
                padLayer(for: padstackJSON?.string("padstack_type")),
                flipped: packageTransform.mirrored,
                nInnerLayers: nInnerLayers
            )
            let padstackType = padstackJSON?.string("padstack_type")

            if let parameterPad = BoardLoadTimer.measure("package pads: parameter pad polygon", {
                parameterPadPolygon(
                    padID: "\(boardPackageID)/pad/\(padID)",
                    parameterSet: padstackJSON == nil ? effectiveParameterSet : nil,
                    padstackType: padstackType,
                    transform: transformed,
                    layer: padstackLayer,
                    netID: netID,
                    metadata: padMetadata
                )
            }) {
                pads.append(parameterPad)
                if let padstackJSON {
                    pads.append(
                        contentsOf: padstackMaskShapes(
                            padstackJSON,
                            boardPackageID: boardPackageID,
                            padID: padID,
                            padTransform: transformed,
                            flipped: packageTransform.mirrored,
                            nInnerLayers: nInnerLayers,
                            parameterSet: effectiveParameterSet,
                            netID: netID,
                            metadata: padMetadata
                        )
                    )
                }
                continue
            }

            if let padstackJSON {
                let geometry = BoardLoadTimer.measure("package pads: shape templates lookup") {
                    padstackShapeGeometry(
                        padstackJSON,
                        packageID: packageID,
                        expandedPadstackKey: expandedPadstackKey,
                        flipped: packageTransform.mirrored,
                        nInnerLayers: nInnerLayers,
                        parameterSet: effectiveParameterSet,
                        cache: &padstackShapeTemplateCache
                    )
                }
                // Every pad — through-hole, via, mechanical, shape-defined or
                // polygon-defined — gets the same intrinsic label frame Horizon
                // uses, so the label renderer never has to guess an orientation
                // from a tessellated outline.
                let labelFrame = padLabelFrameDescriptor(
                    localBounds: geometry.localBounds,
                    transform: transformed
                )
                pads.append(
                    contentsOf: BoardLoadTimer.measure("package pads: shape polygons") {
                        padstackShapePolygons(
                            geometry.templates,
                            idPrefix: "\(boardPackageID)/pad/\(padID)",
                            padTransform: transformed,
                            netID: netID,
                            metadata: padMetadata,
                            labelFrame: labelFrame
                        )
                    }
                )
                pads.append(
                    contentsOf: BoardLoadTimer.measure("package pads: padstack polygons") {
                        padstackPolygonPolygons(
                            padstackJSON,
                            boardPackageID: boardPackageID,
                            padID: padID,
                            padTransform: transformed,
                            flipped: packageTransform.mirrored,
                            nInnerLayers: nInnerLayers,
                            netID: netID,
                            metadata: padMetadata,
                            labelFrame: labelFrame
                        )
                    }
                )
            }
        }

        return (pads, holes, positions, netIDs)
    }

    private static func loadPadstack(_ padstackID: String, packageID: String, poolURL: URL) -> JSONDictionary? {
        let padstackID = normalizedID(padstackID)
        if let packageDirectory = packageDirectory(for: packageID, poolURL: poolURL) {
            let packagePadstackURL = packageDirectory
                .appendingPathComponent("padstacks")
                .appendingPathComponent("\(padstackID).json")
            if let packagePadstackURL = existingFileURL(packagePadstackURL) {
                return try? JSONHelper.loadDictionary(from: packagePadstackURL)
            }
        }

        let globalPadstackURL = poolURL
            .appendingPathComponent("padstacks")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(padstackID).json")
        if let globalPadstackURL = existingFileURL(globalPadstackURL) {
            return try? JSONHelper.loadDictionary(from: globalPadstackURL)
        }

        return nil
    }

    private static func loadPadstack(
        _ padstackID: String,
        packageID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary],
        missingCache: inout Set<String>
    ) -> JSONDictionary? {
        let key = "\(normalizedID(packageID))/\(normalizedID(padstackID))"
        if let cached = cache[key] {
            return cached
        }
        if missingCache.contains(key) {
            return nil
        }
        guard let loaded = loadPadstack(padstackID, packageID: packageID, poolURL: poolURL) else {
            missingCache.insert(key)
            return nil
        }
        cache[key] = loaded
        return loaded
    }

    private static func expandedPadstack(
        _ padstackJSON: JSONDictionary,
        padParameterSet: JSONDictionary
    ) -> HorizontalExpandedPadstack {
        var expandedPadstackJSON = padstackJSON
        let parameters = resolvedPadstackParameterSet(
            padstackJSON: expandedPadstackJSON,
            padParameterSet: padParameterSet
        )
        HorizontalParameterProgramEvaluator.apply(
            program: expandedPadstackJSON.string("parameter_program"),
            parameters: parameters,
            to: &expandedPadstackJSON
        )
        return HorizontalExpandedPadstack(json: expandedPadstackJSON, parameterSet: parameters)
    }

    private static func expandedPadstackCacheKey(
        packageID: String,
        padstackID: String,
        padParameterSet: JSONDictionary
    ) -> String {
        [
            normalizedID(packageID),
            normalizedID(padstackID),
            parameterSetCacheKey(padParameterSet)
        ].joined(separator: "|")
    }

    private static func parameterSetCacheKey(_ parameters: JSONDictionary) -> String {
        parameters.keys.sorted().map { key in
            "\(key)=\(parameterCacheValue(parameters[key]))"
        }.joined(separator: ";")
    }

    private static func parameterCacheValue(_ value: Any?) -> String {
        switch value {
        case let value as Int:
            return "i:\(value)"
        case let value as Double:
            return "d:\(value)"
        case let value as String:
            return "s:\(value)"
        case let value as Bool:
            return "b:\(value)"
        case let values as [Any]:
            return "[" + values.map(parameterCacheValue).joined(separator: ",") + "]"
        case let dictionary as JSONDictionary:
            return "{" + parameterSetCacheKey(dictionary) + "}"
        case nil:
            return "nil"
        default:
            return String(describing: value)
        }
    }

    private static func padstackHoles(
        _ padstackJSON: JSONDictionary?,
        boardPackageID: String,
        padID: String,
        padTransform: HorizontalPlacementTransform,
        parameterSet: JSONDictionary?
    ) -> [HorizontalHole] {
        padstackHoles(
            padstackJSON,
            idPrefix: "\(boardPackageID)/pad/\(padID)/hole",
            transform: padTransform,
            parameterSet: parameterSet
        )
    }

    private static func padstackHoles(
        _ padstackJSON: JSONDictionary?,
        idPrefix: String,
        transform: HorizontalPlacementTransform,
        parameterSet: JSONDictionary?
    ) -> [HorizontalHole] {
        guard let padstackJSON else {
            return []
        }

        return padstackJSON.dictionaryMap("holes").compactMap { holeID, hole in
            guard let holeTransform = HorizontalPlacementTransform(json: hole.dictionary("placement")),
                  let diameter = holeDiameter(for: hole, parameterSet: parameterSet) else {
                return nil
            }

            let transformed = transform.accumulated(with: holeTransform)
            let length = holeLength(for: hole, parameterSet: parameterSet, diameter: diameter)
            return HorizontalHole(
                id: "\(idPrefix)/\(holeID)",
                position: transformed.shift,
                diameter: diameter,
                length: length,
                shape: holeShape(for: hole, length: length, diameter: diameter),
                angle: transformed.angle,
                plated: hole.bool("plated") ?? false
            )
        }
    }

    private static func loadPoolPadstack(_ padstackID: String, poolURL: URL) -> JSONDictionary? {
        let padstackID = normalizedID(padstackID)
        let candidateURLs = [
            poolURL
                .appendingPathComponent("padstacks")
                .appendingPathComponent("cache")
                .appendingPathComponent("\(padstackID).json"),
            poolURL
                .appendingPathComponent("padstacks")
                .appendingPathComponent("\(padstackID).json")
        ]
        return candidateURLs.lazy.compactMap { url in
            existingFileURL(url).flatMap { try? JSONHelper.loadDictionary(from: $0) }
        }.first
    }

    private static func holeDiameter(for hole: JSONDictionary, parameterSet: JSONDictionary?) -> Double? {
        if let parameterClass = hole.string("parameter_class"),
           let diameter = parameterSet?.double("\(parameterClass)_diameter") {
            return diameter
        }

        return parameterSet?.double("hole_diameter") ?? hole.double("diameter")
    }

    private static func holeLength(for hole: JSONDictionary, parameterSet: JSONDictionary?, diameter: Double) -> Double {
        if let parameterClass = hole.string("parameter_class"),
           let length = parameterSet?.double("\(parameterClass)_length") {
            return max(length, diameter)
        }

        return max(parameterSet?.double("hole_length") ?? hole.double("length") ?? diameter, diameter)
    }

    private static func holeShape(for hole: JSONDictionary, length: Double, diameter: Double) -> HorizontalHoleShape {
        // Trust the JSON's explicit shape. Reference Horizon
        // unconditionally writes `length` for *every* hole — round padstacks routinely
        // have `length` carried as residual data. The previous fallback of
        // `length > diameter ? .slot : .round` therefore promoted plenty of round
        // holes (e.g. round-via padstacks) to slots, producing the "some vias in
        // pads showing up as slots" symptom from Breadcrumbs.md.
        switch hole.string("shape") {
        case HorizontalHoleShape.slot.rawValue:
            return .slot
        case HorizontalHoleShape.round.rawValue:
            return .round
        default:
            return length > diameter ? .slot : .round
        }
    }

    private static func padMetadata(
        padID: String,
        item: JSONDictionary,
        parameterSet: JSONDictionary?,
        parameterCache: inout [String: [String: String]]
    ) -> [String: String] {
        var result = [String: String]()
        result["Pad"] = item.string("name") ?? String(padID.prefix(8))
        if let padstack = item.string("padstack") {
            result["Padstack"] = String(padstack.prefix(8))
        }
        for (key, value) in padParameterMetadata(parameterSet, cache: &parameterCache) {
            result[key] = value
        }
        return result
    }

    private static func padParameterMetadata(
        _ parameterSet: JSONDictionary?,
        cache: inout [String: [String: String]]
    ) -> [String: String] {
        guard let parameterSet,
              !parameterSet.isEmpty else {
            return [:]
        }

        let cacheKey = parameterSetCacheKey(parameterSet)
        if let cached = cache[cacheKey] {
            return cached
        }

        let metadata = parameterSet.reduce(into: [String: String]()) { result, item in
            let (key, value) = item
            guard let value = stringValue(value) else {
                return
            }
            result[parameterIDDisplayName(key)] = value
        }
        cache[cacheKey] = metadata
        return metadata
    }

    private static func parameterPadPolygon(
        padID: String,
        parameterSet: JSONDictionary?,
        padstackType: String?,
        transform: HorizontalPlacementTransform,
        layer: Int?,
        netID: String?,
        metadata: [String: String]
    ) -> HorizontalPolygon? {
        guard let parameterSet else {
            return nil
        }
        if let padstackType,
           ["through", "via", "hole", "mechanical"].contains(padstackType) {
            return nil
        }

        if let width = parameterSet.double("pad_width"),
           let height = parameterSet.double("pad_height") {
            let radius = parameterSet.double("corner_radius") ?? 0
            let vertices = radius > 0
                ? transform.roundedRectangle(width: width, height: height, radius: radius)
                : transform.rectangle(width: width, height: height)
            // Capture the intrinsic pad frame so the label renderer can drive
            // off the placement angle + true inner dimensions instead of
            // re-deriving them from rounded-corner chord segments.
            let labelFrame = PadLabelFrameDescriptor(
                center: transform.shift,
                halfWidth: width / 2,
                halfHeight: height / 2,
                angle: transform.angle,
                mirrored: transform.mirrored
            )
            return HorizontalPolygon(
                id: padID,
                vertices: vertices,
                layer: layer,
                netID: netID,
                metadata: metadata,
                padLabelFrame: labelFrame
            )
        }

        let diameter = parameterSet.double("pad_diameter")
            ?? parameterSet.double("diameter")

        if let diameter {
            // Circles are rotation-invariant; angle = 0 just keeps the label
            // horizontal (the existing normalize-and-fit logic still chooses
            // the better orientation per text).
            let labelFrame = PadLabelFrameDescriptor(
                center: transform.shift,
                halfWidth: diameter / 2,
                halfHeight: diameter / 2,
                angle: 0
            )
            return HorizontalPolygon(
                id: padID,
                vertices: transform.circle(diameter: diameter),
                layer: layer,
                netID: netID,
                metadata: metadata,
                padLabelFrame: labelFrame
            )
        }

        return nil
    }

    private static func padstackShapeGeometry(
        _ padstackJSON: JSONDictionary,
        packageID: String,
        expandedPadstackKey: String?,
        flipped: Bool,
        nInnerLayers: Int,
        parameterSet: JSONDictionary?,
        cache: inout [String: PadstackShapeGeometry]
    ) -> PadstackShapeGeometry {
        let cacheKey = [
            normalizedID(packageID),
            expandedPadstackKey ?? parameterSetCacheKey(parameterSet ?? [:]),
            flipped ? "flipped" : "normal",
            "inner:\(nInnerLayers)"
        ].joined(separator: "|")
        if let cached = cache[cacheKey] {
            return cached
        }

        let shapes = padstackJSON.dictionaryMap("shapes")
        let templates: [PadstackShapeTemplate] = BoardLoadTimer.measure("package pads: shape templates") {
            shapes.flatMap { shapeID, shape in
            let rawLayer = shape.int("layer")
            let layers = packageShapeLayers(
                rawLayer,
                flipped: flipped,
                nInnerLayers: nInnerLayers
            )
            guard let shapeTransform = HorizontalPlacementTransform(json: shape.dictionary("placement")) else {
                return [PadstackShapeTemplate]()
            }

            let vertices = vertices(forShape: shape, transform: shapeTransform, parameterSet: parameterSet)
            guard vertices.count >= 2 else {
                return [PadstackShapeTemplate]()
            }

            return layers.compactMap { layer in
                guard isCopperLayer(layer) || isMaskLayer(layer) || isPasteLayer(layer) else {
                    return nil
                }
                return PadstackShapeTemplate(
                    idSuffix: "shape/\(shapeID)/layer/\(layer)",
                    vertices: vertices,
                    layer: layer
                )
            }
        }
        }
        let geometry = PadstackShapeGeometry(
            templates: templates,
            localBounds: BoardLoadTimer.measure("package pads: padstack bbox") {
                padstackLocalBounds(
                    padstackJSON,
                    flipped: flipped,
                    nInnerLayers: nInnerLayers,
                    parameterSet: parameterSet
                )
            }
        )
        cache[cacheKey] = geometry
        return geometry
    }

    /// Padstack-local (i.e. pre-pad-placement) axis-aligned bounding box.
    ///
    /// Requirement: the box covers the padstack's COPPER — its copper shapes and
    /// copper polygons — and falls back to everything it has (shapes, polygons
    /// and holes) only when there is no copper at all, as on an unplated or
    /// mechanical padstack. Without that fallback such a padstack would have an
    /// empty box and could carry no label.
    ///
    /// This box, in this local space, is what the label layout is given. That is
    /// why a pad label's orientation must come from the pad's *placement* and
    /// never from the rendered, tessellated outline: on a roundrect dozens of
    /// corner chords pass any minimum-edge filter, and on a circle every chord
    /// is the same length at a different angle, so fitting a rectangle to the
    /// outline picks an arbitrary angle.
    private static func padstackLocalBounds(
        _ padstackJSON: JSONDictionary,
        flipped: Bool,
        nInnerLayers: Int,
        parameterSet: JSONDictionary?
    ) -> HorizontalRect? {
        var copperPoints = [HorizontalPoint]()
        var allPoints = [HorizontalPoint]()

        func accumulate(_ points: [HorizontalPoint], rawLayer: Int?) {
            guard !points.isEmpty else {
                return
            }
            allPoints.append(contentsOf: points)
            let layers = packageShapeLayers(rawLayer, flipped: flipped, nInnerLayers: nInnerLayers)
            if layers.contains(where: { isCopperLayer($0) }) {
                copperPoints.append(contentsOf: points)
            }
        }

        for (_, shape) in padstackJSON.dictionaryMap("shapes") {
            guard let shapeTransform = HorizontalPlacementTransform(json: shape.dictionary("placement")) else {
                continue
            }
            accumulate(
                vertices(forShape: shape, transform: shapeTransform, parameterSet: parameterSet),
                rawLayer: shape.int("layer")
            )
        }

        for (_, polygon) in padstackJSON.dictionaryMap("polygons") {
            accumulate(
                parsePolygonVertices(from: polygon.dictionaryArray("vertices")),
                rawLayer: polygon.int("layer")
            )
        }

        if !copperPoints.isEmpty {
            let bounds = HorizontalRect(points: copperPoints)
            if !bounds.isEmpty {
                return bounds
            }
        }

        for (_, hole) in padstackJSON.dictionaryMap("holes") {
            guard let holeTransform = HorizontalPlacementTransform(json: hole.dictionary("placement")),
                  let diameter = holeDiameter(for: hole, parameterSet: parameterSet) else {
                continue
            }
            let length = holeLength(for: hole, parameterSet: parameterSet, diameter: diameter)
            let width = holeShape(for: hole, length: length, diameter: diameter) == .slot ? length : diameter
            allPoints.append(contentsOf: holeTransform.rectangle(width: width, height: diameter))
        }

        guard !allPoints.isEmpty else {
            return nil
        }
        let bounds = HorizontalRect(points: allPoints)
        return bounds.isEmpty ? nil : bounds
    }

    /// The label frame Horizon computes for a pad: the padstack's local bbox
    /// centre pushed through the pad's placement, the box's un-rotated extents,
    /// and the pad's own placement angle/mirror. `draw_bitmap_text_box` handles
    /// the mirror (it inverts the angle and drops the flag), so the raw
    /// placement is what gets stored.
    private static func padLabelFrameDescriptor(
        localBounds: HorizontalRect?,
        transform: HorizontalPlacementTransform
    ) -> PadLabelFrameDescriptor? {
        guard let localBounds, !localBounds.isEmpty else {
            return nil
        }
        return PadLabelFrameDescriptor(
            center: transform.applying(to: localBounds.center),
            halfWidth: localBounds.width / 2,
            halfHeight: localBounds.height / 2,
            angle: transform.angle,
            mirrored: transform.mirrored
        )
    }

    private static func padstackShapePolygons(
        _ templates: [PadstackShapeTemplate],
        idPrefix: String,
        padTransform: HorizontalPlacementTransform,
        netID: String?,
        metadata: [String: String],
        labelFrame: PadLabelFrameDescriptor?
    ) -> [HorizontalPolygon] {
        templates.map { template in
            HorizontalPolygon(
                id: "\(idPrefix)/\(template.idSuffix)",
                vertices: template.vertices.map(padTransform.applying),
                layer: template.layer,
                netID: netID,
                metadata: metadata,
                padLabelFrame: labelFrame
            )
        }
    }

    private static func padstackPolygonPolygons(
        _ padstackJSON: JSONDictionary,
        boardPackageID: String,
        padID: String,
        padTransform: HorizontalPlacementTransform,
        flipped: Bool,
        nInnerLayers: Int,
        netID: String?,
        metadata: [String: String],
        labelFrame: PadLabelFrameDescriptor?
    ) -> [HorizontalPolygon] {
        let polygons = padstackJSON.dictionaryMap("polygons")
        return polygons.flatMap { polygonID, polygon in
            let layers = packageShapeLayers(
                polygon.int("layer"),
                flipped: flipped,
                nInnerLayers: nInnerLayers
            )
            let vertices = parsePolygonVertexList(
                from: polygon.dictionaryArray("vertices"),
                transform: padTransform.applying,
                flipsArcReverse: padTransform.mirrored
            )
            guard vertices.count >= 2 else {
                return [HorizontalPolygon]()
            }

            return layers.compactMap { layer in
                guard isCopperLayer(layer) || isMaskLayer(layer) || isPasteLayer(layer) else {
                    return nil
                }
                return HorizontalPolygon(
                    id: "\(boardPackageID)/pad/\(padID)/polygon/\(polygonID)/layer/\(layer)",
                    polygonVertices: vertices,
                    layer: layer,
                    netID: netID,
                    metadata: metadata,
                    padLabelFrame: labelFrame
                )
            }
        }
    }

    private static func padstackMaskShapes(
        _ padstackJSON: JSONDictionary,
        boardPackageID: String,
        padID: String,
        padTransform: HorizontalPlacementTransform,
        flipped: Bool,
        nInnerLayers: Int,
        parameterSet: JSONDictionary?,
        netID: String?,
        metadata: [String: String]
    ) -> [HorizontalPolygon] {
        let shapes = padstackJSON.dictionaryMap("shapes")
        return shapes.flatMap { shapeID, shape in
            let rawLayer = shape.int("layer")
            let layers = packageShapeLayers(
                rawLayer,
                flipped: flipped,
                nInnerLayers: nInnerLayers
            )
            guard let shapeTransform = HorizontalPlacementTransform(json: shape.dictionary("placement")) else {
                return [HorizontalPolygon]()
            }

            let transform = padTransform.accumulated(with: shapeTransform)
            let vertices = vertices(forShape: shape, transform: transform, parameterSet: parameterSet)
            guard vertices.count >= 2 else {
                return [HorizontalPolygon]()
            }

            return layers.compactMap { layer in
                guard isMaskLayer(layer) || isPasteLayer(layer) else {
                    return nil
                }
                return HorizontalPolygon(
                    id: "\(boardPackageID)/pad/\(padID)/shape/\(shapeID)/layer/\(layer)",
                    vertices: vertices,
                    layer: layer,
                    netID: netID,
                    metadata: metadata
                )
            }
        }
    }

    private static func vertices(
        forShape shape: JSONDictionary,
        transform: HorizontalPlacementTransform,
        parameterSet: JSONDictionary?
    ) -> [HorizontalPoint] {
        let params = shapeParameters(for: shape, parameterSet: parameterSet)
        switch shape.string("form") {
        case "rectangle":
            guard params.count >= 2 else { return [] }
            return transform.rectangle(width: params[0], height: params[1])
        case "circle":
            guard let diameter = params.first else { return [] }
            return transform.circle(diameter: diameter)
        case "obround":
            guard params.count >= 2 else { return [] }
            return transform.obround(width: params[0], height: params[1])
        default:
            return []
        }
    }

    private static func shapeParameters(for shape: JSONDictionary, parameterSet: JSONDictionary?) -> [Double] {
        let fallback = shape.doubleArray("params")
        guard let parameterSet,
              let parameterClass = shape.string("parameter_class"),
              let form = shape.string("form") else {
            return fallback
        }

        switch form {
        case "circle":
            let diameter = parameterSet.double("\(parameterClass)_diameter")
                ?? shapeDiameterParameter(for: parameterClass, parameterSet: parameterSet)
            if let diameter {
                return [diameter]
            }
        case "rectangle", "obround":
            let width = parameterSet.double("\(parameterClass)_width")
                ?? shapeWidthParameter(for: parameterClass, parameterSet: parameterSet)
            let height = parameterSet.double("\(parameterClass)_height")
                ?? shapeHeightParameter(for: parameterClass, parameterSet: parameterSet)
            if let width, let height {
                return [width, height]
            }
        default:
            break
        }

        return fallback
    }

    private static func shapeDiameterParameter(for parameterClass: String, parameterSet: JSONDictionary) -> Double? {
        switch parameterClass {
        case "via":
            return parameterSet.double("via_diameter")
        case "pad", "copper":
            return parameterSet.double("pad_diameter") ?? parameterSet.double("diameter")
        default:
            return nil
        }
    }

    private static func shapeWidthParameter(for parameterClass: String, parameterSet: JSONDictionary) -> Double? {
        switch parameterClass {
        case "pad", "copper":
            return parameterSet.double("pad_width")
        default:
            return nil
        }
    }

    private static func shapeHeightParameter(for parameterClass: String, parameterSet: JSONDictionary) -> Double? {
        switch parameterClass {
        case "pad", "copper":
            return parameterSet.double("pad_height")
        default:
            return nil
        }
    }

    private static func packageCopperLayers(_ layer: Int?, flipped: Bool, nInnerLayers: Int) -> [Int] {
        guard let layer else {
            return []
        }

        if layer == HorizontalBoardLayers.in1Copper {
            guard nInnerLayers > 0 else {
                return []
            }
            return (0..<nInnerLayers).map { -1 - $0 }
        }

        guard let transformedLayer = packageLayer(layer, flipped: flipped, nInnerLayers: nInnerLayers) else {
            return []
        }
        return [transformedLayer]
    }

    private static func padLayer(for padstackType: String?) -> Int? {
        switch padstackType {
        case "bottom":
            return HorizontalBoardLayers.bottomCopper
        case "top", "through", "via":
            return HorizontalBoardLayers.topCopper
        default:
            return nil
        }
    }

    private static func packageLayer(_ layer: Int?, flipped: Bool, nInnerLayers: Int) -> Int? {
        guard let layer else {
            return nil
        }

        return HorizontalBoardLayers.packageLayer(layer, flipped: flipped, nInnerLayers: nInnerLayers)
    }

    private static func packageShapeLayers(
        _ layer: Int?,
        flipped: Bool,
        nInnerLayers: Int
    ) -> [Int] {
        guard let layer else { return [] }
        if layer == HorizontalBoardLayers.in1Copper {
            guard nInnerLayers > 0 else { return [] }
            return (0..<nInnerLayers).map { -1 - $0 }
        }
        guard let transformedLayer = packageLayer(layer, flipped: flipped, nInnerLayers: nInnerLayers) else {
            return []
        }
        return [transformedLayer]
    }

    private static func isCopperLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return HorizontalBoardLayers.isCopper(layer)
    }

    private static func isMaskLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return layer == HorizontalBoardLayers.topMask || layer == HorizontalBoardLayers.bottomMask
    }

    private static func isPasteLayer(_ layer: Int?) -> Bool {
        guard let layer else {
            return false
        }
        return layer == HorizontalBoardLayers.topPaste || layer == HorizontalBoardLayers.bottomPaste
    }

    private static func endpointPoint(
        _ endpoint: JSONDictionary?,
        junctions: [String: HorizontalPoint],
        packagePositions: [String: HorizontalPoint],
        packagePadPositions: [String: HorizontalPoint]
    ) -> HorizontalPoint? {
        guard let endpoint else {
            return nil
        }

        if let junctionID = endpoint.string("junc") {
            return junctions[junctionID]
        }

        if let pad = endpoint.string("pad") {
            // KNOWN GAP vs Horizon: a track endpoint may carry a per-connection
            // `offset` (package-local) so it attaches off the pad center
            // (reference Track::Connection::get_position = tr.transform(pad.shift
            // + offset)). We return the pad center only; honoring `offset` would
            // require threading the package placement transform here. The field
            // is serialized only when non-zero, so most tracks are unaffected.
            if let position = packagePadPositions[normalizedUUIDPath(pad)] {
                return position
            }

            let packageID = pad.split(separator: "/").first.map { normalizedID(String($0)) }
            if let packageID {
                return packagePositions[packageID]
            }
        }

        return nil
    }

    private static func endpointNetID(
        _ endpoint: JSONDictionary?,
        junctionNetIDs: [String: String],
        packagePadNetIDs: [String: String]
    ) -> String? {
        guard let endpoint else {
            return nil
        }

        if let netID = endpoint.string("net").map(normalizedID) {
            return netID
        }

        if let junctionID = endpoint.string("junc") {
            return junctionNetIDs[junctionID]
        }

        if let pad = endpoint.string("pad") {
            return packagePadNetIDs[normalizedUUIDPath(pad)]
        }

        return nil
    }

    private struct BoardBlockMetadata {
        var components = [String: BoardComponentInfo]()
        var netDetails = [String: HorizontalNetDetails]()
        var titleValues = [String: String]()
    }

    private struct BoardComponentInfo {
        var partID: String?
        var refdes: String
        var value: String
        var noPopulate: Bool
        var connections: [String: String]
        var details: HorizontalComponentDetails?

        var displayLabel: String {
            details?.displayLabel ?? HorizontalBoard.nonEmpty(refdes) ?? HorizontalBoard.nonEmpty(value) ?? ""
        }
    }

    private struct BoardAirwireNode {
        var point: HorizontalPoint
    }

    private struct BoardAirwireCandidate {
        var from: Int
        var to: Int
        var targetComponent: Int
        var weightSquared: Double
    }

    private struct PlaneFragmentsDocument: Decodable {
        var planes: [String: PlaneFragmentList]
    }

    private struct PlaneFragmentList: Decodable {
        var fragments: [PlaneFragment]
    }

    private struct PlaneFragment: Decodable {
        var paths: [[HorizontalPoint]]
        var orphan: Bool

        private enum CodingKeys: String, CodingKey {
            case paths
            case orphan
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paths = try container.decodeIfPresent([[PlaneFragmentPoint]].self, forKey: .paths)?
                .map { $0.map(\.point) } ?? []
            orphan = try container.decodeIfPresent(Bool.self, forKey: .orphan) ?? false
        }
    }

    private struct PlaneFragmentPoint: Decodable {
        var point: HorizontalPoint

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            let x = try container.decode(Double.self)
            let y = try container.decode(Double.self)
            point = HorizontalPoint(x: x, y: y)
        }
    }

    private struct PadstackShapeTemplate {
        var idSuffix: String
        var vertices: [HorizontalPoint]
        var layer: Int
    }

    /// Per-padstack geometry that only depends on the padstack (plus flip and
    /// inner-layer count), so it can be computed once and reused for every pad
    /// that instantiates it.
    private struct PadstackShapeGeometry {
        var templates: [PadstackShapeTemplate]
        /// `Padstack::get_bbox()` in padstack-local coordinates; the
        /// box `draw_bitmap_text_box` lays pad labels out in.
        var localBounds: HorizontalRect?
    }

    private struct BoardAirwireDisjointSet {
        private var parents: [Int]
        private var ranks: [Int]

        init(count: Int) {
            parents = Array(0..<count)
            ranks = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parents[value] != value {
                parents[value] = find(parents[value])
            }
            return parents[value]
        }

        mutating func union(_ lhs: Int, _ rhs: Int) -> Bool {
            let lhsRoot = find(lhs)
            let rhsRoot = find(rhs)
            guard lhsRoot != rhsRoot else {
                return false
            }

            if ranks[lhsRoot] < ranks[rhsRoot] {
                parents[lhsRoot] = rhsRoot
            } else if ranks[lhsRoot] > ranks[rhsRoot] {
                parents[rhsRoot] = lhsRoot
            } else {
                parents[rhsRoot] = lhsRoot
                ranks[lhsRoot] += 1
            }
            return true
        }
    }

    private struct PartDetails {
        var value: String?
        var mpn: String?
        var manufacturer: String?
        var packageName: String?
        var description: String?
        var datasheet: String?
    }

    private struct BoardTextContext {
        var component: BoardComponentInfo? = nil
        var titleValues = [String: String]()
    }

    private static func boardPlaceableObjects(
        componentInfo: [String: BoardComponentInfo]
    ) -> [HorizontalUnplacedObject] {
        let objects = componentInfo.compactMap { componentID, component -> HorizontalUnplacedObject? in
            let normalizedComponentID = normalizedID(componentID)
            guard component.partID != nil else {
                return nil
            }
            return HorizontalUnplacedObject(
                id: normalizedComponentID,
                label: nonEmpty(component.displayLabel) ?? String(componentID.prefix(8)),
                subtitle: "Package",
                componentID: normalizedComponentID,
                gateID: nil,
                details: component.details
            )
        }

        return objects.sorted { lhs, rhs in
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func unplacedBoardObjects(
        placeableObjects: [HorizontalUnplacedObject],
        placedPackages: [HorizontalPlacement]
    ) -> [HorizontalUnplacedObject] {
        let placedComponentIDs = Set(placedPackages.compactMap { $0.componentID.map(normalizedID) })
        let objects = placeableObjects.filter { object in
            guard let componentID = object.componentID.map(normalizedID) else {
                return true
            }
            return !placedComponentIDs.contains(componentID)
        }

        return objects.sorted { lhs, rhs in
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func substituteText(_ text: String, context: BoardTextContext) -> String {
        let values = textSubstitutionValues(for: context)
        return values.keys.sorted { $0.count > $1.count }.reduce(text) { result, key in
            guard let value = values[key] else {
                return result
            }

            return result
                .replacingOccurrences(of: "${\(key)}", with: value)
                .replacingOccurrences(of: "$\(key)", with: value)
        }
    }

    private static func textSubstitutionValues(for context: BoardTextContext) -> [String: String] {
        var values = [String: String]()

        for (key, value) in context.titleValues {
            insertTextSubstitution(key: key, value: value, into: &values)
        }

        if let component = context.component {
            insertTextSubstitution(key: "RD", value: component.refdes, into: &values)
            insertTextSubstitution(key: "REFDES", value: component.refdes, into: &values)
            insertTextSubstitution(key: "REF", value: component.refdes, into: &values)
            insertTextSubstitution(key: "VALUE", value: component.value, into: &values)
            insertTextSubstitution(key: "VAL", value: component.value, into: &values)
            if let mpn = component.details?.mpn {
                insertTextSubstitution(key: "MPN", value: mpn, into: &values)
            }
            if let manufacturer = component.details?.manufacturer {
                insertTextSubstitution(key: "MFR", value: manufacturer, into: &values)
            }
        }

        return values
    }

    private static func insertTextSubstitution(
        key: String,
        value: String,
        into values: inout [String: String]
    ) {
        values[key] = value
        values[key.lowercased()] = value
        values[key.uppercased()] = value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func stringValue(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? Int {
            return String(value)
        }
        if let value = value as? Double {
            return String(value)
        }
        if let value = value as? Bool {
            return value ? "true" : "false"
        }
        return nil
    }

    private static func parameterIDDisplayName(_ id: String) -> String {
        id.split(separator: "_")
            .map { part in
                let lower = part.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func parsePolygonVertexList(
        from rawVertices: [JSONDictionary],
        transform: (HorizontalPoint) -> HorizontalPoint = { $0 },
        flipsArcReverse: Bool = false
    ) -> [HorizontalPolygonVertex] {
        rawVertices.compactMap(HorizontalPolygonVertex.init).map {
            $0.transformed(transform, flipsArcReverse: flipsArcReverse)
        }
    }

    private static func parsePolygonVertices(
        from rawVertices: [JSONDictionary],
        transform: (HorizontalPoint) -> HorizontalPoint = { $0 }
    ) -> [HorizontalPoint] {
        HorizontalPolygon(
            id: "",
            polygonVertices: parsePolygonVertexList(from: rawVertices, transform: transform),
            layer: nil
        ).renderVertices(arcPrecision: 16)
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }

    private static func normalizedUUIDPath(_ path: String) -> String {
        path.split(separator: "/").map { normalizedID(String($0)) }.joined(separator: "/")
    }

    private static func packageDirectory(for packageID: String, poolURL: URL) -> URL? {
        let cacheURL = poolURL
            .appendingPathComponent("packages")
            .appendingPathComponent("cache")
        let candidate = cacheURL.appendingPathComponent(normalizedID(packageID))

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return candidate
        }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: cacheURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first {
            $0.lastPathComponent.caseInsensitiveCompare(packageID) == .orderedSame
        }
    }

    private static func existingFileURL(_ url: URL) -> URL? {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first {
            $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
        }
    }
}
