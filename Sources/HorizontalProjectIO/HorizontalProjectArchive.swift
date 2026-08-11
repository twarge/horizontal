import Foundation

public enum HorizontalProjectArchiveError: LocalizedError, Equatable, Sendable {
    case missingProject(URL)
    case missingProjectFile(URL)
    case invalidJSON(URL)
    case invalidRelativePath(String)
    case unsupportedFileWrapper(String)
    case roundTripMismatch
    case missingManifest

    public var errorDescription: String? {
        switch self {
        case .missingProject(let url):
            "\(url.path) does not exist."
        case .missingProjectFile(let url):
            "\(url.lastPathComponent) does not contain a .hprj project file."
        case .invalidJSON(let url):
            "\(url.lastPathComponent) is not a JSON object."
        case .invalidRelativePath(let path):
            "\(path) is not a valid project-relative path."
        case .unsupportedFileWrapper(let name):
            "\(name) is not a regular file, directory, or symbolic link."
        case .roundTripMismatch:
            "The written archive did not match the source archive."
        case .missingManifest:
            "This project was not opened from a .hprj file, so its files "
                + "have no original locations to be written back to. Save it as a "
                + ".horizontal package instead."
        }
    }
}

public indirect enum HorizontalProjectArchiveNode: Equatable, Sendable {
    case directory([String: HorizontalProjectArchiveNode])
    case regularFile(Data)
    case symbolicLink(String)
}

public struct HorizontalProjectArchive: Equatable, Sendable {
    public var root: HorizontalProjectArchiveNode
    public var suggestedFilename: String?
    public var manifest: HorizontalProjectManifest?

    public init(
        root: HorizontalProjectArchiveNode,
        suggestedFilename: String? = nil,
        manifest: HorizontalProjectManifest? = nil
    ) {
        self.root = root
        self.suggestedFilename = suggestedFilename
        self.manifest = manifest
    }

    public init(regularFileData: Data, suggestedFilename: String? = nil) {
        self.init(root: .regularFile(regularFileData), suggestedFilename: suggestedFilename)
    }

    public init(fileWrapper: FileWrapper) throws {
        root = try Self.node(from: fileWrapper, name: fileWrapper.preferredFilename ?? fileWrapper.filename ?? "document")
        suggestedFilename = fileWrapper.preferredFilename ?? fileWrapper.filename
        manifest = nil
    }

    public static func snapshot(from url: URL) throws -> HorizontalProjectArchive {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HorizontalProjectArchiveError.missingProject(url)
        }

