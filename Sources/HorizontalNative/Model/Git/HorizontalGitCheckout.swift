import Foundation

/// Git's config file, as far as an update needs it: sections, subsections
/// and their values (`git-config`, CONFIGURATION FILE). Includes aren't
/// followed; the last value of a key wins, as git's does.
struct HorizontalGitConfig {
    private var values = [String: String]()

    init(_ text: String) {
        var section = ""
        var pending = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = pending + String(rawLine)
            pending = ""
            // A backslash at the end carries the value onto the next line.
            if line.hasSuffix("\\"), !line.hasSuffix("\\\\") {
                pending = String(line.dropLast())
                continue
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("["), let close = line.lastIndex(of: "]") {
                let header = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let quote = header.firstIndex(of: "\"") {
                    // [remote "origin"]: the subsection keeps its case.
                    let name = header[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    var subsection = String(header[header.index(after: quote)...])
                    if subsection.hasSuffix("\"") { subsection.removeLast() }
                    subsection = subsection.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    section = "\(name).\(subsection)"
                } else if let dot = header.firstIndex(of: ".") {
                    // The old [remote.origin] form, lowercased whole.
                    section = header[..<dot].lowercased() + "." + header[header.index(after: dot)...].lowercased()
                } else {
                    section = header.lowercased()
                }
                continue
            }
            let key: String
            let value: String
            if let equals = line.firstIndex(of: "=") {
                key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                value = Self.value(String(line[line.index(after: equals)...]))
            } else {
                key = line.lowercased()
                value = "true"
            }
            values["\(section).\(key)"] = value
        }
    }

    func value(_ section: String, _ key: String) -> String? {
        values["\(section.lowercased()).\(key.lowercased())"]
    }

    func value(_ section: String, _ subsection: String, _ key: String) -> String? {
        values["\(section.lowercased()).\(subsection).\(key.lowercased())"]
    }

    /// A value's text: quotes joined, escapes read, a comment after it dropped.
    private static func value(_ raw: String) -> String {
        var result = ""
        var quoted = false
        var escaped = false
        for character in raw.trimmingCharacters(in: .whitespaces) {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "b": if !result.isEmpty { result.removeLast() }
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if !quoted, character == "#" || character == ";" {
                break
            } else {
                result.append(character)
            }
        }
        return quoted ? result : result.trimmingCharacters(in: .whitespaces)
    }
}

/// A folder git has checked out, as an update reads it: the branch HEAD is
/// on and its commit, the remote branch it tracks and where that remote is.
struct HorizontalGitCheckout: Equatable, Sendable {
    var root: URL
    var gitDirectory: URL
    /// The local branch, "main".
    var branch: String
    var head: String
    var remoteName: String
    /// The remote's branch the local one merges, "refs/heads/main".
    var upstream: String
    /// Where the remote's branch is kept here, "refs/remotes/origin/main".
    var trackingRef: String
    /// The remote as the config names it, which may be an SSH address.
    var remoteURL: String
    /// Where Horizontal fetches from: the remote itself over HTTP(S), or the
    /// same host over HTTPS for an SSH remote, which a public pool answers.
    var fetchURL: URL?

    var remoteIsHTTP: Bool {
        remoteURL.lowercased().hasPrefix("https://") || remoteURL.lowercased().hasPrefix("http://")
    }

    /// "github.com/horizon-eda/horizon-pool", for showing.
    var remoteDescription: String {
        guard let fetchURL, let host = fetchURL.host else { return remoteURL }
        var path = fetchURL.path
        if path.hasSuffix(".git") { path.removeLast(4) }
        return host + path
    }

