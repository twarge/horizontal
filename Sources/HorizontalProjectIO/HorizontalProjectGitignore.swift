import Foundation

/// Horizon's project `.gitignore` (`project.cpp`): written with every new
/// project, and checked when a project opens, where a file missing any of
/// these lines gets an offer to add them (`gitignore_needs_fixing`,
/// `fix_gitignore`). A project with no `.gitignore` at all is left alone, as
/// upstream leaves it.
public enum HorizontalProjectGitignore {
    /// Upstream's `gitignore_lines`, in its order: the pool's SQLite database
    /// and its journal, the editors' view-state sidecars, autosaves and backups.
    public static let lines = ["pool/*.db", "pool/*.db-*", "*.imp_meta", "*.autosave", "*.bak"]

    public static var data: Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    /// The recommended lines a `.gitignore` lacks, compared after trimming each
    /// of its lines, as upstream compares them.
    public static func missingLines(in data: Data) -> [String] {
        let present = Set(String(decoding: data, as: UTF8.self)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return lines.filter { !present.contains($0) }
    }

    /// `data` with the missing lines appended. Upstream appends at the end of
    /// the file as it stands; a last line with no newline gets one first, so
    /// the first added line doesn't run into it.
    public static func fixed(_ data: Data) -> Data {
        let missing = missingLines(in: data)
        guard !missing.isEmpty else { return data }
        var result = data
        if let last = data.last, last != UInt8(ascii: "\n") { result.append(UInt8(ascii: "\n")) }
        result.append(Data(missing.map { $0 + "\n" }.joined().utf8))
        return result
    }
}

public extension HorizontalProjectArchive {
    /// The `.gitignore` beside the project file, as an archive path: Horizon
    /// looks for it in the directory holding the `.hprj`.
    var gitignoreRelativePath: String? {
        let projectPath: String?
        if let manifest {
            projectPath = manifest.relativePath(for: manifest.projectFileURL)
        } else {
            projectPath = regularFilePaths.filter { $0.hasSuffix(".hprj") }.min { $0.count < $1.count }
        }
        guard let projectPath else { return nil }
        let directory = (projectPath as NSString).deletingLastPathComponent
        return directory.isEmpty ? ".gitignore" : directory + "/.gitignore"
    }

    /// Whether the project's `.gitignore` exists and lacks a recommended line.
    var gitignoreNeedsFixing: Bool {
        guard let path = gitignoreRelativePath, let data = regularFileData(relativePath: path) else { return false }
        return !HorizontalProjectGitignore.missingLines(in: data).isEmpty
    }

    /// Appends the missing recommended lines to the project's `.gitignore`.
    /// Returns whether anything changed.
    @discardableResult
    mutating func fixGitignore() throws -> Bool {
        guard let path = gitignoreRelativePath, let data = regularFileData(relativePath: path) else { return false }
        let fixed = HorizontalProjectGitignore.fixed(data)
        guard fixed != data else { return false }
        try replaceRegularFileData(relativePath: path, with: fixed)
        return true
    }
}
