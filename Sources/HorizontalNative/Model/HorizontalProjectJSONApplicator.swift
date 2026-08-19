import Foundation
#if canImport(HorizontalProjectIO)
import HorizontalProjectIO
#endif

enum HorizontalProjectJSONApplyError: LocalizedError {
    case missingArchivePath(URL)
    case missingJSON(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingArchivePath(let url):
            "Could not map \(url.lastPathComponent) into the project archive."
        case .missingJSON(let path):
            "The project archive does not contain \(path)."
        case .invalidJSON(let path):
            "\(path) is not a JSON object."
        }
    }
}

enum HorizontalProjectJSONApplicator {
    static func apply(
        projectMeta: [String: String],
        targetURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: targetURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: targetURL, from: archive)
        patchProjectMeta(&json, projectMeta: projectMeta)
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(board: HorizontalBoard, in project: HorizontalProject, to archive: inout HorizontalProjectArchive) throws {
        let path = try archivePath(for: board.url, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: board.url, from: archive)
        let removedPackageIDs = removedKeys(from: json.dictionaryMap("packages"), keeping: board.packages.map(\.id))

        patchGridSettings(&json, grid: board.grid)
        patchStackup(&json, stackupLayers: board.stackupLayers)
        patchUserLayers(&json, userLayers: board.userLayers)
        patchJunctions(&json, points: board.junctions, netIDs: board.junctionNetIDs)
        patchPlacements(&json, key: "packages", placements: board.packages, boardPackages: true)
        removeConnectionLinesReferencingPackages(&json, packageIDs: removedPackageIDs)
        patchSegments(&json, key: "tracks", segments: board.tracks, supportsLayer: true, supportsArcCenter: true)
        patchNewBoardTracks(
            &json,
            tracks: board.tracks,
            junctions: board.junctions,
            padPositions: board.packagePadPositions
        )
        patchSegments(&json, key: "net_ties", segments: board.netTies, supportsLayer: true)
        patchBoardDrawingLines(&json, lines: board.lines, junctions: board.junctions)
        patchBoardDrawingArcs(&json, arcs: board.arcs, junctions: board.junctions)
        patchSegments(&json, key: "connection_lines", segments: board.connectionLines, supportsLayer: false)
        patchPolygons(&json, key: "polygons", polygons: board.polygons, removing: board.removedPolygonIDs)
        patchHoles(&json, key: "holes", holes: board.holes)
        patchVias(&json, vias: board.vias)
        patchNewBoardVias(&json, vias: board.vias, junctions: board.junctions, padstackID: board.viaTemplate?.padstackID)
        patchPlanes(&json, planes: board.planes)
        patchKeepouts(&json, keepouts: board.keepouts)
        patchDimensions(&json, dimensions: board.dimensions)
        // Packages smashed in-memory but whose from-smash texts weren't
        // materialized (e.g. the board was opened without a resolvable pool):
        // their `texts` map entries and package `texts[]` must be preserved
        // verbatim so a save never silently drops smashed silk.
        let materializedSmashPackageIDs = Set(
            board.packageTexts
                .filter(\.fromSmash)
                .compactMap { smashedTextComponents($0.id)?.packageID }
                .map(normalizedID)
        )
        let unmaterializedSmashPackageIDs = Set(
            board.packages
                .filter { $0.smashed && !materializedSmashPackageIDs.contains(normalizedID($0.id)) }
                .map { normalizedID($0.id) }
        )
        let preservedSmashTextIDs = preservedSmashTextUUIDs(in: json, packageIDs: unmaterializedSmashPackageIDs)

        let boardTexts = boardLevelTexts(texts: board.texts, packageTexts: board.packageTexts)
        patchTexts(&json, key: "texts", texts: boardTexts, keepingAdditional: preservedSmashTextIDs)
        patchNewTexts(&json, key: "texts", texts: boardTexts)
        patchPackageSmashState(
            &json,
            packages: board.packages,
            packageTexts: board.packageTexts,
            preserving: unmaterializedSmashPackageIDs
        )
        patchBoardPanels(&json, panels: board.boardPanels)

        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func boardRules(in project: HorizontalProject, from archive: HorizontalProjectArchive) throws -> JSONDictionary {
        guard let board = project.board else {
            return [:]
        }
        let path = try archivePath(for: board.url, project: project, archive: archive)
        let json = try loadJSON(relativePath: path, fallbackURL: board.url, from: archive)
        return json.dictionary("rules") ?? [:]
    }

    static func apply(boardRules rules: JSONDictionary, in project: HorizontalProject, to archive: inout HorizontalProjectArchive) throws {
        guard let board = project.board else {
            return
        }
        let path = try archivePath(for: board.url, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: board.url, from: archive)
        json["rules"] = rules
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func applyPlaneCache(board: HorizontalBoard, in project: HorizontalProject, to archive: inout HorizontalProjectArchive) throws {
        guard let planesFilename = project.planesFilename else {
            return
        }

        let planeMap = board.planes
            .filter { !$0.id.contains("/") }
            .reduce(into: JSONDictionary()) { result, plane in
                result[plane.id] = [
                    "fragments": plane.fragments.map { fragment in
                        [
                            "orphan": fragment.orphan,
                            "paths": fragment.paths.map { path in
                                path.map(jsonPoint)
                            }
                        ] as JSONDictionary
                    }
                ] as JSONDictionary
            }

        try saveJSON(["planes": planeMap], relativePath: planesFilename, to: &archive)
    }

    static func apply(
        schematicSheet sheet: HorizontalSchematicSheet,
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        guard var sheets = json["sheets"] as? JSONDictionary,
              let sheetKey = matchingKey(sheet.id, in: sheets),
              var sheetJSON = sheets[sheetKey] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }
        let removedComponentIDs = removedReferencedIDs(
            from: sheetJSON.dictionaryMap("symbols"),
            keeping: sheet.symbols.map(\.id),
            referenceKey: "component"
        )
        let removedBlockInstanceIDs = removedReferencedIDs(
            from: sheetJSON.dictionaryMap("block_symbols"),
            keeping: schematicBlockSymbolIDs(in: sheet),
            referenceKey: "block_instance"
        )
        let removedBlockNetTieIDs = removedReferencedIDs(
            from: sheetJSON.dictionaryMap("net_ties"),
            keeping: sheet.netTies.map(\.id),
            referenceKey: "net_tie"
        )

        patchGridSettings(&json, grid: sheet.grid)
        patchJunctions(&sheetJSON, points: sheet.junctions, netIDs: sheet.junctionNetIDs)
        patchSchematicNetLines(&sheetJSON, sheet: sheet)
        patchPlacements(&sheetJSON, key: "symbols", placements: sheet.symbols, boardPackages: false)
        try patchAddedSchematicComponents(
            sheet.addedComponents,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        try patchSchematicNets(
            sheet.netDetails,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        try patchSchematicComponentConnections(
            sheet.componentInfo,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        patchSchematicDrawingLines(&sheetJSON, lines: sheet.drawingLines, junctions: sheet.junctions)
        patchSchematicDrawingArcs(&sheetJSON, arcs: sheet.drawingArcs, junctions: sheet.junctions)
        patchTexts(&sheetJSON, key: "texts", texts: sheet.texts)
        patchNewTexts(&sheetJSON, key: "texts", texts: sheet.texts)
        patchSchematicNetLabels(&sheetJSON, labels: sheet.netLabels)
        patchSchematicBusLabels(&sheetJSON, labels: sheet.busLabels)
        patchSchematicNetTies(&sheetJSON, netTies: sheet.netTies)
        patchSchematicPowerSymbols(&sheetJSON, powerSymbols: sheet.powerSymbols, fallbackPowerSymbolIDs: schematicPowerSymbolIDs(in: sheet))
        patchSchematicBusRippers(&sheetJSON, busRipperIDs: schematicBusRipperIDs(in: sheet))
        patchSchematicBlockSymbols(&sheetJSON, blockSymbolIDs: schematicBlockSymbolIDs(in: sheet))

        sheets[sheetKey] = sheetJSON
        json["sheets"] = sheets
        try removeBlockResourcesIfUnused(
            removedComponentIDs: removedComponentIDs,
            removedBlockInstanceIDs: removedBlockInstanceIDs,
            removedBlockNetTieIDs: removedBlockNetTieIDs,
            schematicJSON: json,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(
        netClasses: [HorizontalNetClass],
        blockURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        patchNetClasses(&json, netClasses: netClasses)
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(
        netClassID: String?,
        forNetID netID: String,
        blockURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        guard var nets = json["nets"] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }

        let netKey = matchingKey(netID, in: nets) ?? netID
        var netJSON = nets[netKey] as? JSONDictionary ?? [:]
        if let netClassID {
            netJSON["net_class"] = netClassID
        } else {
            netJSON.removeValue(forKey: "net_class")
        }
        nets[netKey] = netJSON
        json["nets"] = nets
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(
        componentRefdes refdes: String,
        forComponentID componentID: String,
        blockURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        guard var components = json["components"] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }

        let componentKey = matchingKey(componentID, in: components) ?? componentID
        var componentJSON = components[componentKey] as? JSONDictionary ?? [:]
        componentJSON["refdes"] = refdes
        components[componentKey] = componentJSON
        json["components"] = components
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(
        sheetName name: String,
        forSheetID sheetID: String,
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        guard var sheets = json["sheets"] as? JSONDictionary,
              let sheetKey = matchingKey(sheetID, in: sheets),
              var sheetJSON = sheets[sheetKey] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }
        sheetJSON["name"] = name
        sheets[sheetKey] = sheetJSON
        json["sheets"] = sheets
        try saveJSON(json, relativePath: path, to: &archive)
    }

    /// Rewrites every listed sheet's `index` to its position in
    /// `orderedSheetIDs` (1-based, Horizon's numbering). Sheets not listed keep
    /// their stored index.
    static func apply(
        sheetOrder orderedSheetIDs: [String],
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        guard var sheets = json["sheets"] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }
        for (position, sheetID) in orderedSheetIDs.enumerated() {
            guard let sheetKey = matchingKey(sheetID, in: sheets),
                  var sheetJSON = sheets[sheetKey] as? JSONDictionary else {
                continue
            }
            sheetJSON["index"] = position + 1
            sheets[sheetKey] = sheetJSON
        }
        json["sheets"] = sheets
        try saveJSON(json, relativePath: path, to: &archive)
    }

    static func apply(
        symbolPinNames pins: [HorizontalSymbolPinName],
        forComponentID componentID: String,
        blockURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        guard var components = json["components"] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }

        let componentKey = matchingKey(componentID, in: components) ?? componentID
        var componentJSON = components[componentKey] as? JSONDictionary ?? [:]
        var altPins = componentJSON["alt_pins"] as? JSONDictionary ?? [:]
        for pin in pins {
            let entryKey = matchingKey(pin.gatePinPath, in: altPins) ?? pin.gatePinPath
            altPins[entryKey] = [
                "custom_direction": pin.state.customDirection,
                "custom_name": pin.state.customName,
                "pin_names": pin.state.pinNames,
                "use_custom_name": pin.state.useCustomName,
                "use_primary_name": pin.state.usePrimaryName
            ] as JSONDictionary
        }
        componentJSON["alt_pins"] = altPins
        components[componentKey] = componentJSON
        json["components"] = components
        try saveJSON(json, relativePath: path, to: &archive)
    }

    private static func patchGridSettings(_ json: inout JSONDictionary, grid: HorizontalGridSettings) {
        var settings = json["grid_settings"] as? JSONDictionary ?? [:]
        var current = settings["current"] as? JSONDictionary ?? [:]
        current["mode"] = grid.mode
        current["spacing_square"] = jsonNumber(grid.spacingSquare)
        current["spacing_rect"] = jsonPoint(grid.spacingRect)
        current["origin"] = jsonPoint(grid.origin)
        current["name"] = grid.name
        settings["current"] = current
        if settings["grids"] == nil {
            settings["grids"] = JSONDictionary()
        }
        json["grid_settings"] = settings
    }

    private static func patchProjectMeta(_ json: inout JSONDictionary, projectMeta: [String: String]) {
        let cleaned = projectMeta.reduce(into: JSONDictionary()) { result, item in
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                result[item.key] = value
            }
        }

        if cleaned.isEmpty {
            json.removeValue(forKey: "project_meta")
        } else {
            json["project_meta"] = cleaned
        }
    }

    private static func patchStackup(_ json: inout JSONDictionary, stackupLayers: [HorizontalBoardStackupLayer]) {
        let innerLayerCount = stackupLayers.filter {
            HorizontalBoardLayers.category(for: $0.layer) == .innerCopper
        }.count
        json["n_inner_layers"] = innerLayerCount

        var map = JSONDictionary()
        for layer in stackupLayers {
            map[String(layer.layer)] = [
                "thickness": jsonNumber(layer.copperThickness),
                "substrate_thickness": jsonNumber(layer.substrateThickness)
            ] as JSONDictionary
        }
        json["stackup"] = map
    }

    private static func patchUserLayers(_ json: inout JSONDictionary, userLayers: [HorizontalBoardUserLayer]) {
        guard !userLayers.isEmpty else {
            json.removeValue(forKey: "user_layers")
            return
        }

        var map = JSONDictionary()
        for layer in userLayers {
            map[String(layer.id)] = [
                "name": layer.name,
                "position": jsonNumber(layer.position ?? Double(layer.id)),
                "id_color": layer.colorLayer,
                "type": layer.type
            ] as JSONDictionary
        }
        json["user_layers"] = map
    }

    private static func patchNetClasses(_ json: inout JSONDictionary, netClasses: [HorizontalNetClass]) {
        let existingMap = json["net_classes"] as? JSONDictionary ?? [:]
        let wantedIDs = Set(netClasses.map { normalizedID($0.id) })
        var map = existingMap.filter { wantedIDs.contains(normalizedID($0.key)) }

        for netClass in netClasses {
            let itemKey = matchingKey(netClass.id, in: existingMap) ?? netClass.id
            var item = map[itemKey] as? JSONDictionary ?? existingMap[itemKey] as? JSONDictionary ?? [:]
            item["name"] = netClass.name
            map[itemKey] = item
        }
        json["net_classes"] = map
    }

    private static func patchSchematicNets(
        _ netDetails: [String: HorizontalNetDetails],
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        guard !netDetails.isEmpty,
              let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }

        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        var nets = json["nets"] as? JSONDictionary ?? [:]

        for detail in netDetails.values {
            let netID = normalizedID(detail.id)
            let key = matchingKey(netID, in: nets) ?? netID
            var item = nets[key] as? JSONDictionary ?? [:]
            item["name"] = detail.name
            item["is_power"] = detail.isPower
            item["is_port"] = detail.isPort
            if let netClassID = detail.netClassID {
                item["net_class"] = netClassID
            } else {
                item.removeValue(forKey: "net_class")
            }
            if let portDirection = detail.portDirection {
                item["port_direction"] = portDirection
            } else {
                item.removeValue(forKey: "port_direction")
            }
            if let powerSymbolStyle = detail.powerSymbolStyle {
                item["power_symbol_style"] = powerSymbolStyle
            } else {
                item.removeValue(forKey: "power_symbol_style")
            }
            nets[key] = item
        }

        json["nets"] = nets
        try saveJSON(json, relativePath: path, to: &archive)
    }

    private static func patchJunctions(
        _ json: inout JSONDictionary,
        points: [String: HorizontalPoint],
        netIDs: [String: String] = [:]
    ) {
        var junctions = json["junctions"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&junctions, keeping: Array(points.keys))

        for (id, point) in points {
            let key = matchingKey(id, in: junctions) ?? id
            var item = junctions[key] as? JSONDictionary ?? [:]
            item["position"] = jsonPoint(point)
            if let netID = netIDs[id] ?? netIDs[key] {
                item["net"] = netID
            } else {
                item.removeValue(forKey: "net")
            }
            junctions[key] = item
        }
        json["junctions"] = junctions
    }

    private static func patchSchematicNetLines(
        _ json: inout JSONDictionary,
        sheet: HorizontalSchematicSheet
    ) {
        var map = json["net_lines"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: sheet.netLines.map(\.id))
        for line in sheet.netLines {
            let key = matchingKey(line.id, in: map) ?? line.id
            var item = map[key] as? JSONDictionary ?? [:]
            if let fromEndpoint = schematicNetLineEndpoint(at: line.from, netID: line.netID, in: sheet) {
                item["from"] = fromEndpoint
            }
            if let toEndpoint = schematicNetLineEndpoint(at: line.to, netID: line.netID, in: sheet) {
                item["to"] = toEndpoint
            }
            if let netID = line.netID {
                item["net"] = netID
            } else {
                item.removeValue(forKey: "net")
            }
            guard item["from"] != nil, item["to"] != nil else {
                continue
            }
            map[key] = item
        }
        json["net_lines"] = map
    }

    private static func schematicJunctionEndpoint(_ junctionID: String) -> JSONDictionary {
        [
            "bus_ripper": NSNull(),
            "junc": junctionID,
            "pin": NSNull(),
            "port": NSNull()
        ]
    }

    private static func schematicPinEndpoint(_ pinPath: String) -> JSONDictionary {
        [
            "bus_ripper": NSNull(),
            "junc": NSNull(),
            "pin": pinPath,
            "port": NSNull()
        ]
    }

    private static func schematicNetLineEndpoint(
        at point: HorizontalPoint,
        netID: String?,
        in sheet: HorizontalSchematicSheet
    ) -> JSONDictionary? {
        if let junctionID = junctionID(at: point, in: sheet.junctions) {
            return schematicJunctionEndpoint(junctionID)
        }
        if let pinPath = schematicSymbolPinPath(at: point, netID: netID, in: sheet) {
            return schematicPinEndpoint(pinPath)
        }
        return nil
    }

    private static func schematicSymbolPinPath(
        at point: HorizontalPoint,
        netID: String?,
        in sheet: HorizontalSchematicSheet
    ) -> String? {
        let key = jsonPointKey(point)
        for pin in sheet.symbolPins where jsonPointKey(pin.from) == key && netsMatch(pin.netID, netID) {
            if let pinPath = schematicSymbolPinPath(fromGeometryID: pin.id) {
                return pinPath
            }
        }
        return nil
    }

    private static func schematicSymbolPinPath(fromGeometryID geometryID: String) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[1] == "pin" else {
            return nil
        }
        return "\(components[0])/\(components[2])"
    }

    private static func junctionID(at point: HorizontalPoint, in junctions: [String: HorizontalPoint]) -> String? {
        let key = jsonPointKey(point)
        return junctions.first { jsonPointKey($0.value) == key }?.key
    }

    private static func patchSchematicDrawingLines(
        _ json: inout JSONDictionary,
        lines: [HorizontalSegment],
        junctions: [String: HorizontalPoint]
    ) {
        var map = json["lines"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: lines.map { sourceID($0.id, removing: "sheet/line") })

        for line in lines {
            let sourceID = sourceID(line.id, removing: "sheet/line")
            guard let fromJunctionID = junctionID(at: line.from, in: junctions),
                  let toJunctionID = junctionID(at: line.to, in: junctions) else {
                continue
            }

            let key = matchingKey(sourceID, in: map) ?? sourceID
            var item = map[key] as? JSONDictionary ?? [:]
            item["from"] = fromJunctionID
            item["to"] = toJunctionID
            if item["width"] != nil || line.width > 0 {
                item["width"] = jsonNumber(line.width)
            }
            if let layer = line.layer {
                item["layer"] = layer
            }
            map[key] = item
        }
        json["lines"] = map
    }

    private static func patchSchematicDrawingArcs(
        _ json: inout JSONDictionary,
        arcs: [HorizontalArc],
        junctions: [String: HorizontalPoint]
    ) {
        var map = json["arcs"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: arcs.map { sourceID($0.id, removing: "sheet/arc") })

        for arc in arcs {
            let sourceID = sourceID(arc.id, removing: "sheet/arc")
            guard let fromJunctionID = junctionID(at: arc.from, in: junctions),
                  let toJunctionID = junctionID(at: arc.to, in: junctions),
                  let centerJunctionID = junctionID(at: arc.center, in: junctions) else {
                continue
            }

            let key = matchingKey(sourceID, in: map) ?? sourceID
            var item = map[key] as? JSONDictionary ?? [:]
            item["from"] = arc.reverse ? toJunctionID : fromJunctionID
            item["to"] = arc.reverse ? fromJunctionID : toJunctionID
            item["center"] = centerJunctionID
            if item["width"] != nil || arc.width > 0 {
                item["width"] = jsonNumber(arc.width)
            }
            if let layer = arc.layer {
                item["layer"] = layer
            }
            map[key] = item
        }
        json["arcs"] = map
    }

    private static func patchPlacements(
        _ json: inout JSONDictionary,
        key: String,
        placements: [HorizontalPlacement],
        boardPackages: Bool
    ) {
        var map = json[key] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: placements.map(\.id))

        for placement in placements {
            let itemKey = matchingKey(placement.id, in: map) ?? placement.id
            var item = map[itemKey] as? JSONDictionary ?? [:]
            if !boardPackages && map[itemKey] == nil {
                guard let componentID = placement.componentID,
                      let gateID = placement.gateID,
                      let symbolID = placement.symbolID else {
                    continue
                }
                item["component"] = componentID
                item["gate"] = gateID
                item["symbol"] = symbolID
            } else if map[itemKey] == nil {
                continue
            }

            var placementJSON = item["placement"] as? JSONDictionary ?? [:]
            placementJSON["shift"] = jsonPoint(placement.position)
            placementJSON["angle"] = jsonNumber(Double(placement.angle))
            placementJSON["mirror"] = placement.mirrored
            item["placement"] = placementJSON
            if boardPackages, item["flip"] != nil {
                item["flip"] = placement.mirrored
            }
            if !boardPackages {
                if let customValue = placement.customValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !customValue.isEmpty {
                    item["custom_value"] = customValue
                } else {
                    item.removeValue(forKey: "custom_value")
                }
                item["pin_display_mode"] = placement.pinDisplayMode
            }
            map[itemKey] = item
        }
        json[key] = map
    }