    /// The checkout at `root`, or nil when it isn't one: no `.git` there.
    static func read(_ root: URL) throws -> HorizontalGitCheckout? {
        let fileManager = FileManager.default
        var gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory) else {
            return nil
        }
        if !isDirectory.boolValue {
            // "gitdir: <path>", for a submodule's checkout.
            let text = (try? String(contentsOf: gitDirectory, encoding: .utf8)) ?? ""
            guard text.hasPrefix("gitdir:") else {
                throw HorizontalGitUpdateError.unsupported("its .git isn't a folder git wrote")
            }
            let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: root).standardizedFileURL
        }
        if fileManager.fileExists(atPath: gitDirectory.appendingPathComponent("commondir").path) {
            throw HorizontalGitUpdateError.unsupported("it's a git worktree; update it with git")
        }
        let headText = try String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard headText.hasPrefix("ref: refs/heads/") else {
            throw HorizontalGitUpdateError.notOnBranch
        }
        let branch = String(headText.dropFirst("ref: refs/heads/".count))
        guard let head = ref("refs/heads/\(branch)", in: gitDirectory) else {
            throw HorizontalGitUpdateError.unsupported("its branch \(branch) has no commit yet")
        }
        let config = HorizontalGitConfig((try? String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8)) ?? "")
        guard let remoteName = config.value("branch", branch, "remote"), remoteName != ".",
              let upstream = config.value("branch", branch, "merge"),
              let remoteURL = config.value("remote", remoteName, "url") else {
            throw HorizontalGitUpdateError.noUpstream(branch)
        }
        let shortUpstream = upstream.hasPrefix("refs/heads/") ? String(upstream.dropFirst("refs/heads/".count)) : upstream
        return HorizontalGitCheckout(
            root: root, gitDirectory: gitDirectory, branch: branch, head: head, remoteName: remoteName,
            upstream: upstream.hasPrefix("refs/") ? upstream : "refs/heads/\(upstream)",
            trackingRef: "refs/remotes/\(remoteName)/\(shortUpstream)",
            remoteURL: remoteURL, fetchURL: fetchURL(forRemote: remoteURL)
        )
    }

    /// The HTTP(S) address to fetch `remote` from: itself when it is one,
    /// the same host and path over HTTPS for `git@host:path` and
    /// `ssh://host/path`, and nil for a folder or anything else.
    static func fetchURL(forRemote remote: String) -> URL? {
        let lowered = remote.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return URL(string: remote)
        }
        if let scheme = remote.range(of: "://") {
            guard ["ssh", "git+ssh", "ssh+git", "git"].contains(lowered[..<scheme.lowerBound]),
                  let components = URLComponents(string: remote), let host = components.host, !components.path.isEmpty else {
                return nil
            }
            return URL(string: "https://\(host)\(components.path)")
        }
        // scp-like [user@]host:path, a colon before any slash.
        guard let colon = remote.firstIndex(of: ":"), !remote[..<colon].contains("/"), !remote.hasPrefix("/") else {
            return nil
        }
        let authority = remote[..<colon]
        let host = authority.split(separator: "@").last.map(String.init) ?? String(authority)
        var path = String(remote[remote.index(after: colon)...])
        while path.hasPrefix("/") { path.removeFirst() }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return URL(string: "https://\(host)/\(path)")
    }

    // MARK: - Refs

    /// The commit `name` names: its loose file, else its packed-refs line,
    /// following a symbolic ref.
    static func ref(_ name: String, in gitDirectory: URL, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }
        if let text = try? String(contentsOf: gitDirectory.appendingPathComponent(name), encoding: .utf8) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("ref: ") {
                return ref(String(value.dropFirst(5)), in: gitDirectory, depth: depth + 1)
            }
            return HorizontalGitPack.id(hex: value) == nil ? nil : value.lowercased()
        }
        let packed = (try? String(contentsOf: gitDirectory.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[1] == name, HorizontalGitPack.id(hex: String(fields[0])) != nil {
                return fields[0].lowercased()
            }
        }
        return nil
    }

    /// Points `name` at `commit` as git does: a lock file written, then moved
    /// over the ref, and the reflog told when there is one.
    static func setRef(_ name: String, to commit: String, from old: String?, in gitDirectory: URL, message: String) throws {
        let url = gitDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = URL(fileURLWithPath: url.path + ".lock")
        try HorizontalGitLock.create(lock, contents: Data("\(commit)\n".utf8))
        do {
            try HorizontalGitLock.commit(lock, over: url)
        } catch {
            try? FileManager.default.removeItem(at: lock)
            throw error
        }
        appendReflog(gitDirectory.appendingPathComponent("logs").appendingPathComponent(name), old: old, new: commit, message: message)
    }

    /// One line on a reflog that exists; a ref without one stays without.
    static func appendReflog(_ url: URL, old: String?, new: String, message: String) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        let seconds = Int(Date().timeIntervalSince1970)
        let offset = TimeZone.current.secondsFromGMT()
        let zone = String(format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, (abs(offset) % 3600) / 60)
        let zero = String(repeating: "0", count: 40)
        let line = "\(old ?? zero) \(new) Horizontal <horizontal@localhost> \(seconds) \(zone)\t\(message)\n"
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// Git's lock files: `<file>.lock` made only if none is there, which is how
/// git keeps two writers apart, then renamed over the file.
enum HorizontalGitLock {
    static func create(_ lock: URL, contents: Data? = nil) throws {
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw HorizontalGitUpdateError.locked(lock.lastPathComponent) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lock.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        if let contents {
            try handle.write(contentsOf: contents)
        }
        try handle.close()
    }

    static func commit(_ lock: URL, over url: URL) throws {
        guard rename(lock.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

enum HorizontalGitUpdateError: LocalizedError, Equatable {
    case notOnBranch
    case noUpstream(String)
    case unsupported(String)
    case unreachableRemote(String)
    case noRemoteBranch(String)
    case diverged
    case localChanges([String])
    case inTheWay([String])
    case locked(String)
    case signInNeeded(String)

    var errorDescription: String? {
        switch self {
        case .notOnBranch:
            "It isn't on a branch (its HEAD is detached); check a branch out with git first."
        case .noUpstream(let branch):
            "Its branch \(branch) doesn't track a remote branch."
        case .unsupported(let why):
            "Horizontal can't update it: \(why)."
        case .unreachableRemote(let remote):
            "Horizontal can only fetch over HTTPS, and \(remote) isn't an address it can reach that way."
        case .noRemoteBranch(let branch):
            "The remote has no branch \(branch)."
        case .diverged:
            "It has commits of its own that the remote doesn't, and the remote has moved on; merge them with git."
        case .localChanges(let paths):
            "It has changes the update would overwrite: \(Self.list(paths)). Commit or discard them with git, then update."
        case .inTheWay(let paths):
            "Files the update would write are in the way: \(Self.list(paths)). Move them aside, then update."
        case .locked(let file):
            "Another git is working in it (\(file) is there). Wait for it to finish, or remove \(file) if none is."
        case .signInNeeded(let host):
            "\(host) asked for a sign-in, which Horizontal can't give yet: a private pool needs SSH, which isn't supported yet."
        }
    }

    private static func list(_ paths: [String]) -> String {
        let shown = paths.prefix(5).joined(separator: ", ")
        return paths.count > 5 ? "\(shown) and \(paths.count - 5) more" : shown
    }
}
