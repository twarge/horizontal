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
}