        return HorizontalProjectArchive(
            root: try node(from: url),
            suggestedFilename: url.lastPathComponent
        )
    }

    public static func completeProject(from url: URL) throws -> HorizontalProjectArchive {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HorizontalProjectArchiveError.missingProject(url)
        }

        if isDirectory.boolValue {
            return try snapshot(from: url)
        }

        let manifest = try HorizontalProjectManifest.discover(from: url)
        var builder = ArchiveBuilder()
        for itemURL in manifest.includedURLs {
            guard let relativePath = manifest.relativePath(for: itemURL) else {
                continue
            }
            try builder.insertFileSystemItem(at: itemURL, relativePath: relativePath)
        }

        return HorizontalProjectArchive(
            root: .directory(builder.children),
            suggestedFilename: manifest.baseURL.lastPathComponent + ".horizontal",
            manifest: manifest
        )
    }

    public func fileWrapper() throws -> FileWrapper {
        let wrapper = try Self.fileWrapper(for: root, name: suggestedFilename ?? "document")
        wrapper.preferredFilename = suggestedFilename
        return wrapper
    }

    /// The wrapper to hand back when the document's own URL is a Horizon `.hprj`
    /// FILE rather than a `.horizontal` package.
    ///
    /// A `.hprj` is plain JSON, and Horizon keeps the blocks / schematic / board
    /// / pool it references as SIBLINGS on disk — the project is a file in a
    /// folder, never a bundle. `completeProject(from:)` gathers all of that into
    /// one directory-rooted archive so it can also be saved as a `.horizontal`
    /// package, but handing that directory to the document writer for a `.hprj`
    /// URL replaces the user's project FILE with a FOLDER of the same name.
    ///
    /// So: write the gathered siblings back to where they came from, and return
    /// only the project JSON, keeping the `.hprj` a file.
    public func projectFileWrapper() throws -> FileWrapper {
        guard case .directory = root else {
            // Never expanded (read-only open, or built from raw data) — it is
            // already a single regular file, so write it unchanged.
            return try fileWrapper()
        }
        guard let manifest else {
            throw HorizontalProjectArchiveError.missingManifest
        }

        let projectRelativePath = manifest.relativePath(for: manifest.projectFileURL)
        // The project file itself is skipped: the document writer puts the
        // returned wrapper at the document URL, which IS that file.
        _ = try writeInPlace(skipping: projectRelativePath.map { [$0] } ?? [])

        guard let projectRelativePath,
              let data = regularFileData(relativePath: projectRelativePath) else {
            throw HorizontalProjectArchiveError.missingProjectFile(manifest.projectFileURL)
        }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = manifest.projectFileURL.lastPathComponent
        return wrapper
    }

    /// Writes the archive's regular files back to the paths they were gathered
    /// from (`manifest.baseURL` + archive-relative path) — the in-place save a
    /// Horizon project on disk needs.
    ///
    /// Files whose bytes already match disk are left alone, so saving an edit to
    /// one board doesn't rewrite (and re-timestamp) an entire pool. Returns the
    /// relative paths actually written.
    ///
    /// Requires the `manifest` recorded by `completeProject(from:)`; without it
    /// nothing maps archive paths back onto disk.
    @discardableResult
    public func writeInPlace(skipping skippedRelativePaths: Set<String> = []) throws -> [String] {
        guard let manifest else {
            throw HorizontalProjectArchiveError.missingManifest
        }

        let fileManager = FileManager.default
        var written = [String]()
        for relativePath in regularFilePaths where !skippedRelativePaths.contains(relativePath) {
            guard let data = regularFileData(relativePath: relativePath) else {
                continue
            }
            let url = manifest.baseURL.appendingPathComponent(relativePath)
            if let existing = try? Data(contentsOf: url), existing == data {
                continue
            }
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            written.append(relativePath)
        }
        return written.sorted()
    }

    public func write(to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try Self.write(root, to: url)
    }

    public var regularFileCount: Int {
        root.regularFileCount
    }

    public var directoryCount: Int {
        root.directoryCount
    }

    public var symbolicLinkCount: Int {
        root.symbolicLinkCount
    }

    public var regularFilePaths: [String] {
        root.regularFilePaths(prefix: "")
    }

    public func regularFileData(relativePath: String) -> Data? {
        root.regularFileData(components: relativePath.pathComponentsForArchive)
    }

    public mutating func replaceRegularFileData(relativePath: String, with data: Data) throws {
        let components = try Self.archivePathComponents(relativePath)
        try root.replaceRegularFileData(components: components, with: data)
    }

    private static func node(from wrapper: FileWrapper, name: String) throws -> HorizontalProjectArchiveNode {
        if wrapper.isDirectory {
            var children = [String: HorizontalProjectArchiveNode]()
            for (childName, childWrapper) in wrapper.fileWrappers ?? [:] {
                children[childName] = try node(from: childWrapper, name: childName)
            }
            return .directory(children)
        }

        if wrapper.isSymbolicLink {
            let destination = wrapper.symbolicLinkDestinationURL?.path ?? ""
            return .symbolicLink(destination)
        }

        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            return .regularFile(data)
        }

        throw HorizontalProjectArchiveError.unsupportedFileWrapper(name)
    }

    private static func node(from url: URL) throws -> HorizontalProjectArchiveNode {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])

        if values.isSymbolicLink == true {
            return .symbolicLink(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }

        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey],
                options: []
            )
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            var nodes = [String: HorizontalProjectArchiveNode]()
            for child in children {
                nodes[child.lastPathComponent] = try node(from: child)
            }
            return .directory(nodes)
        }

        if values.isRegularFile == true {
            return .regularFile(try Data(contentsOf: url))
        }

        throw HorizontalProjectArchiveError.unsupportedFileWrapper(url.lastPathComponent)
    }

    private static func fileWrapper(for node: HorizontalProjectArchiveNode, name: String) throws -> FileWrapper {
        switch node {
        case .directory(let children):
            var wrappers = [String: FileWrapper]()
            for (childName, childNode) in children {
                let wrapper = try fileWrapper(for: childNode, name: childName)
                wrapper.preferredFilename = childName
                wrappers[childName] = wrapper
            }
            let wrapper = FileWrapper(directoryWithFileWrappers: wrappers)
            wrapper.preferredFilename = name
            return wrapper
        case .regularFile(let data):
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = name
            return wrapper
        case .symbolicLink(let destination):
            let wrapper = FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: destination))
            wrapper.preferredFilename = name
            return wrapper
        }
    }

    private static func write(_ node: HorizontalProjectArchiveNode, to url: URL) throws {
        let fileManager = FileManager.default
        switch node {
        case .directory(let children):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, child) in children {
                try write(child, to: url.appendingPathComponent(name))
            }
        case .regularFile(let data):
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        case .symbolicLink(let destination):
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }
    }

    fileprivate static func archivePathComponents(_ path: String) throws -> ArraySlice<String> {
        let components = path.pathComponentsForArchive
        guard !components.isEmpty,
              !path.hasPrefix("/"),
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw HorizontalProjectArchiveError.invalidRelativePath(path)
        }
        return ArraySlice(components)
    }
}

