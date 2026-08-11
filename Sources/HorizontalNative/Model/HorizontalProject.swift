import Foundation

struct HorizontalDiagnostic: Identifiable, Hashable {
    var id = UUID()
    var message: String
}

struct HorizontalProjectBlock: Identifiable, Hashable {
    var id: String { uuid }

    var uuid: String
    var blockFilename: String?
    var schematicFilename: String?
    var symbolFilename: String?
    var isTop: Bool

    var displayName: String {
        if let blockFilename, !blockFilename.isEmpty {
            return URL(fileURLWithPath: blockFilename).deletingPathExtension().lastPathComponent
        }
        if let schematicFilename, !schematicFilename.isEmpty {
            return URL(fileURLWithPath: schematicFilename).deletingPathExtension().lastPathComponent
        }
        return String(uuid.prefix(8))
    }
}

struct HorizontalProjectSchematic: Identifiable {
    var id: String { block.uuid }

    var block: HorizontalProjectBlock
    var schematicFilename: String
    var schematic: HorizontalSchematic
}

struct HorizontalProject: Identifiable {
    var id: String { uuid }

    var url: URL
    var projectFileURL: URL
    var baseURL: URL
    var uuid: String
    var title: String
    var name: String
    var projectMeta: [String: String]
    var blocksFilename: String
    var boardFilename: String?
    var planesFilename: String?
    var schematicFilename: String?
    var blockFilename: String?
    var poolDirectory: String?
    var blocks: [HorizontalProjectBlock]
    var schematics: [HorizontalProjectSchematic]
    var diagnostics: [HorizontalDiagnostic]
    var poolParts: [HorizontalPoolPart]
    var schematic: HorizontalSchematic?
    var board: HorizontalBoard?

