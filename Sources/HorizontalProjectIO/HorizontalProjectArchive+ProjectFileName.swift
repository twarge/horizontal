import Foundation

/// The name of a package's `.hprj`, and keeping it in step with the package.
///
/// Opening a `.horizontal` package reads the `.hprj` at its top named like the
/// package, or the first by name when none is. Nothing else ties the two
/// together, so a project made as `Untitled.horizontal` and saved as
/// `Evan.horizontal` still held `Untitled.hprj`, which is what Horizon shows
/// anyone opening the folder. A package save names it after the package.
extension HorizontalProjectArchive {
    /// The `.hprj` at the top of a package-shaped archive, as opening the
    /// package as `packageName` would pick it: the one named like the package,
    /// else the first by name. Nil for a single-file archive or a package
    /// without one.
    public func packageProjectFileName(packageName: String? = nil) -> String? {
        guard case .directory(let children) = root else {
            return nil
        }
        let projectFiles = Self.projectFileNames(in: children)
        if let packageName,
           let named = projectFiles.first(where: { Self.stem(of: $0).caseInsensitiveCompare(packageName) == .orderedSame }) {
            return named
        }
        return projectFiles.first
    }

    /// The archive with its `.hprj` named after the package it is saved as,
    /// `<packageName>.hprj`, and the manifest, if it has one, naming the file
    /// where it now is. Unchanged unless the package holds exactly one `.hprj`
    /// at its top, that one is named otherwise (letter case aside), and no
    /// other file already has the new name: a package of several projects is
    /// opened by name, and renaming one of them could change which opens.
    public func renamingProjectFile(toMatchPackageNamed packageName: String) -> HorizontalProjectArchive {
        guard case .directory(var children) = root,
              let target = Self.projectFileName(forPackageNamed: packageName) else {
            return self
        }
        let projectFiles = Self.projectFileNames(in: children)
        guard projectFiles.count == 1, let current = projectFiles.first,
              current.caseInsensitiveCompare(target) != .orderedSame,
              !children.keys.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }),
              let node = children.removeValue(forKey: current) else {
            return self
        }
        children[target] = node
        var renamed = self
        renamed.root = .directory(children)
        if var manifest = renamed.manifest, manifest.relativePath(for: manifest.projectFileURL) == current {
            let moved = manifest.baseURL.appendingPathComponent(target)
            let old = manifest.projectFileURL.standardizedFileURL
            manifest.includedURLs = manifest.includedURLs.map { $0.standardizedFileURL == old ? moved : $0 }
            manifest.projectFileURL = moved
            renamed.manifest = manifest
        }
        return renamed
    }

    /// `<name>.hprj` for a package or folder called `name`, with its extension
    /// (`.horizontal`) dropped and the characters a file name can't hold
    /// replaced, as a new project's are; nil for a name with nothing left.
    public static func projectFileName(forPackageNamed name: String) -> String? {
        var stem = name
        if (stem as NSString).pathExtension.caseInsensitiveCompare("horizontal") == .orderedSame {
            stem = (stem as NSString).deletingPathExtension
        }
        stem = stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, !stem.hasPrefix(".") else {
            return nil
        }
        return "\(stem).hprj"
    }

    /// Writes a package-shaped archive's files into the folder at `url`,
    /// making it and any folder inside it as needed, each file replaced
    /// whole. Files already in the folder that the archive doesn't hold are
    /// left where they are: a project folder holds more than the project (a
    /// fabrication folder, notes, a repository), and an export over it must
    /// not take those away, as `write(to:)` replacing the folder would.
    public func writeContents(into url: URL) throws {
        guard case .directory(let children) = root else {
            throw HorizontalProjectArchiveError.unsupportedFileWrapper(url.lastPathComponent)
        }
        try Self.writeContents(children, into: url)
    }

    private static func writeContents(_ children: [String: HorizontalProjectArchiveNode], into url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, node) in children {
            let child = url.appendingPathComponent(name)
            switch node {
            case .directory(let grandchildren):
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    try fileManager.removeItem(at: child)
                }
                try writeContents(grandchildren, into: child)
            case .regularFile(let data):
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try fileManager.removeItem(at: child)
                }
                try data.write(to: child, options: .atomic)
            case .symbolicLink(let destination):
                if (try? fileManager.destinationOfSymbolicLink(atPath: child.path)) != nil
                    || fileManager.fileExists(atPath: child.path) {
                    try fileManager.removeItem(at: child)
                }
                try fileManager.createSymbolicLink(atPath: child.path, withDestinationPath: destination)
            }
        }
    }

    private static func projectFileNames(in children: [String: HorizontalProjectArchiveNode]) -> [String] {
        children.compactMap { name, node in
            guard case .regularFile = node,
                  (name as NSString).pathExtension.caseInsensitiveCompare("hprj") == .orderedSame else {
                return nil
            }
            return name
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