private struct ArchiveBuilder {
    var children = [String: HorizontalProjectArchiveNode]()

    mutating func insertFileSystemItem(at url: URL, relativePath: String) throws {
        let components = try HorizontalProjectArchive.archivePathComponents(relativePath)
        let node = try HorizontalProjectArchive.snapshot(from: url).root
        insert(node, components: components, into: &children)
    }

    private func insert(
        _ node: HorizontalProjectArchiveNode,
        components: ArraySlice<String>,
        into children: inout [String: HorizontalProjectArchiveNode]
    ) {
        guard let name = components.first else {
            return
        }

        if components.count == 1 {
            children[name] = node
            return
        }

        let remaining = components.dropFirst()
        var directoryChildren: [String: HorizontalProjectArchiveNode]
        if case .directory(let existingChildren) = children[name] {
            directoryChildren = existingChildren
        } else {
            directoryChildren = [:]
        }

        insert(node, components: remaining, into: &directoryChildren)
        children[name] = .directory(directoryChildren)
    }

    private func archivePathComponents(_ path: String) throws -> ArraySlice<String> {
        let components = path.pathComponentsForArchive
        guard !components.isEmpty,
              !path.hasPrefix("/"),
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw HorizontalProjectArchiveError.invalidRelativePath(path)
        }
        return ArraySlice(components)
    }
}

private extension HorizontalProjectArchiveNode {
    mutating func replaceRegularFileData(components: ArraySlice<String>, with data: Data) throws {
        guard let first = components.first else {
            self = .regularFile(data)
            return
        }

        guard components.count > 1 else {
            switch self {
            case .directory(var children):
                children[first] = .regularFile(data)
                self = .directory(children)
            case .regularFile, .symbolicLink:
                throw HorizontalProjectArchiveError.invalidRelativePath(first)
            }
            return
        }

        switch self {
        case .directory(var children):
            var child = children[first] ?? .directory([:])
            try child.replaceRegularFileData(components: components.dropFirst(), with: data)
            children[first] = child
            self = .directory(children)
        case .regularFile, .symbolicLink:
            throw HorizontalProjectArchiveError.invalidRelativePath(components.joined(separator: "/"))
        }
    }

    var regularFileCount: Int {
        switch self {
        case .regularFile:
            1
        case .symbolicLink:
            0
        case .directory(let children):
            children.values.reduce(0) { $0 + $1.regularFileCount }
        }
    }

    var directoryCount: Int {
        switch self {
        case .regularFile, .symbolicLink:
            0
        case .directory(let children):
            1 + children.values.reduce(0) { $0 + $1.directoryCount }
        }
    }

    var symbolicLinkCount: Int {
        switch self {
        case .regularFile:
            0
        case .symbolicLink:
            1
        case .directory(let children):
            children.values.reduce(0) { $0 + $1.symbolicLinkCount }
        }
    }

    func regularFilePaths(prefix: String) -> [String] {
        switch self {
        case .regularFile:
            [prefix]
        case .symbolicLink:
            []
        case .directory(let children):
            children.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.flatMap { name in
                guard let child = children[name] else {
                    return [String]()
                }
                let childPrefix = prefix.isEmpty ? name : "\(prefix)/\(name)"
                return child.regularFilePaths(prefix: childPrefix)
            }
        }
    }

    func regularFileData(components: ArraySlice<String>) -> Data? {
        switch self {
        case .regularFile(let data):
            return components.isEmpty ? data : nil
        case .symbolicLink:
            return nil
        case .directory(let children):
            guard let first = components.first,
                  let child = children[first] else {
                return nil
            }
            return child.regularFileData(components: components.dropFirst())
        }
    }
}

private extension String {
    var pathComponentsForArchive: ArraySlice<String> {
        ArraySlice(
            split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
        )
    }
}