    var displayTitle: String {
        if let projectTitle = Self.nonEmpty(projectMeta["project_title"]) ?? Self.nonEmpty(projectMeta["project_name"]) {
            return projectTitle
        }
        if !title.isEmpty {
            return title
        }
        if !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func load(from url: URL) throws -> HorizontalProject {
        try load(from: url, visitedProjectURLs: [])
    }

    static func load(from url: URL, visitedProjectURLs: Set<URL>) throws -> HorizontalProject {
        try BoardLoadTimer.profile("Horizontal project file load profile: \(url.lastPathComponent)") {
            try _loadImpl(from: url, visitedProjectURLs: visitedProjectURLs)
        }
    }

    private static func _loadImpl(from url: URL, visitedProjectURLs: Set<URL>) throws -> HorizontalProject {
        let resolved = try BoardLoadTimer.measure("resolve project file") {
            try resolveProjectFile(from: url)
        }
        let projectFileURL = resolved.projectFileURL
        let standardizedProjectURL = projectFileURL.standardizedFileURL
        guard !visitedProjectURLs.contains(standardizedProjectURL) else {
            throw HorizontalJSONError.missingValue("a non-recursive project include", projectFileURL)
        }
        let childVisitedProjectURLs = visitedProjectURLs.union([standardizedProjectURL])
        let projectJSON = try BoardLoadTimer.measure("load project JSON") {
            try resolved.inferredProjectJSON ?? JSONHelper.loadDictionary(from: projectFileURL)
        }
        let baseURL = projectFileURL.deletingLastPathComponent()
        var diagnostics = [HorizontalDiagnostic]()
        diagnostics.append(contentsOf: resolved.diagnostics)

        let uuid = projectJSON.string("uuid") ?? "unknown-project"
        let title = projectJSON.string("title") ?? ""
        let name = projectJSON.string("name") ?? ""
        let boardFilename = projectJSON.string("board_filename")
        let planesFilename = projectJSON.string("planes_filename")
        let blocksFilename = projectJSON.string("blocks_filename") ?? "blocks.json"
        let poolDirectory = projectJSON.string("pool_directory")
        let poolURL = poolDirectory.map { baseURL.appendingPathComponent($0) }
        let poolParts = BoardLoadTimer.measure("load project pool parts") {
            poolURL.map { HorizontalPoolPart.loadAll(from: $0) } ?? []
        }

        let blockInfo = BoardLoadTimer.measure("load block metadata") {
            loadBlockInfo(
                projectJSON: projectJSON,
                blocksURL: baseURL.appendingPathComponent(blocksFilename),
                diagnostics: &diagnostics
            )
        }
        let blockSymbolResources = BoardLoadTimer.measure("load block symbol resources") {
            loadBlockSymbolResources(
                for: blockInfo.blocks,
                baseURL: baseURL,
                diagnostics: &diagnostics
            )
        }

        var board: HorizontalBoard?
        if let boardFilename {
            let boardURL = baseURL.appendingPathComponent(boardFilename)
            let blockURL = blockInfo.blockFilename.map { baseURL.appendingPathComponent($0) }
            let planesURL = planesFilename.map { baseURL.appendingPathComponent($0) }
            do {
                board = try BoardLoadTimer.measure("load board model") {
                    try HorizontalBoard.load(
                        from: boardURL,
                        blockURL: blockURL,
                        planesURL: planesURL,
                        poolURL: poolURL,
                        visitedProjectURLs: childVisitedProjectURLs,
                        diagnostics: &diagnostics
                    )
                }
                if let board, !board.packages.isEmpty, board.packagePads.isEmpty {
                    diagnostics.append(
                        HorizontalDiagnostic(
                            message: "No package pads resolved. Check that \(poolDirectory ?? "pool") is present inside the document package."
                        )
                    )
                }
            } catch {
                diagnostics.append(HorizontalDiagnostic(message: "Could not load \(boardFilename): \(error.localizedDescription)"))
            }
        } else {
            diagnostics.append(HorizontalDiagnostic(message: "Project does not declare board_filename."))
        }

        let schematics = BoardLoadTimer.measure("load schematic models") {
            loadSchematics(
                for: blockInfo.blocks,
                baseURL: baseURL,
                poolURL: poolURL,
                blockSymbolResources: blockSymbolResources,
                diagnostics: &diagnostics
            )
        }
        let schematic = BoardLoadTimer.measure("select top schematic") {
            topSchematic(
                from: schematics,
                topSchematicFilename: blockInfo.schematicFilename,
                topBlockFilename: blockInfo.blockFilename
            )
        }

        if schematic == nil {
            diagnostics.append(HorizontalDiagnostic(message: "Project does not declare a top schematic."))
        }

        return HorizontalProject(
            url: url,
            projectFileURL: projectFileURL,
            baseURL: baseURL,
            uuid: uuid,
            title: title,
            name: name,
            projectMeta: blockInfo.projectMeta,
            blocksFilename: blocksFilename,
            boardFilename: boardFilename,
            planesFilename: planesFilename,
            schematicFilename: blockInfo.schematicFilename,
            blockFilename: blockInfo.blockFilename,
            poolDirectory: poolDirectory,
            blocks: blockInfo.blocks,
            schematics: schematics,
            diagnostics: diagnostics,
            poolParts: poolParts,
            schematic: schematic,
            board: board
        )
    }

    private static func resolveProjectFile(from url: URL) throws -> (
        projectFileURL: URL,
        diagnostics: [HorizontalDiagnostic],
        inferredProjectJSON: JSONDictionary?
    ) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HorizontalJSONError.missingValue("project document", url)
        }

        guard isDirectory.boolValue else {
            return (url, [], nil)
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let projectFiles = children
            .filter { $0.pathExtension.caseInsensitiveCompare("hprj") == .orderedSame }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !projectFiles.isEmpty else {
            let inferredProjectJSON = inferredProjectJSON(forPackageAt: url)
            guard inferredProjectJSON != nil else {
                throw HorizontalJSONError.missingValue("a .hprj file inside \(url.lastPathComponent)", url)
            }
            let inferredProjectFileURL = url.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).hprj")
            return (
                inferredProjectFileURL,
                [HorizontalDiagnostic(message: "No .hprj file found; inferred project structure from package contents.")],
                inferredProjectJSON
            )
        }