    private static func patchAddedSchematicComponents(
        _ components: [HorizontalSchematicComponentRecord],
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        guard !components.isEmpty,
              let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }

        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        var componentMap = json["components"] as? JSONDictionary ?? [:]
        var tagNames = json["tag_names"] as? JSONDictionary ?? [:]

        for component in components {
            let key = matchingKey(component.id, in: componentMap) ?? component.id
            var item = componentMap[key] as? JSONDictionary ?? [:]
            item["alt_pins"] = item["alt_pins"] as? JSONDictionary ?? [:]
            item["connections"] = item["connections"] as? JSONDictionary ?? [:]
            item["entity"] = component.entityID
            item["group"] = item["group"] as? String ?? "00000000-0000-0000-0000-000000000000"
            item["part"] = component.partID
            item["pin_names"] = item["pin_names"] as? JSONDictionary ?? [:]
            item["refdes"] = component.refdes
            item["tag"] = component.tagID
            item["value"] = item["value"] as? String ?? ""
            componentMap[key] = item

            if tagNames[component.tagID] == nil {
                tagNames[component.tagID] = String(tagNames.count)
            }
        }

        json["components"] = componentMap
        json["tag_names"] = tagNames
        try saveJSON(json, relativePath: path, to: &archive)
    }

    private static func patchSchematicComponentConnections(
        _ componentInfo: [String: SchematicComponentInfo],
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        guard !componentInfo.isEmpty,
              let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }

        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        var componentMap = json["components"] as? JSONDictionary ?? [:]

        for (componentID, info) in componentInfo {
            guard let componentKey = matchingKey(componentID, in: componentMap),
                  var componentJSON = componentMap[componentKey] as? JSONDictionary else {
                continue
            }

            var connections = componentJSON["connections"] as? JSONDictionary ?? [:]
            for (gatePinPath, state) in info.connections {
                let key = matchingKey(gatePinPath, in: connections) ?? gatePinPath
                var entry = connections[key] as? JSONDictionary ?? [:]
                switch state {
                case .connected(let netID):
                    entry["net"] = netID
                case .notConnected:
                    entry.removeValue(forKey: "net")
                }
                connections[key] = entry
            }
            componentJSON["connections"] = connections
            componentMap[componentKey] = componentJSON
        }

        json["components"] = componentMap
        try saveJSON(json, relativePath: path, to: &archive)
    }

    private static func patchSegments(
        _ json: inout JSONDictionary,
        key: String,
        segments: [HorizontalSegment],
        idPrefix: String? = nil,
        supportsLayer: Bool,
        supportsArcCenter: Bool = false
    ) {
        guard var map = json[key] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: segments.map { sourceID($0.id, removing: idPrefix) })

        for segment in segments {
            let sourceID = sourceID(segment.id, removing: idPrefix)
            guard let itemKey = matchingKey(sourceID, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }

            if item["width"] != nil || segment.width > 0 {
                item["width"] = jsonNumber(segment.width)
            }
            if supportsLayer, let layer = segment.layer {
                item["layer"] = layer
            }
            if supportsArcCenter {
                if let center = segment.center {
                    item["center"] = jsonPoint(center)
                } else {
                    item.removeValue(forKey: "center")
                }
            }
            map[itemKey] = item
        }
        json[key] = map
    }

    /// Writes full entries for newly drawn board tracks. `patchSegments` only
    /// patches width/layer/center on tracks that already exist in the JSON
    /// (it never writes `from`/`to`), because the move tool only relocates
    /// existing tracks. Interactively drawn tracks have no JSON entry yet, so
    /// here we emit `from`/`to` as junction references (mirroring
    /// `patchBoardDrawingLines`) plus the track's net, width and layer. The new
    /// junctions themselves are written by `patchJunctions`.
    private static func patchNewBoardTracks(
        _ json: inout JSONDictionary,
        tracks: [HorizontalSegment],
        junctions: [String: HorizontalPoint],
        padPositions: [String: HorizontalPoint] = [:]
    ) {
        var map = json["tracks"] as? JSONDictionary ?? [:]
        // Own-board geometry has plain UUID ids; panel-instance copies are
        // prefixed "panelID/…" — never serialize those into the host board.
        for track in tracks where !track.id.contains("/") {
            // Skip tracks that already round-trip through patchSegments.
            guard matchingKey(track.id, in: map) == nil else {
                continue
            }
            guard let fromEndpoint = boardTrackEndpoint(at: track.from, junctions: junctions, padPositions: padPositions),
                  let toEndpoint = boardTrackEndpoint(at: track.to, junctions: junctions, padPositions: padPositions) else {
                continue
            }

            // Field set + defaults mirror Track::serialize. Notably
            // `width_from_net_class` defaults to true on load, which would make
            // Horizon ignore our explicit width — so we pin it false.
            var item: JSONDictionary = [
                "from": fromEndpoint,
                "to": toEndpoint,
                "width": jsonNumber(track.width),
                "layer": track.layer ?? HorizontalBoardLayers.topCopper,
                "width_from_net_class": false,
                "locked": false
            ]
            // Curved track: the arc center is a coordinate (Horizon stores it as
            // a point, not a junction).
            if let center = track.center {
                item["center"] = jsonPoint(center)
            }
            // Not part of Track::serialize (net is derived from the
            // endpoints there), but our parser reads it as the primary net
            // source, so we keep it for a lossless in-app round-trip.
            if let netID = track.netID {
                item["net"] = netID
            }
            map[track.id] = item
        }
        json["tracks"] = map
    }

    private static func boardJunctionEndpoint(_ junctionID: String) -> JSONDictionary {
        ["junc": junctionID, "pad": NSNull()]
    }

    /// Resolves a drawn track endpoint to its serialized connection: a junction
    /// reference when a junction sits at the point, else a direct pad reference
    /// when the point is a retained pad center (the draw tool snaps pad
    /// endpoints to pad centers and skips junction creation there).
    private static func boardTrackEndpoint(
        at point: HorizontalPoint,
        junctions: [String: HorizontalPoint],
        padPositions: [String: HorizontalPoint]
    ) -> JSONDictionary? {
        if let junctionID = junctionID(at: point, in: junctions) {
            return boardJunctionEndpoint(junctionID)
        }
        let key = jsonPointKey(point)
        if let padPath = padPositions.first(where: { jsonPointKey($0.value) == key })?.key {
            return ["junc": NSNull(), "pad": padPath]
        }
        return nil
    }

    /// Writes full entries for interactively placed vias. `patchVias` only
    /// patches the diameter of vias already present, so newly dropped vias need
    /// their own entry — junction reference + the supplied pool padstack +
    /// parameter_set, as `source: "local"` (from_rules false) so our geometry
    /// is honored. Field set mirrors Via::serialize. New junctions are
    /// written by patchJunctions.
    private static func patchNewBoardVias(
        _ json: inout JSONDictionary,
        vias: [HorizontalMarker],
        junctions: [String: HorizontalPoint],
        padstackID: String?
    ) {
        guard let padstackID else {
            return
        }
        var map = json["vias"] as? JSONDictionary ?? [:]
        for via in vias where !via.id.contains("/") {
            guard matchingKey(via.id, in: map) == nil else {
                continue
            }
            guard let junctionID = junctionID(at: via.position, in: junctions) else {
                continue
            }
            var parameterSet: JSONDictionary = ["via_diameter": jsonNumber(via.size)]
            if let hole = via.holeSize {
                parameterSet["hole_diameter"] = jsonNumber(hole)
            }
            var item: JSONDictionary = [
                "junction": junctionID,
                "padstack": padstackID,
                "parameter_set": parameterSet,
                "from_rules": false,
                "source": "local",
                "locked": false
            ]
            if let netID = via.netID {
                item["net_set"] = netID
            }
            map[via.id] = item
        }
        json["vias"] = map
    }

    private static func patchBoardDrawingLines(
        _ json: inout JSONDictionary,
        lines: [HorizontalSegment],
        junctions: [String: HorizontalPoint]
    ) {
        let ownLines = lines.filter { !$0.id.contains("/") }
        var map = json["lines"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: ownLines.map(\.id))

        for line in ownLines {
            guard let fromJunctionID = junctionID(at: line.from, in: junctions),
                  let toJunctionID = junctionID(at: line.to, in: junctions) else {
                continue
            }

            let itemKey = matchingKey(line.id, in: map) ?? line.id
            var item = map[itemKey] as? JSONDictionary ?? [:]
            item["from"] = fromJunctionID
            item["to"] = toJunctionID
            if item["width"] != nil || line.width > 0 {
                item["width"] = jsonNumber(line.width)
            }
            if let layer = line.layer {
                item["layer"] = layer
            }
            map[itemKey] = item
        }
        json["lines"] = map
    }

    private static func patchBoardDrawingArcs(
        _ json: inout JSONDictionary,
        arcs: [HorizontalArc],
        junctions: [String: HorizontalPoint]
    ) {
        let ownArcs = arcs.filter { !$0.id.contains("/") }
        var map = json["arcs"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: ownArcs.map(\.id))

        for arc in ownArcs {
            guard let fromJunctionID = junctionID(at: arc.from, in: junctions),
                  let toJunctionID = junctionID(at: arc.to, in: junctions),
                  let centerJunctionID = junctionID(at: arc.center, in: junctions) else {
                continue
            }

            let itemKey = matchingKey(arc.id, in: map) ?? arc.id
            var item = map[itemKey] as? JSONDictionary ?? [:]
            item["from"] = arc.reverse ? toJunctionID : fromJunctionID
            item["to"] = arc.reverse ? fromJunctionID : toJunctionID
            item["center"] = centerJunctionID
            if item["width"] != nil || arc.width > 0 {
                item["width"] = jsonNumber(arc.width)
            }
            if let layer = arc.layer {
                item["layer"] = layer
            }
            map[itemKey] = item
        }
        json["arcs"] = map
    }

    private static func patchPolygons(
        _ json: inout JSONDictionary,
        key: String,
        polygons: [HorizontalPolygon],
        removing removedIDs: Set<String> = []
    ) {
        let ownPolygons = polygons.filter { !$0.id.contains("/") }
        var map = json[key] as? JSONDictionary ?? [:]
        // NOTE: we intentionally do NOT remove map entries the model doesn't
        // know about. The parser silently drops objects whose dependencies it
        // couldn't resolve (e.g. polygons with unparseable arc vertices); if we
        // also removed them on write we would silently destroy user data the
        // file still contains. So absence-from-model means "we couldn't parse
        // it", not "the user deleted it" — deletions come through `removedIDs`,
        // an explicit set the editor populates (e.g. polygon → line loop).
        for id in removedIDs {
            if let itemKey = matchingKey(id, in: map) {
                map.removeValue(forKey: itemKey)
            }
        }

        for polygon in ownPolygons {
            let itemKey = matchingKey(polygon.id, in: map) ?? polygon.id
            var item = map[itemKey] as? JSONDictionary ?? [:]

            if let layer = polygon.layer {
                item["layer"] = layer
            }
            // Horizon always serializes parameter_class; default it for freshly
            // created polygons (e.g. a drawn plane outline) so the entry matches
            // schema. Existing polygons keep their stored value.
            if item["parameter_class"] == nil {
                item["parameter_class"] = ""
            }
            item["vertices"] = reconciledVertices(item["vertices"] as? [JSONDictionary] ?? [], vertices: polygon.polygonVertices)
            map[itemKey] = item
        }
        json[key] = map
    }

    private static func reconciledVertices(_ existing: [JSONDictionary], vertices: [HorizontalPolygonVertex]) -> [JSONDictionary] {
        var remaining = existing
        var result = [JSONDictionary]()

        for polygonVertex in vertices {
            let key = jsonPointKey(polygonVertex.position)
            let index = remaining.firstIndex { vertex in
                guard let position = vertex.point("position") else {
                    return false
                }
                return jsonPointKey(position) == key
            } ?? remaining.startIndex

            var vertex = remaining.isEmpty ? JSONDictionary() : remaining.remove(at: index)
            vertex["type"] = polygonVertex.type.rawValue
            vertex["position"] = jsonPoint(polygonVertex.position)
            vertex["arc_center"] = jsonPoint(polygonVertex.arcCenter)
            vertex["arc_reverse"] = polygonVertex.arcReverse
            result.append(vertex)
        }

        return result
    }

    private static func patchHoles(_ json: inout JSONDictionary, key: String, holes: [HorizontalHole]) {
        guard var map = json[key] as? JSONDictionary else {
            return
        }
        // Preserve unknown source entries. See note in patchPolygons.

        for hole in holes {
            guard let itemKey = matchingKey(hole.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }

            var placement = item["placement"] as? JSONDictionary ?? [:]
            placement["shift"] = jsonPoint(hole.position)
            placement["angle"] = hole.angle
            item["placement"] = placement
            item["diameter"] = jsonNumber(hole.diameter)
            item["length"] = jsonNumber(hole.effectiveLength)
            item["shape"] = hole.shape.rawValue
            item["plated"] = hole.plated
            map[itemKey] = item
        }
        json[key] = map
    }

    private static func patchVias(_ json: inout JSONDictionary, vias: [HorizontalMarker]) {
        guard var map = json["vias"] as? JSONDictionary else {
            return
        }
        // Preserve unknown source entries. See note in patchPolygons.

        for via in vias {
            guard let itemKey = matchingKey(via.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            var parameters = item["parameter_set"] as? JSONDictionary ?? [:]
            parameters["via_diameter"] = jsonNumber(via.size)
            item["parameter_set"] = parameters
            map[itemKey] = item
        }
        json["vias"] = map
    }

    private static func patchPlanes(_ json: inout JSONDictionary, planes: [HorizontalPlane]) {
        let ownPlanes = planes.filter { !$0.id.contains("/") }
        // Use ?? [:] (not a guard) so a board that never had planes can gain its
        // first drawn plane. Preserve unknown source entries (see patchPolygons).
        var map = json["planes"] as? JSONDictionary ?? [:]

        for plane in ownPlanes {
            // matchingKey ?? plane.id: update an existing plane in place, or
            // create a brand-new entry for a freshly drawn plane.
            let itemKey = matchingKey(plane.id, in: map) ?? plane.id
            let existing = map[itemKey] as? JSONDictionary
            map[itemKey] = planeJSONEntry(plane, existing: existing)
        }
        json["planes"] = map
    }

    /// Builds a single plane's on-disk entry, matching the on-disk schema
    /// (board/plane.cpp Plane::serialize): { net, polygon, priority, from_rules,
    /// settings }. Fragments are NOT stored here — they live in the separate plane
    /// cache (applyPlaneCache). Merges over any existing entry so unknown keys are
    /// preserved and an unchanged net keeps its original casing.
    static func planeJSONEntry(_ plane: HorizontalPlane, existing: JSONDictionary?) -> JSONDictionary {
        var item = existing ?? [:]
        if let netID = plane.netID {
            let existingNet = item["net"] as? String
            if existingNet.map(normalizedID) != normalizedID(netID) {
                item["net"] = netID
            }
        }
        item["polygon"] = plane.polygonID
        item["priority"] = plane.priority
        item["from_rules"] = plane.fromRules
        item["settings"] = planeSettingsJSON(plane.settings, existing: item["settings"] as? JSONDictionary)
        return item
    }

    /// Serializes plane settings to exact schema (board/plane.cpp
    /// PlaneSettings::serialize + ThermalSettings::serialize, the thermal keys
    /// inlined into the same object). Merges over any existing dictionary so
    /// unknown keys a future Horizon writes are preserved.
    static func planeSettingsJSON(_ settings: HorizontalPlaneSettings, existing: JSONDictionary?) -> JSONDictionary {
        var j = existing ?? [:]
        j["min_width"] = settings.minWidth
        j["keep_orphans"] = settings.keepOrphans
        j["style"] = planeStyleString(settings.style)
        // ThermalSettings::serialize writes these inline (no nested object).
        j["connect_style"] = connectStyleString(settings.thermalSettings.connectStyle)
        j["thermal_gap_width"] = settings.thermalSettings.thermalGapWidth
        j["thermal_spoke_width"] = settings.thermalSettings.thermalSpokeWidth
        j["n_spokes"] = settings.thermalSettings.nSpokes
        j["angle"] = settings.thermalSettings.angle
        j["text_style"] = textStyleString(settings.textStyle)
        j["fill_style"] = fillStyleString(settings.fillStyle)
        j["hatch_border_width"] = settings.hatchBorderWidth
        j["hatch_line_spacing"] = settings.hatchLineSpacing
        j["hatch_line_width"] = settings.hatchLineWidth
        return j
    }

    private static func planeStyleString(_ style: HorizontalPlaneSettings.Style) -> String {
        switch style {
        case .round: return "round"
        case .square: return "square"
        case .miter: return "miter"
        }
    }

    private static func textStyleString(_ style: HorizontalPlaneSettings.TextStyle) -> String {
        switch style {
        case .expand: return "expand"
        case .bbox: return "bbox"
        }
    }

    private static func fillStyleString(_ style: HorizontalPlaneSettings.FillStyle) -> String {
        switch style {
        case .solid: return "solid"
        case .hatch: return "hatch"
        }
    }

    private static func connectStyleString(_ style: HorizontalThermalSettings.ConnectStyle) -> String {
        switch style {
        case .solid: return "solid"
        case .thermal: return "thermal"
        case .fromPlane: return "from_plane"
        case .none: return "none"
        }
    }

    private static func patchKeepouts(_ json: inout JSONDictionary, keepouts: [HorizontalKeepout]) {
        guard var map = json["keepouts"] as? JSONDictionary else {
            return
        }
        // Preserve unknown source entries. See note in patchPolygons.

        for keepout in keepouts {
            guard let itemKey = matchingKey(keepout.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            item["keepout_class"] = keepout.keepoutClass
            map[itemKey] = item
        }
        json["keepouts"] = map
    }

    private static func patchDimensions(_ json: inout JSONDictionary, dimensions: [HorizontalDimension]) {
        guard var map = json["dimensions"] as? JSONDictionary else {
            return
        }
        // Preserve unknown source entries. See note in patchPolygons.

        for dimension in dimensions {
            guard let itemKey = matchingKey(dimension.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            item["label_size"] = jsonNumber(dimension.labelSize)
            item["mode"] = dimension.mode.rawValue
            map[itemKey] = item
        }
        json["dimensions"] = map
    }

    /// Creates JSON entries for texts whose id isn't already present (i.e.
    /// freshly added via "Add Text"). `patchTexts` only updates existing entries,
    /// so this mirrors `patchNewBoardVias` for the create path. Shared by the
    /// board and schematic sheets (both use the same absolute-text schema).
    private static func patchNewTexts(_ json: inout JSONDictionary, key: String, texts: [HorizontalText]) {
        var map = json[key] as? JSONDictionary ?? [:]
        for text in texts where !text.id.contains("/") {
            guard matchingKey(text.id, in: map) == nil else {
                continue
            }
            let placement: JSONDictionary = [
                "shift": jsonPoint(text.position),
                "angle": jsonNumber(Double(text.angle)),
                "mirror": text.mirrored
            ]
            var item: JSONDictionary = [
                "text": text.text,
                "placement": placement,
                "size": jsonNumber(text.size),
                "width": jsonNumber(text.width),
                "origin": text.origin.rawValue,
                "font": text.font.rawValue,
                "allow_upside_down": text.allowUpsideDown,
                "from_smash": text.fromSmash
            ]
            if let layer = text.layer {
                item["layer"] = layer
            }
            map[text.id] = item
        }
        json[key] = map
    }

    private static func patchTexts(
        _ json: inout JSONDictionary,
        key: String,
        texts: [HorizontalText],
        keepingAdditional: Set<String> = []
    ) {
        guard var map = json[key] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: texts.map(\.id) + keepingAdditional)

        for text in texts {
            guard let itemKey = matchingKey(text.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }

            var placement = item["placement"] as? JSONDictionary ?? [:]
            placement["shift"] = jsonPoint(text.position)
            placement["angle"] = jsonNumber(Double(text.angle))
            placement["mirror"] = text.mirrored
            item["placement"] = placement
            item["text"] = text.text
            item["size"] = jsonNumber(text.size)
            item["width"] = jsonNumber(text.width)
            if let layer = text.layer {
                item["layer"] = layer
            }
            item["origin"] = text.origin.rawValue
            item["font"] = text.font.rawValue
            item["allow_upside_down"] = text.allowUpsideDown
            item["from_smash"] = text.fromSmash
            map[itemKey] = item
        }
        json[key] = map
    }

    /// Board-level text entries for the "texts" map: standalone board texts plus
    /// the editable copies extracted by Smash (which live in `packageTexts` with a
    /// `{packageID}/text/{uuid}` id — rekeyed here to the bare `uuid` the package
    /// references). The package side (`smashed` + `texts[]`) is written by
    /// `patchPackageSmashState`.
    private static func boardLevelTexts(texts: [HorizontalText], packageTexts: [HorizontalText]) -> [HorizontalText] {
        let smashed = packageTexts.compactMap { text -> HorizontalText? in
            guard text.fromSmash, let uuid = smashedTextComponents(text.id)?.uuid else {
                return nil
            }
            var rekeyed = text
            rekeyed.id = uuid
            return rekeyed
        }
        return texts + smashed
    }

    /// Writes each package's `smashed` flag and, for smashed packages, the `texts`
    /// array referencing its `fromSmash` text uuids (the inverse of the loader's
    /// `packageTextIDs` / `smashed` read).
    private static func patchPackageSmashState(
        _ json: inout JSONDictionary,
        packages: [HorizontalPlacement],
        packageTexts: [HorizontalText],
        preserving: Set<String> = []
    ) {
        guard var map = json["packages"] as? JSONDictionary else {
            return
        }
        var uuidsByPackage = [String: [String]]()
        for text in packageTexts where text.fromSmash {
            if let parts = smashedTextComponents(text.id) {
                uuidsByPackage[normalizedID(parts.packageID), default: []].append(parts.uuid)
            }
        }
        for package in packages {
            guard let itemKey = matchingKey(package.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            // omit_silkscreen / fixed are always serialized by Horizon; omit_outline
            // only when true. These round-trip independently of the smash texts.
            item["omit_silkscreen"] = package.omitSilkscreen
            item["fixed"] = package.fixed
            if package.omitOutline {
                item["omit_outline"] = true
            } else {
                item.removeValue(forKey: "omit_outline")
            }
            // Leave smashed packages whose texts weren't materialized untouched
            // (their existing `smashed`/`texts` are preserved verbatim).
            if !preserving.contains(normalizedID(package.id)) {
                // Horizon always serializes both keys on a board package; `texts`
                // is the (possibly empty) list of from-smash text uuids.
                item["smashed"] = package.smashed
                item["texts"] = uuidsByPackage[normalizedID(package.id)] ?? []
            }
            map[itemKey] = item
        }
        json["packages"] = map
    }

    /// The `texts`-map uuids referenced by the given (unmaterialized smashed)
    /// packages, so a save preserves them instead of dropping them.
    private static func preservedSmashTextUUIDs(in json: JSONDictionary, packageIDs: Set<String>) -> Set<String> {
        guard !packageIDs.isEmpty, let map = json["packages"] as? JSONDictionary else {
            return []
        }
        var ids = Set<String>()
        for (key, value) in map where packageIDs.contains(normalizedID(key)) {
            if let item = value as? JSONDictionary, let texts = item["texts"] as? [String] {
                ids.formUnion(texts.map(normalizedID))
            }
        }
        return ids
    }

    /// Splits a smashed package-text id "{packageID}/text/{uuid}" into its parts.
    private static func smashedTextComponents(_ id: String) -> (packageID: String, uuid: String)? {
        guard let range = id.range(of: "/text/") else {
            return nil
        }
        let packageID = String(id[id.startIndex..<range.lowerBound])
        let uuid = String(id[range.upperBound...])
        guard !packageID.isEmpty, !uuid.isEmpty else {
            return nil
        }
        return (packageID, uuid)
    }

    private static func patchSchematicNetLabels(_ json: inout JSONDictionary, labels: [HorizontalSchematicNetLabel]) {
        guard var map = json["net_labels"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: labels.map(\.id))

        for label in labels {
            guard let itemKey = matchingKey(label.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            item["size"] = jsonNumber(label.size)
            if let netID = label.netID {
                item["last_net"] = netID
            } else {
                item.removeValue(forKey: "last_net")
            }
            map[itemKey] = item
        }
        json["net_labels"] = map
    }

    private static func patchSchematicBusLabels(_ json: inout JSONDictionary, labels: [HorizontalBusLabel]) {
        guard var map = json["bus_labels"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: labels.map(\.id))

        for label in labels {
            guard let itemKey = matchingKey(label.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            item["size"] = jsonNumber(label.size)
            map[itemKey] = item
        }
        json["bus_labels"] = map
    }

    private static func patchSchematicNetTies(_ json: inout JSONDictionary, netTies: [HorizontalSchematicNetTie]) {
        guard var map = json["net_ties"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: netTies.map(\.id))
        json["net_ties"] = map
    }

    private static func patchSchematicPowerSymbols(
        _ json: inout JSONDictionary,
        powerSymbols: [HorizontalPowerSymbol],
        fallbackPowerSymbolIDs: [String]
    ) {
        guard var map = json["power_symbols"] as? JSONDictionary else {
            return
        }
        let keptIDs = powerSymbols.isEmpty ? fallbackPowerSymbolIDs : powerSymbols.map(\.id)
        removeEntriesNotIn(&map, keeping: keptIDs)

        for symbol in powerSymbols {
            guard let itemKey = matchingKey(symbol.id, in: map),
                  var item = map[itemKey] as? JSONDictionary else {
                continue
            }
            item["junction"] = symbol.junctionID
            if let netID = symbol.netID {
                item["net"] = netID
            } else {
                item.removeValue(forKey: "net")
            }
            item["orientation"] = symbol.orientation
            item["mirror"] = symbol.mirrored
            map[itemKey] = item
        }
        json["power_symbols"] = map
    }

    private static func patchSchematicBusRippers(_ json: inout JSONDictionary, busRipperIDs: [String]) {
        guard var map = json["bus_rippers"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: busRipperIDs)
        json["bus_rippers"] = map
    }

    private static func patchSchematicBlockSymbols(_ json: inout JSONDictionary, blockSymbolIDs: [String]) {
        guard var map = json["block_symbols"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: blockSymbolIDs)
        json["block_symbols"] = map
    }

    private static func patchBoardPanels(_ json: inout JSONDictionary, panels: [HorizontalBoardPanel]) {
        guard var map = json["board_panels"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: panels.map(\.id))
        json["board_panels"] = map
    }

    private static func schematicPowerSymbolIDs(in sheet: HorizontalSchematicSheet) -> [String] {
        groupedObjectIDs(
            geometryIDs: sheet.powerSymbolLines.map(\.id)
                + sheet.powerSymbolCircles.map(\.id)
                + sheet.powerSymbolTexts.map(\.id),
            separators: ["circle", "line", "text"]
        )
    }

    private static func schematicBusRipperIDs(in sheet: HorizontalSchematicSheet) -> [String] {
        groupedObjectIDs(
            geometryIDs: sheet.busRipperLines.map(\.id) + sheet.busRipperTexts.map(\.id),
            separators: ["bus-ripper", "line", "text"]
        )
    }

    private static func schematicBlockSymbolIDs(in sheet: HorizontalSchematicSheet) -> [String] {
        groupedObjectIDs(
            geometryIDs: sheet.blockSymbolLines.map(\.id)
                + sheet.blockSymbolPorts.map(\.id)
                + sheet.blockSymbolTexts.map(\.id),
            separators: ["block-line", "block-port", "block-text", "line", "port", "text"]
        )
    }

    private static func groupedObjectIDs(geometryIDs: [String], separators: Set<String>) -> [String] {
        var ids = Set<String>()
        for geometryID in geometryIDs {
            if let objectID = objectIDPrefix(in: geometryID, separators: separators)
                ?? normalizedID(geometryID).split(separator: "/").first.map(String.init) {
                ids.insert(objectID)
            }
        }
        return Array(ids)
    }

    private static func objectIDPrefix(in geometryID: String, separators: Set<String>) -> String? {
        let components = normalizedID(geometryID).split(separator: "/").map(String.init)
        guard let separatorIndex = components.firstIndex(where: { separators.contains($0) }),
              separatorIndex > components.startIndex else {
            return nil
        }
        return components[..<separatorIndex].joined(separator: "/")
    }

    private static func removeEntriesNotIn(_ map: inout JSONDictionary, keeping ids: [String]) {
        let wantedIDs = Set(ids.map(normalizedID))
        map = map.filter { wantedIDs.contains(normalizedID($0.key)) }
    }

    private static func removedReferencedIDs(
        from map: [String: JSONDictionary],
        keeping ids: [String],
        referenceKey: String
    ) -> Set<String> {
        let wantedIDs = Set(ids.map(normalizedID))
        return Set(map.compactMap { key, item in
            guard !wantedIDs.contains(normalizedID(key)) else {
                return nil
            }
            return item.string(referenceKey).map(normalizedID)
        })
    }

    private static func removedKeys(from map: [String: JSONDictionary], keeping ids: [String]) -> Set<String> {
        let wantedIDs = Set(ids.map(normalizedID))
        return Set(map.keys.compactMap { key in
            wantedIDs.contains(normalizedID(key)) ? nil : normalizedID(key)
        })
    }

    private static func removeConnectionLinesReferencingPackages(_ json: inout JSONDictionary, packageIDs: Set<String>) {
        guard !packageIDs.isEmpty,
              var map = json["connection_lines"] as? JSONDictionary else {
            return
        }

        map = map.filter { _, value in
            guard let item = value as? JSONDictionary else {
                return true
            }
            return !endpointReferencesPackage(item.dictionary("from"), packageIDs: packageIDs)
                && !endpointReferencesPackage(item.dictionary("to"), packageIDs: packageIDs)
        }
        json["connection_lines"] = map
    }

    private static func endpointReferencesPackage(_ endpoint: JSONDictionary?, packageIDs: Set<String>) -> Bool {
        guard let endpoint,
              let packageID = endpoint.string("package") else {
            return false
        }
        return packageIDs.contains(normalizedID(packageID))
    }

    private static func removeBlockResourcesIfUnused(
        removedComponentIDs: Set<String>,
        removedBlockInstanceIDs: Set<String>,
        removedBlockNetTieIDs: Set<String>,
        schematicJSON: JSONDictionary,
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        let usedComponentIDs = referencedIDs(in: schematicJSON, sheetKey: "symbols", referenceKey: "component")
        let usedBlockInstanceIDs = referencedIDs(in: schematicJSON, sheetKey: "block_symbols", referenceKey: "block_instance")
        let usedBlockNetTieIDs = referencedIDs(in: schematicJSON, sheetKey: "net_ties", referenceKey: "net_tie")

        let componentIDs = removedComponentIDs.subtracting(usedComponentIDs)
        let blockInstanceIDs = removedBlockInstanceIDs.subtracting(usedBlockInstanceIDs)
        let blockNetTieIDs = removedBlockNetTieIDs.subtracting(usedBlockNetTieIDs)
        guard !componentIDs.isEmpty || !blockInstanceIDs.isEmpty || !blockNetTieIDs.isEmpty,
              let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }

        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var blockJSON = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        removeEntries(with: componentIDs, from: &blockJSON, key: "components")
        removeEntries(with: blockInstanceIDs, from: &blockJSON, key: "block_instances")
        removeEntries(with: blockNetTieIDs, from: &blockJSON, key: "net_ties")
        try saveJSON(blockJSON, relativePath: path, to: &archive)
    }

    private static func referencedIDs(in schematicJSON: JSONDictionary, sheetKey: String, referenceKey: String) -> Set<String> {
        guard let sheets = schematicJSON["sheets"] as? JSONDictionary else {
            return []
        }

        return Set(sheets.values.flatMap { sheetObject -> [String] in
            guard let sheet = sheetObject as? JSONDictionary else {
                return []
            }
            return sheet.dictionaryMap(sheetKey).values.compactMap { $0.string(referenceKey).map(normalizedID) }
        })
    }

    private static func removeEntries(with ids: Set<String>, from json: inout JSONDictionary, key: String) {
        guard !ids.isEmpty,
              var map = json[key] as? JSONDictionary else {
            return
        }
        map = map.filter { !ids.contains(normalizedID($0.key)) }
        json[key] = map
    }

    private static func blockURL(for schematicURL: URL, in project: HorizontalProject) -> URL? {
        let standardized = schematicURL.standardizedFileURL
        if let schematic = project.schematics.first(where: { $0.schematic.url.standardizedFileURL == standardized }),
           let blockFilename = schematic.block.blockFilename {
            return project.baseURL.appendingPathComponent(blockFilename)
        }
        if project.schematic?.url.standardizedFileURL == standardized,
           let blockFilename = project.blockFilename {
            return project.baseURL.appendingPathComponent(blockFilename)
        }
        return nil
    }

    private static func archivePath(
        for url: URL,
        project: HorizontalProject,
        archive: HorizontalProjectArchive
    ) throws -> String {
        if let path = archive.manifest?.relativePath(for: url) {
            return path
        }
        if let path = relativePath(for: url, baseURL: project.baseURL) {
            return path
        }
        throw HorizontalProjectJSONApplyError.missingArchivePath(url)
    }

    private static func loadJSON(
        relativePath: String,
        fallbackURL: URL,
        from archive: HorizontalProjectArchive
    ) throws -> JSONDictionary {
        let data: Data
        if let archiveData = archive.regularFileData(relativePath: relativePath) {
            data = archiveData
        } else if FileManager.default.fileExists(atPath: fallbackURL.path) {
            data = try Data(contentsOf: fallbackURL)
        } else {
            throw HorizontalProjectJSONApplyError.missingJSON(relativePath)
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let json = object as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(relativePath)
        }
        return json
    }

    private static func saveJSON(
        _ json: JSONDictionary,
        relativePath: String,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var terminated = data
        terminated.append(0x0A)
        try archive.replaceRegularFileData(relativePath: relativePath, with: terminated)
    }

    private static func relativePath(for url: URL, baseURL: URL) -> String? {
        let basePath = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }

    private static func matchingKey(_ id: String, in map: JSONDictionary) -> String? {
        if map[id] != nil {
            return id
        }
        let normalized = normalizedID(id)
        return map.keys.first { normalizedID($0) == normalized }
    }

    private static func sourceID(_ id: String, removing prefix: String?) -> String {
        guard let prefix else {
            return id
        }
        let marker = "\(prefix)/"
        guard id.hasPrefix(marker) else {
            return id
        }
        return String(id.dropFirst(marker.count))
    }

    private static func jsonPoint(_ point: HorizontalPoint) -> [Any] {
        [jsonNumber(point.x), jsonNumber(point.y)]
    }

    private static func jsonNumber(_ value: Double) -> Any {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0001,
           rounded >= Double(Int.min),
           rounded <= Double(Int.max) {
            return Int(rounded)
        }
        return value
    }

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }

    private static func netsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return normalizedID(lhs) == normalizedID(rhs)
    }

    private static func jsonPointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }
}
