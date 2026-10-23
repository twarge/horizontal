import Foundation
import XCTest
@testable import HorizontalNative

/// An HTTPS git server in the test process: `https://git.test/<name>`
/// answers as a smart HTTP server does, by running git's own
/// `upload-pack --stateless-rpc` on the repository the name is given.
final class HorizontalLocalGitServer: URLProtocol {
    nonisolated(unsafe) static var repositories = [String: URL]()
    /// Names answered with this HTTP status instead.
    nonisolated(unsafe) static var refusals = [String: Int]()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HorizontalLocalGitServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "git.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let name = String(url.path.split(separator: "/").first ?? "")
        func respond(_ status: Int, _ body: Data, type: String = "text/plain") {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if let status = Self.refusals[name] {
            return respond(status, Data())
        }
        guard let repository = Self.repositories[name] else {
            return respond(404, Data())
        }
        do {
            if url.path.hasSuffix("/info/refs") {
                var body = HorizontalGitProtocol.pktLine("# service=git-upload-pack\n")
                body.append(HorizontalGitProtocol.flush)
                body.append(try Self.uploadPack(["--stateless-rpc", "--advertise-refs", repository.path], input: nil))
                respond(200, body, type: "application/x-git-upload-pack-advertisement")
            } else {
                var input = request.httpBody ?? Data()
                if input.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    var buffer = [UInt8](repeating: 0, count: 1 << 16)
                    while stream.hasBytesAvailable {
                        let read = stream.read(&buffer, maxLength: buffer.count)
                        if read <= 0 { break }
                        input.append(contentsOf: buffer[0..<read])
                    }
                    stream.close()
                }
                respond(200, try Self.uploadPack(["--stateless-rpc", repository.path], input: input), type: "application/x-git-upload-pack-result")
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func uploadPack(_ arguments: [String], input: Data?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["upload-pack"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// Updating a checkout from its remote, judged by git itself: after an
/// update the checkout is on the remote's commit with nothing for
/// `git status` to report, and an update that would lose something leaves
/// the checkout as it was.
final class HorizontalGitPullTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private let remote = URL(string: "https://git.test/pool.git")!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HorizontalGitPullTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        HorizontalLocalGitServer.repositories = ["pool.git": source]
        HorizontalLocalGitServer.refusals = [:]
        session = HorizontalLocalGitServer.session()
        try makeSource()
    }

    override func tearDownWithError() throws {
        HorizontalLocalGitServer.repositories = [:]
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                               "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
                               "HOME": root.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(errorText)"])
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, _ path: String, in directory: URL, executable: Bool = false) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    private func commit(_ message: String) throws {
        try git(["add", "-A"], in: source)
        try git(["commit", "-q", "-m", message], in: source)
    }

    /// A pool with folders, an executable, a symlink and a long file edited
    /// over several commits, partly packed and partly loose.
    private func makeSource() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "master"], in: source)
        var long = (0..<300).map { "line \($0) of a part that changes a little" }
        for number in 0..<4 {
            long[number * 9] = "edited \(number)"
            try write(long.joined(separator: "\n"), "parts/passive/resistor.json", in: source)
            try write("{\"version\": \(number)}\n", "pool.json", in: source)
            if number == 0 {
                try write("#!/bin/sh\n", "tools/update.sh", in: source, executable: true)
                try write("old\n", "parts/stays.json", in: source)
                try write("goes\n", "parts/goes.json", in: source)
                try write("a file\n", "becomes", in: source)
                try write("in a folder\n", "folder/inside.json", in: source)
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("latest").path, withDestinationPath: "pool.json")
            }
            try commit("commit \(number)")
        }
        try git(["repack", "-adq"], in: source)
        try write("loose\n", "parts/loose.json", in: source)
        try commit("a loose commit")
    }

    /// The next commits the remote has: a file edited, one removed, one
    /// added in a new folder, an executable made plain, a file that becomes
    /// a folder and a folder that becomes a file, and a link retargeted.
    private func advanceSource() throws {
        try write("{\"version\": 9}\n", "pool.json", in: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("parts/goes.json"))
        try write("new\n", "parts/new/added.json", in: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.appendingPathComponent("tools/update.sh").path)
        try commit("remote 1")
        try FileManager.default.removeItem(at: source.appendingPathComponent("becomes"))
        try write("now a folder\n", "becomes/file.json", in: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("folder"))
        try write("now a file\n", "folder", in: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("latest"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("latest").path, withDestinationPath: "parts/new/added.json")
        try commit("remote 2")
    }

    private func cloneWithHorizontal() async throws -> URL {
        let local = root.appendingPathComponent("local-\(UUID().uuidString.prefix(6))", isDirectory: true)
        _ = try await HorizontalGitClone.clone(remote, into: local, session: session)
        return local
    }

    private func cloneWithGit() throws -> URL {
        let local = root.appendingPathComponent("git-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try git(["clone", "-q", source.path, local.path], in: root)
        try git(["remote", "set-url", "origin", remote.absoluteString], in: local)
        return local
    }

    /// Every file of the source's checkout is in `local`, the same.
    private func assertSameFiles(_ local: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let tracked = try git(["ls-files"], in: source).split(separator: "\n").map(String.init)
        XCTAssertEqual(try git(["ls-files"], in: local).split(separator: "\n").map(String.init), tracked, file: file, line: line)
        for path in tracked {
            let a = source.appendingPathComponent(path), b = local.appendingPathComponent(path)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: a.path) {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: b.path), target, path, file: file, line: line)
            } else {
                XCTAssertEqual(try Data(contentsOf: b), try Data(contentsOf: a), path, file: file, line: line)
                XCTAssertEqual(FileManager.default.isExecutableFile(atPath: b.path), FileManager.default.isExecutableFile(atPath: a.path), path, file: file, line: line)
            }
        }
    }

    func testAnUpdateFastForwardsAHorizontalCloneAndAGitClone() async throws {
        let ours = try await cloneWithHorizontal()
        let theirs = try cloneWithGit()
        let before = try git(["rev-parse", "HEAD"], in: source)
        try advanceSource()
        let after = try git(["rev-parse", "HEAD"], in: source)
        for local in [ours, theirs] {
            let available = try await HorizontalGitPull.check(local, session: session)
            XCTAssertEqual(available, .available(remote: after))
            let outcome = try await HorizontalGitPull.update(local, session: session)
            XCTAssertEqual(outcome, .updated(from: before, to: after, commits: 2, files: 9))
            XCTAssertEqual(try git(["rev-parse", "HEAD"], in: local), after)
            XCTAssertEqual(try git(["rev-parse", "origin/master"], in: local), after)
            XCTAssertEqual(try git(["rev-parse", "ORIG_HEAD"], in: local), before)
            XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: local), "",
                           "the files and the index are the commit's")
            try git(["fsck", "--full", "--strict"], in: local)
            try assertSameFiles(local)
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("folder/inside.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("parts/goes.json").path))
            let again = try await HorizontalGitPull.update(local, session: session)
            XCTAssertEqual(again, .upToDate(commit: after))
            let checked = try await HorizontalGitPull.check(local, session: session)
            XCTAssertEqual(checked, .upToDate)
        }
        XCTAssertTrue(try git(["reflog", "-1", "--format=%gs"], in: theirs).contains("pull: Fast-forward"), "git's reflog is told")
    }

    func testAnEditTheUpdateWouldOverwriteLeavesTheCheckoutAsItWas() async throws {
        let local = try cloneWithGit()
        let head = try git(["rev-parse", "HEAD"], in: local)
        try write("my own edit\n", "pool.json", in: local)
        try advanceSource()
        do {
            _ = try await HorizontalGitPull.update(local, session: session)
            XCTFail("it overwrote an edit")
        } catch {
            XCTAssertEqual(error as? HorizontalGitUpdateError, .localChanges(["pool.json"]))
        }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: local), head)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("pool.json"), encoding: .utf8), "my own edit\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: local), "M pool.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent(".git/index.lock").path))
        try git(["fsck", "--full"], in: local)

        // Staged rather than edited, it is refused the same.
        try git(["add", "pool.json"], in: local)
        do {
            _ = try await HorizontalGitPull.update(local, session: session)
            XCTFail("it overwrote a staged edit")
        } catch {
            XCTAssertEqual(error as? HorizontalGitUpdateError, .localChanges(["pool.json"]))
        }
    }

    func testAnEditToAFileTheUpdateLeavesAloneStays() async throws {
        let local = try cloneWithGit()
        try write("my own edit\n", "parts/stays.json", in: local)
        try advanceSource()
        let outcome = try await HorizontalGitPull.update(local, session: session)
        guard case .updated = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("parts/stays.json"), encoding: .utf8), "my own edit\n")
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: local), "M parts/stays.json",
                       "git still sees the edit")
    }

    func testAnUntrackedFileWhereTheUpdateWritesIsInTheWay() async throws {
        let local = try cloneWithGit()
        try write("mine\n", "parts/new/added.json", in: local)
        try advanceSource()
        do {
            _ = try await HorizontalGitPull.update(local, session: session)
            XCTFail("it wrote over an untracked file")
        } catch {
            XCTAssertEqual(error as? HorizontalGitUpdateError, .inTheWay(["parts/new/added.json"]))
        }
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("parts/new/added.json"), encoding: .utf8), "mine\n")
    }

    func testCommitsOfItsOwnAreAheadAndADivergedCheckoutIsLeftAlone() async throws {
        let local = try cloneWithGit()
        try write("local\n", "parts/local.json", in: local)
        try git(["add", "-A"], in: local)
        try git(["commit", "-q", "-m", "a commit of its own"], in: local)
        let own = try git(["rev-parse", "HEAD"], in: local)
        let checked = try await HorizontalGitPull.check(local, session: session)
        XCTAssertEqual(checked, .ahead)
        let ahead = try await HorizontalGitPull.update(local, session: session)
        XCTAssertEqual(ahead, .ahead(commit: own))
        try advanceSource()
        do {
            _ = try await HorizontalGitPull.update(local, session: session)
            XCTFail("it moved a branch with commits of its own")
        } catch {
            XCTAssertEqual(error as? HorizontalGitUpdateError, .diverged)
        }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: local), own)
        XCTAssertEqual(try git(["status", "--porcelain"], in: local), "")
    }

    func testAPrivateRemoteAsksForASignIn() async throws {
        let local = try cloneWithGit()
        HorizontalLocalGitServer.refusals["pool.git"] = 401
        do {
            _ = try await HorizontalGitPull.update(local, session: session)
            XCTFail("it updated without the server")
        } catch {
            XCTAssertEqual(error as? HorizontalGitUpdateError, .signInNeeded("git.test"))
        }
    }

    func testTheCheckoutIsReadFromItsGitFolder() throws {
        let local = try cloneWithGit()
        try git(["remote", "set-url", "origin", "git@github.com:horizon-eda/horizon-pool.git"], in: local)
        let checkout = try XCTUnwrap(try HorizontalGitCheckout.read(local))
        XCTAssertEqual(checkout.branch, "master")
        XCTAssertEqual(checkout.head, try git(["rev-parse", "HEAD"], in: local))
        XCTAssertEqual(checkout.upstream, "refs/heads/master")
        XCTAssertEqual(checkout.trackingRef, "refs/remotes/origin/master")
        XCTAssertEqual(checkout.fetchURL, URL(string: "https://github.com/horizon-eda/horizon-pool.git"))
        XCTAssertFalse(checkout.remoteIsHTTP)
        XCTAssertEqual(checkout.remoteDescription, "github.com/horizon-eda/horizon-pool")
        // Packed by git gc, the branch is still found.
        try git(["pack-refs", "--all"], in: local)
        XCTAssertEqual(try HorizontalGitCheckout.read(local)?.head, checkout.head)
        XCTAssertNil(try HorizontalGitCheckout.read(root), "a folder that isn't a checkout")
        try git(["checkout", "-q", "--detach"], in: local)
        XCTAssertThrowsError(try HorizontalGitCheckout.read(local)) { error in
            XCTAssertEqual(error as? HorizontalGitUpdateError, .notOnBranch)
        }
    }

    func testRemotesAreFetchedOverHTTPS() {
        XCTAssertEqual(HorizontalGitCheckout.fetchURL(forRemote: "https://example.com/a/b.git"), URL(string: "https://example.com/a/b.git"))
        XCTAssertEqual(HorizontalGitCheckout.fetchURL(forRemote: "git@gitlab.com:group/pool.git"), URL(string: "https://gitlab.com/group/pool.git"))
        XCTAssertEqual(HorizontalGitCheckout.fetchURL(forRemote: "ssh://git@github.com/twarge/pool.git"), URL(string: "https://github.com/twarge/pool.git"))
        XCTAssertNil(HorizontalGitCheckout.fetchURL(forRemote: "/Users/me/pool"))
        XCTAssertNil(HorizontalGitCheckout.fetchURL(forRemote: "file:///Users/me/pool"))
    }

    func testConfigValuesAreReadAsGitReadsThem() {
        let config = HorizontalGitConfig("""
        [core]
        \tbare = false ; a comment
        [remote "Origin"]
        \turl = "https://example.com/pool.git" # trailing
        [branch "main"]
        \tremote = Origin
        \tmerge = refs/heads/main
        [Remote.second]
        \tURL = https://second
        [http]
        \tsslVerify
        """)
        XCTAssertEqual(config.value("core", "bare"), "false")
        XCTAssertEqual(config.value("remote", "Origin", "url"), "https://example.com/pool.git")
        XCTAssertNil(config.value("remote", "origin", "url"), "a subsection keeps its case")
        XCTAssertEqual(config.value("branch", "main", "merge"), "refs/heads/main")
        XCTAssertEqual(config.value("remote", "second", "url"), "https://second")
        XCTAssertEqual(config.value("http", "sslverify"), "true")
    }
}

