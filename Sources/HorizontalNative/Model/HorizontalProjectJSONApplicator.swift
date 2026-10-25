import Foundation
#if canImport(HorizontalProjectIO)
import HorizontalProjectIO
#endif

enum HorizontalProjectJSONApplyError: LocalizedError {
    case missingArchivePath(URL)
    case missingJSON(String)
    case invalidJSON(String)
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason):
            reason
        case .missingArchivePath(let url):
            "Could not map \(url.lastPathComponent) into the project archive."
        case .missingJSON(let path):
            "The project archive does not contain \(path)."
        case .invalidJSON(let path):
            "\(path) is not a JSON object."
        }
    }
}

/// A change to the title-block values — what `$project_title` and the like
/// stand for: keys to set and keys to remove.
struct HorizontalTitleBlockChanges {
    var set: [String: String] = [:]
    var removed: Set<String> = []

    init(set: [String: String] = [:], removed: Set<String> = []) {
        self.set = set
        self.removed = removed
    }

    /// One key as an editor field gives it: trimmed, and blank means gone.
    init(key: String, value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { removed = [key] } else { set = [key: trimmed] }
    }

    /// Applies the change to one table of values and returns the keys it
    /// changed. A copy (`onlyExisting`) is changed or cleared, never added to:
    /// a key it lacks falls through to the block's value already.
    func patch(_ table: inout JSONDictionary, onlyExisting: Bool) -> [String] {
        var changed = [String]()
        for (key, value) in set where (table[key] as? String) != value && (!onlyExisting || table[key] != nil) {
            table[key] = value
            changed.append(key)
        }
        for key in removed where table[key] != nil {
            table.removeValue(forKey: key)
            changed.append(key)
        }
        return changed
    }

    /// The copies a schematic keeps — its own `title_block_values` and each
    /// sheet's — patched where they hold a key. Returns the keys changed and
    /// which copies ("schematic", "sheet:<id>") changed.
    func patchCopies(inSchematic schematic: inout JSONDictionary) -> (changed: Set<String>, copies: [String]) {
        var changed = Set<String>(), copies = [String]()
        if var table = schematic["title_block_values"] as? JSONDictionary {
            let keys = patch(&table, onlyExisting: true)
            if !keys.isEmpty {
                schematic["title_block_values"] = table
                changed.formUnion(keys)
                copies.append("schematic")
            }
        }
        guard var sheets = schematic["sheets"] as? JSONDictionary else { return (changed, copies) }
        var sheetsChanged = false
        for id in sheets.keys.sorted() {
            guard var sheet = sheets[id] as? JSONDictionary, var table = sheet["title_block_values"] as? JSONDictionary else { continue }
            let keys = patch(&table, onlyExisting: true)
            guard !keys.isEmpty else { continue }
            sheet["title_block_values"] = table
            sheets[id] = sheet
            sheetsChanged = true
            changed.formUnion(keys)
            copies.append("sheet:\(id)")
        }
        if sheetsChanged { schematic["sheets"] = sheets }
        return (changed, copies)
    }
}

enum HorizontalProjectJSONApplicator {
    /// Sets and removes title-block values where the project keeps them: in
    /// the top block, where the board and Horizon read them (the project file
    /// when there is no block), and in any copy the top schematic keeps of a
    /// key, once for the whole schematic and once per sheet. A copy wins on
    /// the sheets it covers, so changing the block alone would leave them
    /// showing the old value. Returns the keys that changed anywhere.
    @discardableResult
    static func apply(
        titleBlockChanges changes: HorizontalTitleBlockChanges,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws -> Set<String> {
        var changed = Set<String>()
        let top = project.blocks.first(where: \.isTop)
        let blockFilename = (top?.blockFilename ?? project.blockFilename).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let metaURL = blockFilename.map { project.baseURL.appendingPathComponent($0) } ?? project.projectFileURL
        let metaPath = try archivePath(for: metaURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: metaPath, fallbackURL: metaURL, from: archive)
        var meta = json.dictionary("project_meta") ?? [:]
        let keys = changes.patch(&meta, onlyExisting: false)
        if !keys.isEmpty {
            if meta.isEmpty { json.removeValue(forKey: "project_meta") } else { json["project_meta"] = meta }
            try saveJSON(json, relativePath: metaPath, to: &archive)
            changed.formUnion(keys)
        }
        if let schematicFilename = top?.schematicFilename ?? project.schematicFilename,
           !schematicFilename.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = project.baseURL.appendingPathComponent(schematicFilename)
            let path = try archivePath(for: url, project: project, archive: archive)
            var schematic = try loadJSON(relativePath: path, fallbackURL: url, from: archive)
            let copies = changes.patchCopies(inSchematic: &schematic)
            if !copies.changed.isEmpty {
                try saveJSON(schematic, relativePath: path, to: &archive)
                changed.formUnion(copies.changed)
            }
        }
        return changed
    }

