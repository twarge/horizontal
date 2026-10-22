import Foundation
import XCTest
@testable import HorizontalNative

/// The built-in clone, judged by git itself: a history git packs is read,
/// written out and checked out, and the result passes `git fsck`, has
/// nothing for `git status` to report and is on the same commit.
final class HorizontalGitCloneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HorizontalGitCloneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL, input: Data? = nil) throws -> Data {
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
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(errorText)"])
        }
        return data
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A history with nested folders, an executable, a symlink, an empty
    /// file and a file edited many times, so the pack holds deltas.
    private func makeSource() throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("parts/passive", isDirectory: true), withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "master"], in: source)
        var long = (0..<400).map { "line \($0) of a pool item that changes a little each commit" }
        for commit in 0..<12 {
            long[commit * 7] = "edited in commit \(commit)"
            try Data(long.joined(separator: "\n").utf8).write(to: source.appendingPathComponent("parts/passive/resistor.json"))
            try Data("{\"commit\": \(commit)}\n".utf8).write(to: source.appendingPathComponent("pool.json"))
            if commit == 0 {
                try Data("#!/bin/sh\necho update\n".utf8).write(to: source.appendingPathComponent("update.sh"))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("update.sh").path)
                try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("latest").path, withDestinationPath: "parts/passive/resistor.json")
                try Data().write(to: source.appendingPathComponent("parts/empty.json"))
                try Data((0..<4096).map { UInt8($0 % 251) }).write(to: source.appendingPathComponent("parts/model.step"))
            }
            try git(["add", "-A"], in: source)
            try git(["commit", "-q", "-m", "commit \(commit)"], in: source)
        }
        try git(["repack", "-adq", "--depth=50", "--window=50"], in: source)
        return source
    }

    private func clone(pack packData: Data, branch: String = "refs/heads/master", head: String, into destination: URL) throws -> HorizontalGitPack {
        let pack = try HorizontalGitPack(packData)
        try pack.index()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try HorizontalGitRepository.writeRepository(pack: packData, packObjects: pack, branch: branch, commit: head,
                                                    remote: URL(string: "https://example.com/pool.git")!, into: destination)
        try HorizontalGitRepository.checkOut(commit: HorizontalGitPack.id(hex: head)!, from: pack, into: destination)
        return pack
    }

    func testAPackGitWritesIsClonedIntoARepositoryGitAccepts() throws {
        let source = try makeSource()
        let head = text(try git(["rev-parse", "HEAD"], in: source))
        for offsets in [true, false] {
            // Deltas on a base by its offset, and by its name.
            let packData = try git(["pack-objects", "--stdout", "--revs", "-q"] + (offsets ? ["--delta-base-offset"] : []),
                                   in: source, input: Data("HEAD\n".utf8))
            let destination = root.appendingPathComponent(offsets ? "clone-ofs" : "clone-ref", isDirectory: true)
            let pack = try clone(pack: packData, head: head, into: destination)

            XCTAssertGreaterThan(pack.objectCount, 30)
            XCTAssertEqual(text(try git(["rev-parse", "HEAD"], in: destination)), head)
            XCTAssertEqual(text(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: destination)), "master")
            try git(["fsck", "--full", "--strict"], in: destination)
            XCTAssertEqual(text(try git(["status", "--porcelain", "--untracked-files=all"], in: destination)), "",
                           "the index and the files agree with the commit")
            XCTAssertEqual(text(try git(["rev-list", "--count", "HEAD"], in: destination)), "12", "the whole history came")
            XCTAssertEqual(text(try git(["config", "remote.origin.url"], in: destination)), "https://example.com/pool.git")
            XCTAssertEqual(text(try git(["rev-parse", "origin/master"], in: destination)), head)
            // What the files are, not only that git agrees.
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("pool.json"), encoding: .utf8), "{\"commit\": 11}\n")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appendingPathComponent("update.sh").path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("latest").path),
                           "parts/passive/resistor.json")
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("parts/empty.json")).count, 0)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("parts/model.step")),
                           try Data(contentsOf: source.appendingPathComponent("parts/model.step")))
        }
    }

    func testTheIndexOfThePackIsTheOneGitWrites() throws {
        let source = try makeSource()
        let packData = try git(["pack-objects", "--stdout", "--revs", "-q", "--delta-base-offset"], in: source, input: Data("HEAD\n".utf8))
        let pack = try HorizontalGitPack(packData)
        try pack.index()
        let packURL = root.appendingPathComponent("check.pack")
        try packData.write(to: packURL)
        // git index-pack writes the index from the pack alone.
        try git(["index-pack", packURL.path], in: source)
        XCTAssertEqual(pack.indexFile(), try Data(contentsOf: root.appendingPathComponent("check.idx")), "byte for byte")
    }

    func testACorruptPackIsRefused() throws {
        let source = try makeSource()
        var packData = try git(["pack-objects", "--stdout", "--revs", "-q"], in: source, input: Data("HEAD\n".utf8))
        packData[packData.count / 2] ^= 0xFF
        XCTAssertThrowsError(try HorizontalGitPack(packData)) { error in
            XCTAssertEqual(error as? HorizontalGitCloneError, .corruptPack("its checksum doesn't match"))
        }
    }

    // MARK: - Protocol

    func testTheAdvertisementNamesTheRefsAndHeadsBranch() throws {
        var reply = HorizontalGitProtocol.pktLine("# service=git-upload-pack\n")
        reply.append(HorizontalGitProtocol.flush)
        let head = String(repeating: "a", count: 40)
        let tag = String(repeating: "b", count: 40)
        reply.append(HorizontalGitProtocol.pktLine("\(head) HEAD\0multi_ack side-band-64k ofs-delta symref=HEAD:refs/heads/master agent=git/github\n"))
        reply.append(HorizontalGitProtocol.pktLine("\(head) refs/heads/master\n"))
        reply.append(HorizontalGitProtocol.pktLine("\(tag) refs/tags/v1\n"))
        reply.append(HorizontalGitProtocol.pktLine("\(head) refs/tags/v1^{}\n"))
        reply.append(HorizontalGitProtocol.flush)
        let advertisement = try HorizontalGitProtocol.advertisement(from: reply)
        XCTAssertEqual(advertisement.headBranch, "refs/heads/master")
        XCTAssertEqual(advertisement.id(of: "refs/heads/master"), head)
        XCTAssertEqual(advertisement.refs.map(\.name), ["HEAD", "refs/heads/master", "refs/tags/v1"], "a peeled tag isn't a ref")
        XCTAssertEqual(HorizontalGitProtocol.SideBand(advertisement.capabilities), .large)

        let request = String(decoding: HorizontalGitProtocol.uploadPackRequest(want: head, capabilities: advertisement.capabilities), as: UTF8.self)
        XCTAssertEqual(request, "005dwant \(head) side-band-64k ofs-delta agent=horizontal/1\n00000009done\n")

        XCTAssertThrowsError(try HorizontalGitProtocol.advertisement(from: Data("\(head)\trefs/heads/master\n".utf8)),
                             "a dumb server's plain list")
    }

    func testThePackComesOutOfTheSideBandAndAServerErrorIsReported() throws {
        var reply = HorizontalGitProtocol.pktLine("NAK\n")
        reply.append(HorizontalGitProtocol.pktLine(Data([2]) + Data("Counting objects: 3\n".utf8)))
        reply.append(HorizontalGitProtocol.pktLine(Data([1]) + Data("PACK".utf8)))
        reply.append(HorizontalGitProtocol.pktLine(Data([1]) + Data([0, 0, 0, 2])))
        reply.append(HorizontalGitProtocol.flush)
        XCTAssertEqual(try HorizontalGitProtocol.pack(fromUploadPackResponse: reply, sideBand: .large), Data("PACK".utf8) + Data([0, 0, 0, 2]))

        var failed = HorizontalGitProtocol.pktLine("NAK\n")
        failed.append(HorizontalGitProtocol.pktLine(Data([3]) + Data("upload-pack: not our ref\n".utf8)))
        XCTAssertThrowsError(try HorizontalGitProtocol.pack(fromUploadPackResponse: failed, sideBand: .large)) { error in
            XCTAssertEqual(error as? HorizontalGitCloneError, .server("upload-pack: not our ref"))
        }
        XCTAssertEqual(try HorizontalGitProtocol.pack(fromUploadPackResponse: HorizontalGitProtocol.pktLine("NAK\n") + Data("PACK".utf8), sideBand: .none),
                       Data("PACK".utf8))
    }

    func testEndpointsFollowTheRemote() {
        let remote = URL(string: "https://github.com/horizon-eda/horizon-pool.git/")!
        XCTAssertEqual(HorizontalGitClone.endpoint(remote, "info/refs?service=git-upload-pack").absoluteString,
                       "https://github.com/horizon-eda/horizon-pool.git/info/refs?service=git-upload-pack")
    }

    /// Over the network, when asked: HORIZONTAL_NETWORK_TESTS=1.
    func testCloningAPublicRepositoryOverHTTPS() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HORIZONTAL_NETWORK_TESTS"] == "1", "set HORIZONTAL_NETWORK_TESTS=1")
        let remote = URL(string: ProcessInfo.processInfo.environment["HORIZONTAL_CLONE_URL"] ?? "https://github.com/octocat/Hello-World.git")!
        let destination = root.appendingPathComponent("network-clone", isDirectory: true)
        let result = try await HorizontalGitClone.clone(remote, into: destination)
        XCTAssertEqual(text(try git(["rev-parse", "HEAD"], in: destination)), result.commit)
        try git(["fsck", "--full"], in: destination)
        XCTAssertEqual(text(try git(["status", "--porcelain"], in: destination)), "")
    }

    func testAFolderWithFilesInItIsRefused() async throws {
        let destination = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: destination.appendingPathComponent("notes.txt"))
        do {
            _ = try await HorizontalGitClone.clone(URL(string: "https://example.invalid/pool.git")!, into: destination)
            XCTFail("it cloned into a folder with files in it")
        } catch {
            XCTAssertEqual(error as? HorizontalGitCloneError, .destinationNotEmpty(destination.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes.txt").path), "and left the folder alone")
    }
}

/// The offer's clone: where it goes, and that what it leaves is registered.
@MainActor
final class HorizontalDefaultPoolCloneTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HorizontalDefaultPoolCloneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        HorizontalPoolRegistryStore.defaults = try XCTUnwrap(UserDefaults(suiteName: "HorizontalDefaultPoolCloneTests-\(UUID().uuidString)"))
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDown() async throws {
        for url in HorizontalPoolRegistryStore.poolURLs() {
            HorizontalPoolRegistryStore.removePool(at: url)
        }
        HorizontalPoolRegistryStore.defaults = .standard
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: root)
    }

    private func writeDefaultPool(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"type\": \"pool\", \"uuid\": \"\(HorizontalDefaultPool.uuid)\", \"name\": \"Default pool\"}\n".utf8)
            .write(to: folder.appendingPathComponent("pool.json"))
    }

    private func settle(_ clone: HorizontalDefaultPoolClone, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while case .cloning = clone.state {
            guard Date() < deadline else { return XCTFail("the clone didn't finish") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testTheCloneGoesIntoAnEmptyFolderOrANewFolderInIt() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(HorizontalDefaultPool.destination(in: empty), empty)

        let documents = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: documents.appendingPathComponent("notes.txt"))
        XCTAssertEqual(HorizontalDefaultPool.destination(in: documents), documents.appendingPathComponent("horizon-pool", isDirectory: true))

        // The clone itself, picked again, isn't cloned into.
        let pool = root.appendingPathComponent("pool", isDirectory: true)
        try writeDefaultPool(in: pool)
        XCTAssertEqual(HorizontalDefaultPool.destination(in: pool), pool)
    }

    func testAFolderHoldingTheDefaultPoolIsRegisteredAsItIs() async throws {
        try writeDefaultPool(in: root.appendingPathComponent("horizon-pool", isDirectory: true))
        try Data("mine".utf8).write(to: root.appendingPathComponent("notes.txt"))
        XCTAssertFalse(HorizontalDefaultPool.isRegistered)

        let clone = HorizontalDefaultPoolClone()
        clone.start(in: root)
        try await settle(clone)
        let pool = root.appendingPathComponent("horizon-pool", isDirectory: true)
        XCTAssertEqual(clone.state, .finished(pool))
        XCTAssertTrue(HorizontalDefaultPool.isRegistered)
        XCTAssertEqual(HorizontalPoolRegistryStore.poolURLs().map(\.standardizedFileURL), [pool.standardizedFileURL])
        XCTAssertFalse(HorizontalDefaultPool.shouldOfferAtLaunch, "not offered to someone who has it")
    }

    /// Over the network, when asked: HORIZONTAL_NETWORK_TESTS=1. The whole
    /// default pool, about 15 s.
    func testTheDefaultPoolIsClonedAndRegistered() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HORIZONTAL_NETWORK_TESTS"] == "1", "set HORIZONTAL_NETWORK_TESTS=1")
        let clone = HorizontalDefaultPoolClone()
        clone.start(in: root)
        try await settle(clone, timeout: 600)
        XCTAssertEqual(clone.state, .finished(root))
        XCTAssertTrue(HorizontalDefaultPool.isDefaultPool(root))
        XCTAssertTrue(HorizontalDefaultPool.isRegistered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/config").path))
    }

    func testCancellingTheCloneTakesBackWhatItWrote() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HORIZONTAL_NETWORK_TESTS"] == "1", "set HORIZONTAL_NETWORK_TESTS=1")
        let clone = HorizontalDefaultPoolClone()
        clone.start(in: root)
        // Partway through the download.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if case .cloning(let progress) = clone.state, progress.phase == .receiving { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        clone.cancel()
        try await settle(clone)
        XCTAssertEqual(clone.state, .offer)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "the folder is as it was")
        XCTAssertFalse(HorizontalDefaultPool.isRegistered)
    }
}
