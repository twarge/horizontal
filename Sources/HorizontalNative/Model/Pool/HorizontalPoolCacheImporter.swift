import Foundation
import HorizontalProjectIO

enum HorizontalPoolCacheImporterError: LocalizedError {
    case missing(HorizontalPoolItemCategory, String)
    case noSymbol(unitID: String)
    case noEntity(partID: String)
    case noPackage(partID: String)

    var errorDescription: String? {
        switch self {
        case .missing(let category, let uuid):
            "The \(category.singularTitle.lowercased()) \(uuid) is not in any browsed pool."
        case .noSymbol(let unitID):
            "No symbol in the browsed pools draws the unit \(unitID), so the part cannot be placed."
        case .noEntity(let partID):
            "The part \(partID) names no entity."
        case .noPackage(let partID):
            "The part \(partID) names no package."
        }
    }
}

struct HorizontalPoolCacheImportResult {
    /// Files written into the project pool, for the open project's archive.
    var writtenFiles: [URL] = []
}

/// Horizon's project pool cache: a part placed from a pool is copied, with
/// everything it depends on, into the project pool's `<kind>/cache/`
/// directories so the project stays self-contained — the layout
/// `PoolProjectManagerAppWindow` creates and `ProjectPool` reads. Packages
/// keep their own directory (`packages/cache/<uuid>/package.json`, local
/// padstacks beside it) and have their 3D model paths rewritten to
/// `3d_models/cache/<pool uuid>/…`, where the models are copied too.
enum HorizontalPoolCacheImporter {
    /// Ensures `item` (a part) and its entity, units, symbols, package and
    /// padstacks are in `projectPoolURL`'s cache, copying from the item's
    /// pool and the pools it includes. Already-cached files are left alone.
    static func cachePart(_ item: HorizontalPoolLibraryItem, into projectPoolURL: URL) throws -> HorizontalPoolCacheImportResult {
        var result = HorizontalPoolCacheImportResult()
        let sourcePools = HorizontalPoolLibrary.editorPoolURLs(forPoolRoot: item.poolURL)
        let index = HorizontalPoolLibraryIndex(items: sourcePools.flatMap { poolURL in
            HorizontalPoolLibrary.items(inPool: poolURL, poolName: HorizontalPoolRegistryStore.poolInfo(at: poolURL).name)
        })
        var session = Session(projectPoolURL: projectPoolURL, index: index, result: result)
        try session.cachePart(item.uuid)
        result = session.result
        return result
    }

    private struct Session {
        let projectPoolURL: URL
        let index: HorizontalPoolLibraryIndex
        var result: HorizontalPoolCacheImportResult
        private var visitedParts = Set<String>()

        init(projectPoolURL: URL, index: HorizontalPoolLibraryIndex, result: HorizontalPoolCacheImportResult) {
            self.projectPoolURL = projectPoolURL
            self.index = index
            self.result = result
        }

        // MARK: Parts

        /// The part, its base chain, and the entity and package the chain
        /// resolves to.
        mutating func cachePart(_ partID: String) throws {
            let normalized = partID.lowercased()
            guard visitedParts.insert(normalized).inserted else {
                return
            }
            let json = try cacheFlatItem(.part, uuid: normalized)
            var entityID = json.string("entity")
            var packageID = json.string("package")
            if let baseID = json.string("base") {
                try cachePart(baseID)
                // Inherited references come from the base chain.
                var cursor: String? = baseID
                var guardCount = 0
                while let current = cursor, entityID == nil || packageID == nil, guardCount < 16 {
                    let baseJSON = try cacheFlatItem(.part, uuid: current)
                    entityID = entityID ?? baseJSON.string("entity")
                    packageID = packageID ?? baseJSON.string("package")
                    cursor = baseJSON.string("base")
                    guardCount += 1
                }
            }
            guard let entityID else {
                throw HorizontalPoolCacheImporterError.noEntity(partID: normalized)
            }
            guard let packageID else {
                throw HorizontalPoolCacheImporterError.noPackage(partID: normalized)
            }
            try cacheEntity(entityID)
            try cachePackage(packageID)
        }

        private mutating func cacheEntity(_ entityID: String) throws {
            let json = try cacheFlatItem(.entity, uuid: entityID)
            for (_, gate) in json.dictionaryMap("gates") {
                guard let unitID = gate.string("unit")?.lowercased() else {
                    continue
                }
                _ = try cacheFlatItem(.unit, uuid: unitID)
                let symbols = index.items(in: .symbol).filter { $0.symbolUnitID == unitID }
                guard !symbols.isEmpty else {
                    throw HorizontalPoolCacheImporterError.noSymbol(unitID: unitID)
                }
                for symbol in symbols {
                    _ = try cacheFlatItem(.symbol, uuid: symbol.uuid)
                }
            }
        }

        // MARK: Packages

