import CryptoKit
import Foundation

/// A checkout brought up to date from its remote over HTTPS, as
/// `git pull --ff-only` brings it: the remote's branch fetched (only what the
/// checkout lacks), its commit checked to come after the checkout's own, the
/// files that changed between the two written, removed and recorded in the
/// git index, and the branch moved on. A checkout with changes the update
/// would overwrite, or commits of its own, is left as it was; changes to
/// files the update doesn't touch stay as they are.
enum HorizontalGitPull {
    enum Outcome: Equatable, Sendable {
        case upToDate(commit: String)
        case updated(from: String, to: String, commits: Int, files: Int)
        /// The checkout has commits the remote hasn't, and nothing is new there.
        case ahead(commit: String)
    }

    enum Availability: Equatable, Sendable {
        case upToDate
        case available(remote: String)
        case ahead
    }

    /// Where the checkout stands against its remote, from the remote's refs
    /// alone: nothing is fetched.
    static func check(_ root: URL, session: URLSession = .shared) async throws -> Availability {
        let checkout = try checkout(at: root)
        let tip = try await remoteTip(of: checkout, session: session).tip
        if tip == checkout.head {
            return .upToDate
        }
        let store = try HorizontalGitObjectStore(gitDirectory: checkout.gitDirectory)
        if let tipID = HorizontalGitPack.id(hex: tip), store.contains(tipID),
           let headID = HorizontalGitPack.id(hex: checkout.head), try ancestors(of: headID, in: store).contains(tipID) {
            return .ahead
        }
        return .available(remote: tip)
    }

    static func update(
        _ root: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (HorizontalGitClone.Progress) -> Void = { _ in }
    ) async throws -> Outcome {
        let checkout = try checkout(at: root)
        progress(HorizontalGitClone.Progress(phase: .connecting))
        let (tip, advertisement, fetchURL) = try await remoteTip(of: checkout, session: session)
        if tip == checkout.head {
            try moveTrackingRef(of: checkout, to: tip)
            return .upToDate(commit: tip)
        }
        guard let tipID = HorizontalGitPack.id(hex: tip) else {
            throw HorizontalGitCloneError.protocolError("The remote named a malformed commit")
        }
        let store = try HorizontalGitObjectStore(gitDirectory: checkout.gitDirectory)
        if !store.contains(tipID) {
            // What the checkout has, so the pack holds only what it lacks.
            var haves = [checkout.head]
            if let tracking = HorizontalGitCheckout.ref(checkout.trackingRef, in: checkout.gitDirectory), tracking != checkout.head,
               let trackingID = HorizontalGitPack.id(hex: tracking), store.contains(trackingID) {
                haves.append(tracking)
            }
            let response = try await HorizontalGitClone.post(
                HorizontalGitClone.endpoint(fetchURL, "git-upload-pack"),
                body: HorizontalGitProtocol.uploadPackRequest(want: tip, haves: haves, capabilities: advertisement.capabilities),
                session: session
            ) { received in
                progress(HorizontalGitClone.Progress(phase: .receiving, completed: received))
            }
            let packData = try HorizontalGitProtocol.pack(fromUploadPackResponse: response, sideBand: HorizontalGitProtocol.SideBand(advertisement.capabilities))
            try Task.checkCancellation()
            let pack = try HorizontalGitPack(packData)
            try pack.index { done, total in
                progress(HorizontalGitClone.Progress(phase: .indexing, completed: done, total: total))
            }
            store.add(pack)
            // Kept whatever follows: objects only add to a repository.
            try write(pack: packData, objects: pack, into: checkout.gitDirectory)
        }
        try Task.checkCancellation()
        return try fastForward(checkout, to: tip, store: store, progress: progress)
    }

