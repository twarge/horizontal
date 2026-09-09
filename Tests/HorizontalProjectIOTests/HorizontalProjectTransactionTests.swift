import Foundation
import XCTest
@testable import HorizontalProjectIO

final class HorizontalProjectTransactionTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("horizontal-transaction-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.json"), b = root.appendingPathComponent("b.json")
        try Data("a0".utf8).write(to: a); try Data("b0".utf8).write(to: b)
        return (root.appendingPathComponent("project.hprj"), a, b)
    }

    func testFailureAtEveryReplacementRestoresEveryFile() throws {
        for failAt in 0...1 {
            let (project, a, b) = try fixture()
            let transaction = try HorizontalProjectTransaction(projectURL: project)
            let changes = [HorizontalProjectTransaction.Update(url: a, before: Data("a0".utf8), after: Data("a1".utf8)),
                           .init(url: b, before: Data("b0".utf8), after: Data("b1".utf8))]
            XCTAssertThrowsError(try transaction.commit(changes, afterReplace: { if $0 == failAt { throw CocoaError(.fileWriteOutOfSpace) } }))
            XCTAssertEqual(try Data(contentsOf: a), Data("a0".utf8))
            XCTAssertEqual(try Data(contentsOf: b), Data("b0".utf8))
        }
    }

    func testRecoveryPreservesThirdPartyWritesAndRetainsJournal() throws {
        let (project, a, b) = try fixture()
        let transaction = try HorizontalProjectTransaction(projectURL: project)
        let changes = [HorizontalProjectTransaction.Update(url: a, before: Data("a0".utf8), after: Data("a1".utf8)),
                       .init(url: b, before: Data("b0".utf8), after: Data("b1".utf8))]
        XCTAssertThrowsError(try transaction.commit(changes, afterReplace: { index in
            if index == 0 { try Data("external".utf8).write(to: b); throw CocoaError(.fileWriteOutOfSpace) }
        }))
        XCTAssertEqual(try Data(contentsOf: b), Data("external".utf8))
        XCTAssertThrowsError(try transaction.recover())
        // Once the conflict is resolved to a recorded state, recovery completes.
        try Data("b0".utf8).write(to: b)
        try transaction.recover()
        XCTAssertEqual(try Data(contentsOf: a), Data("a0".utf8))
    }

    func testValidationFailureRemovesNewFilesAndCommitPersistsReceipt() throws {
        let (project, a, b) = try fixture()
        let new = b.deletingLastPathComponent().appendingPathComponent("created.json")
        let transaction = try HorizontalProjectTransaction(projectURL: project)
        let updates = [HorizontalProjectTransaction.Update(url: new, before: nil, after: Data("new".utf8))]
        XCTAssertThrowsError(try transaction.commit(updates, validate: { throw CocoaError(.fileReadCorruptFile) }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        try transaction.commit([.init(url: a, before: Data("a0".utf8), after: Data("a1".utf8))], operationID: "op1", receipt: Data("receipt".utf8))
        XCTAssertEqual(try transaction.receipt(operationID: "op1"), Data("receipt".utf8))
        try transaction.recover()
        XCTAssertEqual(try Data(contentsOf: a), Data("a1".utf8))
    }

    func testInterruptedPreparedAndCommittedJournalsRecoverOnNextOpen() throws {
        for phase in ["prepared", "committed"] {
            let (project, a, b) = try fixture()
            let directory = project.deletingLastPathComponent().appendingPathComponent(".horizontal-transactions")
                .appendingPathComponent(HorizontalProjectTransaction.digest(Data(project.resolvingSymlinksInPath().path.utf8)))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let updates = [HorizontalProjectTransaction.Update(url: a, before: Data("a0".utf8), after: Data("a1".utf8)),
                           .init(url: b, before: Data("b0".utf8), after: Data("b1".utf8))]
            let encodedUpdates = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updates))
            let journal: [String: Any] = ["updates": encodedUpdates, "phase": phase, "operationID": "interrupted", "receipt": Data("receipt".utf8).base64EncodedString()]
            let journalURL = directory.appendingPathComponent("journal.json")
            try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
            // Process died after only the first replacement, or during recovery.
            try Data("a1".utf8).write(to: a)
            let reopened = try HorizontalProjectTransaction(projectURL: project)
            try reopened.recover()
            XCTAssertEqual(try Data(contentsOf: a), Data((phase == "committed" ? "a1" : "a0").utf8))
            XCTAssertEqual(try Data(contentsOf: b), Data((phase == "committed" ? "b1" : "b0").utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
            XCTAssertEqual(try reopened.receipt(operationID: "interrupted"), phase == "committed" ? Data("receipt".utf8) : nil)
        }
    }

    func testTransactionDirectoryIgnoresItselfInAGitWorkingTree() throws {
        let (project, _, _) = try fixture()
        _ = try HorizontalProjectTransaction(projectURL: project)
        let root = project.deletingLastPathComponent().appendingPathComponent(".horizontal-transactions")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".gitignore")), Data("*\n".utf8))
    }

    func testHoldersReportThisProcessAndForgetDeadOnes() throws {
        let (project, _, _) = try fixture()
        XCTAssertEqual(HorizontalProjectHolders.all(projectURL: project).count, 0)

        var holder: HorizontalProjectHolder? = HorizontalProjectHolder(projectURL: project, name: "Test")
        XCTAssertNotNil(holder)
        let held = HorizontalProjectHolders.all(projectURL: project)
        XCTAssertEqual(held.map(\.name), ["Test"])
        XCTAssertEqual(held.first?.pid, getpid())
        // A writer only refuses for editors other than itself.
        XCTAssertEqual(HorizontalProjectHolders.others(projectURL: project).count, 0)

        // A record nobody holds a lock on belonged to a process that has gone.
        let directory = HorizontalProjectTransaction.transactionDirectory(project).appendingPathComponent("holders")
        let id = UUID().uuidString.lowercased()
        let staleLock = directory.appendingPathComponent("\(id).lock")
        let staleRecord = directory.appendingPathComponent("\(id).json")
        try Data().write(to: staleLock)
        try Data(#"{"pid":999999,"name":"Crashed","since":"2026-09-08T00:00:00Z"}"#.utf8).write(to: staleRecord)
        XCTAssertEqual(HorizontalProjectHolders.all(projectURL: project).map(\.name), ["Test"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRecord.path))

        // A record with no lock beside it — an older build's, or a crash
        // between the two writes — cannot be proved live, so it is cleared.
        let orphan = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data(#"{"pid":1,"name":"Older","since":"2026-09-08T00:00:00Z"}"#.utf8).write(to: orphan)
        XCTAssertEqual(HorizontalProjectHolders.all(projectURL: project).map(\.name), ["Test"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        holder = nil
        XCTAssertEqual(HorizontalProjectHolders.all(projectURL: project).count, 0)
    }

    /// The app's own discovery file is inside its sandbox container, which
    /// macOS refuses other processes. The holder record beside the project is
    /// the copy a client which can read the project can always read — and it
    /// survives being rewritten when the channel comes and goes.
    func testHolderPublishesAndWithdrawsItsLiveChannel() throws {
        let (project, _, _) = try fixture()
        let holder = try XCTUnwrap(HorizontalProjectHolder(projectURL: project, name: "Horizontal"))
        XCTAssertNil(HorizontalProjectHolders.all(projectURL: project).first?.endpoint)

        holder.update(endpoint: ["host": "127.0.0.1", "port": "51234", "token": "secret"])
        let published = try XCTUnwrap(HorizontalProjectHolders.all(projectURL: project).first)
        XCTAssertEqual(published.endpoint?["port"], "51234")
        XCTAssertEqual(published.endpoint?["token"], "secret")
        XCTAssertEqual(published.project, project.resolvingSymlinksInPath().standardizedFileURL.path,
                       "a reader matches on the recorded path, not on a digest it has to reproduce")
        // Rewriting the record must not orphan the lock the liveness check uses.
        XCTAssertEqual(HorizontalProjectHolders.others(projectURL: project).count, 0)
        XCTAssertNil(published.summary["endpoint"].flatMap { ($0 as? [String: String])?["token"] },
                     "a token is never handed to a caller")

        holder.update(endpoint: nil)
        XCTAssertNil(HorizontalProjectHolders.all(projectURL: project).first?.endpoint)
        withExtendedLifetime(holder) {}
    }

    func testHolderRecordIsNotWorldReadable() throws {
        let (project, _, _) = try fixture()
        let holder = try XCTUnwrap(HorizontalProjectHolder(projectURL: project, name: "Horizontal"))
        holder.update(endpoint: ["host": "127.0.0.1", "port": "1", "token": "secret"])
        let record = try XCTUnwrap(FileManager.default.enumerator(
            at: HorizontalProjectTransaction.transactionDirectory(project).appendingPathComponent("holders"),
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let mode = try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the record carries a token")
        withExtendedLifetime(holder) {}
    }
}