        private mutating func cachePackage(_ packageID: String) throws {
            let normalized = packageID.lowercased()
            let directory = projectPoolURL
                .appendingPathComponent("packages", isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent(normalized, isDirectory: true)
            let destination = directory.appendingPathComponent("package.json")
            let fileManager = FileManager.default

            let packageJSON: JSONDictionary
            var localPadstackIDs = Set<String>()
            if fileManager.fileExists(atPath: destination.path) {
                packageJSON = try JSONHelper.loadDictionary(from: destination)
                localPadstackIDs = Self.padstackIDs(inDirectory: directory.appendingPathComponent("padstacks"))
            } else if let source = index.item(.package, uuid: normalized), isInsideProjectPool(source.url) {
                packageJSON = try JSONHelper.loadDictionary(from: source.url)
                localPadstackIDs = Self.padstackIDs(inDirectory: source.url.deletingLastPathComponent().appendingPathComponent("padstacks"))
            } else {
                guard let source = index.item(.package, uuid: normalized) else {
                    throw HorizontalPoolCacheImporterError.missing(.package, normalized)
                }
                var json = try JSONHelper.loadDictionary(from: source.url)
                let sourcePoolUUID = HorizontalPoolRegistryStore.poolInfo(at: source.poolURL).uuid
                let sourceDirectory = source.url.deletingLastPathComponent()

                // `ProjectPool::patch_package`: model paths move under the
                // cache, keyed by the pool they came from; copy the models.
                var modelPaths = [String]()
                if let legacy = json.string("model_filename") {
                    modelPaths.append(legacy)
                    json["model_filename"] = Self.cachedModelPath(legacy, poolUUID: sourcePoolUUID)
                }
                var models = json.dictionaryMap("models")
                for (key, var model) in models {
                    if let filename = model.string("filename") {
                        modelPaths.append(filename)
                        model["filename"] = Self.cachedModelPath(filename, poolUUID: sourcePoolUUID)
                        models[key] = model
                    }
                }
                if !models.isEmpty {
                    json["models"] = models
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try HorizontalHorizonJSONWriter.data(json).write(to: destination, options: [.atomic])
                result.writtenFiles.append(destination)
                for path in modelPaths {
                    let modelSource = source.poolURL.appendingPathComponent(path)
                    let modelDestination = projectPoolURL.appendingPathComponent(Self.cachedModelPath(path, poolUUID: sourcePoolUUID))
                    if fileManager.fileExists(atPath: modelSource.path), !fileManager.fileExists(atPath: modelDestination.path) {
                        try fileManager.createDirectory(at: modelDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.copyItem(at: modelSource, to: modelDestination)
                        result.writtenFiles.append(modelDestination)
                    }
                }

                // Package-local padstacks ride along in the package's directory.
                let localSource = sourceDirectory.appendingPathComponent("padstacks", isDirectory: true)
                if let locals = try? fileManager.contentsOfDirectory(at: localSource, includingPropertiesForKeys: nil) {
                    let localDestination = directory.appendingPathComponent("padstacks", isDirectory: true)
                    for url in locals where url.pathExtension.lowercased() == "json" {
                        guard let padstackJSON = try? JSONHelper.loadDictionary(from: url),
                              let uuid = padstackJSON.string("uuid")?.lowercased() else {
                            continue
                        }
                        try fileManager.createDirectory(at: localDestination, withIntermediateDirectories: true)
                        let target = localDestination.appendingPathComponent(url.lastPathComponent)
                        if !fileManager.fileExists(atPath: target.path) {
                            try fileManager.copyItem(at: url, to: target)
                            result.writtenFiles.append(target)
                        }
                        localPadstackIDs.insert(uuid)
                    }
                }
                packageJSON = json
            }

            for (_, pad) in packageJSON.dictionaryMap("pads") {
                guard let padstackID = pad.string("padstack")?.lowercased(), !localPadstackIDs.contains(padstackID) else {
                    continue
                }
                _ = try cacheFlatItem(.padstack, uuid: padstackID)
            }
        }

        private func isInsideProjectPool(_ url: URL) -> Bool {
            let root = projectPoolURL.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return url.standardizedFileURL.path.hasPrefix(prefix)
        }

        private static func padstackIDs(inDirectory directory: URL) -> Set<String> {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return Set(urls.compactMap { url in
                (try? JSONHelper.loadDictionary(from: url))?.string("uuid")?.lowercased()
            })
        }

        static func cachedModelPath(_ filename: String, poolUUID: String) -> String {
            "3d_models/cache/\(poolUUID)/\(filename)"
        }

        // MARK: Flat items

        /// `<kind>/cache/<uuid>.json`: copied verbatim from the source pool
        /// when not already there. Returns the cached JSON.
        private mutating func cacheFlatItem(_ category: HorizontalPoolItemCategory, uuid: String) throws -> JSONDictionary {
            let normalized = uuid.lowercased()
            let destination = projectPoolURL
                .appendingPathComponent(HorizontalPoolItemFactory.directoryName(for: category), isDirectory: true)
                .appendingPathComponent("cache", isDirectory: true)
                .appendingPathComponent("\(normalized).json")
            if FileManager.default.fileExists(atPath: destination.path) {
                return try JSONHelper.loadDictionary(from: destination)
            }
            guard let source = index.item(category, uuid: normalized) else {
                throw HorizontalPoolCacheImporterError.missing(category, normalized)
            }
            // An item the project pool holds outside its cache (a project-local
            // part, say) is already the project's own; caching it too would
            // give the pool two files with one uuid.
            if isInsideProjectPool(source.url) {
                return try JSONHelper.loadDictionary(from: source.url)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.url, to: destination)
            result.writtenFiles.append(destination)
            return try JSONHelper.loadDictionary(from: destination)
        }
    }
}