    /// Returns whether the board's file changed, so a caller can leave the
    /// document alone when it didn't.
    @discardableResult
    static func apply(board: HorizontalBoard, in project: HorizontalProject, to archive: inout HorizontalProjectArchive) throws -> Bool {
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
        patchUnstatedViaRules(&json, rules: board.rules)
        patchPlanes(&json, planes: board.planes)
        patchKeepouts(&json, keepouts: board.keepouts)
        patchDimensions(&json, dimensions: board.dimensions, removing: board.removedDimensionIDs)
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

        return try saveJSON(json, relativePath: path, to: &archive)
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

    /// Returns whether the plane cache's file changed.
    @discardableResult
    static func applyPlaneCache(board: HorizontalBoard, in project: HorizontalProject, to archive: inout HorizontalProjectArchive) throws -> Bool {
        guard let planesFilename = project.planesFilename else {
            return false
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

        return try saveJSON(["planes": planeMap], relativePath: planesFilename, to: &archive)
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

        let smashedTextsBefore = smashedSymbolTextIDs(in: sheetJSON)

        // A schematic's grid is fixed, and neither Horizon nor Horizontal
        // reads one from the file; earlier saves wrote it all the same.
        json.removeValue(forKey: "grid_settings")
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
            removedNetIDs: sheet.removedNetIDs,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        // Only the pins of the gates this sheet draws, or drew before the
        // edit: every sheet carries the whole block's connections, and its
        // copy of a gate drawn on another sheet is out of date as soon as
        // that sheet wires it. Writing that copy back put the pins of a net
        // segment moved on one sheet back on their old net when another
        // sheet was saved.
        var drawnGates = sheet.drawnGateKeys
        for symbol in sheetJSON.dictionaryMap("symbols").values {
            if let componentID = symbol.string("component"), let gateID = symbol.string("gate") {
                drawnGates.insert(normalizedID(componentID) + "/" + normalizedID(gateID))
            }
        }
        try patchSchematicComponentConnections(
            sheet.componentInfo,
            removedConnections: sheet.removedConnections,
            gates: drawnGates,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )
        patchSchematicDrawingLines(&sheetJSON, lines: sheet.drawingLines, junctions: sheet.junctions)
        patchSchematicDrawingArcs(&sheetJSON, arcs: sheet.drawingArcs, junctions: sheet.junctions)
        // A smashed symbol's texts are the sheet's, and one the canvas didn't
        // draw (it reads as nothing) is kept all the same.
        patchTexts(&sheetJSON, key: "texts", texts: sheet.texts,
                   keepingAdditional: Set(sheet.symbols.filter(\.smashed).flatMap(\.smashedTextIDs)))
        patchNewTexts(&sheetJSON, key: "texts", texts: sheet.texts)
        patchSmashedSymbolTexts(&sheetJSON, namedBefore: smashedTextsBefore)
        patchSchematicNetLabels(&sheetJSON, labels: sheet.netLabels, junctions: sheet.junctions)
        patchSchematicBusLabels(&sheetJSON, labels: sheet.busLabels)
        patchSchematicNetTies(&sheetJSON, netTies: sheet.netTies)
        patchSchematicPowerSymbols(&sheetJSON, powerSymbols: sheet.powerSymbols, fallbackPowerSymbolIDs: schematicPowerSymbolIDs(in: sheet))
        patchSchematicBusRippers(&sheetJSON, busRipperIDs: schematicBusRipperIDs(in: sheet))
        patchSchematicBlockSymbols(&sheetJSON, blockSymbolIDs: schematicBlockSymbolIDs(in: sheet), blockSymbols: sheet.blockSymbols)
        try patchBlockInstanceConnections(
            sheet.blockSymbols,
            schematicURL: schematicURL,
            project: project,
            archive: &archive
        )

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

    /// The block symbol editor's symbol, written to the block's symbol file
    /// as it stands.
    static func apply(
        blockSymbol json: JSONDictionary,
        symbolURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: symbolURL, project: project, archive: archive)
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

    /// Sets the pool frame a sheet's title block is drawn with (`frame`), or
    /// takes it away when `frameID` is nil. Horizon writes no key for a
    /// sheet without one.
    static func apply(
        sheetFrame frameID: String?,
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
        if let frameID {
            sheetJSON["frame"] = frameID.lowercased()
        } else {
            sheetJSON.removeValue(forKey: "frame")
        }
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

    /// Horizon's Add Sheet (`Schematic::add_sheet`): a page after the last,
    /// named for its number and drawn with the last page's frame, so a new
    /// page looks like the others. Returns its id.
    @discardableResult
    static func addSheet(
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws -> String {
        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        var sheets = json["sheets"] as? JSONDictionary ?? [:]
        let pages = sheets.values.compactMap { $0 as? JSONDictionary }
        let last = pages.max { ($0.int("index") ?? 0) < ($1.int("index") ?? 0) }
        let index = (last?.int("index") ?? 0) + 1
        // Horizon doesn't mind two pages with one name, but a list that
        // shows two "Sheet 3"s reads as a mistake.
        let names = Set(pages.compactMap { $0.string("name") })
        var number = index
        while names.contains("Sheet \(number)") { number += 1 }
        var sheet: JSONDictionary = ["name": "Sheet \(number)", "index": index]
        for key in HorizontalSchematic.sheetCollectionKeys { sheet[key] = JSONDictionary() }
        if let frame = last?.string("frame") { sheet["frame"] = frame }
        let id = UUID().uuidString.lowercased()
        sheets[id] = sheet
        json["sheets"] = sheets
        try saveJSON(json, relativePath: path, to: &archive)
        return id
    }

    /// Why a sheet can't be deleted, or nil when it can. Horizon deletes only
    /// a page with no symbols on it, a part's or a block's, which would
    /// lose their drawing, and never the last page.
    static func sheetDeletionRefusal(_ sheetJSON: JSONDictionary, pageCount: Int) -> String? {
        if pageCount <= 1 { return "A schematic keeps at least one sheet." }
        let symbols = sheetJSON.dictionaryMap("symbols").count + sheetJSON.dictionaryMap("block_symbols").count
        if symbols > 0 { return "Only an empty sheet can be deleted; this one has \(symbols) symbol\(symbols == 1 ? "" : "s") on it." }
        return nil
    }

    /// Horizon's Delete Sheet: an empty page goes, with any wiring, labels
    /// or text left on it, and the pages after it close up.
    static func removeSheet(
        _ sheetID: String,
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        guard var sheets = json["sheets"] as? JSONDictionary,
              let sheetKey = matchingKey(sheetID, in: sheets),
              let sheetJSON = sheets[sheetKey] as? JSONDictionary else {
            throw HorizontalProjectJSONApplyError.invalidJSON(path)
        }
        if let refusal = sheetDeletionRefusal(sheetJSON, pageCount: sheets.count) {
            throw HorizontalProjectJSONApplyError.refused(refusal)
        }
        sheets.removeValue(forKey: sheetKey)
        let page = sheetJSON.int("index") ?? 0
        for (key, value) in sheets {
            guard var other = value as? JSONDictionary, let index = other.int("index"), index > page else { continue }
            other["index"] = index - 1
            sheets[key] = other
        }
        json["sheets"] = sheets
        try saveJSON(json, relativePath: path, to: &archive)
    }

    /// A frame from a pool the project draws from cached into the project
    /// pool, in the archive, as placing a part caches it: Horizon's frame
    /// chooser browses the whole pool, but a sheet draws its frame from
    /// `frames/cache/`. Written with the edit that uses it, it is undone with
    /// that edit. A project made before projects carried a pool gets one.
    static func cacheFrame(
        _ item: HorizontalPoolLibraryItem,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let poolDirectory = project.poolDirectory ?? HorizontalProjectArchive.projectPoolDirectoryName
        let poolURL = project.baseURL.appendingPathComponent(poolDirectory, isDirectory: true)
        // The importer names every file by appending to poolURL, so its path
        // starts with poolURL's. Standardizing would not do: it drops a
        // /private only from a path that exists, and a file being cached
        // doesn't yet.
        let poolPrefix = poolURL.path.hasSuffix("/") ? poolURL.path : poolURL.path + "/"
        func poolPath(_ url: URL, in archive: HorizontalProjectArchive) -> String? {
            if let path = archive.manifest?.relativePath(for: url) {
                return path
            }
            guard url.path.hasPrefix(poolPrefix) else { return nil }
            return "\(poolDirectory)/\(url.path.dropFirst(poolPrefix.count))"
        }
        let current = archive
        let destination = HorizontalPoolCacheDestination(
            read: { url in poolPath(url, in: current).flatMap { current.regularFileData(relativePath: $0) } },
            list: HorizontalPoolCacheDestination.disk.list
        )
        let manifest = "\(poolDirectory)/pool.json"
        if archive.regularFileData(relativePath: manifest) == nil,
           !FileManager.default.fileExists(atPath: poolURL.appendingPathComponent("pool.json").path) {
            try archive.replaceRegularFileData(
                relativePath: manifest,
                with: HorizontalProjectArchive.projectPoolData(HorizontalProjectDocument.projectPoolTemplate())
            )
        }
        for file in try HorizontalPoolCacheImporter.planFrame(item, into: poolURL, destination: destination) {
            guard let path = poolPath(file.url, in: archive) else {
                throw HorizontalProjectJSONApplyError.missingArchivePath(file.url)
            }
            try archive.replaceRegularFileData(relativePath: path, with: file.data)
        }
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

    /// Horizon's `Block::merge_nets` for nets a schematic edit joined, across
    /// the files that name them: each key net goes into its value. The block
    /// loses the merged net, and its components, block instances, buses,
    /// ties and diff pairs name the survivor; so do every sheet's cached
    /// wire and junction nets, labels and power symbols, which the loader
    /// takes as given; and, for the top block, the board's planes, vias,
    /// holes and rules, which Horizon cannot load naming a net the block
    /// lacks.
    static func apply(
        netMerges: [String: String],
        schematicURL: URL,
        in project: HorizontalProject,
        to archive: inout HorizontalProjectArchive
    ) throws {
        let merges = Dictionary(netMerges.map { ($0.key.lowercased(), $0.value.lowercased()) }) { first, _ in first }
            .filter { $0.key != $0.value }
        guard !merges.isEmpty else { return }
        // A merge into a net that is itself merged goes all the way.
        func survivor(_ netID: String) -> String {
            var current = netID
            var seen = Set<String>()
            while let next = merges[current], seen.insert(current).inserted { current = next }
            return current
        }

        let path = try archivePath(for: schematicURL, project: project, archive: archive)
        var schematic = try loadJSON(relativePath: path, fallbackURL: schematicURL, from: archive)
        if renameMergedNets(in: &schematic, survivor: survivor) {
            try saveJSON(schematic, relativePath: path, to: &archive)
        }

        if let blockURL = blockURL(for: schematicURL, in: project) {
            let blockPath = try archivePath(for: blockURL, project: project, archive: archive)
            var block = try loadJSON(relativePath: blockPath, fallbackURL: blockURL, from: archive)
            var changed = renameMergedNets(in: &block, survivor: survivor)
            if var nets = block["nets"] as? JSONDictionary {
                for key in nets.keys where merges[key.lowercased()] != nil {
                    nets.removeValue(forKey: key)
                    changed = true
                }
                block["nets"] = nets
            }
            if changed {
                try saveJSON(block, relativePath: blockPath, to: &archive)
            }
        }

        let standardized = schematicURL.standardizedFileURL
        let isTop = project.schematics.first { $0.schematic.url.standardizedFileURL == standardized }?.block.isTop
            ?? (project.schematic?.url.standardizedFileURL == standardized)
        if isTop, let board = project.board {
            let boardPath = try archivePath(for: board.url, project: project, archive: archive)
            var json = try loadJSON(relativePath: boardPath, fallbackURL: board.url, from: archive)
            if renameMergedNets(in: &json, survivor: survivor) {
                try saveJSON(json, relativePath: boardPath, to: &archive)
            }
        }
    }

    /// Every key that names a net in Horizon's files.
    private static let netReferenceKeys: Set<String> = ["net", "net_set", "last_net", "net_primary", "net_secondary", "diffpair"]

    /// Rewrites, anywhere in `json`, a net reference whose net `survivor`
    /// maps elsewhere. Returns whether anything changed.
    private static func renameMergedNets(in json: inout JSONDictionary, survivor: (String) -> String) -> Bool {
        var changed = false
        func visit(_ value: Any) -> Any {
            if var dictionary = value as? JSONDictionary {
                for (key, item) in dictionary {
                    if netReferenceKeys.contains(key), let netID = item as? String {
                        let merged = survivor(netID.lowercased())
                        if merged != netID.lowercased() {
                            dictionary[key] = merged
                            changed = true
                        }
                    } else if item is JSONDictionary || item is [Any] {
                        dictionary[key] = visit(item)
                    }
                }
                return dictionary
            }
            if let array = value as? [Any] {
                return array.map(visit)
            }
            return value
        }
        json = visit(json) as? JSONDictionary ?? json
        return changed
    }

    private static func patchSchematicNets(
        _ netDetails: [String: HorizontalNetDetails],
        removedNetIDs: Set<String> = [],
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        guard !netDetails.isEmpty || !removedNetIDs.isEmpty,
              let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }

        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        var nets = json["nets"] as? JSONDictionary ?? [:]

        for removed in removedNetIDs {
            if let key = matchingKey(normalizedID(removed), in: nets) {
                nets.removeValue(forKey: key)
            }
        }
        for detail in netDetails.values where !removedNetIDs.contains(normalizedID(detail.id)) {
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
            let existing = junctions[key] as? JSONDictionary
            var item = existing ?? [:]
            item["position"] = jsonPoint(point)
            // Horizon writes only a junction's position. Keep a net an MCP edit
            // cached up to date, and give one to a new junction as MCP does,
            // but don't add one to every junction the board editor's
            // connectivity pass found a net for; the board loader works those
            // out again from the copper.
            if existing == nil || existing?["net"] != nil {
                if let netID = netIDs[id] ?? netIDs[key] {
                    item["net"] = netID
                } else {
                    item.removeValue(forKey: "net")
                }
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
            let existing = map[key] as? JSONDictionary
            var item = existing ?? [:]
            if let fromEndpoint = schematicNetLineEndpoint(at: line.from, netID: line.netID, preferred: line.schematicFrom, in: sheet) {
                item["from"] = fromEndpoint
            }
            if let toEndpoint = schematicNetLineEndpoint(at: line.to, netID: line.netID, preferred: line.schematicTo, in: sheet) {
                item["to"] = toEndpoint
            }
            // Horizon stores no net on a wire. Keep the one an MCP edit cached
            // up to date, and give one to a new wire as MCP does, but don't
            // add one to every wire on the sheet.
            if existing == nil || existing?["net"] != nil {
                if let netID = line.netID {
                    item["net"] = netID
                } else {
                    item.removeValue(forKey: "net")
                }
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
        preferred: HorizontalSchematicEndpoint? = nil,
        in sheet: HorizontalSchematicSheet
    ) -> JSONDictionary? {
        let pointKey = jsonPointKey(point)
        switch preferred {
        case .junction(let id):
            if let position = sheet.junctions[id], jsonPointKey(position) == pointKey { return preferred?.json }
        case .pin(let path):
            if sheet.symbolPins.contains(where: {
                schematicSymbolPinPath(fromGeometryID: $0.id) == path && jsonPointKey($0.from) == pointKey && netsMatch($0.netID, netID)
            }) { return preferred?.json }
        case .port, .busRipper:
            // These endpoints are resolved by the loader; retain their native references.
            return preferred?.json
        case nil: break
        }
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
                // A package placed on the board: Horizon's `BoardPackage::serialize`.
                guard let componentID = placement.componentID else {
                    continue
                }
                item["component"] = componentID
                item["flip"] = placement.mirrored
                item["smashed"] = placement.smashed
                item["omit_silkscreen"] = placement.omitSilkscreen
                if placement.omitOutline {
                    item["omit_outline"] = true
                }
                item["fixed"] = placement.fixed
                item["texts"] = [String]()
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
        removedConnections: [String: Set<String>],
        gates: Set<String>,
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

        // "component/gate" for a component's gate/pin path.
        func isDrawn(_ componentID: String, _ gatePinPath: String) -> Bool {
            let gateID = gatePinPath.split(separator: "/").first.map(String.init) ?? gatePinPath
            return gates.contains(normalizedID(componentID) + "/" + normalizedID(gateID))
        }
        for (componentID, info) in componentInfo {
            guard let componentKey = matchingKey(componentID, in: componentMap),
                  var componentJSON = componentMap[componentKey] as? JSONDictionary else {
                continue
            }

            var connections = componentJSON["connections"] as? JSONDictionary ?? [:]
            for (gatePinPath, state) in info.connections where isDrawn(componentID, gatePinPath) {
                let key = matchingKey(gatePinPath, in: connections) ?? gatePinPath
                var entry = connections[key] as? JSONDictionary ?? [:]
                switch state {
                case .connected(let netID):
                    entry["net"] = netID
                case .notConnected:
                    // Horizon marks a no-connect with a null net and reads
                    // "net" with at(), so an entry without one is dropped.
                    entry["net"] = NSNull()
                }
                connections[key] = entry
            }
            // `info.connections` only lists what is there, so a pin that left
            // its net is named in `removedConnections`; one connected again
            // since is back in `info.connections` and stays.
            for gatePinPath in removedConnections[componentID] ?? []
                where info.connections[gatePinPath] == nil && isDrawn(componentID, gatePinPath) {
                if let key = matchingKey(gatePinPath, in: connections) {
                    connections.removeValue(forKey: key)
                }
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
        var map = json["vias"] as? JSONDictionary ?? [:]
        for via in vias where !via.id.contains("/") {
            guard matchingKey(via.id, in: map) == nil else {
                continue
            }
            // Its own padstack (a route's via has its rule's, a pasted one
            // the one it was copied with), else the board's.
            guard let padstack = via.padstackID ?? padstackID,
                  let junctionID = junctionID(at: via.position, in: junctions) else {
                continue
            }
            var parameterSet = via.parameterSet.reduce(into: JSONDictionary()) { result, item in
                result[item.key] = jsonNumber(item.value)
            }
            parameterSet["via_diameter"] = jsonNumber(via.size)
            if let hole = via.holeSize {
                parameterSet["hole_diameter"] = jsonNumber(hole)
            }
            // A via shaped by the rules goes on taking its shape from them,
            // as Horizon's router writes one.
            var item: JSONDictionary = [
                "junction": junctionID,
                "padstack": padstack,
                "parameter_set": parameterSet,
                "from_rules": via.fromRules,
                "source": via.fromRules ? "rules" : "local",
                "locked": false
            ]
            if let netID = via.netID {
                item["net_set"] = netID
            }
            map[via.id] = item
        }
        json["vias"] = map
    }

    /// A board whose rules say nothing about vias, as Horizontal's template
    /// wrote them before it gave a new board Horizon's via rule, gets the one
    /// the loader gave it in their place (`HorizontalBoard.load`), so the vias
    /// a route takes from it have a rule to take their shape from. Rules that
    /// state their vias, even none, are the Rules editor's, and stay as they are.
    private static func patchUnstatedViaRules(_ json: inout JSONDictionary, rules: HorizontalBoardRules) {
        var fileRules = json["rules"] as? JSONDictionary ?? [:]
        guard fileRules["via"] == nil, !rules.viaRules.isEmpty else {
            return
        }
        fileRules["via"] = rules.viaRules.reduce(into: JSONDictionary()) { result, rule in
            result[rule.id] = rule.json
        }
        json["rules"] = fileRules
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
                  let item = map[itemKey] as? JSONDictionary else {
                continue
            }
            map[itemKey] = holeJSONEntry(hole, existing: item)
        }
        json[key] = map
    }

    /// Builds one hole's on-disk entry, merged over the existing entry so
    /// unknown keys survive. Padstack-backed board holes follow Horizon's
    /// BoardHole::serialize — geometry lives in `parameter_set`, never as
    /// direct diameter/length/shape keys — while plain holes keep the direct
    /// Hole::serialize keys.
    static func holeJSONEntry(_ hole: HorizontalHole, existing: JSONDictionary) -> JSONDictionary {
        var item = existing
        var placement = item["placement"] as? JSONDictionary ?? [:]
        placement["shift"] = jsonPoint(hole.position)
        placement["angle"] = hole.angle
        item["placement"] = placement

        if item["padstack"] != nil || hole.padstackID != nil {
            var parameters = foreignParameters(in: item)
            for (key, value) in hole.parameterSet {
                parameters[key] = jsonNumber(value)
            }
            parameters["hole_diameter"] = jsonNumber(hole.diameter)
            // hole_length is only materialized when the entry already carries
            // it or the hole is genuinely a slot, so round holes don't grow a
            // spurious key on unrelated saves.
            if parameters["hole_length"] != nil || hole.shape == .slot {
                parameters["hole_length"] = jsonNumber(hole.effectiveLength)
            }
            item["parameter_set"] = parameters
            if let padstackID = hole.padstackID,
               (item["padstack"] as? String)?.lowercased() != padstackID.lowercased() {
                item["padstack"] = padstackID
            }
            return item
        }

        item["diameter"] = jsonNumber(hole.diameter)
        item["length"] = jsonNumber(hole.effectiveLength)
        item["shape"] = hole.shape.rawValue
        item["plated"] = hole.plated
        return item
    }

    private static func patchVias(_ json: inout JSONDictionary, vias: [HorizontalMarker]) {
        guard var map = json["vias"] as? JSONDictionary else {
            return
        }
        // Preserve unknown source entries. See note in patchPolygons.

        for via in vias {
            guard let itemKey = matchingKey(via.id, in: map),
                  let item = map[itemKey] as? JSONDictionary else {
                continue
            }
            map[itemKey] = viaJSONEntry(via, existing: item)
        }
        json["vias"] = map
    }

    /// Builds one via's on-disk entry from the model, merged over the existing
    /// entry so unknown item-level keys survive (Via::serialize: junction,
    /// padstack, parameter_set, from_rules, source, definition, net_set,
    /// locked). The parameter_set itself is REBUILT from the model — the parse
    /// lifts every numeric entry into `parameterSet`, so nothing is lost and a
    /// parameter removed in the inspector actually disappears from disk; only
    /// non-numeric foreign entries are carried over verbatim. The expanded set
    /// is always written — Horizon serializes it expanded too — with the
    /// marker's size/hole authoritative for the two geometry parameters.
    static func viaJSONEntry(_ via: HorizontalMarker, existing: JSONDictionary) -> JSONDictionary {
        var item = existing
        var parameters = foreignParameters(in: existing)
        for (key, value) in via.parameterSet {
            parameters[key] = jsonNumber(value)
        }
        parameters["via_diameter"] = jsonNumber(via.size)
        if let holeSize = via.holeSize {
            parameters["hole_diameter"] = jsonNumber(holeSize)
        }
        item["parameter_set"] = parameters

        // Only rewrite the padstack when it actually changed, so an untouched
        // reference keeps its original casing.
        if let padstackID = via.padstackID,
           (item["padstack"] as? String)?.lowercased() != padstackID.lowercased() {
            item["padstack"] = padstackID
        }

        // from_rules: an absent key means true in Horizon, so it is only
        // materialized when the model departs from that default.
        let existingFromRules = item["from_rules"] as? Bool
        if existingFromRules != nil || via.fromRules != (existingFromRules ?? true) {
            item["from_rules"] = via.fromRules
        }

        if let definitionID = via.definitionID {
            if (item["definition"] as? String)?.lowercased() != definitionID.lowercased() {
                item["definition"] = definitionID
            }
        } else {
            item.removeValue(forKey: "definition")
        }

        // source mirrors from_rules/definition; only written when the file
        // already speaks that dialect or a definition forces it.
        if item["source"] != nil || via.definitionID != nil {
            item["source"] = via.fromRules ? "rules" : (via.definitionID != nil ? "definition" : "local")
        }
        return item
    }

    /// The parameter_set entries the model cannot represent (non-numeric
    /// values — Horizon parameters are int64, so these are foreign data). The
    /// entry builders start from these so a rebuild-from-model never destroys
    /// them, while numeric keys absent from the model stay deleted.
    private static func foreignParameters(in item: JSONDictionary) -> JSONDictionary {
        (item["parameter_set"] as? JSONDictionary ?? [:]).filter { !($0.value is NSNumber) }
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

    private static func patchDimensions(
        _ json: inout JSONDictionary,
        dimensions: [HorizontalDimension],
        removing removedIDs: Set<String> = []
    ) {
        // A slash marks a panel's copy of another board's dimension; it belongs
        // to that board's file, not this one.
        let ownDimensions = dimensions.filter { !$0.id.contains("/") }
        // Defaulted rather than guarded: a board that has never carried a
        // dimension has no `dimensions` key, and returning there would drop the
        // first one drawn. Unknown source entries are preserved and deletions
        // come through `removedIDs` — see the note in patchPolygons for why
        // absence from the model cannot be read as deletion.
        var map = json["dimensions"] as? JSONDictionary ?? [:]
        for id in removedIDs {
            if let itemKey = matchingKey(id, in: map) {
                map.removeValue(forKey: itemKey)
            }
        }

        for dimension in ownDimensions {
            let itemKey = matchingKey(dimension.id, in: map) ?? dimension.id
            var item = map[itemKey] as? JSONDictionary ?? [:]
            // A dimension just drawn has no entry to update, so its geometry is
            // written too, not only the label properties an existing one needs.
            item["p0"] = jsonPoint(dimension.p0)
            item["p1"] = jsonPoint(dimension.p1)
            item["label_distance"] = jsonNumber(dimension.labelDistance)
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
                "angle": storedAngle(of: text),
                "mirror": text.mirrored
            ]
            var item: JSONDictionary = [
                "text": text.fileText,
                "placement": placement,
                "size": jsonNumber(text.size),
                "width": jsonNumber(text.width),
                "origin": text.origin.rawValue,
                "font": text.font.rawValue,
                "from_smash": text.fromSmash
            ]
            if let layer = text.layer {
                item["layer"] = layer
            }
            if text.allowUpsideDown {
                item["allow_upside_down"] = true
            }
            map[text.id] = item
        }
        json[key] = map
    }

    /// The angle a free text's placement stores. The loaders read a mirrored
    /// one as it draws, 32768 less the stored angle (`accumulatedText`), so
    /// writing that back turned each mirrored text half a turn: 45 of Billo's
    /// bottom-side references on one in-app board edit, and back on the next.
    private static func storedAngle(of text: HorizontalText) -> Any {
        guard text.mirrored else {
            return jsonNumber(Double(text.angle))
        }
        return jsonNumber(Double(((32_768 - text.angle) % 65_536 + 65_536) % 65_536))
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
            placement["angle"] = storedAngle(of: text)
            placement["mirror"] = text.mirrored
            item["placement"] = placement
            // What the file stores, not what the text draws: a smashed refdes
            // keeps "$RD" and a title "$project_title".
            item["text"] = text.fileText
            item["size"] = jsonNumber(text.size)
            item["width"] = jsonNumber(text.width)
            if let layer = text.layer {
                item["layer"] = layer
            }
            item["origin"] = text.origin.rawValue
            item["font"] = text.font.rawValue
            // As Horizon writes it: only when set.
            if text.allowUpsideDown {
                item["allow_upside_down"] = true
            } else {
                item.removeValue(forKey: "allow_upside_down")
            }
            item["from_smash"] = text.fromSmash
            map[itemKey] = item
        }
        json[key] = map
    }

    /// The sheet texts the smashed symbols on a sheet name, lowercased.
    private static func smashedSymbolTextIDs(in sheetJSON: JSONDictionary) -> Set<String> {
        Set(sheetJSON.dictionaryMap("symbols").values
            .filter { $0.bool("smashed") == true }
            .flatMap { ($0["texts"] as? [String] ?? []).map(normalizedID) })
    }

    /// Each smashed symbol names only the sheet texts the sheet still has,
    /// in its order, as Horizon prunes the list when it loads; and a text a
    /// smash made goes with the symbol that named it, when the edit took
    /// the symbol away or the text from it.
    private static func patchSmashedSymbolTexts(_ sheetJSON: inout JSONDictionary, namedBefore: Set<String>) {
        guard var symbols = sheetJSON["symbols"] as? JSONDictionary else {
            return
        }
        var texts = sheetJSON["texts"] as? JSONDictionary ?? [:]
        let textKeys = Set(texts.keys.map(normalizedID))
        for (key, value) in symbols {
            guard var symbol = value as? JSONDictionary, symbol.bool("smashed") == true else {
                continue
            }
            let listed = symbol["texts"] as? [String] ?? []
            let kept = listed.filter { textKeys.contains(normalizedID($0)) }
            if kept != listed {
                symbol["texts"] = kept
                symbols[key] = symbol
            }
        }
        sheetJSON["symbols"] = symbols
        let namedAfter = smashedSymbolTextIDs(in: sheetJSON)
        let orphaned = namedBefore.subtracting(namedAfter)
        guard !orphaned.isEmpty else {
            return
        }
        texts = texts.filter { key, value in
            !(orphaned.contains(normalizedID(key)) && (value as? JSONDictionary)?.bool("from_smash") == true)
        }
        sheetJSON["texts"] = texts
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

    private static func patchSchematicNetLabels(_ json: inout JSONDictionary, labels: [HorizontalSchematicNetLabel], junctions: [String: HorizontalPoint]) {
        var map = json["net_labels"] as? JSONDictionary ?? [:]
        removeEntriesNotIn(&map, keeping: labels.map(\.id))

        for label in labels {
            // A label the canvas placed is a new entry, with Horizon's
            // defaults for what the canvas doesn't model; the rest are
            // updated in place. Horizon can't load a label without a
            // junction, so a new one needs one where it stands, and an id
            // of its own rather than a copy's prefixed one.
            let existingKey = matchingKey(label.id, in: map)
            let junction: String?
            if let id = label.junctionID, junctions[id].map(jsonPointKey) == jsonPointKey(label.position) {
                junction = id
            } else {
                junction = junctionID(at: label.position, in: junctions)
            }
            guard existingKey != nil || (junction != nil && !label.id.contains("/")) else {
                continue
            }
            let itemKey = existingKey ?? label.id
            var item = existingKey.flatMap { map[$0] as? JSONDictionary } ?? ["offsheet_refs": true, "show_port": false]
            item["size"] = jsonNumber(label.size)
            // A flip or turn changes only this, and Horizon reads it back.
            item["orientation"] = label.orientation
            // Horizon's "Show port", written once it has been set.
            if label.showsPort || item["show_port"] != nil {
                item["show_port"] = label.showsPort
            }
            if let junction {
                item["junction"] = junction
            }
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
            item["orientation"] = label.orientation
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
        var map = json["power_symbols"] as? JSONDictionary ?? [:]
        let keptIDs = powerSymbols.isEmpty ? fallbackPowerSymbolIDs : powerSymbols.map(\.id)
        removeEntriesNotIn(&map, keeping: keptIDs)

        // Placed symbols are new entries; the rest are updated in place.
        for symbol in powerSymbols {
            let itemKey = matchingKey(symbol.id, in: map) ?? symbol.id
            var item = map[itemKey] as? JSONDictionary ?? [:]
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

    /// A block symbol the sheet still draws keeps its entry, placed where
    /// the sheet now has it; one it doesn't is gone. New ones are made by
    /// `place_block_symbol`, never here.
    private static func patchSchematicBlockSymbols(
        _ json: inout JSONDictionary,
        blockSymbolIDs: [String],
        blockSymbols: [HorizontalSchematicBlockSymbol]
    ) {
        guard var map = json["block_symbols"] as? JSONDictionary else {
            return
        }
        removeEntriesNotIn(&map, keeping: blockSymbolIDs)
        for blockSymbol in blockSymbols {
            guard let key = matchingKey(blockSymbol.id, in: map), var item = map[key] as? JSONDictionary else {
                continue
            }
            var placement = item["placement"] as? JSONDictionary ?? [:]
            placement["shift"] = jsonPoint(blockSymbol.placement.shift)
            placement["angle"] = blockSymbol.placement.angle
            placement["mirror"] = blockSymbol.placement.mirrored
            item["placement"] = placement
            map[key] = item
        }
        json["block_symbols"] = map
    }

    /// What the sheet's block symbols wire their ports to is their
    /// instances': a port wired here, or left with no wire, is written to
    /// the instance's `connections` in the sheet's block. Instances drawn
    /// only on other sheets are theirs to write.
    private static func patchBlockInstanceConnections(
        _ blockSymbols: [HorizontalSchematicBlockSymbol],
        schematicURL: URL,
        project: HorizontalProject,
        archive: inout HorizontalProjectArchive
    ) throws {
        guard !blockSymbols.isEmpty, let blockURL = blockURL(for: schematicURL, in: project) else {
            return
        }
        let path = try archivePath(for: blockURL, project: project, archive: archive)
        var json = try loadJSON(relativePath: path, fallbackURL: blockURL, from: archive)
        guard var instances = json["block_instances"] as? JSONDictionary else {
            return
        }
        for blockSymbol in blockSymbols {
            guard let key = matchingKey(blockSymbol.instanceID, in: instances),
                  var instance = instances[key] as? JSONDictionary else {
                continue
            }
            instance["connections"] = blockSymbol.connectionsJSON
            instances[key] = instance
        }
        json["block_instances"] = instances
        try saveJSON(json, relativePath: path, to: &archive)
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

    /// Written the way Horizon writes it, as every other writer of project
    /// files does, so an edit made here and one made over MCP leave the same
    /// bytes and a diff shows only what changed.
    /// Writes `json` unless the file already holds exactly that, and says
    /// whether it wrote.
    @discardableResult
    private static func saveJSON(
        _ json: JSONDictionary,
        relativePath: String,
        to archive: inout HorizontalProjectArchive
    ) throws -> Bool {
        let data = try HorizontalHorizonJSONWriter.data(json)
        guard archive.regularFileData(relativePath: relativePath) != data else {
            return false
        }
        try archive.replaceRegularFileData(relativePath: relativePath, with: data)
        return true
    }

    private static func relativePath(for url: URL, baseURL: URL) -> String? {
        // As given first: standardizing drops /private from a path on disk
        // and not from one only the archive holds yet, such as a new block's.
        for (basePath, path) in [(baseURL.path, url.path), (baseURL.standardizedFileURL.path, url.standardizedFileURL.path)] {
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return nil
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