    /// The checkout at `root`, refused when it is in the middle of something
    /// git should finish.
    static func checkout(at root: URL) throws -> HorizontalGitCheckout {
        guard let checkout = try HorizontalGitCheckout.read(root) else {
            throw HorizontalGitUpdateError.unsupported("it isn't a git checkout")
        }
        let git = checkout.gitDirectory
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: git.appendingPathComponent("shallow").path) {
            throw HorizontalGitUpdateError.unsupported("it's a shallow clone; update it with git")
        }
        for (file, what) in [("MERGE_HEAD", "a merge"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"),
                             ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert")]
            where fileManager.fileExists(atPath: git.appendingPathComponent(file).path) {
            throw HorizontalGitUpdateError.unsupported("it's in the middle of \(what); finish it with git")
        }
        return checkout
    }

    private static func remoteTip(
        of checkout: HorizontalGitCheckout,
        session: URLSession
    ) async throws -> (tip: String, advertisement: HorizontalGitProtocol.Advertisement, fetchURL: URL) {
        guard let fetchURL = checkout.fetchURL else {
            throw HorizontalGitUpdateError.unreachableRemote(checkout.remoteURL)
        }
        let advertisement: HorizontalGitProtocol.Advertisement
        do {
            advertisement = try HorizontalGitProtocol.advertisement(from: try await HorizontalGitClone.get(
                HorizontalGitClone.endpoint(fetchURL, "info/refs?service=git-upload-pack"),
                session: session
            ))
        } catch HorizontalGitCloneError.http(let status) where status == 401 || status == 403 {
            throw HorizontalGitUpdateError.signInNeeded(fetchURL.host ?? checkout.remoteURL)
        } catch HorizontalGitCloneError.http(404) where !checkout.remoteIsHTTP {
            throw HorizontalGitUpdateError.unreachableRemote(checkout.remoteURL)
        }
        guard let tip = advertisement.id(of: checkout.upstream) else {
            throw HorizontalGitUpdateError.noRemoteBranch(String(checkout.upstream.dropFirst("refs/heads/".count)))
        }
        return (tip.lowercased(), advertisement, fetchURL)
    }

    /// The pack and its index beside the others, as `git fetch` leaves them.
    static func write(pack data: Data, objects pack: HorizontalGitPack, into gitDirectory: URL) throws {
        let directory = gitDirectory.appendingPathComponent("objects/pack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "pack-" + HorizontalGitPack.hex(pack.checksum)
        let packURL = directory.appendingPathComponent("\(name).pack")
        let indexURL = directory.appendingPathComponent("\(name).idx")
        guard !FileManager.default.fileExists(atPath: indexURL.path) else { return }
        try data.write(to: packURL, options: .atomic)
        try pack.indexFile().write(to: indexURL, options: .atomic)
    }

    // MARK: - The local half

    /// From the checkout's commit to `tip`, whose objects `store` has.
    static func fastForward(
        _ checkout: HorizontalGitCheckout,
        to tip: String,
        store: HorizontalGitObjectStore,
        progress: (HorizontalGitClone.Progress) -> Void = { _ in }
    ) throws -> Outcome {
        guard let headID = HorizontalGitPack.id(hex: checkout.head), let tipID = HorizontalGitPack.id(hex: tip) else {
            throw HorizontalGitCloneError.protocolError("A malformed commit name")
        }
        if headID == tipID {
            try moveTrackingRef(of: checkout, to: tip)
            return .upToDate(commit: tip)
        }
        // Where the two stand: what the checkout's commit comes after, and
        // whether the remote's comes after it.
        let behind = try ancestors(of: headID, in: store)
        if behind.contains(tipID) {
            try moveTrackingRef(of: checkout, to: tip)
            return .ahead(commit: checkout.head)
        }
        let (newCommits, reachesHead) = try commits(from: tipID, until: behind, head: headID, in: store)
        guard reachesHead else {
            throw HorizontalGitUpdateError.diverged
        }

        let changes = try diff(
            try HorizontalGitRepository.tree(ofCommit: try store.object(headID).content),
            try HorizontalGitRepository.tree(ofCommit: try store.object(tipID).content),
            in: store
        )
        let git = checkout.gitDirectory
        let indexURL = git.appendingPathComponent("index")
        let lock = git.appendingPathComponent("index.lock")
        try HorizontalGitLock.create(lock)
        var locked = true
        defer { if locked { try? FileManager.default.removeItem(at: lock) } }

        guard let indexData = try? Data(contentsOf: indexURL) else {
            throw HorizontalGitUpdateError.unsupported("it has no git index")
        }
        var indexInfo = Darwin.stat()
        let indexTime = lstat(indexURL.path, &indexInfo) == 0 ? Int(indexInfo.st_mtimespec.tv_sec) : Int.max
        var entries = Dictionary(try HorizontalGitRepository.readIndex(indexData).map { ($0.path, $0) }, uniquingKeysWith: { $1 })
        try refuseOverwriting(changes, entries: entries, root: checkout.root, indexTime: indexTime, store: store)

        try apply(changes, root: checkout.root, store: store, entries: &entries, progress: progress)
        try HorizontalGitRepository.indexFile(Array(entries.values)).write(to: lock)
        try HorizontalGitLock.commit(lock, over: indexURL)
        locked = false

        let message = "pull: Fast-forward"
        try HorizontalGitCheckout.setRef("refs/heads/\(checkout.branch)", to: tip, from: checkout.head, in: git, message: message)
        HorizontalGitCheckout.appendReflog(git.appendingPathComponent("logs/HEAD"), old: checkout.head, new: tip, message: message)
        try? Data("\(checkout.head)\n".utf8).write(to: git.appendingPathComponent("ORIG_HEAD"))
        try moveTrackingRef(of: checkout, to: tip)
        return .updated(from: checkout.head, to: tip, commits: newCommits, files: changes.count)
    }

    private static func moveTrackingRef(of checkout: HorizontalGitCheckout, to tip: String) throws {
        let old = HorizontalGitCheckout.ref(checkout.trackingRef, in: checkout.gitDirectory)
        guard old != tip else { return }
        try HorizontalGitCheckout.setRef(checkout.trackingRef, to: tip, from: old, in: checkout.gitDirectory,
                                         message: "pull: fast-forward")
    }

    // MARK: - History

    /// Every commit `id` comes after, and itself.
    static func ancestors(of id: Data, in store: HorizontalGitObjectStore) throws -> Set<Data> {
        var seen: Set<Data> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for parent in try store.parents(ofCommit: next) where seen.insert(parent).inserted {
                queue.append(parent)
            }
        }
        return seen
    }

    /// The commits from `tip` back to where the checkout's history begins,
    /// and whether the checkout's commit itself is among their parents: a
    /// remote that only adds to the checkout's history reaches it.
    private static func commits(
        from tip: Data, until known: Set<Data>, head: Data, in store: HorizontalGitObjectStore
    ) throws -> (count: Int, reachesHead: Bool) {
        var seen: Set<Data> = [tip]
        var queue = [tip]
        var reachesHead = false
        while let next = queue.popLast() {
            for parent in try store.parents(ofCommit: next) {
                if parent == head { reachesHead = true }
                if !known.contains(parent), seen.insert(parent).inserted {
                    queue.append(parent)
                }
            }
        }
        return (seen.count, reachesHead)
    }

    // MARK: - Trees

    /// A path the update writes, changes or removes.
    struct Change: Equatable {
        var path: [UInt8]
        var old: HorizontalGitRepository.TreeEntry?
        var new: HorizontalGitRepository.TreeEntry?

        var pathString: String { String(decoding: path, as: UTF8.self) }
    }

    /// What differs between two trees, file by file: a file that becomes a
    /// folder is one removed and others added, and the other way round.
    static func diff(_ old: Data?, _ new: Data?, in store: HorizontalGitObjectStore, prefix: [UInt8] = []) throws -> [Change] {
        func entries(_ id: Data?) throws -> [[UInt8]: HorizontalGitRepository.TreeEntry] {
            guard let id else { return [:] }
            let tree = try store.object(id)
            guard tree.kind == .tree else {
                throw HorizontalGitCloneError.corruptPack("a tree entry names a \(tree.kind.name)")
            }
            return Dictionary(try HorizontalGitRepository.treeEntries(tree.content).map { ($0.name, $0) }, uniquingKeysWith: { $1 })
        }
        let before = try entries(old)
        let after = try entries(new)
        var changes = [Change]()
        for name in Set(before.keys).union(after.keys).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            let was = before[name], now = after[name]
            if let was, let now, was.id == now.id, was.mode == now.mode { continue }
            if let now {
                // Nothing a checkout could write outside the clone, or into
                // its .git (in any case, the disk being case-insensitive).
                guard !now.name.isEmpty, now.name != [0x2E], now.name != [0x2E, 0x2E], !now.name.contains(0x2F),
                      String(decoding: now.name, as: UTF8.self).lowercased() != ".git" else {
                    throw HorizontalGitCloneError.corruptPack("a tree has an unsafe name")
                }
            }
            let path = prefix.isEmpty ? name : prefix + [0x2F] + name
            switch (was?.isTree ?? false, now?.isTree ?? false) {
            case (true, true):
                changes += try diff(was!.id, now!.id, in: store, prefix: path)
            case (true, false):
                changes += try diff(was!.id, nil, in: store, prefix: path)
                if let now { changes.append(Change(path: path, old: nil, new: now)) }
            case (false, true):
                if let was { changes.append(Change(path: path, old: was, new: nil)) }
                changes += try diff(nil, now!.id, in: store, prefix: path)
            case (false, false):
                changes.append(Change(path: path, old: was, new: now))
            }
        }
        return changes
    }

