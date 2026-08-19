import Foundation

struct HorizontalSchematicBlockNetResource {
    var name: String
    var isPort: Bool
    var portDirection: String
}

struct HorizontalSchematicBlockResource {
    var symbolURL: URL
    var name: String
    var nets: [String: HorizontalSchematicBlockNetResource]
}

struct HorizontalSchematicNoPopulateMark: Identifiable, Hashable {
    var id: String
    var symbolID: String
    var firstLine: HorizontalSegment
    var secondLine: HorizontalSegment

    var points: [HorizontalPoint] {
        [firstLine.from, firstLine.to, secondLine.from, secondLine.to]
    }
}

struct HorizontalSchematicPartPlacementDraft {
    var sheet: HorizontalSchematicSheet
    var symbolInstanceID: String
    var componentID: String
}

struct SchematicComponentInfo {
    var refdes: String
    var value: String
    var partID: String?
    var noPopulate: Bool
    var gateSuffixes: [String: String]
    var gateSymbolIDs: [String: String]
    var altPins: [String: SchematicAltPinInfo]
    var connections: [String: SchematicConnectionState]
    var details: HorizontalComponentDetails?
}

struct SchematicAltPinInfo {
    var pinNames: [String]
    var usePrimaryName: Bool
    var useCustomName: Bool
    var customName: String
    var customDirection: String
}

enum SchematicConnectionState {
    case connected(String)
    case notConnected

    var netID: String? {
        switch self {
        case .connected(let netID):
            return netID
        case .notConnected:
            return nil
        }
    }
}

struct HorizontalSchematicSheet: Identifiable {
    var id: String
    var name: String
    var index: Int
    var grid: HorizontalGridSettings
    var netClasses: [HorizontalNetClass]
    var junctions: [String: HorizontalPoint]
    var junctionNetIDs: [String: String]
    var netDetails: [String: HorizontalNetDetails]
    var netLines: [HorizontalSegment]
    var drawingLines: [HorizontalSegment]
    var drawingArcs: [HorizontalArc]
    var busLabels: [HorizontalBusLabel]
    var busRipperLines: [HorizontalSegment]
    var busRipperTexts: [HorizontalText]
    var blockSymbolLines: [HorizontalSegment]
    var blockSymbolPorts: [HorizontalSegment]
    var blockSymbolTexts: [HorizontalText]
    var netTies: [HorizontalSchematicNetTie]
    var symbols: [HorizontalPlacement]
    var symbolLines: [HorizontalSegment]
    var symbolPins: [HorizontalSegment]
    var symbolPinCircles: [HorizontalCircle]
    var symbolPolygons: [HorizontalPolygon]
    var symbolTexts: [HorizontalText]
    var noPopulateMarks: [HorizontalSchematicNoPopulateMark]
    var frameLines: [HorizontalSegment]
    var framePolygons: [HorizontalPolygon]
    var frameTexts: [HorizontalText]
    var texts: [HorizontalText]
    var netLabels: [HorizontalSchematicNetLabel]
    var powerSymbols: [HorizontalPowerSymbol]
    var powerSymbolLines: [HorizontalSegment]
    var powerSymbolCircles: [HorizontalCircle]
    var powerSymbolTexts: [HorizontalText]
    var placeableObjects: [HorizontalUnplacedObject] = []
    var unplacedObjects: [HorizontalUnplacedObject] = []
    var addedComponents: [HorizontalSchematicComponentRecord] = []
    var componentInfo: [String: SchematicComponentInfo] = [:]
    var bounds: HorizontalRect

    var junctionCount: Int { junctions.count }
    var netLineCount: Int { netLines.count }
    var drawingLineCount: Int { drawingLines.count + drawingArcs.count }
    var busLabelCount: Int { busLabels.count }
    var busRipperCount: Int { busRipperLines.count }
    var blockSymbolCount: Int {
        Set(
            (blockSymbolLines.map(\.id) + blockSymbolPorts.map(\.id) + blockSymbolTexts.map(\.id)).map {
                $0.split(separator: "/").first.map(String.init) ?? $0
            }
        ).count
    }
    var symbolCount: Int { symbols.count }
    var symbolPinCount: Int { symbolPins.count }
    var netTieCount: Int { netTies.count }
    var netLabelCount: Int { netLabels.count }
    var powerSymbolCount: Int {
        if !powerSymbols.isEmpty {
            return powerSymbols.count
        }
        return Set(powerSymbolLines.map { $0.id.split(separator: "/").first.map(String.init) ?? $0.id }).count
    }
    var textCount: Int { texts.count }
    var totalNetLength: Double { netLines.reduce(0) { $0 + $1.length } }
    var totalBusRipperLength: Double { busRipperLines.reduce(0) { $0 + $1.length } }
}

struct HorizontalSchematic {
    var url: URL
    var uuid: String
    var name: String
    var sheetName: String
    var grid: HorizontalGridSettings
    var netClasses: [HorizontalNetClass]
    var sheets: [HorizontalSchematicSheet]
    var junctions: [String: HorizontalPoint]
    var junctionNetIDs: [String: String]
    var netDetails: [String: HorizontalNetDetails]
    var netLines: [HorizontalSegment]
    var drawingLines: [HorizontalSegment]
    var drawingArcs: [HorizontalArc]
    var busLabels: [HorizontalBusLabel]
    var busRipperLines: [HorizontalSegment]
    var busRipperTexts: [HorizontalText]
    var blockSymbolLines: [HorizontalSegment]
    var blockSymbolPorts: [HorizontalSegment]
    var blockSymbolTexts: [HorizontalText]
    var netTies: [HorizontalSchematicNetTie]
    var symbols: [HorizontalPlacement]
    var symbolLines: [HorizontalSegment]
    var symbolPins: [HorizontalSegment]
    var symbolPinCircles: [HorizontalCircle]
    var symbolPolygons: [HorizontalPolygon]
    var symbolTexts: [HorizontalText]
    var noPopulateMarks: [HorizontalSchematicNoPopulateMark]
    var frameLines: [HorizontalSegment]
    var framePolygons: [HorizontalPolygon]
    var frameTexts: [HorizontalText]
    var texts: [HorizontalText]
    var netLabels: [HorizontalSchematicNetLabel]
    var powerSymbols: [HorizontalPowerSymbol]
    var powerSymbolLines: [HorizontalSegment]
    var powerSymbolCircles: [HorizontalCircle]
    var powerSymbolTexts: [HorizontalText]
    var placeableObjects: [HorizontalUnplacedObject]
    var unplacedObjects: [HorizontalUnplacedObject]
    var bounds: HorizontalRect

    private struct SchematicBlockInfo {
        var components: [String: SchematicComponentInfo] = [:]
        var nets: [String: SchematicNetInfo] = [:]
        var buses: [String: SchematicBusInfo] = [:]
        var blockInstances: [String: SchematicBlockInstanceInfo] = [:]
        var netTies: [String: SchematicNetTieInfo] = [:]
        var netClasses: [HorizontalNetClass] = []
        var netDetails: [String: HorizontalNetDetails] = [:]
        var projectMeta: [String: String] = [:]
    }

    private struct SchematicNetInfo {
        var name: String
        var netClassName: String?
        var isPower: Bool
        var isPort: Bool
        var portDirection: String
        var powerSymbolStyle: String
        var powerSymbolNameVisible: Bool
    }

    private struct SchematicBusInfo {
        var name: String
        var members: [String: SchematicBusMemberInfo]
    }

    private struct SchematicBusMemberInfo {
        var name: String
        var netID: String?
    }

    private struct SchematicBlockInstanceInfo {
        var blockID: String
        var refdes: String
        var connections: [String: SchematicConnectionState]
    }

    private struct SchematicNetTieInfo {
        var primaryID: String?
        var secondaryID: String?
        var primaryName: String
        var secondaryName: String
    }

    private struct SchematicPartInfo {
        var padNamesByGatePin: [String: [String]]
        var details: PartDetails?
    }

    private struct PartDetails {
        var value: String?
        var mpn: String?
        var manufacturer: String?
        var packageName: String?
        var description: String?
        var datasheet: String?
        var parametricValues: [String: String]
    }

    private struct SchematicFrameArtwork {
        var lines: [HorizontalSegment] = []
        var polygons: [HorizontalPolygon] = []
        var texts: [HorizontalText] = []

        var points: [HorizontalPoint] {
            var result = [HorizontalPoint]()
            appendPoints(to: &result)
            return result
        }

        func appendPoints(to result: inout [HorizontalPoint]) {
            for line in lines {
                result.append(line.from)
                result.append(line.to)
            }
            for polygon in polygons {
                result.append(contentsOf: polygon.vertices)
            }
            for text in texts {
                result.append(contentsOf: text.renderBoundsPoints)
            }
        }

        static let empty = SchematicFrameArtwork()
    }

    private struct SchematicSymbolResource {
        var unitID: String?
        var version: Int
        var junctions: [String: HorizontalPoint]
        var pins: [String: JSONDictionary]
        var lines: [String: JSONDictionary]
        var arcs: [String: JSONDictionary]
        var polygons: [String: JSONDictionary]
        var texts: [String: JSONDictionary]
        var textPlacements: [String: JSONDictionary]
    }

    private struct SchematicUnitPinInfo {
        var primaryName: String
        var primaryDirection: String
        var alternateNames: [String: String]
        var alternateNameOptions: [HorizontalSymbolPinNameOption]
    }

    private struct SchematicSymbolArtwork {
        var lines: [HorizontalSegment] = []
        var pins: [HorizontalSegment] = []
        var pinCircles: [HorizontalCircle] = []
        var polygons: [HorizontalPolygon] = []
        var texts: [HorizontalText] = []
        var noPopulateMarks: [HorizontalSchematicNoPopulateMark] = []
        var pinPositions: [String: HorizontalPoint] = [:]

        static let empty = SchematicSymbolArtwork()

        var points: [HorizontalPoint] {
            var result = [HorizontalPoint]()
            appendPoints(to: &result)
            return result
        }

        func appendPoints(to result: inout [HorizontalPoint]) {
            for line in lines {
                result.append(line.from)
                result.append(line.to)
            }
            for pin in pins {
                result.append(pin.from)
                result.append(pin.to)
            }
            for circle in pinCircles {
                result.append(contentsOf: circleBounds(circle))
            }
            for polygon in polygons {
                result.append(contentsOf: polygon.vertices)
            }
            for text in texts {
                result.append(contentsOf: text.renderBoundsPoints)
            }
            for mark in noPopulateMarks {
                result.append(contentsOf: mark.points)
            }
            result.append(contentsOf: pinPositions.values)
        }

        mutating func append(_ other: SchematicSymbolArtwork) {
            lines.append(contentsOf: other.lines)
            pins.append(contentsOf: other.pins)
            pinCircles.append(contentsOf: other.pinCircles)
            polygons.append(contentsOf: other.polygons)
            texts.append(contentsOf: other.texts)
            noPopulateMarks.append(contentsOf: other.noPopulateMarks)
            pinPositions.merge(other.pinPositions) { current, _ in current }
        }
    }

    private struct SchematicBusArtwork {
        var labels: [HorizontalBusLabel] = []
        var ripperLines: [HorizontalSegment] = []
        var ripperTexts: [HorizontalText] = []
        var ripperConnectorPositions: [String: HorizontalPoint] = [:]
    }

    private struct SchematicBlockSymbolArtwork {
        var lines: [HorizontalSegment] = []
        var ports: [HorizontalSegment] = []
        var texts: [HorizontalText] = []
        var portPositions: [String: HorizontalPoint] = [:]

        var points: [HorizontalPoint] {
            lines.flatMap { [$0.from, $0.to] }
                + ports.flatMap { [$0.from, $0.to] }
                + texts.flatMap(\.renderBoundsPoints)
                + Array(portPositions.values)
        }
    }

    static func load(
        from url: URL,
        blockURL: URL? = nil,
        poolURL: URL? = nil,
        blockSymbols: [String: HorizontalSchematicBlockResource] = [:],
        diagnostics: inout [HorizontalDiagnostic]
    ) throws -> HorizontalSchematic {
        let json = try BoardLoadTimer.measure("schematic: load JSON") {
            try JSONHelper.loadDictionary(from: url)
        }
        let grid = HorizontalGridSettings.load(from: json, fileURL: url, defaultGrid: .schematicDefault)
        let sheetsMap = json.dictionaryMap("sheets")
        var blockInfo = BoardLoadTimer.measure("schematic: parse block info") {
            blockURL.flatMap { try? parseBlockInfo(from: $0, poolURL: poolURL) } ?? SchematicBlockInfo()
        }
        blockInfo.projectMeta.merge(parseTitleBlockValues(from: json.dictionary("title_block_values"))) { _, schematicValue in
            schematicValue
        }
        var sheets = BoardLoadTimer.measure("schematic: parse sheets") {
            parseSheets(
                from: sheetsMap,
                poolURL: poolURL,
                grid: grid,
                blockInfo: blockInfo,
                blockSymbols: blockSymbols,
                diagnostics: &diagnostics
            )
        }
        let placeableObjects = BoardLoadTimer.measure("schematic: placeable objects") {
            schematicPlaceableObjects(componentInfo: blockInfo.components)
        }
        let unplacedObjects = BoardLoadTimer.measure("schematic: unplaced objects") {
            unplacedSchematicObjects(
                placeableObjects: placeableObjects,
                sheets: sheets
            )
        }
        sheets = sheets.map { sheet in
            var sheet = sheet
            sheet.placeableObjects = placeableObjects
            sheet.unplacedObjects = unplacedObjects
            return sheet
        }
        let topSheet = sheets.first

        return HorizontalSchematic(
            url: url,
            uuid: json.string("uuid") ?? "unknown-schematic",
            name: json.string("name") ?? url.deletingPathExtension().lastPathComponent,
            sheetName: topSheet?.name ?? "Sheet",
            grid: grid,
            netClasses: topSheet?.netClasses ?? [],
            sheets: sheets,
            junctions: topSheet?.junctions ?? [:],
            junctionNetIDs: topSheet?.junctionNetIDs ?? [:],
            netDetails: topSheet?.netDetails ?? [:],
            netLines: topSheet?.netLines ?? [],
            drawingLines: topSheet?.drawingLines ?? [],
            drawingArcs: topSheet?.drawingArcs ?? [],
            busLabels: topSheet?.busLabels ?? [],
            busRipperLines: topSheet?.busRipperLines ?? [],
            busRipperTexts: topSheet?.busRipperTexts ?? [],
            blockSymbolLines: topSheet?.blockSymbolLines ?? [],
            blockSymbolPorts: topSheet?.blockSymbolPorts ?? [],
            blockSymbolTexts: topSheet?.blockSymbolTexts ?? [],
            netTies: topSheet?.netTies ?? [],
            symbols: topSheet?.symbols ?? [],
            symbolLines: topSheet?.symbolLines ?? [],
            symbolPins: topSheet?.symbolPins ?? [],
            symbolPinCircles: topSheet?.symbolPinCircles ?? [],
            symbolPolygons: topSheet?.symbolPolygons ?? [],
            symbolTexts: topSheet?.symbolTexts ?? [],
            noPopulateMarks: topSheet?.noPopulateMarks ?? [],
            frameLines: topSheet?.frameLines ?? [],
            framePolygons: topSheet?.framePolygons ?? [],
            frameTexts: topSheet?.frameTexts ?? [],
            texts: topSheet?.texts ?? [],
            netLabels: topSheet?.netLabels ?? [],
            powerSymbols: topSheet?.powerSymbols ?? [],
            powerSymbolLines: topSheet?.powerSymbolLines ?? [],
            powerSymbolCircles: topSheet?.powerSymbolCircles ?? [],
            powerSymbolTexts: topSheet?.powerSymbolTexts ?? [],
            placeableObjects: placeableObjects,
            unplacedObjects: unplacedObjects,
            bounds: topSheet?.bounds ?? .empty
        )
    }

    static func load(from url: URL) throws -> HorizontalSchematic {
        var diagnostics = [HorizontalDiagnostic]()
        return try load(from: url, diagnostics: &diagnostics)
    }

