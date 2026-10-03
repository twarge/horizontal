import Foundation
import HorizontalProjectIO

enum HorizontalDispatchMutation {
    static func execute(session: HorizontalDispatchSession, entry: HorizontalDispatchProjectEntry,
                        params: JSONDictionary, beforeCommit: () throws -> Void = {},
                        build: (HorizontalArchiveFileStore) throws -> JSONDictionary) throws -> JSONDictionary {
        let dryRun = params.bool("dry_run") ?? false
        let operationID = params.string("operation_id")
        if !dryRun, operationID?.isEmpty != false { throw HorizontalDispatchError.invalidParams("operation_id is required for a mutation.") }
        let transaction = entry.live == nil ? try HorizontalProjectTransaction(projectURL: entry.url) : nil
        defer { withExtendedLifetime(transaction) {} }
        try transaction?.recover()
        let payload = params.filter { !["handle", "include_metadata", "operation_id", "plan_digest", "deadline_unix_ms", "detail"].contains($0.key) }
        let payloadHash = HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        if let operationID {
            let existing: JSONDictionary?
            if let transaction {
                existing = try transaction.receipt(operationID: operationID).map { try JSONHelper.loadDictionary(from: $0) }
            } else { existing = entry.receipts[operationID] }
            if let existing {
                guard existing.string("payload_hash") == payloadHash else { throw HorizontalDispatchError.invalidParams("operation_id was already used for a different request.") }
                return shaped(existing, params)
            }
        }
        do {
            let result = try perform(session: session, entry: entry, params: params, transaction: transaction,
                                     payloadHash: payloadHash, dryRun: dryRun, operationID: operationID,
                                     beforeCommit: beforeCommit, build: build)
            if let operationID { entry.failedOperations.removeValue(forKey: operationID) }
            return shaped(result, params)
        } catch {
            // Nothing was committed: every failure below is thrown before the
            // archive is installed or the transaction commits.
            if let operationID, !dryRun {
                let failure = error as? HorizontalDispatchError
                entry.failedOperations[operationID] = [
                    "operation_id": operationID, "status": "not_committed", "payload_hash": payloadHash,
                    "instance_id": entry.instanceID, "error": failure?.message ?? String(describing: error),
                    "code": failure?.code.label ?? "ENGINE_ERROR"
                ]
            }
            throw error
        }
    }

    /// What changed in one file, as JSON paths rather than text:
    /// "sheets/<id>/net_lines/<id>" removed, and so on, at most `limit` of
    /// each with the full count beside. A file that is not JSON, or is new or
    /// gone, gets its sizes only.
    static func fileDiff(before: Data?, after: Data?, limit: Int = 100) -> JSONDictionary {
        var result: JSONDictionary = ["before_bytes": before?.count ?? 0, "after_bytes": after?.count ?? 0]
        guard let before, let after,
              let old = try? JSONSerialization.jsonObject(with: before), let new = try? JSONSerialization.jsonObject(with: after) else {
            return result
        }
        var added = [String](), removed = [String](), changed = [String]()
        func walk(_ a: Any, _ b: Any, _ path: String) {
            guard let a = a as? JSONDictionary, let b = b as? JSONDictionary else {
                if !((a as? NSObject)?.isEqual(b) ?? false) { changed.append(path) }
                return
            }
            for key in Set(a.keys).union(b.keys).sorted() {
                let sub = path.isEmpty ? key : path + "/" + key
                switch (a[key], b[key]) {
                case (nil, _?): added.append(sub)
                case (_?, nil): removed.append(sub)
                case let (x?, y?): walk(x, y, sub)
                default: break
                }
            }
        }
        walk(old, new, "")
        for (key, list) in [("added", added), ("removed", removed), ("changed", changed)] where !list.isEmpty {
            result[key] = Array(list.prefix(limit))
            if list.count > limit { result[key + "_count"] = list.count }
        }
        return result
    }

