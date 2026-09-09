import Foundation
import Darwin

/// Who has a project open for editing right now, and how to reach them.
///
/// A writer that is not the one making a change — Horizontal holding the
/// document on screen while an automation client edits the same files on disk
/// — cannot be discovered through the app's own discovery file. That file
/// lives in the app's sandbox container, and macOS refuses another process
/// access to it. So each editor records itself beside the project instead, in
/// the transaction directory the writers already share, and holds an advisory
/// lock on that record for as long as it has the project open.
///
/// Liveness needs no process table and no timestamps: the kernel drops the
/// lock when the holder exits or crashes, so a record another process can lock
/// is by definition stale and is deleted on sight.
///
/// A holder that is serving its live channel publishes the channel's loopback
/// endpoint and token in the record, so a client that can read the project can
/// reach the document rather than being told to edit files underneath it. The
/// record is mode 0600: the same protection the app's own discovery file has,
/// in a place a client can actually read.
public struct HorizontalProjectHolderInfo: Sendable, Equatable {
    /// The holder's process id, so a caller can recognize itself.
    public var pid: Int32
    /// A human-readable name for the holder, e.g. "Horizontal".
    public var name: String
    /// The project this record is about, so a reader never has to reproduce
    /// the path digest that names the directory.
    public var project: String
    /// When the holder opened the project.
    public var since: Date
    /// The holder's live channel — `host`, `port`, `token` — or nil when it is
    /// not serving one.
    public var endpoint: [String: String]?

    public var json: [String: Any] {
        var json: [String: Any] = ["pid": Int(pid), "name": name, "project": project,
                                   "since": ISO8601DateFormatter().string(from: since)]
        if let endpoint { json["endpoint"] = endpoint }
        return json
    }

    /// The record without its token, for reporting a holder to a caller.
    public var summary: [String: Any] {
        var json = self.json
        if var endpoint = json["endpoint"] as? [String: String] {
            endpoint.removeValue(forKey: "token")
            json["endpoint"] = endpoint
        }
        return json
    }
}

/// One registration, live for as long as the object is retained.
///
/// The lock and the record are separate files. The record is rewritten
/// whenever the live channel starts or stops, and rewriting is atomic — which
/// replaces the file — so the lock has to live on a file that is never
/// replaced, or the kernel would be holding a lock on an orphan.
public final class HorizontalProjectHolder {
    private let lockURL: URL
    private let recordURL: URL
    private let descriptor: Int32
    private var info: HorizontalProjectHolderInfo

    /// Registers this process as holding `projectURL` open. Returns nil when
    /// the record cannot be written — a read-only volume, say. Holding a
    /// project open is advisory, so failing to announce it is not an error
    /// that should stop a document from opening.
    public init?(projectURL: URL, name: String, endpoint: [String: String]? = nil) {
        let directory = HorizontalProjectHolders.directory(projectURL: projectURL)
        let id = UUID().uuidString.lowercased()
        lockURL = directory.appendingPathComponent("\(id).lock")
        recordURL = directory.appendingPathComponent("\(id).json")
        info = HorizontalProjectHolderInfo(
            pid: getpid(), name: name,
            project: projectURL.resolvingSymlinksInPath().standardizedFileURL.path,
            since: Date(), endpoint: endpoint
        )
        do {
            try HorizontalProjectTransaction.createDirectory(directory)
            // The record lands before the lock it is found by, so a reader
            // never sees a held lock whose record has not been written yet.
            // Dying in between leaves a lock nobody holds, which reads as stale.
            try Self.write(info, to: recordURL)
            try Data().write(to: lockURL, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: recordURL)
            return nil
        }
        descriptor = Darwin.open(lockURL.path, O_RDWR, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: recordURL)
            try? FileManager.default.removeItem(at: lockURL)
            return nil
        }
    }

    private static func write(_ info: HorizontalProjectHolderInfo, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: info.json, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
        // The token is in here; keep it as private as the app's own file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Publishes, or withdraws, the live channel this holder serves.
    public func update(endpoint: [String: String]?) {
        guard info.endpoint != endpoint else { return }
        info.endpoint = endpoint
        try? Self.write(info, to: recordURL)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: recordURL)
        try? FileManager.default.removeItem(at: lockURL)
    }
}

public enum HorizontalProjectHolders {
    static func directory(projectURL: URL) -> URL {
        HorizontalProjectTransaction.transactionDirectory(projectURL).appendingPathComponent("holders")
    }

    /// Everyone holding `projectURL` open, this process included. Records
    /// whose lock is free belonged to a process that has since exited; they
    /// are removed rather than reported.
    public static func all(projectURL: URL) -> [HorizontalProjectHolderInfo] {
        let directory = directory(projectURL: projectURL)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var holders = [HorizontalProjectHolderInfo]()
        // A record with no lock beside it is an orphan: a crash between the two
        // writes, or a record an older build left behind. Nothing can prove it
        // live, so it is cleared rather than left to accumulate.
        let locks = Set(urls.filter { $0.pathExtension.lowercased() == "lock" }
            .map { $0.deletingPathExtension().lastPathComponent })
        for record in urls where record.pathExtension.lowercased() == "json"
            && !locks.contains(record.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: record)
        }
        for lock in urls.sorted(by: { $0.path < $1.path }) where lock.pathExtension.lowercased() == "lock" {
            let record = lock.deletingPathExtension().appendingPathExtension("json")
            let descriptor = Darwin.open(lock.path, O_RDONLY)
            guard descriptor >= 0 else { continue }
            // A lock this process can take is a lock nobody holds. flock is
            // per open file description, so our own registration still
            // conflicts with this second descriptor and is reported.
            let stale = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if stale { flock(descriptor, LOCK_UN) }
            Darwin.close(descriptor)
            if stale {
                try? FileManager.default.removeItem(at: lock)
                try? FileManager.default.removeItem(at: record)
                continue
            }
            guard let data = try? Data(contentsOf: record),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = json["pid"] as? Int else {
                continue
            }
            holders.append(HorizontalProjectHolderInfo(
                pid: Int32(pid),
                name: json["name"] as? String ?? "",
                project: json["project"] as? String ?? "",
                since: (json["since"] as? String).flatMap(ISO8601DateFormatter().date(from:)) ?? Date(),
                endpoint: json["endpoint"] as? [String: String]
            ))
        }
        return holders.sorted { ($0.since, $0.pid) < ($1.since, $1.pid) }
    }

    /// The holders that are not this process.
    public static func others(projectURL: URL) -> [HorizontalProjectHolderInfo] {
        let mine = getpid()
        return all(projectURL: projectURL).filter { $0.pid != mine }
    }
}
