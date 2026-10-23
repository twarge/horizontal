import Foundation

/// A clone over HTTPS, built into the app so it works in the Mac's sandbox
/// and on iPad, where there is no git to run: the server's refs, one pack of
/// the default branch's whole history, and a checkout of it, left as an
/// ordinary repository (`HorizontalGitRepository`) that git can `pull` later.
/// It fetches the remote's HEAD branch alone and speaks protocol version 0,
/// which every smart HTTP server answers; SSH, authentication and fetching
/// into an existing clone are for later.
enum HorizontalGitClone {
    struct Progress: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case connecting
            /// Bytes of the pack received so far.
            case receiving
            /// Objects of the pack read and named.
            case indexing
            /// Files written.
            case checkingOut
        }

        var phase: Phase
        var completed: Int = 0
        var total: Int? = nil

        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(completed) / Double(total))
        }
    }

    struct Result: Equatable, Sendable {
        var branch: String
        var commit: String
        var objects: Int
    }

    /// Clones `remote` into `directory`, which must not exist or be empty. A
    /// clone that fails or is cancelled takes back what it wrote.
    static func clone(
        _ remote: URL,
        into directory: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
        if existed {
            guard isDirectory.boolValue, (try fileManager.contentsOfDirectory(atPath: directory.path)).filter({ $0 != ".DS_Store" }).isEmpty else {
                throw HorizontalGitCloneError.destinationNotEmpty(directory.path)
            }
        }
        do {
            progress(Progress(phase: .connecting))
            let advertisement = try HorizontalGitProtocol.advertisement(from: try await get(
                endpoint(remote, "info/refs?service=git-upload-pack"),
                session: session
            ))
            let branch = advertisement.headBranch
                ?? ["refs/heads/main", "refs/heads/master"].first { advertisement.id(of: $0) != nil }
                ?? advertisement.refs.first { $0.name.hasPrefix("refs/heads/") }?.name
            guard let branch, let commit = advertisement.id(of: branch), let commitID = HorizontalGitPack.id(hex: commit) else {
                throw HorizontalGitCloneError.noBranch
            }
            let sideBand = HorizontalGitProtocol.SideBand(advertisement.capabilities)
            let response = try await post(
                endpoint(remote, "git-upload-pack"),
                body: HorizontalGitProtocol.uploadPackRequest(want: commit, capabilities: advertisement.capabilities),
                session: session
            ) { received in
                progress(Progress(phase: .receiving, completed: received))
            }
            let packData = try HorizontalGitProtocol.pack(fromUploadPackResponse: response, sideBand: sideBand)
            try Task.checkCancellation()

            let pack = try HorizontalGitPack(packData)
            try pack.index { done, total in
                progress(Progress(phase: .indexing, completed: done, total: total))
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try HorizontalGitRepository.writeRepository(
                pack: packData, packObjects: pack, branch: branch, commit: commit, remote: remote, into: directory
            )
            try HorizontalGitRepository.checkOut(commit: commitID, from: pack, into: directory) { done, total in
                progress(Progress(phase: .checkingOut, completed: done, total: total))
            }
            return Result(branch: branch, commit: commit, objects: pack.objectCount)
        } catch {
            // Back to how it was: gone, or the empty folder it was.
            if existed {
                for item in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    try? fileManager.removeItem(at: item)
                }
            } else {
                try? fileManager.removeItem(at: directory)
            }
            throw error
        }
    }

    /// `remote` with a path after it, as git's smart HTTP clients form them.
    static func endpoint(_ remote: URL, _ path: String) -> URL {
        var base = remote.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + path)!
    }

    private static let userAgent = "git/2.0 (Horizontal)"

    static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    static func post(
        _ url: URL,
        body: Data,
        session: URLSession,
        received: @escaping @Sendable (Int) -> Void
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-git-upload-pack-request", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-git-upload-pack-result", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        // Read in blocks, telling how far it has got every 256 KB.
        var data = Data()
        var block = [UInt8]()
        block.reserveCapacity(1 << 16)
        var reported = 0
        for try await byte in bytes {
            block.append(byte)
            if block.count == 1 << 16 {
                data.append(contentsOf: block)
                block.removeAll(keepingCapacity: true)
                if data.count - reported >= 1 << 18 {
                    reported = data.count
                    received(reported)
                }
            }
        }
        data.append(contentsOf: block)
        received(data.count)
        return data
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HorizontalGitCloneError.http(http.statusCode)
        }
    }
}
