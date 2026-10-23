import CryptoKit
import Foundation

/// The repository a clone leaves: the pack and its index under `.git`, the
/// branch checked out from the remote's HEAD, the files of its commit written
/// out, and the git index describing them, so it is an ordinary repository
/// that real git can `pull` and `status` (`Documentation/gitformat-index.txt`,
/// `gitrepository-layout.txt`).
enum HorizontalGitRepository {
    struct TreeEntry: Equatable {
        var mode: String
        var name: [UInt8]
        var id: Data

        var isTree: Bool { mode == "40000" }
    }

    /// One file of the checkout, for the git index: what git compares the
    /// file on disk against to tell whether it changed.
    struct IndexEntry: Equatable {
        var path: [UInt8]
        var mode: UInt32
        var id: Data
        var ctimeSeconds: UInt32 = 0
        var ctimeNanoseconds: UInt32 = 0
        var mtimeSeconds: UInt32 = 0
        var mtimeNanoseconds: UInt32 = 0
        var device: UInt32 = 0
        var inode: UInt32 = 0
        var uid: UInt32 = 0
        var gid: UInt32 = 0
        var size: UInt32 = 0
        /// Git's assume-valid bit, which `update-index --assume-unchanged` sets.
        var assumeValid = false

        init(path: [UInt8], mode: UInt32, id: Data) {
            self.path = path
            self.mode = mode
            self.id = id
        }

        init(path: [UInt8], mode: UInt32, id: Data, stat info: Darwin.stat) {
            self.init(path: path, mode: mode, id: id)
            ctimeSeconds = UInt32(truncatingIfNeeded: info.st_ctimespec.tv_sec)
            ctimeNanoseconds = UInt32(truncatingIfNeeded: info.st_ctimespec.tv_nsec)
            mtimeSeconds = UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
            mtimeNanoseconds = UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
            device = UInt32(truncatingIfNeeded: info.st_dev)
            inode = UInt32(truncatingIfNeeded: info.st_ino)
            uid = UInt32(truncatingIfNeeded: info.st_uid)
            gid = UInt32(truncatingIfNeeded: info.st_gid)
            size = mode == 0o160000 ? 0 : UInt32(truncatingIfNeeded: info.st_size)
        }

