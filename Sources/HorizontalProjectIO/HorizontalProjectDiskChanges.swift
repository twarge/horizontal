import Foundation

/// What a project's files hold, as a content digest per archive-relative path.
///
/// An open document autosaves in place, so its files change all the time and
/// a change on its own says nothing. What matters is whether the files hold
/// something the document never had: that is a change something else made —
/// a git checkout, a pull, another tool — and the document's next autosave
/// would write over it. Fingerprints of the files and of the document are
/// what `HorizontalProjectChangeDetector` compares to tell the two apart.
public struct HorizontalProjectFingerprint: Equatable, Sendable {
    /// Digest by path; a symbolic link records its destination instead.
    public private(set) var entries: [String: String]

    public init(archive: HorizontalProjectArchive) {
        var entries = [String: String]()
        Self.collect(archive.root, path: "", into: &entries)
        self.entries = entries
    }

    /// Files a change to which is not a change to the project: what Finder,
    /// git, safe saves and Horizon itself leave beside it. The last group is
    /// what `HorizontalProjectGitignore.lines` keeps out of version control.
    public static func ignores(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = components.last else { return false }
        if components.contains(where: { $0 == ".git" || $0 == ".horizontal-transactions" || $0 == ".Trashes" }) {
            return true
        }
        if name == ".DS_Store" || name.hasPrefix("._") || name.contains(".sb-") {
            return true
        }
        return name.hasSuffix(".db") || name.contains(".db-") || name.hasSuffix(".imp_meta")
            || name.hasSuffix(".autosave") || name.hasSuffix(".bak")
    }

    private static func collect(_ node: HorizontalProjectArchiveNode, path: String, into entries: inout [String: String]) {
        switch node {
        case .directory(let children):
            for (name, child) in children {
                collect(child, path: path.isEmpty ? name : path + "/" + name, into: &entries)
            }
        case .regularFile(let data):
            guard !ignores(path) else { return }
            entries[path] = HorizontalProjectTransaction.digest(data)
        case .symbolicLink(let destination):
            guard !ignores(path) else { return }
            entries[path] = "link:" + destination
        }
    }
}

/// Tells a change something else made to an open project's files from the
/// document's own writes.
///
/// The files are expected to hold one of:
/// - **what the document holds now** — it has written everything;
/// - **what they held when last seen in step** — the document has edits it
///   hasn't written yet;
/// - **something the document wrote since** — an autosave of an earlier state,
///   overtaken by a newer edit before the check ran.
///
/// - **a mix of those, file by file** — the app writes some files itself
///   before the document's next autosave writes the rest: Place and Replace
///   cache a part into the project pool, on disk and in the document, while
///   the edit that uses it waits to autosave (131).
///
/// Anything else is a change from outside. `baseline` moves forward whenever
/// the files are found in step with the document or with one of its writes.
public struct HorizontalProjectChangeDetector: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// The files hold the document, or something it wrote.
        case inStep
        /// The files are as last seen, and the document is ahead of them.
        case documentAhead
        /// Something other than the document changed the files.
        case changedOnDisk
    }

    /// How many recent writes are remembered: autosaves overtaken by newer
    /// edits before a check could see them.
    public static let rememberedWrites = 8

    public private(set) var baseline: HorizontalProjectFingerprint
    private var writes: [HorizontalProjectFingerprint] = []

    public init(baseline: HorizontalProjectFingerprint) {
        self.baseline = baseline
    }

    /// The document is writing this; the files may hold it next.
    public mutating func recordWrite(_ fingerprint: HorizontalProjectFingerprint) {
        writes.append(fingerprint)
        if writes.count > Self.rememberedWrites {
            writes.removeFirst(writes.count - Self.rememberedWrites)
        }
    }

    /// The files now hold `disk`, and the document stays as it is (the user
    /// kept their version): only a later change is reported.
    public mutating func accept(_ disk: HorizontalProjectFingerprint) {
        baseline = disk
        writes.removeAll()
    }

    /// `document` is nil when the document holds no complete copy of the
    /// project to compare with, as when it was opened read-only.
    public mutating func classify(disk: HorizontalProjectFingerprint,
                                  document: HorizontalProjectFingerprint?) -> Verdict {
        if let document, disk == document {
            accept(disk)
            return .inStep
        }
        if disk == baseline {
            return document == nil ? .inStep : .documentAhead
        }
        if let index = writes.firstIndex(of: disk) {
            baseline = disk
            writes.removeFirst(index + 1)
            return document == nil ? .inStep : .documentAhead
        }
        if holdsOnlyKnownVersions(disk, document: document) {
            baseline = disk
            return document == nil ? .inStep : .documentAhead
        }
        return .changedOnDisk
    }

    /// Whether every file, on its own, holds what the document holds, what it
    /// held when last in step, or what the document wrote: a file that is
    /// there or gone in one of those. A checkout or a pull writes something
    /// none of them had, a pulled part included.
    private func holdsOnlyKnownVersions(_ disk: HorizontalProjectFingerprint,
                                        document: HorizontalProjectFingerprint?) -> Bool {
        let known = [baseline] + writes + (document.map { [$0] } ?? [])
        let paths = Set(disk.entries.keys).union(known.flatMap(\.entries.keys))
        return paths.allSatisfy { path in
            let held = disk.entries[path]
            return known.contains { $0.entries[path] == held }
        }
    }
}

public extension HorizontalProjectArchive {
    /// Whether a change at `relativePath` could change what the project is.
    /// A path in the archive, or inside one of its directories, could. For a
    /// Horizon `.hprj` beside other files, a new file at the top level could
    /// not: the project only takes in what it references, and a new reference
    /// arrives as a change to a file it already has.
    func tracks(relativePath: String) -> Bool {
        guard !HorizontalProjectFingerprint.ignores(relativePath) else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first else { return true }
        guard manifest != nil else { return true }
        guard case .directory(let children) = root, let top = children[first] else { return false }
        if case .directory = top { return true }
        return components.count == 1
    }
}