        let packageName = url.deletingPathExtension().lastPathComponent
        let preferred = projectFiles.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(packageName) == .orderedSame
        } ?? projectFiles[0]

        var diagnostics = [HorizontalDiagnostic]()
        if projectFiles.count > 1 {
            diagnostics.append(
                HorizontalDiagnostic(
                    message: "Found multiple .hprj files in \(url.lastPathComponent); using \(preferred.lastPathComponent)."
                )
            )
        }

        return (preferred, diagnostics, nil)
    }

    private static func inferredProjectJSON(forPackageAt packageURL: URL) -> JSONDictionary? {
        let fileManager = FileManager.default
        let packageName = packageURL.deletingPathExtension().lastPathComponent

        func fileExists(_ filename: String) -> Bool {
            fileManager.fileExists(atPath: packageURL.appendingPathComponent(filename).path)
        }

        func directoryExists(_ dirname: String) -> Bool {
            var isDirectory = ObjCBool(false)
            let exists = fileManager.fileExists(
                atPath: packageURL.appendingPathComponent(dirname).path,
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        }

        var projectJSON: JSONDictionary = [
            "uuid": "inferred-\(packageName)",
            "title": packageName,
            "name": packageName
        ]

        var foundProjectContent = false
        if fileExists("board.json") {
            projectJSON["board_filename"] = "board.json"
            foundProjectContent = true
        }
        if fileExists("planes.json") {
            projectJSON["planes_filename"] = "planes.json"
        }
        if fileExists("blocks.json") {
            projectJSON["blocks_filename"] = "blocks.json"
            foundProjectContent = true
        } else if fileExists("top_schematic.json") || fileExists("top_block.json") {
            var legacyBlock: JSONDictionary = [
                "uuid": "top_block",
                "is_top": true
            ]
            if fileExists("top_block.json") {
                legacyBlock["block_filename"] = "top_block.json"
            }
            if fileExists("top_schematic.json") {
                legacyBlock["schematic_filename"] = "top_schematic.json"
            }
            projectJSON["blocks"] = [legacyBlock]
            foundProjectContent = true
        }
        if directoryExists("pool") {
            projectJSON["pool_directory"] = "pool"
        }

        return foundProjectContent ? projectJSON : nil
    }

    private static func loadSchematics(
        for blocks: [HorizontalProjectBlock],
        baseURL: URL,
        poolURL: URL?,
        blockSymbolResources: [String: HorizontalSchematicBlockResource],
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [HorizontalProjectSchematic] {
        blocks.compactMap { block in
            guard let schematicFilename = block.schematicFilename, !schematicFilename.isEmpty else {
                return nil
            }

            let schematicURL = baseURL.appendingPathComponent(schematicFilename)
            let blockURL = block.blockFilename.map { baseURL.appendingPathComponent($0) }
            do {
                let schematic = try HorizontalSchematic.load(
                    from: schematicURL,
                    blockURL: blockURL,
                    poolURL: poolURL,
                    blockSymbols: blockSymbolResources,
                    diagnostics: &diagnostics
                )
                return HorizontalProjectSchematic(
                    block: block,
                    schematicFilename: schematicFilename,
                    schematic: schematic
                )
            } catch {
                diagnostics.append(HorizontalDiagnostic(message: "Could not load \(schematicFilename): \(error.localizedDescription)"))
                return nil
            }
        }
    }

    private static func loadBlockSymbolResources(
        for blocks: [HorizontalProjectBlock],
        baseURL: URL,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> [String: HorizontalSchematicBlockResource] {
        blocks.reduce(into: [String: HorizontalSchematicBlockResource]()) { result, block in
            guard let symbolFilename = block.symbolFilename, !symbolFilename.isEmpty else {
                return
            }

            let symbolURL = baseURL.appendingPathComponent(symbolFilename)
            guard FileManager.default.fileExists(atPath: symbolURL.path) else {
                diagnostics.append(HorizontalDiagnostic(message: "Could not find block symbol \(symbolFilename)."))
                return
            }

            let blockJSON = block.blockFilename
                .map { baseURL.appendingPathComponent($0) }
                .flatMap { try? JSONHelper.loadDictionary(from: $0) }
            let nets = blockJSON?.dictionaryMap("nets").reduce(into: [String: HorizontalSchematicBlockNetResource]()) { result, item in
                result[normalizedID(item.key)] = HorizontalSchematicBlockNetResource(
                    name: item.value.string("name") ?? String(item.key.prefix(8)),
                    isPort: item.value.bool("is_port") ?? false,
                    portDirection: item.value.string("port_direction") ?? "bidirectional"
                )
            } ?? [:]

            result[normalizedID(block.uuid)] = HorizontalSchematicBlockResource(
                symbolURL: symbolURL,
                name: blockJSON?.string("name") ?? block.displayName,
                nets: nets
            )
        }
    }

    private static func topSchematic(
        from schematics: [HorizontalProjectSchematic],
        topSchematicFilename: String?,
        topBlockFilename: String?
    ) -> HorizontalSchematic? {
        if let topSchematicFilename,
           let schematic = schematics.first(where: { $0.schematicFilename == topSchematicFilename }) {
            return schematic.schematic
        }

        if let topBlockFilename,
           let schematic = schematics.first(where: { $0.block.blockFilename == topBlockFilename }) {
            return schematic.schematic
        }

        return schematics.first?.schematic
    }

    private static func loadBlockInfo(
        projectJSON: JSONDictionary,
        blocksURL: URL,
        diagnostics: inout [HorizontalDiagnostic]
    ) -> (blockFilename: String?, schematicFilename: String?, blocks: [HorizontalProjectBlock], projectMeta: [String: String]) {
        let baseURL = blocksURL.deletingLastPathComponent()
        let projectMeta = parseProjectMeta(from: projectJSON.dictionary("project_meta"))

        if FileManager.default.fileExists(atPath: blocksURL.path) {
            do {
                let blocksJSON = try JSONHelper.loadDictionary(from: blocksURL)
                let blocksMap = blocksJSON.dictionaryMap("blocks")
                let topBlockID = blocksJSON.string("top_block")
                let blocks = blocksMap.map { uuid, block in
                    HorizontalProjectBlock(
                        uuid: uuid,
                        blockFilename: block.string("block_filename"),
                        schematicFilename: block.string("schematic_filename"),
                        symbolFilename: block.string("symbol_filename"),
                        isTop: uuid == topBlockID
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isTop != rhs.isTop {
                        return lhs.isTop
                    }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }

                if let topBlockID, let block = blocksMap[topBlockID] {
                    let blockFilename = block.string("block_filename")
                    return (
                        blockFilename,
                        block.string("schematic_filename"),
                        blocks,
                        projectMeta.merging(loadProjectMeta(blockFilename: blockFilename, baseURL: baseURL)) { _, blockValue in blockValue }
                    )
                }

                if let first = blocks.first {
                    return (
                        first.blockFilename,
                        first.schematicFilename,
                        blocks,
                        projectMeta.merging(loadProjectMeta(blockFilename: first.blockFilename, baseURL: baseURL)) { _, blockValue in blockValue }
                    )
                }
            } catch {
                diagnostics.append(HorizontalDiagnostic(message: "Could not load \(blocksURL.lastPathComponent): \(error.localizedDescription)"))
            }
        }

        let legacyBlocks = projectJSON.dictionaryArray("blocks").enumerated().map { index, block in
            HorizontalProjectBlock(
                uuid: block.string("uuid") ?? block.string("block_filename") ?? "legacy-block-\(index)",
                blockFilename: block.string("block_filename"),
                schematicFilename: block.string("schematic_filename"),
                symbolFilename: nil,
                isTop: block.bool("is_top") ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isTop != rhs.isTop {
                return lhs.isTop
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        for block in legacyBlocks where block.isTop {
            return (
                block.blockFilename,
                block.schematicFilename,
                legacyBlocks,
                projectMeta.merging(loadProjectMeta(blockFilename: block.blockFilename, baseURL: baseURL)) { _, blockValue in blockValue }
            )
        }

        if let block = legacyBlocks.first {
            return (
                block.blockFilename,
                block.schematicFilename,
                legacyBlocks,
                projectMeta.merging(loadProjectMeta(blockFilename: block.blockFilename, baseURL: baseURL)) { _, blockValue in blockValue }
            )
        }

        return (nil, nil, [], projectMeta)
    }

    private static func loadProjectMeta(blockFilename: String?, baseURL: URL) -> [String: String] {
        guard let blockFilename, !blockFilename.isEmpty else {
            return [:]
        }

        let blockURL = baseURL.appendingPathComponent(blockFilename)
        guard let blockJSON = try? JSONHelper.loadDictionary(from: blockURL) else {
            return [:]
        }

        return parseProjectMeta(from: blockJSON.dictionary("project_meta"))
    }

    private static func parseProjectMeta(from json: JSONDictionary?) -> [String: String] {
        (json ?? [:]).reduce(into: [String: String]()) { result, item in
            if let value = stringValue(item.value) {
                result[item.key] = value
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

    private static func normalizedID(_ id: String) -> String {
        id.lowercased()
    }
}