    // MARK: - The working tree

    static func modeValue(_ mode: String) -> UInt32 {
        switch mode {
        case "100755": 0o100755
        case "120000": 0o120000
        case "160000": 0o160000
        case "40000": 0o040000
        default: 0o100644
        }
    }

    /// Refuses an update that would lose something: a file it changes or
    /// removes that was edited, or whose edit is staged, and anything
    /// untracked where it would write.
    private static func refuseOverwriting(
        _ changes: [Change],
        entries: [[UInt8]: HorizontalGitRepository.IndexEntry],
        root: URL,
        indexTime: Int,
        store: HorizontalGitObjectStore
    ) throws {
        let removed = Set(changes.filter { $0.old != nil && $0.new == nil }.map(\.path))
        var edited = [String]()
        var inTheWay = [String]()
        for change in changes {
            let url = root.appendingPathComponent(change.pathString, isDirectory: false)
            let entry = entries[change.path]
            if let old = change.old {
                if old.mode != "160000" {
                    guard let entry, entry.id == old.id, entry.mode == modeValue(old.mode) else {
                        edited.append(change.pathString)
                        continue
                    }
                }
                if try !isUnchanged(url, from: old, entry: entry, indexTime: indexTime, store: store) {
                    edited.append(change.pathString)
                    continue
                }
            } else if let new = change.new {
                if let entry, entry.id != new.id {
                    edited.append(change.pathString)
                    continue
                }
                var info = Darwin.stat()
                if lstat(url.path, &info) == 0 {
                    if info.st_mode & S_IFMT == S_IFDIR {
                        if new.mode != "160000", !onlyHolds(removed, under: change.path, at: url) {
                            inTheWay.append(change.pathString)
                        }
                    } else if try !holds(url, new, store: store) {
                        inTheWay.append(change.pathString)
                    }
                }
            }
            // Every folder above it a folder, not a link out of the pool.
            if change.new != nil, let blocked = blockedParent(of: change.path, root: root, removed: removed) {
                inTheWay.append(blocked)
            }
        }
        if !edited.isEmpty {
            throw HorizontalGitUpdateError.localChanges(edited)
        }
        if !inTheWay.isEmpty {
            throw HorizontalGitUpdateError.inTheWay(Array(Set(inTheWay)).sorted())
        }
    }

