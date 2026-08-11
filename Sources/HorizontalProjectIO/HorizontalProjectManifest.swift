import Foundation

public struct HorizontalProjectManifest: Equatable, Sendable {
    public var baseURL: URL
    public var projectFileURL: URL
    public var includedURLs: [URL]
    public var missingReferences: [String]
    public var externalReferences: [URL]
    public var poolDirectoryURL: URL?

    public var relativePaths: [String] {
        includedURLs.compactMap(relativePath(for:)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func relativePath(for url: URL) -> String? {
        Self.relativePath(for: url, baseURL: baseURL)
    }

    public static func discover(from url: URL) throws -> HorizontalProjectManifest {
        var collector = ProjectReferenceCollector(rootURL: url)
        try collector.collectProject(from: url)
        return collector.manifest()
    }

    static func relativePath(for url: URL, baseURL: URL) -> String? {
        let basePath = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }
}

private struct ProjectReferenceCollector {
    var rootBaseURL: URL
    var projectFileURL: URL?
    var includedURLs = Set<URL>()
    var missingReferences = [String]()
    var externalReferences = Set<URL>()
    var poolDirectoryURL: URL?
    var visitedProjectURLs = Set<URL>()

    init(rootURL: URL) {
        let resolved = Self.resolveProjectLocation(rootURL)
        rootBaseURL = resolved.baseURL
        projectFileURL = resolved.projectFileURL
    }

    func manifest() -> HorizontalProjectManifest {
        HorizontalProjectManifest(
            baseURL: rootBaseURL,
            projectFileURL: projectFileURL ?? rootBaseURL,
            includedURLs: includedURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            missingReferences: missingReferences,
            externalReferences: externalReferences.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            poolDirectoryURL: poolDirectoryURL
        )
    }

    mutating func collectProject(from url: URL) throws {
        let resolved = try Self.resolveProjectFile(from: url)
        let projectURL = resolved.standardizedFileURL
        guard !visitedProjectURLs.contains(projectURL) else {
            return
        }
        visitedProjectURLs.insert(projectURL)
        projectFileURL = projectFileURL ?? projectURL

        includeExisting(projectURL)

        let projectJSON = try loadJSON(from: projectURL)
        let baseURL = projectURL.deletingLastPathComponent()

        includeReferencedFile(projectJSON.hpioString("board_filename"), baseURL: baseURL)
        includeReferencedFile(projectJSON.hpioString("planes_filename"), baseURL: baseURL)
        includeReferencedFile(projectJSON.hpioString("block_filename"), baseURL: baseURL)
        includeReferencedFile(projectJSON.hpioString("schematic_filename"), baseURL: baseURL)
        includeReferencedFile(projectJSON.hpioString("symbol_filename"), baseURL: baseURL)

        if let poolDirectory = projectJSON.hpioString("pool_directory") {
            let poolURL = resolvedURL(for: poolDirectory, baseURL: baseURL)
            if isInsideRoot(poolURL) {
                poolDirectoryURL = poolURL
                includeExisting(poolURL)
            } else {
                externalReferences.insert(poolURL)
            }
        }

        let blocksFilename = projectJSON.hpioString("blocks_filename") ?? "blocks.json"
        if let blocksURL = includeReferencedFile(blocksFilename, baseURL: baseURL),
           let blocksJSON = try? loadJSON(from: blocksURL) {
            for block in blocksJSON.hpioDictionaryMap("blocks").values {
                includeBlockReferences(from: block, baseURL: baseURL)
            }
        }

        for block in projectJSON.hpioDictionaryArray("blocks") {
            includeBlockReferences(from: block, baseURL: baseURL)
        }

        if let boardFilename = projectJSON.hpioString("board_filename") {
            let boardURL = resolvedURL(for: boardFilename, baseURL: baseURL)
            if isInsideRoot(boardURL),
               FileManager.default.fileExists(atPath: boardURL.path),
               let boardJSON = try? loadJSON(from: boardURL) {
                try collectIncludedBoardProjects(from: boardJSON, boardBaseURL: boardURL.deletingLastPathComponent())
            }
        }
    }

    private mutating func includeBlockReferences(from block: ProjectIOJSONDictionary, baseURL: URL) {
        includeReferencedFile(block.hpioString("block_filename"), baseURL: baseURL)
        includeReferencedFile(block.hpioString("schematic_filename"), baseURL: baseURL)
        includeReferencedFile(block.hpioString("symbol_filename"), baseURL: baseURL)
    }

    private mutating func collectIncludedBoardProjects(from boardJSON: ProjectIOJSONDictionary, boardBaseURL: URL) throws {
        for includedBoard in boardJSON.hpioDictionaryMap("included_boards").values {
            guard let projectFilename = includedBoard.hpioString("project_filename") else {
                continue
            }

            let childURL = resolvedURL(for: projectFilename, baseURL: boardBaseURL)
            guard isInsideRoot(childURL) else {
                externalReferences.insert(childURL)
                continue
            }

            if FileManager.default.fileExists(atPath: childURL.path) {
                try collectProject(from: childURL)
            } else {
                missingReferences.append(projectFilename)
            }
        }
    }

    @discardableResult
    private mutating func includeReferencedFile(_ path: String?, baseURL: URL) -> URL? {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let url = resolvedURL(for: path, baseURL: baseURL)
        guard isInsideRoot(url) else {
            externalReferences.insert(url)
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            missingReferences.append(path)
            return nil
        }

        includeExisting(url)
        return url
    }

    private mutating func includeExisting(_ url: URL) {
        includedURLs.insert(url.standardizedFileURL)
    }

    private func resolvedURL(for path: String, baseURL: URL) -> URL {
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = path.split(separator: "/", omittingEmptySubsequences: true)
                .reduce(baseURL) { partial, component in
                    partial.appendingPathComponent(String(component))
                }
        }
        return url.standardizedFileURL
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        HorizontalProjectManifest.relativePath(for: url, baseURL: rootBaseURL) != nil
            || url.standardizedFileURL == rootBaseURL.standardizedFileURL
    }

    private static func resolveProjectFile(from url: URL) throws -> URL {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HorizontalProjectArchiveError.missingProject(url)
        }

        if !isDirectory.boolValue {
            return url
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )

        let projectFiles = children
            .filter { $0.pathExtension.caseInsensitiveCompare("hprj") == .orderedSame }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard let firstProject = projectFiles.first else {
            throw HorizontalProjectArchiveError.missingProjectFile(url)
        }

        let packageName = url.deletingPathExtension().lastPathComponent
        return projectFiles.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(packageName) == .orderedSame
        } ?? firstProject
    }

    private func loadJSON(from url: URL) throws -> ProjectIOJSONDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [])
        guard let dictionary = object as? ProjectIOJSONDictionary else {
            throw HorizontalProjectArchiveError.invalidJSON(url)
        }
        return dictionary
    }

    private static func resolveProjectLocation(_ url: URL) -> (baseURL: URL, projectFileURL: URL?) {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let projectURL = try? resolveProjectFile(from: url)
            return (url.standardizedFileURL, projectURL?.standardizedFileURL)
        }
        return (url.deletingLastPathComponent().standardizedFileURL, url.standardizedFileURL)
    }
}

private typealias ProjectIOJSONDictionary = [String: Any]

private extension Dictionary where Key == String, Value == Any {
    func hpioString(_ key: String) -> String? {
        self[key] as? String
    }

    func hpioDictionaryMap(_ key: String) -> [String: ProjectIOJSONDictionary] {
        guard let map = self[key] as? [String: Any] else {
            return [:]
        }

        return map.reduce(into: [String: ProjectIOJSONDictionary]()) { result, item in
            if let value = item.value as? ProjectIOJSONDictionary {
                result[item.key] = value
            }
        }
    }

    func hpioDictionaryArray(_ key: String) -> [ProjectIOJSONDictionary] {
        self[key] as? [ProjectIOJSONDictionary] ?? []
    }
}