    /// What a caller asked to see of a result. "compact" keeps the ids and
    /// counts an agent acts on and drops what it already sent or can ask for:
    /// the echoed ops, file previews, the project summary. A dry run keeps its
    /// normalized ops, because they are what gets replayed with plan_digest.
    /// "full", the default, previews each file as the JSON paths it changes;
    /// "files" adds each file's whole text before and after.
    static func shaped(_ result: JSONDictionary, _ params: JSONDictionary) -> JSONDictionary {
        guard params.string("detail") == "compact" else { return result }
        var compact = result
        for key in ["preview", "project", "payload_hash"] { compact.removeValue(forKey: key) }
        if result.bool("dry_run") != true { compact.removeValue(forKey: "normalized_ops") }
        if let changes = result["changes"] as? [JSONDictionary] {
            compact["changes"] = changes.map(compactChange)
        }
        for key in ["written", "would_write"] {
            // A pool import writes dozens of files; their number is enough.
            if let files = result[key] as? [String], files.count > 12 {
                compact[key] = Array(files.prefix(12))
                compact[key + "_count"] = files.count
            }
        }
        return compact
    }

    /// Scalars stay; short lists of ids and small tables of counts stay;
    /// anything bigger becomes its size.
    private static func compactChange(_ change: JSONDictionary) -> JSONDictionary {
        var result = JSONDictionary()
        for (key, value) in change {
            switch value {
            case is String, is NSNumber, is NSNull, is Bool, is Int, is Double:
                result[key] = value
            case let list as [Any] where list.count <= 8 && list.allSatisfy({ $0 is String || $0 is NSNumber }):
                result[key] = list
            case let list as [Any]:
                result[key + "_count"] = list.count
            case let table as JSONDictionary where table.count <= 12 && table.values.allSatisfy({ $0 is String || $0 is NSNumber || $0 is NSNull }):
                result[key] = table
            case let table as JSONDictionary:
                result[key + "_count"] = table.count
            default:
                result[key] = value
            }
        }
        return result
    }