    /// The file is as `old` checked it out, or gone, which an update may
    /// write over: by the index's stat when git would trust it, else by its
    /// content.
    private static func isUnchanged(
        _ url: URL, from old: HorizontalGitRepository.TreeEntry, entry: HorizontalGitRepository.IndexEntry?,
        indexTime: Int, store: HorizontalGitObjectStore
    ) throws -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT }
        if old.mode == "160000" {
            return true
        }
        if let entry, !entry.assumeValid, entry.matches(info), Int(info.st_mtimespec.tv_sec) < indexTime,
           (info.st_mode & S_IFMT == S_IFLNK) == (old.mode == "120000") {
            return (info.st_mode & 0o111 != 0) == (old.mode == "100755") || old.mode == "120000"
        }
        return try holds(url, old, store: store)
    }

    /// The file on disk is the blob `entry` names, of the same kind.
    private static func holds(_ url: URL, _ entry: HorizontalGitRepository.TreeEntry, store: HorizontalGitObjectStore) throws -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return false }
        let content: Data
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            guard entry.mode == "120000", let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
            content = Data(target.utf8)
        case S_IFREG:
            guard entry.mode != "120000", entry.mode != "160000", (info.st_mode & 0o111 != 0) == (entry.mode == "100755") else { return false }
            content = try Data(contentsOf: url)
        default:
            return false
        }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(content.count)\0".utf8))
        hasher.update(data: content)
        return Data(hasher.finalize()) == entry.id
    }

    /// The folder at `url` holds only files the update removes (and folders
    /// of them), so it goes before a file takes its place.
    private static func onlyHolds(_ removed: Set<[UInt8]>, under path: [UInt8], at url: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return false }
        while let relative = walker.nextObject() as? String {
            if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
            if !removed.contains(path + [0x2F] + Array(relative.utf8)), (relative as NSString).lastPathComponent != ".DS_Store" { return false }
        }
        return true
    }

    /// The first folder above `path` that is a link or a file the update
    /// doesn't remove, which a write would go through or fail on.
    private static func blockedParent(of path: [UInt8], root: URL, removed: Set<[UInt8]>) -> String? {
        let parts = path.split(separator: 0x2F, omittingEmptySubsequences: false).dropLast()
        var prefix = [UInt8]()
        for part in parts {
            prefix = prefix.isEmpty ? Array(part) : prefix + [0x2F] + Array(part)
            var info = Darwin.stat()
            guard lstat(root.appendingPathComponent(String(decoding: prefix, as: UTF8.self)).path, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            if info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK, removed.contains(prefix) { return nil }
            return String(decoding: prefix, as: UTF8.self)
        }
        return nil
    }

    /// Removes what goes, then writes what comes, recording each in the
    /// index. Not cancelled midway: a half-written update is worse than a
    /// late one.
    private static func apply(
        _ changes: [Change],
        root: URL,
        store: HorizontalGitObjectStore,
        entries: inout [[UInt8]: HorizontalGitRepository.IndexEntry],
        progress: (HorizontalGitClone.Progress) -> Void
    ) throws {
        let fileManager = FileManager.default
        for change in changes where change.old != nil && change.new == nil {
            let url = root.appendingPathComponent(change.pathString, isDirectory: false)
            var info = Darwin.stat()
            if lstat(url.path, &info) == 0 {
                if change.old?.mode == "160000" {
                    // A submodule's folder goes only when empty, as git leaves one.
                    rmdir(url.path)
                } else {
                    try fileManager.removeItem(at: url)
                }
            }
            entries[change.path] = nil
            pruneEmptyFolders(above: url, root: root)
        }
        let writes = changes.filter { $0.new != nil }
        for (number, change) in writes.enumerated() {
            if number % 64 == 0 {
                progress(HorizontalGitClone.Progress(phase: .checkingOut, completed: number, total: writes.count))
            }
            let new = change.new!
            let url = root.appendingPathComponent(change.pathString, isDirectory: false)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var info = Darwin.stat()
            let exists = lstat(url.path, &info) == 0
            let mode = modeValue(new.mode)
            switch new.mode {
            case "160000":
                if !exists { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
            case "120000":
                let blob = try store.object(new.id)
                if exists { try fileManager.removeItem(at: url) }
                try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: String(decoding: blob.content, as: UTF8.self))
            default:
                let blob = try store.object(new.id)
                guard blob.kind == .blob else {
                    throw HorizontalGitCloneError.corruptPack("a file entry names a \(blob.kind.name)")
                }
                if exists, info.st_mode & S_IFMT != S_IFREG { try fileManager.removeItem(at: url) }
                try Data(blob.content).write(to: url, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: mode == 0o100755 ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
            guard lstat(url.path, &info) == 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            entries[change.path] = HorizontalGitRepository.IndexEntry(path: change.path, mode: mode, id: new.id, stat: info)
        }
        progress(HorizontalGitClone.Progress(phase: .checkingOut, completed: writes.count, total: writes.count))
    }

    private static func pruneEmptyFolders(above url: URL, root: URL) {
        var folder = url.deletingLastPathComponent().standardizedFileURL
        let top = root.standardizedFileURL.path
        while folder.path.count > top.count, folder.path.hasPrefix(top + "/") {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["?"]
            if contents == [".DS_Store"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(".DS_Store"))
            } else if !contents.isEmpty {
                return
            }
            guard rmdir(folder.path) == 0 else { return }
            folder = folder.deletingLastPathComponent()
        }
    }
}