    static func placingPart(
        _ part: HorizontalPoolPart,
        in sheet: HorizontalSchematicSheet,
        at position: HorizontalPoint,
        poolURL: URL
    ) -> HorizontalSchematicPartPlacementDraft? {
        guard let entityID = part.entityID.map(normalizedID),
              let gate = part.gates.first,
              let symbolID = gate.symbolID.map(normalizedID) else {
            return nil
        }

        var symbolCache = [String: JSONDictionary]()
        var unitCache = [String: JSONDictionary]()
        var unitPinInfoCache = [String: [String: SchematicUnitPinInfo]]()
        var partCache = [String: SchematicPartInfo]()
        var packageCache = [String: JSONDictionary]()
        guard let symbolJSON = loadSymbol(symbolID, poolURL: poolURL, cache: &symbolCache) else {
            return nil
        }

        let componentID = UUID().uuidString.lowercased()
        let tagID = UUID().uuidString.lowercased()
        let symbolInstanceID = UUID().uuidString.lowercased()
        let refdes = "\(part.refdesPrefix)?"
        let details = HorizontalComponentDetails(
            componentID: componentID,
            refdes: refdes,
            value: part.value,
            partID: part.id,
            mpn: part.mpn,
            manufacturer: part.manufacturer,
            packageName: part.packageName,
            description: part.partDescription
        )
        let component = SchematicComponentInfo(
            refdes: refdes,
            value: part.value,
            partID: part.id,
            noPopulate: false,
            gateSuffixes: Dictionary(uniqueKeysWithValues: part.gates.map { ($0.id, $0.suffix) }),
            gateSymbolIDs: Dictionary(uniqueKeysWithValues: part.gates.compactMap { gate in
                gate.symbolID.map { (normalizedID(gate.id), normalizedID($0)) }
            }),
            altPins: [:],
            connections: [:],
            details: details
        )
        let transform = HorizontalPlacementTransform(shift: position, angle: 0, mirrored: false)
        let symbolItem: JSONDictionary = [
            "component": componentID,
            "gate": gate.id,
            "symbol": symbolID,
            "placement": [
                "shift": [position.x, position.y],
                "angle": 0,
                "mirror": false
            ],
            "pin_display_mode": HorizontalSymbolPinDisplayMode.selectedOnly.rawValue
        ]
        let artwork = parseSingleSymbolArtwork(
            symbolInstanceID: symbolInstanceID,
            symbolItem: symbolItem,
            symbolResource: schematicSymbolResource(from: symbolJSON),
            symbolTransform: transform,
            sheetTextsByID: [:],
            component: component,
            poolURL: poolURL,
            unitCache: &unitCache,
            unitPinInfoCache: &unitPinInfoCache,
            partCache: &partCache,
            packageCache: &packageCache
        )

        var placements = parsePlacements(
            from: [symbolInstanceID: symbolItem],
            componentInfo: [componentID: component]
        )
        attachSymbolPinNames(
            to: &placements,
            from: [symbolInstanceID: symbolItem],
            poolURL: poolURL,
            componentInfo: [componentID: component],
            symbolCache: &symbolCache,
            unitCache: &unitCache,
            unitPinInfoCache: &unitPinInfoCache
        )
        guard let placement = placements.first else {
            return nil
        }

        var draft = sheet
        draft.symbols.append(placement)
        draft.symbolLines.append(contentsOf: artwork.lines)
        draft.symbolPins.append(contentsOf: artwork.pins)
        draft.symbolPinCircles.append(contentsOf: artwork.pinCircles)
        draft.symbolPolygons.append(contentsOf: artwork.polygons)
        draft.symbolTexts.append(contentsOf: artwork.texts)
        draft.noPopulateMarks.append(contentsOf: artwork.noPopulateMarks)
        draft.addedComponents.removeAll { normalizedID($0.id) == componentID }
        draft.addedComponents.append(
            HorizontalSchematicComponentRecord(
                id: componentID,
                entityID: entityID,
                partID: part.id,
                refdes: refdes,
                tagID: tagID
            )
        )
        draft.componentInfo[componentID] = component
        draft.bounds = HorizontalRect(points: draftBoundsPoints(draft)).padded()
        return HorizontalSchematicPartPlacementDraft(
            sheet: draft,
            symbolInstanceID: symbolInstanceID,
            componentID: componentID
        )
    }

    static func placingUnplacedSymbol(
        _ object: HorizontalUnplacedObject,
        in sheet: HorizontalSchematicSheet,
        at position: HorizontalPoint,
        poolURL: URL
    ) -> HorizontalSchematicPartPlacementDraft? {
        guard let componentID = object.componentID.map(normalizedID),
              let gateID = object.gateID.map(normalizedID),
              let symbolID = object.symbolID.map(normalizedID),
              let component = sheet.componentInfo[componentID] else {
            return nil
        }

        var symbolCache = [String: JSONDictionary]()
        var unitCache = [String: JSONDictionary]()
        var unitPinInfoCache = [String: [String: SchematicUnitPinInfo]]()
        var partCache = [String: SchematicPartInfo]()
        var packageCache = [String: JSONDictionary]()
        guard let symbolJSON = loadSymbol(symbolID, poolURL: poolURL, cache: &symbolCache) else {
            return nil
        }

        let symbolInstanceID = UUID().uuidString.lowercased()
        let transform = HorizontalPlacementTransform(shift: position, angle: 0, mirrored: false)
        let symbolItem: JSONDictionary = [
            "component": componentID,
            "gate": gateID,
            "symbol": symbolID,
            "placement": [
                "shift": [position.x, position.y],
                "angle": 0,
                "mirror": false
            ],
            "pin_display_mode": HorizontalSymbolPinDisplayMode.selectedOnly.rawValue
        ]
        let componentInfo = [componentID: component]
        let artwork = parseSingleSymbolArtwork(
            symbolInstanceID: symbolInstanceID,
            symbolItem: symbolItem,
            symbolResource: schematicSymbolResource(from: symbolJSON),
            symbolTransform: transform,
            sheetTextsByID: [:],
            component: component,
            poolURL: poolURL,
            unitCache: &unitCache,
            unitPinInfoCache: &unitPinInfoCache,
            partCache: &partCache,
            packageCache: &packageCache
        )

        var placements = parsePlacements(
            from: [symbolInstanceID: symbolItem],
            componentInfo: componentInfo
        )
        attachSymbolPinNames(
            to: &placements,
            from: [symbolInstanceID: symbolItem],
            poolURL: poolURL,
            componentInfo: componentInfo,
            symbolCache: &symbolCache,
            unitCache: &unitCache,
            unitPinInfoCache: &unitPinInfoCache
        )
        guard let placement = placements.first else {
            return nil
        }

        var draft = sheet
        draft.symbols.append(placement)
        draft.symbolLines.append(contentsOf: artwork.lines)
        draft.symbolPins.append(contentsOf: artwork.pins)
        draft.symbolPinCircles.append(contentsOf: artwork.pinCircles)
        draft.symbolPolygons.append(contentsOf: artwork.polygons)
        draft.symbolTexts.append(contentsOf: artwork.texts)
        draft.noPopulateMarks.append(contentsOf: artwork.noPopulateMarks)
        draft.bounds = HorizontalRect(points: draftBoundsPoints(draft)).padded()
        return HorizontalSchematicPartPlacementDraft(
            sheet: draft,
            symbolInstanceID: symbolInstanceID,
            componentID: componentID
        )
    }