        /// The file is as the index saw it, by the stat git trusts.
        func matches(_ info: Darwin.stat) -> Bool {
            mtimeSeconds == UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec)
                && mtimeNanoseconds == UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec)
                && size == UInt32(truncatingIfNeeded: info.st_size)
                && inode == UInt32(truncatingIfNeeded: info.st_ino)
        }
    }

    /// "<mode> <name>\0<20-byte id>", over and over.
    static func treeEntries(_ content: [UInt8]) throws -> [TreeEntry] {
        var entries = [TreeEntry]()
        var cursor = 0
        while cursor < content.count {
            guard let space = content[cursor...].firstIndex(of: 0x20),
                  let nul = content[space...].firstIndex(of: 0), nul + 21 <= content.count else {
                throw HorizontalGitCloneError.corruptPack("a tree is malformed")
            }
            entries.append(TreeEntry(
                mode: String(decoding: content[cursor..<space], as: UTF8.self),
                name: Array(content[(space + 1)..<nul]),
                id: Data(content[(nul + 1)..<(nul + 21)])
            ))
            cursor = nul + 21
        }
        return entries
    }

    /// The tree a commit records, from its "tree <id>" first line.
    static func tree(ofCommit content: [UInt8]) throws -> Data {
        let header = String(decoding: content.prefix(45), as: UTF8.self)
        guard header.hasPrefix("tree "), let id = HorizontalGitPack.id(hex: String(header.dropFirst(5).prefix(40))) else {
            throw HorizontalGitCloneError.corruptPack("a commit names no tree")
        }
        return id
    }

    /// Writes the pack, its index, the refs and the config.
    static func writeRepository(
        pack: Data,
        packObjects: HorizontalGitPack,
        branch: String,
        commit: String,
        remote: URL,
        into root: URL
    ) throws {
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let fileManager = FileManager.default
        for directory in ["objects/pack", "objects/info", "refs/heads", "refs/tags", "refs/remotes/origin", "info"] {
            try fileManager.createDirectory(at: git.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
        let name = "pack-" + HorizontalGitPack.hex(packObjects.checksum)
        try pack.write(to: git.appendingPathComponent("objects/pack/\(name).pack"))
        try packObjects.indexFile().write(to: git.appendingPathComponent("objects/pack/\(name).idx"))

        let shortBranch = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        try write("ref: refs/heads/\(shortBranch)\n", to: git.appendingPathComponent("HEAD"))
        try write("\(commit)\n", to: git.appendingPathComponent("refs/heads/\(shortBranch)"))
        try write("\(commit)\n", to: git.appendingPathComponent("refs/remotes/origin/\(shortBranch)"))
        try write("ref: refs/remotes/origin/\(shortBranch)\n", to: git.appendingPathComponent("refs/remotes/origin/HEAD"))
        try write("""
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tbare = false
        \tlogallrefupdates = true
        \tignorecase = true
        \tprecomposeunicode = true
        [remote "origin"]
        \turl = \(remote.absoluteString)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "\(shortBranch)"]
        \tremote = origin
        \tmerge = refs/heads/\(shortBranch)

        """, to: git.appendingPathComponent("config"))
        try write("# git ls-files --others --exclude-from=.git/info/exclude\n", to: git.appendingPathComponent("info/exclude"))
    }

    /// Writes out the files of `commit` under `root` and the git index for
    /// them. Directories come from trees, files and symlinks from blobs, and a
    /// submodule (a gitlink) is an empty directory, as git leaves one before
    /// `submodule update`.
    static func checkOut(
        commit: Data,
        from pack: HorizontalGitPack,
        into root: URL,
        progress: (Int, Int) -> Void = { _, _ in }
    ) throws {
        let commitObject = try pack.object(commit)
        guard commitObject.kind == .commit else {
            throw HorizontalGitCloneError.corruptPack("the branch doesn't name a commit")
        }
        // The files first, so progress has a total.
        var files = [(path: [UInt8], entry: TreeEntry)]()
        func walk(_ treeID: Data, prefix: [UInt8]) throws {
            let tree = try pack.object(treeID)
            guard tree.kind == .tree else {
                throw HorizontalGitCloneError.corruptPack("a tree entry names a \(tree.kind.name)")
            }
            for entry in try treeEntries(tree.content) {
                let path = prefix.isEmpty ? entry.name : prefix + [0x2F] + entry.name
                // Nothing a checkout could write outside the clone, or into
                // its .git (in any case, the disk being case-insensitive).
                guard !entry.name.isEmpty, entry.name != [0x2E], entry.name != [0x2E, 0x2E], !entry.name.contains(0x2F),
                      String(decoding: entry.name, as: UTF8.self).lowercased() != ".git" else {
                    throw HorizontalGitCloneError.corruptPack("a tree has an unsafe name")
                }
                if entry.isTree {
                    try walk(entry.id, prefix: path)
                } else {
                    files.append((path, entry))
                }
            }
        }
        try walk(try tree(ofCommit: commitObject.content), prefix: [])

        let fileManager = FileManager.default
        var indexEntries = [IndexEntry]()
        indexEntries.reserveCapacity(files.count)
        for (number, file) in files.enumerated() {
            if number % 64 == 0 {
                try Task.checkCancellation()
                progress(number, files.count)
            }
            let url = root.appendingPathComponent(String(decoding: file.path, as: UTF8.self), isDirectory: false)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mode: UInt32
            switch file.entry.mode {
            case "160000":
                // A submodule: its commit isn't in this pack.
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                mode = 0o160000
            case "120000":
                let blob = try pack.object(file.entry.id)
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: String(decoding: blob.content, as: UTF8.self))
                mode = 0o120000
            default:
                let blob = try pack.object(file.entry.id)
                guard blob.kind == .blob else {
                    throw HorizontalGitCloneError.corruptPack("a file entry names a \(blob.kind.name)")
                }
                try Data(blob.content).write(to: url)
                let executable = file.entry.mode == "100755"
                try fileManager.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
                mode = executable ? 0o100755 : 0o100644
            }
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            indexEntries.append(IndexEntry(path: file.path, mode: mode, id: file.entry.id, stat: info))
        }
        progress(files.count, files.count)
        try indexFile(indexEntries).write(to: root.appendingPathComponent(".git/index"))
    }

    /// The git index, version 2: a header, the entries sorted by path with
    /// each one's stat and id, and the SHA-1 of it all.
    static func indexFile(_ entries: [IndexEntry]) -> Data {
        let sorted = entries.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        var out = Data("DIRC".utf8)
        append(2, to: &out)
        append(UInt32(sorted.count), to: &out)
        for entry in sorted {
            let start = out.count
            for value in [entry.ctimeSeconds, entry.ctimeNanoseconds, entry.mtimeSeconds, entry.mtimeNanoseconds,
                          entry.device, entry.inode, entry.mode, entry.uid, entry.gid, entry.size] {
                append(value, to: &out)
            }
            out.append(entry.id)
            let flags = UInt16(min(entry.path.count, 0xFFF)) | (entry.assumeValid ? 0x8000 : 0)
            out.append(contentsOf: [UInt8(flags >> 8), UInt8(flags & 0xFF)])
            out.append(contentsOf: entry.path)
            // NULs to the next multiple of eight, at least one.
            let length = out.count - start
            out.append(contentsOf: [UInt8](repeating: 0, count: 8 - length % 8))
        }
        out.append(Data(Insecure.SHA1.hash(data: out)))
        return out
    }

    /// A git index of version 2 or 3, its entries as written. Its extensions
    /// are caches git rebuilds and are left behind, except the ones that
    /// change what the entries mean (a split or sparse index), which, like
    /// version 4, conflicts and sparse checkouts, are refused.
    static func readIndex(_ data: Data) throws -> [IndexEntry] {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> UInt32 { bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
        guard bytes.count >= 32, bytes[0..<4].elementsEqual(Array("DIRC".utf8)) else {
            throw HorizontalGitUpdateError.unsupported("its git index is unreadable")
        }
        let version = word(4)
        guard version == 2 || version == 3 else {
            throw HorizontalGitUpdateError.unsupported("its git index is version \(version)")
        }
        let body = bytes.count - 20
        if !bytes[body...].allSatisfy({ $0 == 0 }) {
            guard Data(Insecure.SHA1.hash(data: Data(bytes[..<body]))) == Data(bytes[body...]) else {
                throw HorizontalGitUpdateError.unsupported("its git index is damaged")
            }
        }
        var entries = [IndexEntry]()
        var cursor = 12
        for _ in 0..<Int(word(8)) {
            guard cursor + 62 <= body else { throw HorizontalGitUpdateError.unsupported("its git index is cut short") }
            let start = cursor
            var entry = IndexEntry(path: [], mode: word(cursor + 24), id: Data(bytes[(cursor + 40)..<(cursor + 60)]))
            entry.ctimeSeconds = word(cursor)
            entry.ctimeNanoseconds = word(cursor + 4)
            entry.mtimeSeconds = word(cursor + 8)
            entry.mtimeNanoseconds = word(cursor + 12)
            entry.device = word(cursor + 16)
            entry.inode = word(cursor + 20)
            entry.uid = word(cursor + 28)
            entry.gid = word(cursor + 32)
            entry.size = word(cursor + 36)
            let flags = UInt16(bytes[cursor + 60]) << 8 | UInt16(bytes[cursor + 61])
            entry.assumeValid = flags & 0x8000 != 0
            guard (flags >> 12) & 0x3 == 0 else {
                throw HorizontalGitUpdateError.unsupported("it's in the middle of a merge; finish it with git")
            }
            cursor += 62
            if flags & 0x4000 != 0 {
                guard version == 3, cursor + 2 <= body else { throw HorizontalGitUpdateError.unsupported("its git index is malformed") }
                guard bytes[cursor] == 0, bytes[cursor + 1] == 0 else {
                    throw HorizontalGitUpdateError.unsupported("it's a sparse checkout, or has files added with intent to add")
                }
                cursor += 2
            }
            guard let nul = bytes[cursor..<body].firstIndex(of: 0) else {
                throw HorizontalGitUpdateError.unsupported("its git index is malformed")
            }
            entry.path = Array(bytes[cursor..<nul])
            // NULs to the next multiple of eight, at least one.
            cursor = start + ((nul - start) / 8 + 1) * 8
            entries.append(entry)
        }
        while cursor + 8 <= body {
            let signature = String(decoding: bytes[cursor..<cursor + 4], as: UTF8.self)
            guard signature != "link", signature != "sdir" else {
                throw HorizontalGitUpdateError.unsupported("its git index is split or sparse")
            }
            cursor += 8 + Int(word(cursor + 4))
        }
        return entries
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
