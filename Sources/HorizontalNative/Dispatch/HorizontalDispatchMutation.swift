import Foundation
import HorizontalProjectIO

enum HorizontalDispatchMutation {
    static func execute(session: HorizontalDispatchSession, entry: HorizontalDispatchProjectEntry,
                        params: JSONDictionary, build: (HorizontalArchiveFileStore) throws -> JSONDictionary) throws -> JSONDictionary {
        let dryRun = params.bool("dry_run") ?? false
        let operationID = params.string("operation_id")
        if !dryRun, operationID?.isEmpty != false { throw HorizontalDispatchError.invalidParams("operation_id is required for a mutation.") }
        let transaction = entry.live == nil ? try HorizontalProjectTransaction(projectURL: entry.url) : nil
        defer { withExtendedLifetime(transaction) {} }
        try transaction?.recover()
        let payload = params.filter { !["handle", "include_metadata", "operation_id", "plan_digest", "deadline_unix_ms"].contains($0.key) }
        let payloadHash = HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        if let operationID {
            let existing: JSONDictionary?
            if let transaction {
                existing = try transaction.receipt(operationID: operationID).map { try JSONHelper.loadDictionary(from: $0) }
            } else { existing = entry.receipts[operationID] }
            if let existing {
                guard existing.string("payload_hash") == payloadHash else { throw HorizontalDispatchError.invalidParams("operation_id was already used for a different request.") }
                return existing
            }
        }
        // A disk write under an open editor is a data-loss path in both
        // directions: the editor's next save overwrites this edit, and
        // reloading the files discards its undo history. The live channel
        // cannot rule an editor out — it stays off until the user turns it on
        // — so the holder records beside the project decide. A dry run reports
        // the conflict instead of throwing, so a caller can plan and be told.
        let holders = entry.live == nil ? HorizontalProjectHolders.others(projectURL: entry.url) : []
        if let holder = holders.first, !dryRun {
            throw HorizontalDispatchError(
                code: .documentOpen,
                message: "\(holder.name) (pid \(holder.pid)) has this project open, so its files cannot be edited on disk. "
                    + "Edit it there instead: turn on the live channel in \(holder.name)'s settings and open the project with source \"live\". "
                    + "Closing the document also releases it.",
                details: ["holders": holders.map(\.summary)]
            )
        }
        try entry.requireRevision(params)
        guard let snapshot = entry.snapshot else { throw HorizontalDispatchError.failed("No project snapshot.") }
        if let live = entry.live {
            guard Thread.isMainThread else { throw HorizontalDispatchError.failed("Live mutations require the app channel.") }
            let readOnly = MainActor.assumeIsolated { live.isReadOnly() }
            guard !readOnly else { throw HorizontalDispatchError(code: .readOnly, message: "The document is read-only.") }
        }
        let store = HorizontalArchiveFileStore(archive: snapshot.archive, baseURL: entry.project.baseURL)
        var result = try build(store)
        let after = HorizontalDispatchSnapshot(archive: store.archive, baseURL: entry.project.baseURL)
        // Load the complete staged project before any original file is replaced.
        let staged = try HorizontalDispatchSession.project(from: after, url: entry.url)
        func diagnostics(_ snapshot: HorizontalDispatchSnapshot) throws -> [String: Int] {
            let project = try snapshot.materializedProject()
            return Dictionary(project.diagnostics.map { ($0.message.replacingOccurrences(of: project.baseURL.path, with: "<project>"), 1) }, uniquingKeysWith: +)
        }
        let previousDiagnostics = try diagnostics(snapshot)
        let nextDiagnostics = try diagnostics(after)
        guard nextDiagnostics.allSatisfy({ $0.value <= previousDiagnostics[$0.key, default: 0] }) else {
            throw HorizontalDispatchError.failed("The edit introduces project load diagnostics; nothing was committed.")
        }
        let changed = after.files.filter { after.archive.regularFileData(relativePath: $0) != snapshot.archive.regularFileData(relativePath: $0) }
        let plan: JSONDictionary = ["revision": entry.revision, "ops": result["normalized_ops"] ?? params["ops"] ?? [], "pool_items": params["pool_items"] ?? params["items"] ?? []]
        let planDigest = HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]))
        if let expected = params.string("plan_digest"), expected != planDigest {
            throw HorizontalDispatchError(code: .staleRevision, message: "Dry-run plan does not match this edit.")
        }
        result["plan_digest"] = planDigest
        result["before_revision"] = entry.revision
        result["before_snapshot_id"] = snapshot.id
        result["after_snapshot_id"] = after.id
        result["source"] = entry.live == nil ? "disk" : "live"
        result["live"] = entry.live != nil
        result["would_write"] = changed
        result["preview"] = changed.map { path -> JSONDictionary in
            ["path": path,
             "before": snapshot.archive.regularFileData(relativePath: path).flatMap { String(data: $0, encoding: .utf8) } as Any,
             "after": after.archive.regularFileData(relativePath: path).flatMap { String(data: $0, encoding: .utf8) } as Any]
        }
        if dryRun {
            result["dry_run"] = true
            if !holders.isEmpty { result["blocked_by"] = holders.map(\.summary) }
            return result
        }
        try HorizontalDispatchValidation.checkDeadline(params)
        result.removeValue(forKey: "preview")
        result["operation_id"] = operationID!
        result["payload_hash"] = payloadHash
        result["status"] = "committed"
        result["durability"] = entry.live == nil ? "disk" : "unsaved_document"
        result["written"] = changed
        result["after_revision"] = "\(entry.instanceID):\(entry.generation + 1):\(after.id)"
        if let transaction {
            let updates = changed.map { path in
                HorizontalProjectTransaction.Update(url: entry.project.baseURL.appendingPathComponent(path), before: snapshot.archive.regularFileData(relativePath: path), after: after.archive.regularFileData(relativePath: path)!)
            }
            // Hash the complete input set again under the writer lock, directly before commit.
            try entry.requireRevision(params)
            try HorizontalDispatchValidation.checkDeadline(params)
            try transaction.commit(updates, operationID: operationID,
                                   receipt: JSONSerialization.data(withJSONObject: HorizontalDispatchJSON.sanitized(result), options: [.sortedKeys])) {
                let installed = try HorizontalDispatchSnapshot.capture(url: entry.url)
                guard installed.id == after.id else { throw HorizontalProjectTransaction.Failure.conflict(entry.url.path) }
            }
            entry.project = staged
            entry.snapshot = after
            entry.generation += 1
            entry.invalidateIndex()
        } else if let live = entry.live {
            let archive = store.archive
            let count = result["applied"] as? Int ?? changed.count
            let action = "Apply \(count) Edit\(count == 1 ? "" : "s")"
            try MainActor.assumeIsolated {
                try live.applyArchive(archive, action)
                session.syncLiveEntries()
            }
            result["after_revision"] = entry.revision
            entry.receipts[operationID!] = result
        }
        result["project"] = HorizontalDispatchMethods.projectSummary(entry)
        return result
    }
}
