import Foundation
import CryptoKit
import Darwin

/// A recoverable multi-file commit. The lock and journal live beside the project,
/// outside packages and their snapshots. All participating writers share this lock.
public final class HorizontalProjectTransaction {
    public struct Update: Codable {
        public var path: String
        public var before: Data?
        public var after: Data

        public init(url: URL, before: Data?, after: Data) {
            path = url.standardizedFileURL.path
            self.before = before
            self.after = after
        }
    }

    private struct Journal: Codable {
        var updates: [Update]
        var phase: String
        var operationID: String?
        var receipt: Data?
    }

    public enum Failure: LocalizedError {
        case timeout, conflict(String), recoveryRequired(String)
        public var errorDescription: String? {
            switch self {
            case .timeout: "Timed out waiting for the project transaction lock."
            case .conflict(let path): "File changed outside this transaction: \(path)"
            case .recoveryRequired(let path): "Recovery requires attention; a file matches neither its original nor committed bytes: \(path)"
            }
        }
    }

    private let directory: URL
    private let descriptor: Int32
    private var journalURL: URL { directory.appendingPathComponent("journal.json") }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func transactionDirectory(_ projectURL: URL) -> URL {
        let canonical = projectURL.resolvingSymlinksInPath().standardizedFileURL
        return canonical.deletingLastPathComponent().appendingPathComponent(".horizontal-transactions")
            .appendingPathComponent(Self.digest(Data(canonical.path.utf8)))
    }

    /// Readers can join an existing writer lock without creating files or
    /// requiring write permission on a project that has never been edited.
    public static func existing(projectURL: URL, timeout: TimeInterval = 10) throws -> HorizontalProjectTransaction? {
        let directory = transactionDirectory(projectURL)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("lock").path) else {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal.json").path) { throw Failure.recoveryRequired(directory.path) }
            return nil
        }
        return try HorizontalProjectTransaction(projectURL: projectURL, timeout: timeout, create: false)
    }

    public convenience init(projectURL: URL, timeout: TimeInterval = 10) throws {
        try self.init(projectURL: projectURL, timeout: timeout, create: true)
    }

    private init(projectURL: URL, timeout: TimeInterval, create: Bool) throws {
        directory = Self.transactionDirectory(projectURL)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        descriptor = Darwin.open(directory.appendingPathComponent("lock").path, create ? O_CREAT | O_RDWR : O_RDONLY, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                Darwin.close(descriptor)
                throw Failure.timeout
            }
            usleep(10_000)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
        syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); Darwin.close(fd) }
    }

    private func durableRemove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        syncDirectory(url.deletingLastPathComponent())
    }

    private func save(_ journal: Journal) throws {
        try durableWrite(JSONEncoder().encode(journal), to: journalURL)
    }

    private func bytes(at path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func receiptURL(_ id: String) -> URL {
        directory.appendingPathComponent("receipts").appendingPathComponent(Self.digest(Data(id.utf8)) + ".json")
    }

    public func receipt(operationID: String) throws -> Data? {
        try bytes(at: receiptURL(operationID).path)
    }

    /// Called with the lock held before opening, editing, or saving a project.
    /// A committed journal is rolled forward; an incomplete one is rolled back.
    public func recover() throws {
        guard let data = try bytes(at: journalURL.path) else { return }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: data) }
        catch { throw Failure.recoveryRequired(journalURL.path) }
        guard ["prepared", "committed"].contains(journal.phase), Set(journal.updates.map(\.path)).count == journal.updates.count else {
            throw Failure.recoveryRequired(journalURL.path)
        }
        // Check the entire set before touching anything. Never overwrite a third state.
        for update in journal.updates {
            let current = try bytes(at: update.path)
            guard current == update.before || current == update.after else {
                throw Failure.recoveryRequired(update.path)
            }
        }
        for update in journal.updates {
            let target = URL(fileURLWithPath: update.path)
            if journal.phase == "committed" {
                try durableWrite(update.after, to: target)
            } else if let before = update.before {
                try durableWrite(before, to: target)
            } else if FileManager.default.fileExists(atPath: target.path) {
                try durableRemove(target)
            }
        }
        if journal.phase == "committed", let id = journal.operationID, let receipt = journal.receipt {
            try durableWrite(receipt, to: receiptURL(id))
        }
        try durableRemove(journalURL)
    }

    /// Validation runs before the commit marker. Any failure restores all files.
    /// `afterReplace` is a fault-injection seam used by recovery tests.
    public func commit(_ updates: [Update], operationID: String? = nil, receipt: Data? = nil,
                       validate: () throws -> Void = {}, afterReplace: (Int) throws -> Void = { _ in }) throws {
        try recover()
        guard Set(updates.map(\.path)).count == updates.count else {
            throw Failure.conflict("duplicate transaction target")
        }
        for update in updates {
            guard try bytes(at: update.path) == update.before else { throw Failure.conflict(update.path) }
        }
        var journal = Journal(updates: updates, phase: "prepared", operationID: operationID, receipt: receipt)
        try save(journal)
        do {
            for (index, update) in updates.enumerated() {
                // A non-cooperating writer can race even after the first check.
                guard try bytes(at: update.path) == update.before else { throw Failure.conflict(update.path) }
                try durableWrite(update.after, to: URL(fileURLWithPath: update.path))
                try afterReplace(index)
            }
            try validate()
            journal.phase = "committed"
            try save(journal)
        } catch {
            // A marker write may report an fsync failure after its rename.
            // Inspect the recorded phase before deciding whether a rollback occurred.
            let recorded = (try? bytes(at: journalURL.path)).flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
            do { try recover() }
            catch { throw Failure.recoveryRequired(journalURL.path) }
            if recorded?.phase == "committed" { return }
            throw error
        }
        // Keep the committed journal if receipt installation fails; recovery finishes it.
        do {
            if let operationID, let receipt { try durableWrite(receipt, to: receiptURL(operationID)) }
            try durableRemove(journalURL)
        } catch { throw Failure.recoveryRequired(journalURL.path) }
    }
}