extension HorizontalGitPullTests {
    /// Over the network, when asked: HORIZONTAL_NETWORK_TESTS=1. A checkout of
    /// Horizon's default pool thirty commits behind, holding only their
    /// objects, is brought up to date from GitHub.
    func testAPoolBehindGitHubIsUpdatedFromIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HORIZONTAL_NETWORK_TESTS"] == "1", "set HORIZONTAL_NETWORK_TESTS=1")
        let url = ProcessInfo.processInfo.environment["HORIZONTAL_UPDATE_URL"] ?? "https://github.com/horizon-eda/horizon-pool.git"
        let bare = root.appendingPathComponent("bare.git", isDirectory: true)
        try git(["clone", "-q", "--bare", url, bare.path], in: root)
        let branch = try git(["symbolic-ref", "--short", "HEAD"], in: bare)
        let tip = try git(["rev-parse", "HEAD"], in: bare)
        try git(["update-ref", "refs/heads/\(branch)", "HEAD~30"], in: bare)
        let behind = root.appendingPathComponent("behind", isDirectory: true)
        try git(["clone", "-q", "--no-local", "file://\(bare.path)", behind.path], in: root)
        try git(["remote", "set-url", "origin", url], in: behind)
        let old = try git(["rev-parse", "HEAD"], in: behind)
        XCTAssertThrowsError(try git(["cat-file", "-e", tip], in: behind), "the newer commits aren't there yet")

        let outcome = try await HorizontalGitPull.update(behind)
        guard case .updated(let from, let to, let commits, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(from, old)
        XCTAssertGreaterThanOrEqual(commits, 30)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: behind), to)
        XCTAssertEqual(try git(["status", "--porcelain", "--untracked-files=all"], in: behind), "")
        try git(["fsck", "--full"], in: behind)
    }
}