    private static func perform(session: HorizontalDispatchSession, entry: HorizontalDispatchProjectEntry, params: JSONDictionary,
                                transaction: HorizontalProjectTransaction?, payloadHash: String, dryRun: Bool, operationID: String?,
                                beforeCommit: () throws -> Void,
                                build: (HorizontalArchiveFileStore) throws -> JSONDictionary) throws -> JSONDictionary {
        var timing = JSONDictionary()
        var clock = Date()
        func lap(_ phase: String) {
            timing[phase] = Int((Date().timeIntervalSince(clock) * 1000).rounded())
            clock = Date()
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
        // A commit that replays the dry run just made — same revision, same
        // request, the plan it returned — installs what the dry run staged and
        // validated instead of editing and loading the project again.
        let planKeys = { (ops: Any?) throws -> String in
            var payload = params.filter { !["handle", "include_metadata", "operation_id", "plan_digest", "deadline_unix_ms", "detail", "dry_run"].contains($0.key) }
            if let ops { payload["ops"] = ops }
            payload["revision"] = entry.revision
            return HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        }
        let requestKey = try planKeys(nil)
        var result: JSONDictionary
        let after: HorizontalDispatchSnapshot
        let staged: HorizontalProject
        let nextDiagnostics: [String: Int]
        if !dryRun, let plan = entry.stagedPlan, plan.revision == entry.revision, plan.keys.contains(requestKey),
           params.string("plan_digest") == plan.digest {
            result = plan.result
            after = plan.after
            staged = plan.staged
            nextDiagnostics = plan.diagnostics
            timing["reused_dry_run"] = true
        } else {
            let store = HorizontalArchiveFileStore(archive: snapshot.archive, baseURL: entry.project.baseURL)
            result = try build(store)
            lap("edit_ms")
            after = HorizontalDispatchSnapshot(archive: store.archive, baseURL: entry.project.baseURL)
            // Load the complete staged project before any original file is
            // replaced. A disk context then reads from it, so it gets the
            // editor's connectivity pass. A live document installs the project
            // as loaded and the session derives its own from the document
            // afterwards, so for one that pass would be thrown away.
            staged = entry.live == nil
                ? try HorizontalDispatchSession.project(from: after, url: entry.url)
                : try after.materializedProject()
            lap("load_ms")
            func diagnostics(_ snapshot: HorizontalDispatchSnapshot) throws -> [String: Int] {
                if let cached = entry.cachedDiagnostics, cached.snapshotID == snapshot.id { return cached.counts }
                let project = try snapshot.materializedProject()
                return Dictionary(project.diagnostics.map { ($0.message.replacingOccurrences(of: project.baseURL.path, with: "<project>"), 1) }, uniquingKeysWith: +)
            }
            nextDiagnostics = try diagnostics(after)
            // Only an edit that leaves diagnostics needs the count it started
            // from, and finding that out means loading the project as it was,
            // which costs as much as loading the edit.
            if !nextDiagnostics.isEmpty {
                let previousDiagnostics = try diagnostics(snapshot)
                guard nextDiagnostics.allSatisfy({ $0.value <= previousDiagnostics[$0.key, default: 0] }) else {
                    throw HorizontalDispatchError.failed("The edit introduces project load diagnostics; nothing was committed.")
                }
            }
            lap("diagnostics_ms")
        }
        let changed = after.files.filter { after.archive.regularFileData(relativePath: $0) != snapshot.archive.regularFileData(relativePath: $0) }
        let plan: JSONDictionary = ["revision": entry.revision, "ops": result["normalized_ops"] ?? params["ops"] ?? [], "pool_items": params["pool_items"] ?? params["items"] ?? []]
        let planDigest = HorizontalProjectTransaction.digest(try JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys]))
        if let expected = params.string("plan_digest"), expected != planDigest {
            throw HorizontalDispatchError(code: .staleRevision, message: "Dry-run plan does not match this edit.")
        }
        if dryRun {
            // Kept for the commit that replays this plan, by either spelling of
            // the request: as sent, or with the normalized ops the reply gave.
            entry.stagedPlan = HorizontalDispatchProjectEntry.StagedPlan(
                keys: [requestKey, try planKeys(result["normalized_ops"])], digest: planDigest, revision: entry.revision,
                after: after, staged: staged, diagnostics: nextDiagnostics, result: result)
        } else {
            entry.stagedPlan = nil
        }
        result["plan_digest"] = planDigest
        result["before_revision"] = entry.revision
        result["before_snapshot_id"] = snapshot.id
        result["after_snapshot_id"] = after.id
        result["source"] = entry.live == nil ? "disk" : "live"
        result["live"] = entry.live != nil
        result["would_write"] = changed
        if params.string("detail") != "compact" { result["preview"] = changed.map { path -> JSONDictionary in
            let before = snapshot.archive.regularFileData(relativePath: path), afterData = after.archive.regularFileData(relativePath: path)
            var file = Self.fileDiff(before: before, after: afterData)
            file["path"] = path
            // The text itself only on request: a schematic runs to megabytes.
            if params.string("detail") == "files" {
                file["before"] = before.flatMap { String(data: $0, encoding: .utf8) } as Any
                file["after"] = afterData.flatMap { String(data: $0, encoding: .utf8) } as Any
            }
            return file
        } }
        if dryRun {
            result["timing"] = timing
            result["dry_run"] = true
            result["status"] = "preview"
            result["written"] = [String]()
            result.removeValue(forKey: "after_revision")
            result.removeValue(forKey: "durability")
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
            try beforeCommit()
            try transaction.commit(updates, operationID: operationID,
                                   receipt: JSONSerialization.data(withJSONObject: HorizontalDispatchJSON.sanitized(result), options: [.sortedKeys])) {
                let installed = try HorizontalDispatchSnapshot.capture(url: entry.url)
                guard installed.id == after.id else { throw HorizontalProjectTransaction.Failure.conflict(entry.url.path) }
            }
            entry.project = staged
            entry.snapshot = after
            entry.generation += 1
            entry.invalidateIndex()
            entry.cachedDiagnostics = (after.id, nextDiagnostics)
            lap("commit_ms")
        } else if let live = entry.live {
            try beforeCommit()
            let archive = after.archive
            let count = result["applied"] as? Int ?? changed.count
            let action = "Apply \(count) Edit\(count == 1 ? "" : "s")"
            // The archive as loaded, before the dispatch layer's own
            // connectivity pass — what the app would load itself.
            let loaded = HorizontalUnsafeSendableBox(try after.materializedProject())
            try MainActor.assumeIsolated {
                if let applyLoaded = live.applyLoadedArchive {
                    try applyLoaded(archive, loaded.value, action)
                } else {
                    try live.applyArchive(archive, action)
                }
                session.syncLiveEntries()
            }
            entry.cachedDiagnostics = (after.id, nextDiagnostics)
            lap("commit_ms")
            result["after_revision"] = entry.revision
            result["timing"] = timing
            entry.receipts[operationID!] = result
        }
        result["timing"] = timing
        // A compact reply leaves the summary out, and it costs a design index.
        if params.string("detail") != "compact" {
            result["project"] = HorizontalDispatchMethods.projectSummary(entry)
        }
        return result
    }
}