    private static func draftBoundsPoints(_ sheet: HorizontalSchematicSheet) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: sheet.bounds.minX, y: sheet.bounds.minY),
            HorizontalPoint(x: sheet.bounds.maxX, y: sheet.bounds.maxY)
        ]
            + Array(sheet.junctions.values)
            + sheet.netLines.flatMap { [$0.from, $0.to] }
            + sheet.drawingLines.flatMap { [$0.from, $0.to] }
            + sheet.drawingArcs.flatMap { [$0.from, $0.to, $0.center] }
            + sheet.symbols.map(\.position)
            + sheet.symbolLines.flatMap { [$0.from, $0.to] }
            + sheet.symbolPins.flatMap { [$0.from, $0.to] }
            + sheet.symbolPinCircles.map(\.center)
            + sheet.symbolPolygons.flatMap(\.vertices)
            + sheet.symbolTexts.flatMap(\.renderBoundsPoints)
            + sheet.frameLines.flatMap { [$0.from, $0.to] }
            + sheet.framePolygons.flatMap(\.vertices)
            + sheet.frameTexts.flatMap(\.renderBoundsPoints)
            + sheet.texts.flatMap(\.renderBoundsPoints)
            + sheet.netLabels.map(\.position)
            + sheet.powerSymbolLines.flatMap { [$0.from, $0.to] }
            + sheet.powerSymbolCircles.map(\.center)
            + sheet.powerSymbolTexts.flatMap(\.renderBoundsPoints)
    }

    private static func parseSheets(
        from sheets: [String: JSONDictionary],
        poolURL: URL?,
        grid: HorizontalGridSettings,
        blockInfo: SchematicBlockInfo,
        blockSymbols: [String: HorizontalSchematicBlockResource],
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [HorizontalSchematicSheet] {
        var symbolCache = [String: JSONDictionary]()
        var unitCache = [String: JSONDictionary]()
        var unitPinInfoCache = [String: [String: SchematicUnitPinInfo]]()
        var partCache = [String: SchematicPartInfo]()
        var packageCache = [String: JSONDictionary]()
        var frameCache = [String: JSONDictionary]()
        var symbolResourceCache = [String: SchematicSymbolResource]()
        var missingSymbolIDs = Set<String>()
        let sheetTotal = sheets.count
        let netLabelSheetRefs = netLabelSheetReferences(from: sheets)

        let parsedSheets = sheets.compactMap { id, sheet in
            let junctions = BoardLoadTimer.measure("schematic sheets: junctions") {
                parseJunctions(from: sheet)
            }
            let junctionNetIDs = BoardLoadTimer.measure("schematic sheets: junction nets") {
                parseJunctionNetIDs(from: sheet)
            }
            let symbolMap = sheet.dictionaryMap("symbols")
            let sheetTexts = sheet.dictionaryMap("texts")
            var symbols = BoardLoadTimer.measure("schematic sheets: placements") {
                parsePlacements(from: symbolMap, componentInfo: blockInfo.components)
            }
            let artwork = BoardLoadTimer.measure("schematic sheets: symbol artwork") {
                parseSymbolArtwork(
                    from: symbolMap,
                    sheetTexts: sheetTexts,
                    poolURL: poolURL,
                    componentInfo: blockInfo.components,
                    symbolCache: &symbolCache,
                    unitCache: &unitCache,
                    unitPinInfoCache: &unitPinInfoCache,
                    partCache: &partCache,
                    packageCache: &packageCache,
                    symbolResourceCache: &symbolResourceCache,
                    missingSymbolIDs: &missingSymbolIDs
                )
            }
            BoardLoadTimer.measure("schematic sheets: pin names") {
                attachSymbolPinNames(
                    to: &symbols,
                    from: symbolMap,
                    poolURL: poolURL,
                    componentInfo: blockInfo.components,
                    symbolCache: &symbolCache,
                    unitCache: &unitCache,
                    unitPinInfoCache: &unitPinInfoCache
                )
            }
            let sheetIndex = sheet.int("index") ?? Int.max
            let frameArtwork = BoardLoadTimer.measure("schematic sheets: frame artwork") {
                parseFrameArtwork(
                    from: sheet.string("frame"),
                    sheet: sheet,
                    sheetName: sheet.string("name") ?? "Sheet",
                    sheetIndex: sheetIndex,
                    sheetTotal: sheetTotal,
                    poolURL: poolURL,
                    blockInfo: blockInfo,
                    frameCache: &frameCache
                )
            }
            let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0.position) })
            let drawingLines = BoardLoadTimer.measure("schematic sheets: drawing lines") {
                parseSymbolLines(
                    from: sheet.dictionaryMap("lines"),
                    symbolInstanceID: "sheet",
                    junctions: junctions
                )
            }
            let drawingArcs = BoardLoadTimer.measure("schematic sheets: drawing arcs") {
                parseDrawingArcs(
                    from: sheet.dictionaryMap("arcs"),
                    junctions: junctions
                )
            }
            let busArtwork = BoardLoadTimer.measure("schematic sheets: bus artwork") {
                parseBusArtwork(
                    from: sheet,
                    junctions: junctions,
                    buses: blockInfo.buses
                )
            }
            let blockSymbolArtwork = BoardLoadTimer.measure("schematic sheets: block symbols") {
                parseBlockSymbolArtwork(
                    from: sheet.dictionaryMap("block_symbols"),
                    blockInfo: blockInfo,
                    blockSymbols: blockSymbols
                )
            }
            let texts = BoardLoadTimer.measure("schematic sheets: texts") {
                parseTexts(from: sheetTexts, excluding: symbolTextIDs(from: symbolMap))
            }
            let netLabels = BoardLoadTimer.measure("schematic sheets: net labels") {
                parseNetLabels(
                    from: sheet.dictionaryMap("net_labels"),
                    sheetID: id,
                    junctions: junctions,
                    nets: blockInfo.nets,
                    sheetRefs: netLabelSheetRefs
                )
            }
            let powerSymbols = BoardLoadTimer.measure("schematic sheets: power symbols") {
                parsePowerSymbols(
                    from: sheet.dictionaryMap("power_symbols"),
                    junctions: junctions,
                    nets: blockInfo.nets
                )
            }
            let netLines = BoardLoadTimer.measure("schematic sheets: net lines") {
                resolveSchematicNetLineIDs(
                    parseNetLines(
                        from: sheet.dictionaryMap("net_lines"),
                        junctions: junctions,
                        junctionNetIDs: junctionNetIDs,
                        symbolPositions: symbolsByID,
                        symbolPinPositions: artwork.pinPositions,
                        busRipperPositions: busArtwork.ripperConnectorPositions,
                        blockPortPositions: blockSymbolArtwork.portPositions
                    ),
                    anchors: schematicNetAnchors(
                        junctions: junctions,
                        junctionNetIDs: junctionNetIDs,
                        netLabels: netLabels,
                        netBearingSegments: artwork.pins
                            + busArtwork.ripperLines
                            + blockSymbolArtwork.ports
                            + powerSymbols.lines,
                        netBearingCircles: artwork.pinCircles + powerSymbols.circles
                    )
                )
            }
            let netTies = BoardLoadTimer.measure("schematic sheets: net ties") {
                parseNetTies(
                    from: sheet.dictionaryMap("net_ties"),
                    junctions: junctions,
                    netTies: blockInfo.netTies
                )
            }
            let points = BoardLoadTimer.measure("schematic sheets: bounds points") {
                var points = [HorizontalPoint]()
                points.reserveCapacity(
                    junctions.count + symbols.count
                    + drawingLines.count * 2
                    + drawingArcs.count * 18
                    + texts.count * 4
                    + netLabels.count * 4
                    + busArtwork.labels.count * 4
                    + busArtwork.ripperLines.count * 2
                    + busArtwork.ripperTexts.count * 4
                    + netTies.count * 2
                    + powerSymbols.lines.count * 2
                    + powerSymbols.texts.count * 4
                    + powerSymbols.circles.count * 4
                    + artwork.lines.count * 2
                    + artwork.pins.count * 2
                    + artwork.texts.count * 4
                )
                points.append(contentsOf: junctions.values)
                points.append(contentsOf: symbols.map(\.position))
                for line in drawingLines {
                    points.append(line.from)
                    points.append(line.to)
                }
                for arc in drawingArcs {
                    points.append(contentsOf: arc.polyline(precision: 16))
                }
                for text in texts {
                    points.append(contentsOf: text.renderBoundsPoints)
                }
                for label in netLabels {
                    points.append(contentsOf: netLabelBoundsPoints(for: label))
                }
                for label in busArtwork.labels {
                    points.append(contentsOf: busLabelBoundsPoints(for: label))
                }
                for line in busArtwork.ripperLines {
                    points.append(line.from)
                    points.append(line.to)
                }
                for text in busArtwork.ripperTexts {
                    points.append(contentsOf: text.renderBoundsPoints)
                }
                points.append(contentsOf: blockSymbolArtwork.points)
                for netTie in netTies {
                    points.append(contentsOf: netTie.points)
                }
                for line in powerSymbols.lines {
                    points.append(line.from)
                    points.append(line.to)
                }
                for text in powerSymbols.texts {
                    points.append(contentsOf: text.renderBoundsPoints)
                }
                for circle in powerSymbols.circles {
                    points.append(contentsOf: circleBounds(circle))
                }
                frameArtwork.appendPoints(to: &points)
                artwork.appendPoints(to: &points)
                return points
            }

            return HorizontalSchematicSheet(
                id: id,
                name: sheet.string("name") ?? "Sheet",
                index: sheetIndex,
                grid: grid,
                netClasses: blockInfo.netClasses,
                junctions: junctions,
                junctionNetIDs: junctionNetIDs,
                netDetails: blockInfo.netDetails,
                netLines: netLines,
                drawingLines: drawingLines,
                drawingArcs: drawingArcs,
                busLabels: busArtwork.labels,
                busRipperLines: busArtwork.ripperLines,
                busRipperTexts: busArtwork.ripperTexts,
                blockSymbolLines: blockSymbolArtwork.lines,
                blockSymbolPorts: blockSymbolArtwork.ports,
                blockSymbolTexts: blockSymbolArtwork.texts,
                netTies: netTies,
                symbols: symbols,
                symbolLines: artwork.lines,
                symbolPins: artwork.pins,
                symbolPinCircles: artwork.pinCircles,
                symbolPolygons: artwork.polygons,
                symbolTexts: artwork.texts,
                noPopulateMarks: artwork.noPopulateMarks,
                frameLines: frameArtwork.lines,
                framePolygons: frameArtwork.polygons,
                frameTexts: frameArtwork.texts,
                texts: texts,
                netLabels: netLabels,
                powerSymbols: powerSymbols.symbols,
                powerSymbolLines: powerSymbols.lines,
                powerSymbolCircles: powerSymbols.circles,
                powerSymbolTexts: powerSymbols.texts,
                placeableObjects: [],
                unplacedObjects: [],
                addedComponents: [],
                componentInfo: blockInfo.components,
                bounds: HorizontalRect(points: points).padded().orEmptyContentCanvasRegion()
            )
        }
        .sorted { lhs, rhs in
            if lhs.index != rhs.index {
                return lhs.index < rhs.index
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        if !missingSymbolIDs.isEmpty {
            diagnostics.append(
                HorizontalDiagnostic(message: "Could not resolve \(missingSymbolIDs.count) schematic symbol files from the project pool.")
            )
        }

        return parsedSheets
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
        componentInfo: [String: SchematicComponentInfo]
    ) -> [HorizontalPlacement] {
        map.compactMap { id, item in
            guard let placement = item.dictionary("placement"),
                  let position = placement.point("shift") else {
                return nil
            }

            let componentID = item.string("component").map(normalizedID)
            let details = componentID.flatMap { componentInfo[$0]?.details }
            return HorizontalPlacement(
                id: id,
                position: position,
                angle: placement.int("angle") ?? 0,
                mirrored: placement.bool("mirror") ?? false,
                label: details?.displayLabel ?? item.string("component") ?? String(id.prefix(8)),
                componentID: componentID,
                componentDetails: details,
                customValue: item.string("custom_value"),
                gateID: item.string("gate").map(normalizedID),
                symbolID: item.string("symbol").map(normalizedID),
                pinDisplayMode: item.string("pin_display_mode") ?? HorizontalSymbolPinDisplayMode.selectedOnly.rawValue
            )
        }
    }

    private static func attachSymbolPinNames(
        to placements: inout [HorizontalPlacement],
        from map: [String: JSONDictionary],
        poolURL: URL?,
        componentInfo: [String: SchematicComponentInfo],
        symbolCache: inout [String: JSONDictionary],
        unitCache: inout [String: JSONDictionary],
        unitPinInfoCache: inout [String: [String: SchematicUnitPinInfo]]
    ) {
        guard let poolURL else {
            return
        }

        let symbolItemsByID = map.reduce(into: [String: JSONDictionary]()) { result, item in
            result[normalizedID(item.key)] = item.value
        }

        for index in placements.indices {
            guard let symbolItem = symbolItemsByID[normalizedID(placements[index].id)],
                  let symbolID = symbolItem.string("symbol").map(normalizedID),
                  let gateID = symbolItem.string("gate").map(normalizedID),
                  let symbolJSON = loadSymbol(symbolID, poolURL: poolURL, cache: &symbolCache),
                  let unitID = symbolJSON.string("unit") else {
                continue
            }
            let unitPins = loadUnitPinInfos(
                unitID,
                poolURL: poolURL,
                unitCache: &unitCache,
                unitPinInfoCache: &unitPinInfoCache
            )

            let component = placements[index].componentID
                .map(normalizedID)
                .flatMap { componentInfo[$0] }
            let symbolPins = symbolJSON.dictionaryMap("pins")
            let editorPins = symbolPins.compactMap { id, _ -> HorizontalSymbolPinName? in
                let pinID = normalizedID(id)
                guard let unitPin = unitPins[pinID] else {
                    return nil
                }
                let gatePinPath = normalizedUUIDPath("\(gateID)/\(pinID)")
                let altInfo = component?.altPins[gatePinPath]
                let state = altInfo.map {
                    HorizontalSymbolPinNameState(
                        pinNames: $0.pinNames,
                        usePrimaryName: $0.usePrimaryName,
                        useCustomName: $0.useCustomName,
                        customName: $0.customName,
                        customDirection: $0.customDirection
                    )
                } ?? HorizontalSymbolPinNameState()
                return HorizontalSymbolPinName(
                    id: pinID,
                    gateID: gateID,
                    gatePinPath: gatePinPath,
                    primaryName: unitPin.primaryName,
                    primaryDirection: unitPin.primaryDirection,
                    alternateNames: unitPin.alternateNameOptions,
                    state: state
                )
            }
            .sorted {
                $0.primaryName.localizedStandardCompare($1.primaryName) == .orderedAscending
            }
            placements[index].gateID = gateID
            placements[index].pinDisplayMode = symbolItem.string("pin_display_mode") ?? HorizontalSymbolPinDisplayMode.selectedOnly.rawValue
            placements[index].symbolPinNames = editorPins
        }
    }

    private static func parseSymbolArtwork(
        from map: [String: JSONDictionary],
        sheetTexts: [String: JSONDictionary],
        poolURL: URL?,
        componentInfo: [String: SchematicComponentInfo],
        symbolCache: inout [String: JSONDictionary],
        unitCache: inout [String: JSONDictionary],
        unitPinInfoCache: inout [String: [String: SchematicUnitPinInfo]],
        partCache: inout [String: SchematicPartInfo],
        packageCache: inout [String: JSONDictionary],
        symbolResourceCache: inout [String: SchematicSymbolResource],
        missingSymbolIDs: inout Set<String>
    ) -> SchematicSymbolArtwork {
        guard let poolURL else {
            return .empty
        }

        var result = SchematicSymbolArtwork.empty
        let sheetTextsByID = sheetTexts.reduce(into: [String: JSONDictionary]()) { result, item in
            result[normalizedID(item.key)] = item.value
        }

        for (symbolInstanceID, item) in map {
            guard let symbolID = item.string("symbol").map(normalizedID),
                  let symbolTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                continue
            }

            guard let symbolJSON = loadSymbol(symbolID, poolURL: poolURL, cache: &symbolCache) else {
                missingSymbolIDs.insert(symbolID)
                continue
            }
            let symbolResource = cachedSymbolResource(
                symbolID,
                symbolJSON: symbolJSON,
                cache: &symbolResourceCache
            )

            let component = item.string("component").map(normalizedID).flatMap { componentInfo[$0] }
            result.append(
                parseSingleSymbolArtwork(
                    symbolInstanceID: symbolInstanceID,
                    symbolItem: item,
                    symbolResource: symbolResource,
                    symbolTransform: symbolTransform,
                    sheetTextsByID: sheetTextsByID,
                    component: component,
                    poolURL: poolURL,
                    unitCache: &unitCache,
                    unitPinInfoCache: &unitPinInfoCache,
                    partCache: &partCache,
                    packageCache: &packageCache
                )
            )
        }

        return result
    }

    private static func parseSingleSymbolArtwork(
        symbolInstanceID: String,
        symbolItem: JSONDictionary,
        symbolResource: SchematicSymbolResource,
        symbolTransform: HorizontalPlacementTransform,
        sheetTextsByID: [String: JSONDictionary],
        component: SchematicComponentInfo?,
        poolURL: URL,
        unitCache: inout [String: JSONDictionary],
        unitPinInfoCache: inout [String: [String: SchematicUnitPinInfo]],
        partCache: inout [String: SchematicPartInfo],
        packageCache: inout [String: JSONDictionary]
    ) -> SchematicSymbolArtwork {
        let junctions = symbolResource.junctions
        let transformedJunctions = junctions.mapValues(symbolTransform.applying)
        let pinArtwork = parseSymbolPins(
            from: symbolResource.pins,
            symbolInstanceID: symbolInstanceID,
            symbolItem: symbolItem,
            unitID: symbolResource.unitID,
            symbolTransform: symbolTransform,
            component: component,
            poolURL: poolURL,
            unitCache: &unitCache,
            unitPinInfoCache: &unitPinInfoCache,
            partCache: &partCache,
            packageCache: &packageCache
        )

        let symbolTexts = symbolItem.bool("smashed") == true
            ? parseSmashedSymbolTexts(
                from: symbolItem,
                sheetTextsByID: sheetTextsByID,
                component: component
            )
            : parseSymbolTexts(
                from: symbolResource.texts,
                textPlacements: symbolResource.textPlacements,
                symbolVersion: symbolResource.version,
                symbolInstanceID: symbolInstanceID,
                symbolTransform: symbolTransform,
                customValue: symbolItem.string("custom_value"),
                component: component
            )

        return SchematicSymbolArtwork(
            lines: parseSymbolLines(
                from: symbolResource.lines,
                symbolInstanceID: symbolInstanceID,
                junctions: transformedJunctions
            ) + parseSymbolArcs(
                from: symbolResource.arcs,
                symbolInstanceID: symbolInstanceID,
                junctions: junctions,
                symbolTransform: symbolTransform
            ),
            pins: pinArtwork.pins,
            pinCircles: pinArtwork.circles,
            polygons: parseSymbolPolygons(
                from: symbolResource.polygons,
                symbolInstanceID: symbolInstanceID,
                symbolTransform: symbolTransform
            ),
            texts: pinArtwork.texts + symbolTexts,
            noPopulateMarks: component?.noPopulate == true
                ? noPopulateMarks(
                    symbolInstanceID: symbolInstanceID,
                    symbolResource: symbolResource,
                    symbolTransform: symbolTransform
                )
                : [],
            pinPositions: pinArtwork.pinPositions
        )
    }

    private static func cachedSymbolResource(
        _ symbolID: String,
        symbolJSON: JSONDictionary,
        cache: inout [String: SchematicSymbolResource]
    ) -> SchematicSymbolResource {
        let symbolID = normalizedID(symbolID)
        if let cached = cache[symbolID] {
            return cached
        }

        let resource = schematicSymbolResource(from: symbolJSON)
        cache[symbolID] = resource
        return resource
    }

    private static func schematicSymbolResource(from symbolJSON: JSONDictionary) -> SchematicSymbolResource {
        SchematicSymbolResource(
            unitID: symbolJSON.string("unit"),
            version: symbolJSON.int("version") ?? 0,
            junctions: parseJunctions(from: symbolJSON),
            pins: symbolJSON.dictionaryMap("pins"),
            lines: symbolJSON.dictionaryMap("lines"),
            arcs: symbolJSON.dictionaryMap("arcs"),
            polygons: symbolJSON.dictionaryMap("polygons"),
            texts: symbolJSON.dictionaryMap("texts"),
            textPlacements: symbolJSON.dictionaryMap("text_placements")
        )
    }

    private static func noPopulateMarks(
        symbolInstanceID: String,
        symbolResource: SchematicSymbolResource,
        symbolTransform: HorizontalPlacementTransform
    ) -> [HorizontalSchematicNoPopulateMark] {
        guard let bounds = symbolNoPopulateBounds(from: symbolResource), !bounds.isEmpty else {
            return []
        }

        let padding = 200_000.0
        let min = HorizontalPoint(x: bounds.minX - padding, y: bounds.minY - padding)
        let max = HorizontalPoint(x: bounds.maxX + padding, y: bounds.maxY + padding)
        let topLeft = HorizontalPoint(x: min.x, y: max.y)
        let bottomRight = HorizontalPoint(x: max.x, y: min.y)
        let lineWidth = 200_000.0

        return [
            HorizontalSchematicNoPopulateMark(
                id: "\(symbolInstanceID)/nopopulate",
                symbolID: symbolInstanceID,
                firstLine: HorizontalSegment(
                    id: "\(symbolInstanceID)/nopopulate/0",
                    from: symbolTransform.applying(to: min),
                    to: symbolTransform.applying(to: max),
                    width: lineWidth,
                    layer: nil
                ),
                secondLine: HorizontalSegment(
                    id: "\(symbolInstanceID)/nopopulate/1",
                    from: symbolTransform.applying(to: topLeft),
                    to: symbolTransform.applying(to: bottomRight),
                    width: lineWidth,
                    layer: nil
                )
            )
        ]
    }

    private static func symbolNoPopulateBounds(from symbolResource: SchematicSymbolResource) -> HorizontalRect? {
        let junctions = symbolResource.junctions
        var points = Array(junctions.values)

        for item in symbolResource.arcs.values {
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                continue
            }
            points.append(contentsOf: arcPolyline(from: from, to: to, centerHint: center))
        }

        for item in symbolResource.pins.values {
            if let position = item.point("position") {
                points.append(position)
            }
        }

        if points.isEmpty {
            for item in symbolResource.polygons.values {
                points.append(contentsOf: parsePolygonVertices(from: item.dictionaryArray("vertices")))
            }
            for item in symbolResource.texts.values {
                if let placement = HorizontalPlacementTransform(json: item.dictionary("placement")) {
                    points.append(placement.shift)
                }
            }
        }

        guard !points.isEmpty else {
            return nil
        }
        return HorizontalRect(points: points)
    }

    private static func parseFrameArtwork(
        from frameID: String?,
        sheet: JSONDictionary,
        sheetName: String,
        sheetIndex: Int,
        sheetTotal: Int,
        poolURL: URL?,
        blockInfo: SchematicBlockInfo,
        frameCache: inout [String: JSONDictionary]
    ) -> SchematicFrameArtwork {
        guard let poolURL,
              let frameID = frameID.map(normalizedID),
              let frameJSON = loadFrame(frameID, poolURL: poolURL, cache: &frameCache) else {
            return .empty
        }

        let junctions = parseJunctions(from: frameJSON)
        var lines = parseSymbolLines(from: frameJSON.dictionaryMap("lines"), symbolInstanceID: "frame", junctions: junctions)
        lines.append(contentsOf: parseSymbolArcs(
            from: frameJSON.dictionaryMap("arcs"),
            symbolInstanceID: "frame",
            junctions: junctions,
            symbolTransform: .identity
        ))

        if let width = frameJSON.double("width"),
           let height = frameJSON.double("height") {
            lines.append(contentsOf: [
                HorizontalSegment(id: "frame/border/bottom", from: .zero, to: HorizontalPoint(x: width, y: 0), width: 0, layer: 0),
                HorizontalSegment(id: "frame/border/right", from: HorizontalPoint(x: width, y: 0), to: HorizontalPoint(x: width, y: height), width: 0, layer: 0),
                HorizontalSegment(id: "frame/border/top", from: HorizontalPoint(x: width, y: height), to: HorizontalPoint(x: 0, y: height), width: 0, layer: 0),
                HorizontalSegment(id: "frame/border/left", from: HorizontalPoint(x: 0, y: height), to: .zero, width: 0, layer: 0),
            ])
        }

        let substitutions = frameSubstitutions(
            sheet: sheet,
            sheetName: sheetName,
            sheetIndex: sheetIndex,
            sheetTotal: sheetTotal,
            projectMeta: blockInfo.projectMeta
        )

        return SchematicFrameArtwork(
            lines: lines,
            polygons: parseSymbolPolygons(
                from: frameJSON.dictionaryMap("polygons"),
                symbolInstanceID: "frame",
                symbolTransform: .identity
            ),
            texts: parseFrameTexts(
                from: frameJSON.dictionaryMap("texts"),
                substitutions: substitutions
            )
        )
    }

    private static func parseSymbolLines(
        from map: [String: JSONDictionary],
        symbolInstanceID: String,
        junctions: [String: HorizontalPoint]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }

            return HorizontalSegment(
                id: "\(symbolInstanceID)/line/\(id)",
                from: from,
                to: to,
                width: item.double("width") ?? 0,
                layer: item.int("layer")
            )
        }
    }

    private static func parseSymbolArcs(
        from map: [String: JSONDictionary],
        symbolInstanceID: String,
        junctions: [String: HorizontalPoint],
        symbolTransform: HorizontalPlacementTransform
    ) -> [HorizontalSegment] {
        map.flatMap { id, item -> [HorizontalSegment] in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                return []
            }

            let points = arcPolyline(from: from, to: to, centerHint: center)
                .map(symbolTransform.applying)
            return zip(points, points.dropFirst()).enumerated().map { index, pair in
                HorizontalSegment(
                    id: "\(symbolInstanceID)/arc/\(id)/\(index)",
                    from: pair.0,
                    to: pair.1,
                    width: item.double("width") ?? 0,
                    layer: item.int("layer")
                )
            }
        }
    }

    private static func parseDrawingArcs(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint]
    ) -> [HorizontalArc] {
        map.compactMap { id, item in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let centerID = item.string("center"),
                  let from = junctions[fromID],
                  let to = junctions[toID],
                  let center = junctions[centerID] else {
                return nil
            }

            return HorizontalArc(
                id: "sheet/arc/\(id)",
                from: from,
                to: to,
                center: center,
                width: item.double("width") ?? 0,
                layer: item.int("layer")
            )
        }
    }

    private static func parseSymbolPins(
        from map: [String: JSONDictionary],
        symbolInstanceID: String,
        symbolItem: JSONDictionary,
        unitID: String?,
        symbolTransform: HorizontalPlacementTransform,
        component: SchematicComponentInfo?,
        poolURL: URL,
        unitCache: inout [String: JSONDictionary],
        unitPinInfoCache: inout [String: [String: SchematicUnitPinInfo]],
        partCache: inout [String: SchematicPartInfo],
        packageCache: inout [String: JSONDictionary]
    ) -> (pins: [HorizontalSegment], circles: [HorizontalCircle], texts: [HorizontalText], pinPositions: [String: HorizontalPoint]) {
        var pinPositions = [String: HorizontalPoint]()
        var circles = [HorizontalCircle]()
        var texts = [HorizontalText]()
        let unitPins = unitID.map {
            loadUnitPinInfos(
                $0,
                poolURL: poolURL,
                unitCache: &unitCache,
                unitPinInfoCache: &unitPinInfoCache
            )
        } ?? [:]
        let gateID = symbolItem.string("gate").map(normalizedID)
        let pinDisplayMode = symbolItem.string("pin_display_mode") ?? "selected_only"
        let displayAllPads = symbolItem.bool("display_all_pads") ?? true
        let partInfo = component?.partID.flatMap {
            loadPartInfo($0, poolURL: poolURL, partCache: &partCache, packageCache: &packageCache)
        }

        var pins = [HorizontalSegment]()
        for (id, item) in map {
            guard let position = item.point("position") else {
                continue
            }

            let transformedPosition = symbolTransform.applying(to: position)
            let pinID = normalizedID(id)
            let pinPath = normalizedUUIDPath("\(symbolInstanceID)/\(pinID)")
            pinPositions[pinPath] = transformedPosition

            let length = item.double("length") ?? 0
            let pinOrientation = pinOrientationForPlacement(item.string("orientation"), transform: symbolTransform)
            let decoration = item.dictionary("decoration")
            let lineLength = adjustedPinLineLength(length, decoration: decoration)
            let inner = pinInnerPoint(
                from: position,
                orientation: item.string("orientation"),
                length: lineLength
            )
            let gatePinPath = gateID.map { normalizedUUIDPath("\($0)/\(pinID)") }
            let pinNetID = gatePinPath.flatMap { component?.connections[$0]?.netID }
            let unitPin = unitPins[pinID]
            let pinName = expandedPinName(
                pinID: pinID,
                gatePinPath: gatePinPath,
                unitPins: unitPins,
                component: component,
                pinDisplayMode: pinDisplayMode
            )
            let padName = gatePinPath.flatMap {
                expandedPadName(for: $0, partInfo: partInfo, displayAllPads: displayAllPads)
            }
            texts.append(
                contentsOf: pinTexts(
                    for: item,
                    id: id,
                    symbolInstanceID: symbolInstanceID,
                    transformedPosition: transformedPosition,
                    symbolTransform: symbolTransform,
                    pinName: pinName,
                    padName: padName,
                    netID: pinNetID
                )
            )

            pins.append(
                HorizontalSegment(
                    id: "\(symbolInstanceID)/pin/\(id)",
                    from: transformedPosition,
                    to: symbolTransform.applying(to: inner),
                    width: 0,
                    layer: nil,
                    netID: pinNetID
                )
            )
            pins.append(
                contentsOf: pinDirectionSegments(
                    id: "\(symbolInstanceID)/pin-direction/\(id)",
                    position: transformedPosition,
                    orientation: pinOrientation,
                    direction: unitPin?.primaryDirection
                ).map { segment in
                    var segment = segment
                    segment.netID = pinNetID
                    return segment
                }
            )

            let connectorStyle = symbolPinConnectorStyle(for: gatePinPath, component: component)
            pins.append(
                contentsOf: pinConnectorSegments(
                    id: "\(symbolInstanceID)/pin-connector/\(id)",
                    position: transformedPosition,
                    orientation: pinOrientation,
                    connectorStyle: connectorStyle
                ).map { segment in
                    var segment = segment
                    segment.netID = pinNetID
                    return segment
                }
            )
            if let text = pinConnectorText(
                id: "\(symbolInstanceID)/pin-connector-text/\(id)",
                position: transformedPosition,
                orientation: pinOrientation,
                connectorStyle: connectorStyle
            ) {
                texts.append(text)
            }
            let decorations = pinDecorationArtwork(
                id: "\(symbolInstanceID)/pin-decoration/\(id)",
                item: item,
                position: transformedPosition,
                orientation: pinOrientation,
                length: length
            )
            pins.append(contentsOf: decorations.segments.map { segment in
                var segment = segment
                segment.netID = pinNetID
                return segment
            })
            circles.append(contentsOf: decorations.circles.map { circle in
                var circle = circle
                circle.netID = pinNetID
                return circle
            })
        }

        return (pins, circles, texts, pinPositions)
    }

    private static func pinDecorationArtwork(
        id: String,
        item: JSONDictionary,
        position: HorizontalPoint,
        orientation: String,
        length: Double
    ) -> (segments: [HorizontalSegment], circles: [HorizontalCircle]) {
        guard let decoration = item.dictionary("decoration") else {
            return ([], [])
        }

        var segments = [HorizontalSegment]()
        var circles = [HorizontalCircle]()

        if decoration.bool("dot") == true {
            circles.append(
                HorizontalCircle(
                    id: "\(id)/dot",
                    center: pinLocalPoint(HorizontalPoint(x: -length + 375_000, y: 0), position: position, orientation: orientation),
                    radius: 375_000,
                    layer: nil
                )
            )
        }

        if decoration.bool("clock") == true {
            let pairs = [
                (HorizontalPoint(x: -length, y: 375_000), HorizontalPoint(x: -length - 750_000, y: 0)),
                (HorizontalPoint(x: -length, y: -375_000), HorizontalPoint(x: -length - 750_000, y: 0)),
            ]
            segments.append(
                contentsOf: pairs.enumerated().map { index, pair in
                    HorizontalSegment(
                        id: "\(id)/clock/\(index)",
                        from: pinLocalPoint(pair.0, position: position, orientation: orientation),
                        to: pinLocalPoint(pair.1, position: position, orientation: orientation),
                        width: 0,
                        layer: nil
                    )
                }
            )
        }

        if decoration.bool("schmitt") == true {
            let shift = (decoration.bool("clock") == true ? 1_875_000.0 : 1_125_000.0)
            let base = pinDecorationBase(position: position, orientation: orientation, distance: length + shift)
            segments.append(
                contentsOf: decorationSegments(
                    id: "\(id)/schmitt",
                    base: base,
                    scale: 25_000,
                    pairs: [
                        (-34, -20, -2, -20),
                        (34, 20, 2, 20),
                        (-20, -20, 2, 20),
                        (-2, -20, 20, 20),
                    ]
                )
            )
        }

        let driver = decoration.string("driver") ?? "default"
        if driver != "default" {
            var shift = 750_000.0
            if decoration.bool("clock") == true {
                shift += 750_000
            }
            if decoration.bool("schmitt") == true {
                shift += 2_000_000
            }
            let base = pinDecorationBase(position: position, orientation: orientation, distance: length + shift)
            segments.append(contentsOf: driverDecorationSegments(id: "\(id)/driver", base: base, driver: driver))
        }

        return (segments, circles)
    }

    private static func adjustedPinLineLength(_ length: Double, decoration: JSONDictionary?) -> Double {
        guard decoration?.bool("dot") == true else {
            return length
        }
        return max(0, length - 750_000)
    }

    private static func pinDecorationBase(
        position: HorizontalPoint,
        orientation: String,
        distance: Double
    ) -> HorizontalPoint {
        position + pinInnerDirection(for: orientation) * distance
    }

    private static func pinInnerDirection(for orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: 1, y: 0)
        case "up":
            return HorizontalPoint(x: 0, y: -1)
        case "down":
            return HorizontalPoint(x: 0, y: 1)
        default:
            return HorizontalPoint(x: -1, y: 0)
        }
    }

    private static func driverDecorationSegments(
        id: String,
        base: HorizontalPoint,
        driver: String
    ) -> [HorizontalSegment] {
        let driver = driver.lowercased()
        var pairs = [(Double, Double, Double, Double)]()

        if driver != "tristate" {
            pairs.append(contentsOf: [
                (0, -1, 1, 0),
                (1, 0, 0, 1),
                (-1, 0, 0, 1),
                (-1, 0, 0, -1),
            ])
        }

        switch driver {
        case "open_collector_pullup", "open_collector_pull_up", "open_emitter_pulldown", "open_emitter_pull_down":
            pairs.append((-1, 0, 1, 0))
        default:
            break
        }

        switch driver {
        case "open_collector", "open_collector_pullup", "open_collector_pull_up":
            pairs.append((-1, -1, 1, -1))
        case "open_emitter", "open_emitter_pulldown", "open_emitter_pull_down":
            pairs.append((-1, 1, 1, 1))
        case "tristate":
            pairs.append(contentsOf: [
                (1, 1, -1, 1),
                (1, 1, 0, -1),
                (-1, 1, 0, -1),
            ])
        default:
            break
        }

        return decorationSegments(id: id, base: base, scale: 500_000, pairs: pairs)
    }

    private static func decorationSegments(
        id: String,
        base: HorizontalPoint,
        scale: Double,
        pairs: [(Double, Double, Double, Double)]
    ) -> [HorizontalSegment] {
        pairs.enumerated().map { index, pair in
            HorizontalSegment(
                id: "\(id)/\(index)",
                from: base + HorizontalPoint(x: pair.0 * scale, y: pair.1 * scale),
                to: base + HorizontalPoint(x: pair.2 * scale, y: pair.3 * scale),
                width: 0,
                layer: nil
            )
        }
    }

    private static func symbolPinConnectorStyle(
        for gatePinPath: String?,
        component: SchematicComponentInfo?
    ) -> String {
        guard let gatePinPath, let connection = component?.connections[gatePinPath] else {
            return "box"
        }

        switch connection {
        case .connected(_):
            return "none"
        case .notConnected:
            return "nc"
        }
    }

    private static func pinTexts(
        for item: JSONDictionary,
        id: String,
        symbolInstanceID: String,
        transformedPosition: HorizontalPoint,
        symbolTransform: HorizontalPlacementTransform,
        pinName: String,
        padName: String?,
        netID: String?
    ) -> [HorizontalText] {
        let length = item.double("length") ?? 0
        let decoration = item.dictionary("decoration")
        var textShiftName = 500_000.0
        if decoration?.bool("clock") == true {
            textShiftName += 750_000
        }
        if decoration?.bool("schmitt") == true {
            textShiftName += 2_000_000
        }
        if decoration?.string("driver") != nil, decoration?.string("driver") != "default" {
            textShiftName += 1_000_000
        }

        let pinOrientation = pinOrientationForPlacement(item.string("orientation"), transform: symbolTransform)
        var namePosition = transformedPosition
        var padPosition = transformedPosition
        var nameOrientation = "left"
        var padOrientation = "left"

        switch pinOrientation {
        case "left":
            namePosition.x += length + textShiftName
            padPosition.x += length - 500_000
            padPosition.y += 500_000
            nameOrientation = "right"
            padOrientation = "left"
        case "right":
            namePosition.x -= length + textShiftName
            padPosition.x -= length - 500_000
            padPosition.y += 500_000
            nameOrientation = "left"
            padOrientation = "right"
        case "up":
            namePosition.y -= length + textShiftName
            padPosition.y -= length - 500_000
            padPosition.x -= 500_000
            nameOrientation = "down"
            padOrientation = "up"
        case "down":
            namePosition.y += length + textShiftName
            padPosition.y += length - 500_000
            padPosition.x -= 500_000
            nameOrientation = "up"
            padOrientation = "down"
        default:
            break
        }

        var texts = [HorizontalText]()
        if item.bool("name_visible") ?? true, !pinName.isEmpty {
            let nameMode = pinNameOrientationMode(from: item)
            let drawInLine = nameMode == "in_line" || (nameMode == "horizontal" && (pinOrientation == "left" || pinOrientation == "right"))
            let position = drawInLine
                ? namePosition
                : namePosition + perpendicularPinNameShift(for: pinOrientation)
            texts.append(
                HorizontalText(
                    id: "\(symbolInstanceID)/pin-name/\(id)",
                    text: pinName,
                    position: position,
                    size: 1_500_000,
                    layer: nil,
                    netID: netID,
                    angle: angle(forOrientation: nameOrientation) + (drawInLine ? 0 : 16_384),
                    origin: .center,
                    centered: !drawInLine
                )
            )
        }

        if item.bool("pad_visible") ?? true, let padName, !padName.isEmpty {
            texts.append(
                HorizontalText(
                    id: "\(symbolInstanceID)/pin-pad/\(id)",
                    text: padName,
                    position: padPosition,
                    size: 750_000,
                    layer: nil,
                    netID: netID,
                    angle: angle(forOrientation: padOrientation),
                    origin: .baseline
                )
            )
        }

        return texts
    }

    private static func pinNameOrientationMode(from item: JSONDictionary) -> String {
        if item.bool("keep_horizontal") == true {
            return "horizontal"
        }
        return item.string("name_orientation") ?? "in_line"
    }

    private static func expandedPinName(
        pinID: String,
        gatePinPath: String?,
        unitPins: [String: SchematicUnitPinInfo],
        component: SchematicComponentInfo?,
        pinDisplayMode: String
    ) -> String {
        guard let unitPin = unitPins[pinID] else {
            return ""
        }

        let primaryName = appendTilde(unitPin.primaryName)
        let alternateNames = unitPin.alternateNames
        let altInfo = gatePinPath.flatMap { component?.altPins[$0] }

        if pinDisplayMode == "all" {
            let names = alternateNames.keys.sorted().compactMap { alternateNames[$0].map(appendTilde) }
            return (names + ["(\(primaryName))"]).joined(separator: " · ")
        }

        if pinDisplayMode == "custom_only" {
            if let customName = altInfo?.customName, !customName.isEmpty {
                return appendTilde(customName)
            }
            return primaryName
        }

        if let altInfo,
           !altInfo.pinNames.isEmpty || altInfo.useCustomName || altInfo.usePrimaryName {
            var names = [String]()
            if altInfo.usePrimaryName || pinDisplayMode == "both" {
                names.append(primaryName)
            }
            for pinNameID in altInfo.pinNames {
                if let name = alternateNames[normalizedID(pinNameID)] {
                    names.append(appendTilde(name))
                }
            }
            if altInfo.useCustomName, !altInfo.customName.isEmpty {
                names.append(appendTilde(altInfo.customName))
            }
            return names.joined(separator: " · ")
        }

        return primaryName
    }

    private static func expandedPadName(
        for gatePinPath: String,
        partInfo: SchematicPartInfo?,
        displayAllPads: Bool
    ) -> String? {
        guard let padNames = partInfo?.padNamesByGatePin[gatePinPath], !padNames.isEmpty else {
            return nil
        }

        let sortedNames = padNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sortedNames.count <= 3 || displayAllPads {
            return sortedNames.joined(separator: " ")
        }

        return "\(sortedNames.first ?? "") ... \(sortedNames.last ?? "")"
    }

    private static func alternatePinNames(from unitPin: JSONDictionary) -> [String: String] {
        let rawNames = unitPin.dictionaryMap("alt_names").isEmpty
            ? unitPin.dictionaryMap("names")
            : unitPin.dictionaryMap("alt_names")
        return rawNames.reduce(into: [String: String]()) { result, item in
            if let name = item.value.string("name") {
                result[normalizedID(item.key)] = name
            }
        }
    }

    private static func alternatePinNameOptions(from unitPin: JSONDictionary) -> [HorizontalSymbolPinNameOption] {
        let rawNames = unitPin.dictionaryMap("alt_names").isEmpty
            ? unitPin.dictionaryMap("names")
            : unitPin.dictionaryMap("alt_names")
        return rawNames.compactMap { id, item in
            item.string("name").map {
                HorizontalSymbolPinNameOption(
                    id: normalizedID(id),
                    name: $0,
                    direction: item.string("direction") ?? unitPin.string("direction") ?? "bidirectional"
                )
            }
        }
        .sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func appendTilde(_ text: String) -> String {
        text.first == "~" ? "\(text)~" : text
    }

    private static func perpendicularPinNameShift(for orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: 1_000_000, y: 0)
        case "up":
            return HorizontalPoint(x: 0, y: -1_000_000)
        case "down":
            return HorizontalPoint(x: 0, y: 1_000_000)
        default:
            return HorizontalPoint(x: -1_000_000, y: 0)
        }
    }

    private static func pinOrientationForPlacement(
        _ orientation: String?,
        transform: HorizontalPlacementTransform
    ) -> String {
        var orientation = orientation ?? "right"
        switch transform.angle {
        case 16_384:
            orientation = [
                "left": "down",
                "up": "left",
                "right": "up",
                "down": "right",
            ][orientation] ?? orientation
        case 32_768:
            orientation = [
                "left": "right",
                "up": "down",
                "right": "left",
                "down": "up",
            ][orientation] ?? orientation
        case 49_152:
            orientation = [
                "left": "up",
                "up": "right",
                "right": "down",
                "down": "left",
            ][orientation] ?? orientation
        default:
            break
        }

        if transform.mirrored {
            orientation = [
                "left": "right",
                "up": "up",
                "right": "left",
                "down": "down",
            ][orientation] ?? orientation
        }

        return orientation
    }

    private static func parseSymbolPolygons(
        from map: [String: JSONDictionary],
        symbolInstanceID: String,
        symbolTransform: HorizontalPlacementTransform
    ) -> [HorizontalPolygon] {
        map.compactMap { id, item in
            let vertices = parsePolygonVertices(
                from: item.dictionaryArray("vertices"),
                transform: symbolTransform.applying
            )
            guard vertices.count >= 2 else {
                return nil
            }

            return HorizontalPolygon(id: "\(symbolInstanceID)/polygon/\(id)", vertices: vertices, layer: item.int("layer"))
        }
    }

    private static func parseSymbolTexts(
        from map: [String: JSONDictionary],
        textPlacements: [String: JSONDictionary],
        symbolVersion: Int,
        symbolInstanceID: String,
        symbolTransform: HorizontalPlacementTransform,
        customValue: String?,
        component: SchematicComponentInfo?
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard let text = item.string("text"),
                  let defaultTextTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return nil
            }

            let transformed: HorizontalPlacementTransform
            if let viewTextTransform = symbolTextPlacement(
                textID: id,
                textPlacements: textPlacements,
                symbolTransform: symbolTransform,
                symbolVersion: symbolVersion
            ) {
                transformed = symbolTransform.accumulatedText(with: viewTextTransform)
            } else {
                transformed = symbolTransform.accumulatedText(with: defaultTextTransform)
            }
            return HorizontalText(
                id: "\(symbolInstanceID)/text/\(id)",
                text: substituteSymbolText(text, component: component, customValue: customValue),
                position: transformed.shift,
                size: item.double("size") ?? 1_000_000,
                layer: item.int("layer"),
                angle: transformed.angle,
                mirrored: transformed.mirrored,
                width: item.double("width") ?? 0,
                origin: item.horizonTextOrigin(),
                font: item.horizonTextFont(),
                allowUpsideDown: item.bool("allow_upside_down") ?? false
            )
        }
    }

    private static func symbolTextPlacement(
        textID: String,
        textPlacements: [String: JSONDictionary],
        symbolTransform: HorizontalPlacementTransform,
        symbolVersion: Int
    ) -> HorizontalPlacementTransform? {
        guard let viewPlacements = textPlacements[symbolTextPlacementViewKey(for: symbolTransform)] else {
            return nil
        }

        let placement = viewPlacements[textID] as? JSONDictionary
            ?? viewPlacements[normalizedID(textID)] as? JSONDictionary
        guard let transform = HorizontalPlacementTransform(json: placement) else {
            return nil
        }
        return legacyCorrectedSymbolTextPlacement(transform, symbolVersion: symbolVersion)
    }

    private static func legacyCorrectedSymbolTextPlacement(
        _ transform: HorizontalPlacementTransform,
        symbolVersion: Int
    ) -> HorizontalPlacementTransform {
        // Horizon GTK compensates old symbol files whose mirrored text-placement angles were saved inverted.
        guard symbolVersion == 0, transform.mirrored else {
            return transform
        }
        return HorizontalPlacementTransform(
            shift: transform.shift,
            angle: -transform.angle,
            mirrored: transform.mirrored
        )
    }

    private static func symbolTextPlacementViewKey(for transform: HorizontalPlacementTransform) -> String {
        let degrees = (transform.angle * 360) / 65_536
        return "\(degrees)\(transform.mirrored ? "m" : "n")"
    }

    private static func parseSmashedSymbolTexts(
        from symbolItem: JSONDictionary,
        sheetTextsByID: [String: JSONDictionary],
        component: SchematicComponentInfo?
    ) -> [HorizontalText] {
        symbolTextIDs(from: symbolItem).compactMap { textID in
            guard let item = sheetTextsByID[normalizedID(textID)] else {
                return nil
            }

            return parseAbsoluteText(
                id: textID,
                item: item,
                component: component,
                customValue: symbolItem.string("custom_value")
            )
        }
    }

    private static func symbolTextIDs(from symbolMap: [String: JSONDictionary]) -> Set<String> {
        symbolMap.reduce(into: Set<String>()) { result, item in
            for textID in symbolTextIDs(from: item.value) {
                result.insert(normalizedID(textID))
            }
        }
    }

    private static func symbolTextIDs(from symbolItem: JSONDictionary) -> [String] {
        symbolItem["texts"] as? [String] ?? []
    }

    private static func parseNetLines(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        symbolPositions: [String: HorizontalPoint],
        symbolPinPositions: [String: HorizontalPoint],
        busRipperPositions: [String: HorizontalPoint],
        blockPortPositions: [String: HorizontalPoint]
    ) -> [HorizontalSegment] {
        map.compactMap { id, item in
            guard let from = schematicEndpointPoint(
                item.dictionary("from"),
                junctions: junctions,
                symbolPositions: symbolPositions,
                symbolPinPositions: symbolPinPositions,
                busRipperPositions: busRipperPositions,
                blockPortPositions: blockPortPositions
            ),
                  let to = schematicEndpointPoint(
                    item.dictionary("to"),
                    junctions: junctions,
                    symbolPositions: symbolPositions,
                    symbolPinPositions: symbolPinPositions,
                    busRipperPositions: busRipperPositions,
                    blockPortPositions: blockPortPositions
                  ) else {
                return nil
            }

            return HorizontalSegment(id: id, from: from, to: to, width: 0, layer: nil)
                .withNetID(
                    item.string("net").map(normalizedID)
                        ?? schematicEndpointNetID(item.dictionary("from"), junctionNetIDs: junctionNetIDs)
                        ?? schematicEndpointNetID(item.dictionary("to"), junctionNetIDs: junctionNetIDs)
                )
        }
    }

    private static func schematicNetAnchors(
        junctions: [String: HorizontalPoint],
        junctionNetIDs: [String: String],
        netLabels: [HorizontalSchematicNetLabel],
        netBearingSegments: [HorizontalSegment],
        netBearingCircles: [HorizontalCircle]
    ) -> [String: Set<String>] {
        var anchors = [String: Set<String>]()

        func add(_ point: HorizontalPoint, netID: String?) {
            guard let netID else {
                return
            }
            anchors[pointKey(point), default: []].insert(normalizedID(netID))
        }

        for (junctionID, point) in junctions {
            add(point, netID: junctionNetIDs[junctionID])
        }
        for label in netLabels {
            add(label.position, netID: label.netID)
        }
        for segment in netBearingSegments {
            add(segment.from, netID: segment.netID)
            add(segment.to, netID: segment.netID)
        }
        for circle in netBearingCircles {
            add(circle.center, netID: circle.netID)
        }

        return anchors
    }

    private static func resolveSchematicNetLineIDs(
        _ netLines: [HorizontalSegment],
        anchors: [String: Set<String>]
    ) -> [HorizontalSegment] {
        var result = netLines
        var neighbors = [String: Set<String>]()
        var lineIndicesByPoint = [String: [Int]]()

        for (index, line) in result.enumerated() {
            let fromKey = pointKey(line.from)
            let toKey = pointKey(line.to)
            neighbors[fromKey, default: []].insert(toKey)
            neighbors[toKey, default: []].insert(fromKey)
            lineIndicesByPoint[fromKey, default: []].append(index)
            lineIndicesByPoint[toKey, default: []].append(index)
        }

        var visited = Set<String>()
        for startKey in neighbors.keys where !visited.contains(startKey) {
            var stack = [startKey]
            var componentLineIndices = Set<Int>()
            var componentNetIDs = Set<String>()
            visited.insert(startKey)

            while let key = stack.popLast() {
                componentNetIDs.formUnion(anchors[key] ?? [])
                for index in lineIndicesByPoint[key] ?? [] {
                    componentLineIndices.insert(index)
                    if let netID = result[index].netID {
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

            for index in componentLineIndices where result[index].netID == nil {
                result[index].netID = netID
            }
        }

        return result
    }

    private static func parseTexts(
        from map: [String: JSONDictionary],
        excluding excludedIDs: Set<String> = []
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard !excludedIDs.contains(normalizedID(id)),
                  item.bool("from_smash") != true else {
                return nil
            }

            return parseAbsoluteText(id: id, item: item, component: nil)
        }
    }

    private static func parseFrameTexts(
        from map: [String: JSONDictionary],
        substitutions: [String: String]
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard var text = parseAbsoluteText(id: "frame/text/\(id)", item: item, component: nil) else {
                return nil
            }

            text.text = substituteFrameText(text.text, substitutions: substitutions)
            return text
        }
    }

    private static func frameSubstitutions(
        sheet: JSONDictionary,
        sheetName: String,
        sheetIndex: Int,
        sheetTotal: Int,
        projectMeta: [String: String]
    ) -> [String: String] {
        var substitutions = projectMeta
        for (key, value) in sheet.dictionary("title_block_values") ?? [:] {
            if let value = value as? String {
                substitutions[key] = value
            }
        }
        substitutions["sheet_idx"] = "\(sheetIndex)"
        substitutions["sheet_total"] = "\(sheetTotal)"
        substitutions["sheet_title"] = sheetName
        return substitutions
    }

    private static func substituteFrameText(_ text: String, substitutions: [String: String]) -> String {
        substitutions.keys.sorted { $0.count > $1.count }.reduce(text) { result, key in
            guard let value = substitutions[key] else {
                return result
            }

            return result
                .replacingOccurrences(of: "${\(key)}", with: value)
                .replacingOccurrences(of: "$\(key)", with: value)
        }
    }

    private static func parseTitleBlockValues(from json: JSONDictionary?) -> [String: String] {
        (json ?? [:]).reduce(into: [String: String]()) { result, item in
            if let value = stringValue(item.value) {
                result[item.key] = value
            }
        }
    }

    private static func parseNetClasses(from map: [String: JSONDictionary]) -> [HorizontalNetClass] {
        map.compactMap { item in
            guard let name = nonEmpty(item.value.string("name")) else {
                return nil
            }
            return HorizontalNetClass(id: normalizedID(item.key), name: name)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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

    private static func parseParametricValues(from json: JSONDictionary?) -> [String: String] {
        (json ?? [:]).reduce(into: [String: String]()) { result, item in
            if let value = stringValue(item.value) {
                result[item.key.lowercased()] = value
            }
        }
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func parseAbsoluteText(
        id: String,
        item: JSONDictionary,
        component: SchematicComponentInfo?,
        customValue: String? = nil
    ) -> HorizontalText? {
        guard let placement = HorizontalPlacementTransform(json: item.dictionary("placement")),
              let text = item.string("text") else {
            return nil
        }

        let substitutedText = substituteSymbolText(text, component: component, customValue: customValue)
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

    private static func parsePowerSymbols(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        nets: [String: SchematicNetInfo]
    ) -> (symbols: [HorizontalPowerSymbol], lines: [HorizontalSegment], circles: [HorizontalCircle], texts: [HorizontalText]) {
        var symbols = [HorizontalPowerSymbol]()
        var lines = [HorizontalSegment]()
        var circles = [HorizontalCircle]()
        var texts = [HorizontalText]()

        for (id, item) in map {
            guard let junctionID = item.string("junction"),
                  let position = junctions[junctionID] else {
                continue
            }

            let netID = item.string("net").map(normalizedID)
            let net = netID.flatMap { nets[$0] }
            let style = net?.powerSymbolStyle ?? "gnd"
            let orientation = item.string("orientation")
            let mirror = item.bool("mirror") ?? false
            symbols.append(
                HorizontalPowerSymbol(
                    id: id,
                    junctionID: junctionID,
                    netID: netID,
                    orientation: orientation ?? "down",
                    mirrored: mirror
                )
            )
            let shapeTransform = HorizontalPlacementTransform(
                shift: position,
                angle: angle(forOrientation: orientation) - (style == "dot" || style == "antenna" ? 16_384 : 49_152),
                mirrored: false
            )

            switch style {
            case "dot":
                lines.append(powerSymbolLine(id: "\(id)/dot/stem", from: .zero, to: HorizontalPoint(x: 0, y: 1_000_000), transform: shapeTransform, netID: netID))
                circles.append(
                    HorizontalCircle(
                        id: "\(id)/dot/circle",
                        center: shapeTransform.applying(to: HorizontalPoint(x: 0, y: 1_750_000)),
                        radius: 750_000,
                        layer: nil,
                        netID: netID
                    )
                )
            case "antenna":
                lines.append(powerSymbolLine(id: "\(id)/antenna/stem", from: .zero, to: HorizontalPoint(x: 0, y: 2_500_000), transform: shapeTransform, netID: netID))
                lines.append(powerSymbolLine(id: "\(id)/antenna/left", from: HorizontalPoint(x: -1_000_000, y: 1_000_000), to: HorizontalPoint(x: 0, y: 2_500_000), transform: shapeTransform, netID: netID))
                lines.append(powerSymbolLine(id: "\(id)/antenna/right", from: HorizontalPoint(x: 1_000_000, y: 1_000_000), to: HorizontalPoint(x: 0, y: 2_500_000), transform: shapeTransform, netID: netID))
            case "earth":
                lines.append(powerSymbolLine(id: "\(id)/earth/stem", from: .zero, to: HorizontalPoint(x: 0, y: -1_250_000), transform: shapeTransform, netID: netID))
                for (index, offset) in [0.0, 500_000.0, 1_000_000.0].enumerated() {
                    lines.append(
                        powerSymbolLine(
                            id: "\(id)/earth/\(index)",
                            from: HorizontalPoint(x: -1_250_000 + offset, y: -1_250_000 - offset),
                            to: HorizontalPoint(x: 1_250_000 - offset, y: -1_250_000 - offset),
                            transform: shapeTransform,
                            netID: netID
                        )
                    )
                }
            default:
                lines.append(powerSymbolLine(id: "\(id)/gnd/stem", from: .zero, to: HorizontalPoint(x: 0, y: -1_250_000), transform: shapeTransform, netID: netID))
                lines.append(powerSymbolLine(id: "\(id)/gnd/top", from: HorizontalPoint(x: -1_250_000, y: -1_250_000), to: HorizontalPoint(x: 1_250_000, y: -1_250_000), transform: shapeTransform, netID: netID))
                lines.append(powerSymbolLine(id: "\(id)/gnd/left", from: HorizontalPoint(x: -1_250_000, y: -1_250_000), to: HorizontalPoint(x: 0, y: -2_500_000), transform: shapeTransform, netID: netID))
                lines.append(powerSymbolLine(id: "\(id)/gnd/right", from: HorizontalPoint(x: 1_250_000, y: -1_250_000), to: HorizontalPoint(x: 0, y: -2_500_000), transform: shapeTransform, netID: netID))
            }

            if net?.powerSymbolNameVisible ?? true {
                texts.append(
                    powerSymbolText(
                        id: id,
                        position: position,
                        style: style,
                        orientation: orientation,
                        mirror: mirror,
                        text: net?.name ?? netID?.prefix(8).description ?? "power",
                        netID: netID
                    )
                )
            }
        }

        return (symbols, lines, circles, texts)
    }

    private static func powerSymbolLine(
        id: String,
        from: HorizontalPoint,
        to: HorizontalPoint,
        transform: HorizontalPlacementTransform,
        netID: String?
    ) -> HorizontalSegment {
        HorizontalSegment(
            id: id,
            from: transform.applying(to: from),
            to: transform.applying(to: to),
            width: 0,
            layer: nil,
            netID: netID
        )
    }

    private static func powerSymbolText(
        id: String,
        position: HorizontalPoint,
        style: String,
        orientation: String?,
        mirror: Bool,
        text: String,
        netID: String?
    ) -> HorizontalText {
        var offset = HorizontalPoint(x: 1_250_000, y: -1_875_000)
        var mirrored = mirror
        if style == "dot" || style == "antenna" {
            mirrored = false
            switch orientation {
            case "up":
                offset = HorizontalPoint(x: 1_250_000, y: 1_875_000)
                mirrored = !mirror
            case "right":
                offset = HorizontalPoint(x: 3_125_000, y: 0)
            case "left":
                offset = HorizontalPoint(x: 3_125_000, y: 0)
                mirrored = true
            default:
                offset = HorizontalPoint(x: 1_250_000, y: -1_875_000)
                mirrored = mirror
            }
        }

        var angle = 0
        if mirrored {
            offset.x *= -1
            angle = 32_768
        }

        return HorizontalText(
            id: "\(id)/power-name",
            text: text,
            position: position + offset,
            size: 1_500_000,
            layer: nil,
            netID: netID,
            angle: angle,
            origin: .center
        )
    }

    private static func parseBusArtwork(
        from sheet: JSONDictionary,
        junctions: [String: HorizontalPoint],
        buses: [String: SchematicBusInfo]
    ) -> SchematicBusArtwork {
        var artwork = SchematicBusArtwork()

        artwork.labels = sheet.dictionaryMap("bus_labels").compactMap { id, item in
            guard let junctionID = item.string("junction"),
                  let position = junctions[junctionID] else {
                return nil
            }

            let busID = item.string("bus").map(normalizedID)
            let busName = busID.flatMap { buses[$0]?.name }
                ?? item.string("bus").map { String($0.prefix(8)) }
                ?? "bus"

            return HorizontalBusLabel(
                id: id,
                text: "B:\(busName)",
                position: position,
                size: item.double("size") ?? 2_500_000,
                orientation: item.string("orientation") ?? "right"
            )
        }

        for (id, item) in sheet.dictionaryMap("bus_rippers") {
            guard let junctionID = item.string("junction"),
                  let junction = junctions[junctionID] else {
                continue
            }

            let orientation = item.string("orientation") ?? (item.bool("mirror") == true ? "left" : "up")
            let connector = junction + busRipperConnectorOffset(for: orientation)
            let busID = item.string("bus").map(normalizedID)
            let memberID = item.string("bus_member").map(normalizedID)
            let memberNetID = busID.flatMap { busID in
                memberID.flatMap { buses[busID]?.members[$0]?.netID }
            }
            artwork.ripperConnectorPositions[normalizedID(id)] = connector
            artwork.ripperLines.append(
                HorizontalSegment(
                    id: "\(id)/bus-ripper",
                    from: junction,
                    to: connector,
                    width: 0,
                    layer: nil,
                    netID: memberNetID
                )
            )

            let memberName = busID.flatMap { busID in
                memberID.flatMap { buses[busID]?.members[$0]?.name }
            } ?? item.string("bus_member").map { String($0.prefix(8)) } ?? ""
            guard !memberName.isEmpty else {
                continue
            }

            let textPosition = item.string("text_position") ?? "top"
            let textShift = textPosition == "bottom" ? -500_000.0 : 500_000.0
            let textOrigin: HorizontalTextOrigin = textPosition == "bottom" ? .bottom : .baseline
            let textAngle = orientation == "left" || orientation == "down" ? 32_768 : 0
            artwork.ripperTexts.append(
                HorizontalText(
                    id: "\(id)/bus-ripper-text",
                    text: memberName,
                    position: connector + HorizontalPoint(x: 0, y: textShift),
                    size: 1_500_000,
                    layer: nil,
                    netID: memberNetID,
                    angle: textAngle,
                    origin: textOrigin
                )
            )
        }

        return artwork
    }

    private static func parseBlockSymbolArtwork(
        from map: [String: JSONDictionary],
        blockInfo: SchematicBlockInfo,
        blockSymbols: [String: HorizontalSchematicBlockResource]
    ) -> SchematicBlockSymbolArtwork {
        var result = SchematicBlockSymbolArtwork()
        var symbolCache = [String: JSONDictionary]()

        for (blockSymbolID, item) in map {
            guard let blockInstanceID = item.string("block_instance").map(normalizedID),
                  let instance = blockInfo.blockInstances[blockInstanceID],
                  let resource = blockSymbols[instance.blockID],
                  let symbolTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                continue
            }

            let cacheKey = resource.symbolURL.path
            let symbolJSON: JSONDictionary
            if let cached = symbolCache[cacheKey] {
                symbolJSON = cached
            } else if let loaded = try? JSONHelper.loadDictionary(from: resource.symbolURL) {
                symbolCache[cacheKey] = loaded
                symbolJSON = loaded
            } else {
                continue
            }

            let localJunctions = parseJunctions(from: symbolJSON)
            let transformedJunctions = localJunctions.mapValues(symbolTransform.applying)
            result.lines.append(contentsOf: parseSymbolLines(
                from: symbolJSON.dictionaryMap("lines"),
                symbolInstanceID: blockSymbolID,
                junctions: transformedJunctions
            ))
            result.lines.append(contentsOf: parseSymbolArcs(
                from: symbolJSON.dictionaryMap("arcs"),
                symbolInstanceID: blockSymbolID,
                junctions: localJunctions,
                symbolTransform: symbolTransform
            ))
            result.texts.append(contentsOf: parseBlockSymbolTexts(
                from: symbolJSON.dictionaryMap("texts"),
                blockSymbolID: blockSymbolID,
                symbolTransform: symbolTransform,
                instance: instance,
                resource: resource
            ))

            let ports = parseBlockSymbolPorts(
                from: symbolJSON.dictionaryMap("ports"),
                blockSymbolID: blockSymbolID,
                symbolTransform: symbolTransform,
                instance: instance,
                resource: resource
            )
            result.ports.append(contentsOf: ports.lines)
            result.texts.append(contentsOf: ports.texts)
            result.portPositions.merge(ports.positions) { current, _ in current }
        }

        return result
    }

    private static func parseBlockSymbolTexts(
        from map: [String: JSONDictionary],
        blockSymbolID: String,
        symbolTransform: HorizontalPlacementTransform,
        instance: SchematicBlockInstanceInfo,
        resource: HorizontalSchematicBlockResource
    ) -> [HorizontalText] {
        map.compactMap { id, item in
            guard let text = item.string("text"),
                  let textTransform = HorizontalPlacementTransform(json: item.dictionary("placement")) else {
                return nil
            }

            let substituted = substituteBlockSymbolText(text, instance: instance, resource: resource)
            guard !substituted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let transformed = symbolTransform.accumulatedText(with: textTransform)
            return HorizontalText(
                id: "\(blockSymbolID)/block-text/\(id)",
                text: substituted,
                position: transformed.shift,
                size: item.double("size") ?? 1_000_000,
                layer: item.int("layer"),
                angle: transformed.angle,
                mirrored: transformed.mirrored,
                width: item.double("width") ?? 0,
                origin: item.horizonTextOrigin(),
                font: item.horizonTextFont(),
                allowUpsideDown: item.bool("allow_upside_down") ?? false
            )
        }
    }

    private static func parseBlockSymbolPorts(
        from map: [String: JSONDictionary],
        blockSymbolID: String,
        symbolTransform: HorizontalPlacementTransform,
        instance: SchematicBlockInstanceInfo,
        resource: HorizontalSchematicBlockResource
    ) -> (lines: [HorizontalSegment], texts: [HorizontalText], positions: [String: HorizontalPoint]) {
        var lines = [HorizontalSegment]()
        var texts = [HorizontalText]()
        var positions = [String: HorizontalPoint]()

        for (id, item) in map {
            guard let localPosition = item.point("position") else {
                continue
            }

            let portID = normalizedID(id)
            let position = symbolTransform.applying(to: localPosition)
            let orientation = pinOrientationForPlacement(item.string("orientation"), transform: symbolTransform)
            let length = item.double("length") ?? 0
            let netID = item.string("net").map(normalizedID)
            let portNetID = netID.flatMap { instance.connections[$0]?.netID }
            let netResource = netID.flatMap { resource.nets[$0] }
            let connectorStyle = blockPortConnectorStyle(for: netID, instance: instance)
            positions[normalizedUUIDPath("\(blockSymbolID)/\(portID)")] = position

            var end = position
            var namePosition = position
            var nameOrientation = "left"
            switch orientation {
            case "left":
                end.x += length
                namePosition.x += length + 500_000
                nameOrientation = "right"
            case "right":
                end.x -= length
                namePosition.x -= length + 500_000
                nameOrientation = "left"
            case "up":
                end.y -= length
                namePosition.y -= length + 500_000
                nameOrientation = "down"
            case "down":
                end.y += length
                namePosition.y += length + 500_000
                nameOrientation = "up"
            default:
                break
            }

            lines.append(
                HorizontalSegment(
                    id: "\(blockSymbolID)/block-port/\(id)",
                    from: position,
                    to: end,
                    width: 0,
                    layer: nil,
                    netID: portNetID
                )
            )
            lines.append(
                contentsOf: pinDirectionSegments(
                    id: "\(blockSymbolID)/block-port-direction/\(id)",
                    position: position,
                    orientation: orientation,
                    direction: netResource?.portDirection
                ).map { segment in
                    var segment = segment
                    segment.netID = portNetID
                    return segment
                }
            )
            lines.append(
                contentsOf: pinConnectorSegments(
                    id: "\(blockSymbolID)/block-port-connector/\(id)",
                    position: position,
                    orientation: orientation,
                    connectorStyle: connectorStyle
                ).map { segment in
                    var segment = segment
                    segment.netID = portNetID
                    return segment
                }
            )
            if let text = pinConnectorText(
                id: "\(blockSymbolID)/block-port-connector-text/\(id)",
                position: position,
                orientation: orientation,
                connectorStyle: connectorStyle
            ) {
                var text = text
                text.netID = portNetID
                texts.append(text)
            }

            let portName = netResource?.name ?? ""
            guard !portName.isEmpty else {
                continue
            }

            let nameMode = item.string("name_orientation") ?? "in_line"
            let drawInLine = nameMode == "in_line" || (nameMode == "horizontal" && (orientation == "left" || orientation == "right"))
            let textPosition = drawInLine
                ? namePosition
                : namePosition + rotate(HorizontalPoint(x: -1_000_000, y: 0), angle: angle(forOrientation: orientation))
            texts.append(
                HorizontalText(
                    id: "\(blockSymbolID)/block-port-name/\(id)",
                    text: portName,
                    position: textPosition,
                    size: 1_500_000,
                    layer: nil,
                    angle: angle(forOrientation: nameOrientation) + (drawInLine ? 0 : 16_384),
                    origin: .center,
                    centered: !drawInLine
                )
            )
        }

        return (lines, texts, positions)
    }

    private static func blockPortConnectorStyle(for netID: String?, instance: SchematicBlockInstanceInfo) -> String {
        guard let netID, let connection = instance.connections[netID] else {
            return "box"
        }

        switch connection {
        case .connected(_):
            return "none"
        case .notConnected:
            return "nc"
        }
    }

    private static func pinDirectionSegments(
        id: String,
        position: HorizontalPoint,
        orientation: String,
        direction: String?
    ) -> [HorizontalSegment] {
        let pairs: [(HorizontalPoint, HorizontalPoint)]
        switch direction?.lowercased() {
        case "output":
            pairs = [
                (millimeters(0, -0.6), millimeters(-1, -0.2)),
                (millimeters(0, -0.6), millimeters(-1, -1)),
            ]
        case "input":
            pairs = [
                (millimeters(-1, -0.6), millimeters(0, -0.2)),
                (millimeters(-1, -0.6), millimeters(0, -1)),
            ]
        case "power_input", "power-in", "power_in":
            pairs = [
                (millimeters(-1, -0.6), millimeters(0, -0.2)),
                (millimeters(-1, -0.6), millimeters(0, -1)),
                (millimeters(-1.4, -0.6), millimeters(-0.4, -0.2)),
                (millimeters(-1.4, -0.6), millimeters(-0.4, -1)),
            ]
        case "power_output", "power-out", "power_out":
            pairs = [
                (millimeters(0, -0.6), millimeters(-1, -0.2)),
                (millimeters(0, -0.6), millimeters(-1, -1)),
                (millimeters(-0.4, -0.6), millimeters(-1.4, -0.2)),
                (millimeters(-0.4, -0.6), millimeters(-1.4, -1)),
            ]
        case "bidirectional", nil:
            pairs = [
                (millimeters(0, -0.6), millimeters(-1, -0.2)),
                (millimeters(0, -0.6), millimeters(-1, -1)),
                (millimeters(-2, -0.6), millimeters(-1, -0.2)),
                (millimeters(-2, -0.6), millimeters(-1, -1)),
            ]
        case "not_connected", "not-connected", "notconnected":
            pairs = [
                (millimeters(-0.4, -1), millimeters(-1, -0.2)),
                (millimeters(-0.4, -0.2), millimeters(-1, -1)),
            ]
        default:
            return []
        }

        return pairs.enumerated().map { index, pair in
            HorizontalSegment(
                id: "\(id)/\(index)",
                from: pinLocalPoint(pair.0, position: position, orientation: orientation),
                to: pinLocalPoint(pair.1, position: position, orientation: orientation),
                width: 0,
                layer: nil
            )
        }
    }

    private static func pinConnectorSegments(
        id: String,
        position: HorizontalPoint,
        orientation: String,
        connectorStyle: String?
    ) -> [HorizontalSegment] {
        switch connectorStyle?.lowercased() {
        case "box":
            let half = millimeters(0.25, 0.25)
            let corners = [
                HorizontalPoint(x: -half.x, y: -half.y),
                HorizontalPoint(x: half.x, y: -half.y),
                HorizontalPoint(x: half.x, y: half.y),
                HorizontalPoint(x: -half.x, y: half.y),
            ].map { pinLocalPoint($0, position: position, orientation: orientation) }
            return zip(corners.indices, corners).map { index, from in
                HorizontalSegment(
                    id: "\(id)/box/\(index)",
                    from: from,
                    to: corners[(index + 1) % corners.count],
                    width: 0,
                    layer: nil
                )
            }
        case "nc", "not_connected", "not-connected", "notconnected":
            let a = millimeters(0.25, 0.25)
            let b = millimeters(-0.25, 0.25)
            return [
                HorizontalSegment(
                    id: "\(id)/nc/0",
                    from: pinLocalPoint(HorizontalPoint(x: -a.x, y: -a.y), position: position, orientation: orientation),
                    to: pinLocalPoint(a, position: position, orientation: orientation),
                    width: 0,
                    layer: nil
                ),
                HorizontalSegment(
                    id: "\(id)/nc/1",
                    from: pinLocalPoint(HorizontalPoint(x: -b.x, y: -b.y), position: position, orientation: orientation),
                    to: pinLocalPoint(b, position: position, orientation: orientation),
                    width: 0,
                    layer: nil
                ),
            ]
        default:
            return []
        }
    }

    private static func pinConnectorText(
        id: String,
        position: HorizontalPoint,
        orientation: String,
        connectorStyle: String?
    ) -> HorizontalText? {
        switch connectorStyle?.lowercased() {
        case "nc", "not_connected", "not-connected", "notconnected":
            return HorizontalText(
                id: id,
                text: "NC",
                position: pinLocalPoint(millimeters(0.25, 0), position: position, orientation: orientation),
                size: 1_500_000,
                layer: nil,
                angle: angle(forOrientation: orientation),
                origin: .center
            )
        default:
            return nil
        }
    }

    private static func pinLocalPoint(
        _ local: HorizontalPoint,
        position: HorizontalPoint,
        orientation: String
    ) -> HorizontalPoint {
        let transformed: HorizontalPoint
        switch orientation {
        case "left":
            transformed = HorizontalPoint(x: -local.x, y: local.y)
        case "up":
            transformed = HorizontalPoint(x: -local.y, y: local.x)
        case "down":
            transformed = HorizontalPoint(x: -local.y, y: -local.x)
        default:
            transformed = local
        }
        return position + transformed
    }

    private static func millimeters(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private static func parseNetLabels(
        from map: [String: JSONDictionary],
        sheetID: String,
        junctions: [String: HorizontalPoint],
        nets: [String: SchematicNetInfo],
        sheetRefs: [String: [String: [Int]]]
    ) -> [HorizontalSchematicNetLabel] {
        map.compactMap { id, item in
            guard let junctionID = item.string("junction"),
                  let position = junctions[junctionID] else {
                return nil
            }

            let netID = item.string("last_net").map(normalizedID)
            let net = netID.flatMap { nets[$0] }
            let netName = net?.name ?? item.string("last_net")?.prefix(8).description ?? ""
            var labelText = netName
            if labelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labelText = "? plz fix"
            }
            if item.bool("show_port") == true, let net, net.isPort {
                labelText = "\(portPrefix(for: net.portDirection)): \(labelText)"
            }

            let references = sheetRefs[sheetID]?[id] ?? []
            if item.bool("offsheet_refs") ?? true, !references.isEmpty {
                labelText += " [\(references.map(String.init).joined(separator: ","))]"
            }

            return HorizontalSchematicNetLabel(
                id: id,
                text: labelText,
                position: position,
                size: item.double("size") ?? 1_000_000,
                orientation: item.string("orientation") ?? "right",
                netID: netID
            )
        }
    }

    private static func netLabelSheetReferences(from sheets: [String: JSONDictionary]) -> [String: [String: [Int]]] {
        var labelsByNet = [String: [(sheetID: String, labelID: String, sheetIndex: Int)]]()

        for (sheetID, sheet) in sheets {
            let sheetIndex = sheet.int("index") ?? 0
            for (labelID, label) in sheet.dictionaryMap("net_labels") {
                guard let netID = label.string("last_net").map(normalizedID) else {
                    continue
                }
                labelsByNet[netID, default: []].append((sheetID: sheetID, labelID: labelID, sheetIndex: sheetIndex))
            }
        }

        var references = [String: [String: [Int]]]()
        for labels in labelsByNet.values where labels.count > 1 {
            for label in labels {
                let otherSheets = Set(labels.compactMap { other -> Int? in
                    guard other.sheetID != label.sheetID else {
                        return nil
                    }
                    return other.sheetIndex
                })
                guard !otherSheets.isEmpty else {
                    continue
                }
                references[label.sheetID, default: [:]][label.labelID] = otherSheets.sorted()
            }
        }
        return references
    }

    private static func portPrefix(for direction: String) -> String {
        switch direction {
        case "input":
            return "IN"
        case "output":
            return "OUT"
        case "open_collector":
            return "OC"
        case "power_input":
            return "PIN"
        case "power_output":
            return "POUT"
        case "passive":
            return "PASV"
        case "not_connected":
            return "NC"
        default:
            return "BIDI"
        }
    }

    private static func parseNetTies(
        from map: [String: JSONDictionary],
        junctions: [String: HorizontalPoint],
        netTies: [String: SchematicNetTieInfo]
    ) -> [HorizontalSchematicNetTie] {
        map.compactMap { id, item in
            guard let fromID = item.string("from"),
                  let toID = item.string("to"),
                  let from = junctions[fromID],
                  let to = junctions[toID] else {
                return nil
            }

            let netTieID = item.string("net_tie").map(normalizedID)
            let info = netTieID.flatMap { netTies[$0] }
            let primaryName = displayNetTieName(info?.primaryName)
            let secondaryName = displayNetTieName(info?.secondaryName)

            return HorizontalSchematicNetTie(
                id: id,
                from: from,
                to: to,
                label: "\(primaryName)\n\(secondaryName)",
                netIDs: Set([info?.primaryID, info?.secondaryID].compactMap(\.self))
            )
        }
    }

    private static func schematicEndpointPoint(
        _ endpoint: JSONDictionary?,
        junctions: [String: HorizontalPoint],
        symbolPositions: [String: HorizontalPoint],
        symbolPinPositions: [String: HorizontalPoint],
        busRipperPositions: [String: HorizontalPoint],
        blockPortPositions: [String: HorizontalPoint]
    ) -> HorizontalPoint? {
        guard let endpoint else {
            return nil
        }

        if let junctionID = endpoint.string("junc") {
            return junctions[junctionID]
        }

        if let pin = endpoint.string("pin") {
            if let position = symbolPinPositions[normalizedUUIDPath(pin)] {
                return position
            }

            let symbolID = pin.split(separator: "/").first.map(String.init)
            if let symbolID {
                return symbolPositions[symbolID]
            }
        }

        if let busRipperID = endpoint.string("bus_ripper") {
            return busRipperPositions[normalizedID(busRipperID)]
        }

        if let portPath = endpoint.string("port") {
            return blockPortPositions[normalizedUUIDPath(portPath)]
        }

        return nil
    }

    private static func schematicEndpointNetID(
        _ endpoint: JSONDictionary?,
        junctionNetIDs: [String: String]
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

        return nil
    }

    private static func parseBlockInfo(from blockURL: URL, poolURL: URL?) throws -> SchematicBlockInfo {
        let json = try JSONHelper.loadDictionary(from: blockURL)
        var packageCache = [String: JSONDictionary]()
        var partDetailsCache = [String: PartDetails]()
        var missingPartDetails = Set<String>()
        var entityGateCache = [String: [String: (suffix: String, symbolID: String?)]]()
        var symbolsByUnitIDCache = [String: [String]]()
        var didLoadSymbolsByUnitID = false
        let components = json.dictionaryMap("components").reduce(into: [String: SchematicComponentInfo]()) { result, item in
            let componentID = normalizedID(item.key)
            let entityID = item.value.string("entity").map(normalizedID)
            let partID = item.value.string("part").map(normalizedID)
            let gateInfo = entityID.flatMap {
                loadEntityGateInfo(
                    $0,
                    poolURL: poolURL,
                    symbolsByUnitIDCache: &symbolsByUnitIDCache,
                    didLoadSymbolsByUnitID: &didLoadSymbolsByUnitID,
                    entityGateCache: &entityGateCache
                )
            } ?? [:]
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
            let componentValue = partDetails?.value ?? item.value.string("value") ?? ""
            let altPins = item.value.dictionaryMap("alt_pins").reduce(into: [String: SchematicAltPinInfo]()) { result, item in
                result[normalizedUUIDPath(item.key)] = SchematicAltPinInfo(
                    pinNames: (item.value["pin_names"] as? [String] ?? []).map(normalizedID),
                    usePrimaryName: item.value.bool("use_primary_name") ?? false,
                    useCustomName: item.value.bool("use_custom_name") ?? false,
                    customName: item.value.string("custom_name") ?? "",
                    customDirection: item.value.string("custom_direction") ?? "bidirectional"
                )
            }
            let connections = parseConnectionStates(from: item.value.dictionaryMap("connections"))
            result[normalizedID(item.key)] = SchematicComponentInfo(
                refdes: item.value.string("refdes") ?? "",
                value: componentValue,
                partID: partID,
                noPopulate: item.value.bool("nopopulate") ?? false,
                gateSuffixes: Dictionary(uniqueKeysWithValues: gateInfo.map { gateID, info in
                    (gateID, info.suffix)
                }),
                gateSymbolIDs: Dictionary(uniqueKeysWithValues: gateInfo.compactMap { gateID, info in
                    info.symbolID.map { (gateID, $0) }
                }),
                altPins: altPins,
                connections: connections,
                details: HorizontalComponentDetails(
                    componentID: componentID,
                    refdes: item.value.string("refdes") ?? "",
                    value: componentValue,
                    partID: partID,
                    noPopulate: item.value.bool("nopopulate") ?? false,
                    mpn: partDetails?.mpn,
                    manufacturer: partDetails?.manufacturer,
                    packageName: partDetails?.packageName,
                    description: partDetails?.description,
                    datasheet: partDetails?.datasheet,
                    parametricValues: partDetails?.parametricValues ?? [:]
                )
            )
        }
        let netClasses = parseNetClasses(from: json.dictionaryMap("net_classes"))
        let netClassNames = Dictionary(uniqueKeysWithValues: netClasses.map { (normalizedID($0.id), $0.name) })
        let nets = json.dictionaryMap("nets").reduce(into: [String: SchematicNetInfo]()) { result, item in
            let name = item.value.string("name") ?? String(item.key.prefix(8))
            let netClassID = item.value.string("net_class").map(normalizedID)
            result[normalizedID(item.key)] = SchematicNetInfo(
                name: name,
                netClassName: netClassID.flatMap { netClassNames[$0] },
                isPower: item.value.bool("is_power") ?? false,
                isPort: item.value.bool("is_port") ?? false,
                portDirection: item.value.string("port_direction") ?? "bidirectional",
                powerSymbolStyle: item.value.string("power_symbol_style") ?? "gnd",
                powerSymbolNameVisible: item.value.bool("power_symbol_name_visible") ?? true
            )
        }
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
        let buses = json.dictionaryMap("buses").reduce(into: [String: SchematicBusInfo]()) { result, item in
            let members = item.value.dictionaryMap("members").reduce(into: [String: SchematicBusMemberInfo]()) { result, item in
                result[normalizedID(item.key)] = SchematicBusMemberInfo(
                    name: item.value.string("name") ?? String(item.key.prefix(8)),
                    netID: item.value.string("net").map(normalizedID)
                )
            }
            result[normalizedID(item.key)] = SchematicBusInfo(
                name: item.value.string("name") ?? String(item.key.prefix(8)),
                members: members
            )
        }
        let blockInstances = json.dictionaryMap("block_instances").reduce(into: [String: SchematicBlockInstanceInfo]()) { result, item in
            guard let blockID = item.value.string("block") else {
                return
            }
            let connections = parseConnectionStates(from: item.value.dictionaryMap("connections"))
            result[normalizedID(item.key)] = SchematicBlockInstanceInfo(
                blockID: normalizedID(blockID),
                refdes: item.value.string("refdes") ?? String(item.key.prefix(8)),
                connections: connections
            )
        }
        let netTies = json.dictionaryMap("net_ties").reduce(into: [String: SchematicNetTieInfo]()) { result, item in
            let primaryID = item.value.string("net_primary").map(normalizedID)
            let secondaryID = item.value.string("net_secondary").map(normalizedID)
            result[normalizedID(item.key)] = SchematicNetTieInfo(
                primaryID: primaryID,
                secondaryID: secondaryID,
                primaryName: primaryID.flatMap { nets[$0]?.name } ?? primaryID.map { String($0.prefix(8)) } ?? "",
                secondaryName: secondaryID.flatMap { nets[$0]?.name } ?? secondaryID.map { String($0.prefix(8)) } ?? ""
            )
        }
        let projectMeta = (json.dictionary("project_meta") ?? [:]).reduce(into: [String: String]()) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            }
        }
        return SchematicBlockInfo(
            components: components,
            nets: nets,
            buses: buses,
            blockInstances: blockInstances,
            netTies: netTies,
            netClasses: netClasses,
            netDetails: netDetails,
            projectMeta: projectMeta
        )
    }

    private static func schematicPlaceableObjects(
        componentInfo: [String: SchematicComponentInfo]
    ) -> [HorizontalUnplacedObject] {
        let objects = componentInfo.flatMap { componentID, component -> [HorizontalUnplacedObject] in
            let normalizedComponentID = normalizedID(componentID)
            let baseRefdes = nonEmpty(component.refdes)
                ?? component.details?.displayLabel
                ?? String(componentID.prefix(8))

            if component.gateSuffixes.isEmpty {
                return [
                    HorizontalUnplacedObject(
                        id: normalizedComponentID,
                    label: baseRefdes,
                    subtitle: "Symbol",
                    componentID: normalizedComponentID,
                    gateID: nil,
                    symbolID: component.gateSymbolIDs.values.sorted {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }.first,
                    details: component.details
                )
            ]
            }

            return component.gateSuffixes.map { gateID, suffix in
                let normalizedGateID = normalizedID(gateID)
                return HorizontalUnplacedObject(
                    id: "\(normalizedComponentID)/\(normalizedGateID)",
                    label: "\(baseRefdes)\(suffix)",
                    subtitle: "Symbol",
                    componentID: normalizedComponentID,
                    gateID: normalizedGateID,
                    symbolID: component.gateSymbolIDs[normalizedGateID],
                    details: component.details
                )
            }
        }

        return objects.sorted { lhs, rhs in
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func unplacedSchematicObjects(
        placeableObjects: [HorizontalUnplacedObject],
        sheets: [HorizontalSchematicSheet]
    ) -> [HorizontalUnplacedObject] {
        var placedGates = Set<String>()
        var placedComponents = Set<String>()
        for sheet in sheets {
            for symbol in sheet.symbols {
                guard let componentID = symbol.componentID.map(normalizedID) else {
                    continue
                }
                placedComponents.insert(componentID)
                if let gateID = symbol.gateID.map(normalizedID) {
                    placedGates.insert("\(componentID)/\(gateID)")
                }
            }
        }

        let objects = placeableObjects.filter { object in
            guard let componentID = object.componentID.map(normalizedID) else {
                return true
            }
            if let gateID = object.gateID.map(normalizedID) {
                return !placedGates.contains("\(componentID)/\(gateID)")
            }
            return !placedComponents.contains(componentID)
        }

        return objects.sorted { lhs, rhs in
            lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    private static func loadEntityGateInfo(
        _ entityID: String,
        poolURL: URL?,
        symbolsByUnitIDCache: inout [String: [String]],
        didLoadSymbolsByUnitID: inout Bool,
        entityGateCache: inout [String: [String: (suffix: String, symbolID: String?)]]
    ) -> [String: (suffix: String, symbolID: String?)] {
        guard let poolURL else {
            return [:]
        }

        let entityID = normalizedID(entityID)
        if let cached = entityGateCache[entityID] {
            return cached
        }

        let entityURL = poolURL
            .appendingPathComponent("entities")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(entityID).json")
        guard let resolvedURL = existingFileURL(entityURL),
              let entityJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            entityGateCache[entityID] = [:]
            return [:]
        }

        if !didLoadSymbolsByUnitID {
            symbolsByUnitIDCache = BoardLoadTimer.measure("schematic block: load symbol unit index") {
                loadSymbolIDsByUnitID(poolURL: poolURL)
            }
            didLoadSymbolsByUnitID = true
        }
        let gateInfo = entityJSON.dictionaryMap("gates").reduce(into: [String: (suffix: String, symbolID: String?)]()) { result, item in
            let unitID = item.value.string("unit").map(normalizedID)
            result[normalizedID(item.key)] = (
                suffix: item.value.string("suffix") ?? "",
                symbolID: unitID.flatMap { symbolsByUnitIDCache[$0]?.first }
            )
        }
        entityGateCache[entityID] = gateInfo
        return gateInfo
    }

    private static func loadSymbolIDsByUnitID(poolURL: URL) -> [String: [String]] {
        let symbolsURL = poolURL
            .appendingPathComponent("symbols")
            .appendingPathComponent("cache")
        guard let symbolURLs = try? FileManager.default.contentsOfDirectory(
            at: symbolsURL,
            includingPropertiesForKeys: nil
        ) else {
            return [:]
        }

        var result = [String: [String]]()
        for url in symbolURLs where url.pathExtension.lowercased() == "json" {
            guard let symbolJSON = try? JSONHelper.loadDictionary(from: url),
                  let unitID = symbolJSON.string("unit").map(normalizedID) else {
                continue
            }
            let symbolID = normalizedID(symbolJSON.string("uuid") ?? url.deletingPathExtension().lastPathComponent)
            result[unitID, default: []].append(symbolID)
        }

        for unitID in result.keys {
            result[unitID]?.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return result
    }

    private static func parseConnectionStates(from map: [String: JSONDictionary]) -> [String: SchematicConnectionState] {
        map.reduce(into: [String: SchematicConnectionState]()) { result, connection in
            if let netID = connection.value.string("net").map(normalizedID) {
                result[normalizedUUIDPath(connection.key)] = .connected(netID)
            } else {
                result[normalizedUUIDPath(connection.key)] = .notConnected
            }
        }
    }

    private static func loadSymbol(
        _ symbolID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let symbolID = normalizedID(symbolID)
        if let cached = cache[symbolID] {
            return cached
        }

        let symbolURL = poolURL
            .appendingPathComponent("symbols")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(symbolID).json")

        guard let resolvedURL = existingFileURL(symbolURL),
              let symbolJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            return nil
        }

        cache[symbolID] = symbolJSON
        return symbolJSON
    }

    private static func loadFrame(
        _ frameID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let frameID = normalizedID(frameID)
        if let cached = cache[frameID] {
            return cached
        }

        let frameURL = poolURL
            .appendingPathComponent("frames")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(frameID).json")

        guard let resolvedURL = existingFileURL(frameURL),
              let frameJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            return nil
        }

        cache[frameID] = frameJSON
        return frameJSON
    }

    private static func loadUnit(
        _ unitID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let unitID = normalizedID(unitID)
        if let cached = cache[unitID] {
            return cached
        }

        let unitURL = poolURL
            .appendingPathComponent("units")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(unitID).json")

        guard let resolvedURL = existingFileURL(unitURL),
              let unitJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            return nil
        }

        cache[unitID] = unitJSON
        return unitJSON
    }

    private static func loadUnitPinInfos(
        _ unitID: String,
        poolURL: URL,
        unitCache: inout [String: JSONDictionary],
        unitPinInfoCache: inout [String: [String: SchematicUnitPinInfo]]
    ) -> [String: SchematicUnitPinInfo] {
        let unitID = normalizedID(unitID)
        if let cached = unitPinInfoCache[unitID] {
            return cached
        }

        guard let unitJSON = loadUnit(unitID, poolURL: poolURL, cache: &unitCache) else {
            unitPinInfoCache[unitID] = [:]
            return [:]
        }

        let pins = unitJSON.dictionaryMap("pins").reduce(into: [String: SchematicUnitPinInfo]()) { result, item in
            let pinID = normalizedID(item.key)
            let pin = item.value
            result[pinID] = SchematicUnitPinInfo(
                primaryName: pin.string("primary_name") ?? "",
                primaryDirection: pin.string("direction") ?? "bidirectional",
                alternateNames: alternatePinNames(from: pin),
                alternateNameOptions: alternatePinNameOptions(from: pin)
            )
        }
        unitPinInfoCache[unitID] = pins
        return pins
    }

    private static func loadPartInfo(
        _ partID: String,
        poolURL: URL,
        partCache: inout [String: SchematicPartInfo],
        packageCache: inout [String: JSONDictionary]
    ) -> SchematicPartInfo? {
        let partID = normalizedID(partID)
        if let cached = partCache[partID] {
            return cached
        }

        let partURL = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(partID).json")

        guard let resolvedURL = existingFileURL(partURL),
              let partJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            return nil
        }

        let baseInfo = partJSON.string("base").flatMap { baseID in
            loadPartInfo(
                baseID,
                poolURL: poolURL,
                partCache: &partCache,
                packageCache: &packageCache
            )
        }

        let packageID = baseInfo == nil ? partJSON.string("package").map(normalizedID) : nil
        let padNamesByID = packageID
            .flatMap { loadPackage($0, poolURL: poolURL, cache: &packageCache) }?
            .dictionaryMap("pads")
            .reduce(into: [String: String]()) { result, item in
                result[normalizedID(item.key)] = item.value.string("name") ?? ""
            } ?? [:]

        var padNamesByGatePin = baseInfo?.padNamesByGatePin ?? [:]
        if baseInfo == nil {
            partJSON.dictionaryMap("pad_map").forEach { item in
                guard let gateID = item.value.string("gate"),
                      let pinID = item.value.string("pin") else {
                    return
                }

                let padName = padNamesByID[normalizedID(item.key)] ?? String(item.key.prefix(8))
                let gatePinPath = normalizedUUIDPath("\(gateID)/\(pinID)")
                padNamesByGatePin[gatePinPath, default: []].append(padName)
            }
        }
        let partInfo = SchematicPartInfo(
            padNamesByGatePin: padNamesByGatePin,
            details: partDetails(
                from: partJSON,
                baseDetails: baseInfo?.details,
                poolURL: poolURL,
                packageCache: &packageCache
            )
        )
        partCache[partID] = partInfo
        return partInfo
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
        guard !missingDetails.contains(partID) else {
            return nil
        }

        let partURL = poolURL
            .appendingPathComponent("parts")
            .appendingPathComponent("cache")
            .appendingPathComponent("\(partID).json")

        guard let resolvedURL = existingFileURL(partURL),
              let partJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
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

        let details = partDetails(from: partJSON, baseDetails: baseDetails, poolURL: poolURL, packageCache: &packageCache)
        detailsCache[partID] = details
        return details
    }

    private static func partDetails(
        from partJSON: JSONDictionary,
        baseDetails: PartDetails? = nil,
        poolURL: URL,
        packageCache: inout [String: JSONDictionary]
    ) -> PartDetails {
        let packageID = baseDetails == nil ? partJSON.string("package").map(normalizedID) : nil
        let packageName = packageID
            .flatMap { loadPackage($0, poolURL: poolURL, cache: &packageCache) }?
            .string("name")
            ?? baseDetails?.packageName
        let mpn = poolAttributeString(partJSON["MPN"], inherited: baseDetails?.mpn)
        let valueAttribute = poolAttribute(partJSON["value"], inherited: baseDetails?.value)

        return PartDetails(
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
            datasheet: poolAttributeString(partJSON["datasheet"], inherited: baseDetails?.datasheet),
            parametricValues: parseParametricValues(from: partJSON.dictionary("parametric"))
        )
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

    private static func loadPackage(
        _ packageID: String,
        poolURL: URL,
        cache: inout [String: JSONDictionary]
    ) -> JSONDictionary? {
        let packageID = normalizedID(packageID)
        if let cached = cache[packageID] {
            return cached
        }

        let packageURL = poolURL
            .appendingPathComponent("packages")
            .appendingPathComponent("cache")
            .appendingPathComponent(packageID)
            .appendingPathComponent("package.json")

        guard let packageDirectory = existingDirectoryURL(packageURL.deletingLastPathComponent()),
              let resolvedURL = existingFileURL(packageDirectory.appendingPathComponent("package.json")),
              let packageJSON = try? JSONHelper.loadDictionary(from: resolvedURL) else {
            return nil
        }

        cache[packageID] = packageJSON
        return packageJSON
    }

    private static func pinInnerPoint(
        from position: HorizontalPoint,
        orientation: String?,
        length: Double
    ) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: position.x + length, y: position.y)
        case "right":
            return HorizontalPoint(x: position.x - length, y: position.y)
        case "up":
            return HorizontalPoint(x: position.x, y: position.y - length)
        case "down":
            return HorizontalPoint(x: position.x, y: position.y + length)
        default:
            return position
        }
    }

    private static func angle(forOrientation orientation: String?) -> Int {
        switch orientation {
        case "left":
            return 32_768
        case "up":
            return 16_384
        case "down":
            return 49_152
        default:
            return 0
        }
    }

    private static func busRipperConnectorOffset(for orientation: String) -> HorizontalPoint {
        let direction: HorizontalPoint
        switch orientation {
        case "right":
            direction = HorizontalPoint(x: 1, y: -1)
        case "down":
            direction = HorizontalPoint(x: -1, y: -1)
        case "left":
            direction = HorizontalPoint(x: -1, y: 1)
        default:
            direction = HorizontalPoint(x: 1, y: 1)
        }
        return direction * 1_250_000
    }

    private static func netLabelBoundsPoints(for label: HorizontalSchematicNetLabel) -> [HorizontalPoint] {
        labelBoundsPoints(
            id: label.id,
            text: label.text,
            position: label.position,
            size: label.size,
            orientation: label.orientation
        )
    }

    private static func busLabelBoundsPoints(for label: HorizontalBusLabel) -> [HorizontalPoint] {
        labelBoundsPoints(
            id: label.id,
            text: label.text,
            position: label.position,
            size: label.size,
            orientation: label.orientation
        )
    }

    private static func labelBoundsPoints(
        id: String,
        text: String,
        position: HorizontalPoint,
        size: Double,
        orientation: String
    ) -> [HorizontalPoint] {
        let horizonText = HorizontalText(
            id: "\(id)/label-bounds",
            text: text,
            position: position + busLabelTextShift(size: size, orientation: orientation),
            size: size,
            layer: nil,
            angle: angle(forOrientation: orientation),
            origin: .center
        )
        return [position] + horizonText.renderBoundsPoints
    }

    private static func busLabelTextShift(size: Double, orientation: String) -> HorizontalPoint {
        switch orientation {
        case "left":
            return HorizontalPoint(x: -size, y: 0)
        case "up":
            return HorizontalPoint(x: 0, y: size)
        case "down":
            return HorizontalPoint(x: 0, y: -size)
        default:
            return HorizontalPoint(x: size, y: 0)
        }
    }

    private static func rotate(_ point: HorizontalPoint, angle: Int) -> HorizontalPoint {
        switch angle {
        case 16_384:
            return HorizontalPoint(x: -point.y, y: point.x)
        case 32_768:
            return HorizontalPoint(x: -point.x, y: -point.y)
        case 49_152:
            return HorizontalPoint(x: point.y, y: -point.x)
        default:
            return point
        }
    }

    private static func substituteSymbolText(
        _ text: String,
        component: SchematicComponentInfo?,
        customValue: String? = nil
    ) -> String {
        guard let component else {
            return text
        }

        if text == "$VALUE", let customValue = nonEmpty(customValue) {
            return interpolateSymbolCustomValue(customValue, component: component)
        }

        let values = symbolSubstitutionValues(for: component)
        return values.keys.sorted { $0.count > $1.count }.reduce(text) { result, key in
            guard let value = values[key] else {
                return result
            }

            return result
                .replacingOccurrences(of: "${\(key)}", with: value)
                .replacingOccurrences(of: "$\(key)", with: value)
        }
    }

    private static func symbolSubstitutionValues(for component: SchematicComponentInfo) -> [String: String] {
        var values = [String: String]()
        insertTextSubstitution(key: "RD", value: component.refdes, into: &values)
        insertTextSubstitution(key: "REFDES", value: component.refdes, into: &values)
        insertTextSubstitution(key: "REF", value: component.refdes, into: &values)
        insertTextSubstitution(key: "VALUE", value: component.value, into: &values)
        insertTextSubstitution(key: "VAL", value: component.value, into: &values)
        if let mpn = component.details?.mpn {
            insertTextSubstitution(key: "MPN", value: mpn, into: &values)
        }
        return values
    }

    private static func interpolateSymbolCustomValue(
        _ text: String,
        component: SchematicComponentInfo
    ) -> String {
        interpolateText(text) { variable in
            let key = variable.lowercased()
            switch key {
            case "value":
                return component.value
            case "pkg":
                return component.details?.packageName ?? "None"
            case "mpn":
                return component.details?.mpn ?? "None"
            case "mfr":
                return component.details?.manufacturer ?? "None"
            case "desc":
                return component.details?.description ?? "None"
            default:
                if key.hasPrefix("p:") {
                    let parametricKey = String(key.dropFirst(2))
                    return component.details?.parametricValues[parametricKey]
                }
                return nil
            }
        }
    }

    private static func interpolateText(
        _ text: String,
        lookup: (String) -> String?
    ) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "$" else {
                result.append(text[index])
                text.formIndex(after: &index)
                continue
            }

            let dollarIndex = index
            text.formIndex(after: &index)
            guard index < text.endIndex else {
                result.append("$")
                break
            }

            if text[index] == "{" {
                let variableStart = text.index(after: index)
                guard let closeIndex = text[variableStart...].firstIndex(of: "}") else {
                    result.append(contentsOf: text[dollarIndex...])
                    break
                }
                let variable = String(text[variableStart..<closeIndex])
                result.append(lookup(variable) ?? String(text[dollarIndex...closeIndex]))
                index = text.index(after: closeIndex)
                continue
            }

            guard isVariableCharacter(text[index]) else {
                result.append("$")
                result.append(text[index])
                text.formIndex(after: &index)
                continue
            }

            let variableStart = index
            while index < text.endIndex, isVariableCharacter(text[index]) {
                text.formIndex(after: &index)
            }
            let variable = String(text[variableStart..<index])
            result.append(lookup(variable) ?? "$\(variable)")
        }
        return result
    }

    private static func isVariableCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == ":"
        }
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

    private static func substituteBlockSymbolText(
        _ text: String,
        instance: SchematicBlockInstanceInfo,
        resource: HorizontalSchematicBlockResource
    ) -> String {
        text
            .replacingOccurrences(of: "$REFDES", with: instance.refdes)
            .replacingOccurrences(of: "$RD", with: instance.refdes)
            .replacingOccurrences(of: "$NAME", with: resource.name)
            .replacingOccurrences(of: "${refdes}", with: instance.refdes)
            .replacingOccurrences(of: "${name}", with: resource.name)
    }

    private static func displayNetTieName(_ name: String?) -> String {
        guard let name, !name.isEmpty else {
            return "unnamed net"
        }
        return name
    }

    private struct PolygonVertex {
        var type: String
        var position: HorizontalPoint
        var arcCenter: HorizontalPoint
        var arcReverse: Bool

        init?(_ json: JSONDictionary) {
            guard let position = json.point("position") else {
                return nil
            }

            self.type = json.string("type") ?? "line"
            self.position = position
            self.arcCenter = json.point("arc_center") ?? .zero
            self.arcReverse = json.bool("arc_reverse") ?? false
        }
    }

    private static func parsePolygonVertices(
        from rawVertices: [JSONDictionary],
        transform: (HorizontalPoint) -> HorizontalPoint = { $0 }
    ) -> [HorizontalPoint] {
        let vertices = rawVertices.compactMap(PolygonVertex.init)
        guard vertices.count >= 2 else {
            return vertices.map { transform($0.position) }
        }

        return vertices.enumerated().flatMap { index, vertex -> [HorizontalPoint] in
            guard vertex.type == "arc" else {
                return [transform(vertex.position)]
            }

            let next = vertices[(index + 1) % vertices.count]
            return arcPolyline(
                from: vertex.position,
                to: next.position,
                centerHint: vertex.arcCenter,
                reverse: vertex.arcReverse
            ).dropLast().map(transform)
        }
    }

    private static func arcPolyline(
        from start: HorizontalPoint,
        to end: HorizontalPoint,
        centerHint: HorizontalPoint,
        reverse: Bool = false,
        precision: Int = 32
    ) -> [HorizontalPoint] {
        guard precision > 1 else {
            return [start, end]
        }

        let center = projectOntoPerpendicularBisector(start, end, centerHint)
        var radius = distance(start, center)
        let endRadius = distance(end, center)
        guard radius > 0, endRadius > 0 else {
            return [start, end]
        }

        var startAngle = atan2(start.y - center.y, start.x - center.x)
        var endAngle = atan2(end.y - center.y, end.x - center.x)
        if startAngle < 0 {
            startAngle += Double.pi * 2
        }
        if endAngle < 0 {
            endAngle += Double.pi * 2
        }

        var delta = endAngle - startAngle
        if delta < 0 {
            delta += Double.pi * 2
        }
        if reverse {
            delta -= Double.pi * 2
        }

        let step = delta / Double(precision)
        let radiusStep = (endRadius - radius) / Double(precision)

        var points = [start]
        for stepIndex in 1..<precision {
            let angle = startAngle + step * Double(stepIndex)
            points.append(
                HorizontalPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            )
            radius += radiusStep
        }
        points.append(end)
        return points
    }

    private static func projectOntoPerpendicularBisector(
        _ start: HorizontalPoint,
        _ end: HorizontalPoint,
        _ point: HorizontalPoint
    ) -> HorizontalPoint {
        let midpoint = HorizontalPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let delta = HorizontalPoint(x: end.x - start.x, y: end.y - start.y)
        let magnitudeSquared = delta.x * delta.x + delta.y * delta.y
        guard magnitudeSquared != 0 else {
            return point
        }

        let projectedDistance = (dot(delta, midpoint) - dot(delta, point)) / magnitudeSquared
        return HorizontalPoint(
            x: point.x + delta.x * projectedDistance,
            y: point.y + delta.y * projectedDistance
        )
    }

    private static func dot(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y
    }

    private static func distance(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func circleBounds(_ circle: HorizontalCircle) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius),
            HorizontalPoint(x: circle.center.x + circle.radius, y: circle.center.y + circle.radius),
        ]
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

    private static func existingDirectoryURL(_ url: URL) -> URL? {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children.first {
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && $0.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame
        }
    }
}
