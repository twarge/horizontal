import Foundation

enum HorizontalMoveProfiler {
    // Gated on $HORIZON_PROFILE so the perf instrumentation shipped with the
    // recent "Performance: modifications directly to resident Metal buffer" /
    // "Substantially improve schematic editor performance" commits can actually
    // be run without rebuilding.
    private static let isEnabled = ProcessInfo.processInfo.environment["HORIZON_PROFILE"] != nil

    private struct Bucket {
        var count = 0
        var totalNanoseconds: UInt64 = 0
        var maxNanoseconds: UInt64 = 0

        mutating func add(_ nanoseconds: UInt64) {
            count += 1
            let summed = totalNanoseconds.addingReportingOverflow(nanoseconds)
            totalNanoseconds = summed.overflow ? UInt64.max : summed.partialValue
            maxNanoseconds = max(maxNanoseconds, nanoseconds)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var buckets = [String: Bucket]()
    nonisolated(unsafe) private static var lastFlushNanoseconds = DispatchTime.now().uptimeNanoseconds
    private static let flushIntervalNanoseconds: UInt64 = 1_000_000_000

    @discardableResult
    static func measure<T>(_ label: String, enabled: Bool = true, _ body: () throws -> T) rethrows -> T {
        guard enabled && isEnabled else {
            return try body()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            record(label, nanoseconds: elapsedNanoseconds(from: start, to: DispatchTime.now().uptimeNanoseconds))
        }
        return try body()
    }

    static func record(_ label: String, enabled: Bool = true, nanoseconds: UInt64) {
        guard enabled && isEnabled else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot: [(String, Bucket)]?
        lock.lock()
        buckets[label, default: Bucket()].add(nanoseconds)
        if elapsedNanoseconds(from: lastFlushNanoseconds, to: now) >= flushIntervalNanoseconds {
            snapshot = buckets.sorted { $0.key < $1.key }
            buckets.removeAll(keepingCapacity: true)
            lastFlushNanoseconds = now
        }
        lock.unlock()

        guard let snapshot, !snapshot.isEmpty else {
            return
        }

        let lines = snapshot.map { label, bucket -> String in
            let average = Double(bucket.totalNanoseconds) / Double(max(bucket.count, 1)) / 1_000_000
            let total = Double(bucket.totalNanoseconds) / 1_000_000
            let maximum = Double(bucket.maxNanoseconds) / 1_000_000
            let paddedLabel = label.padding(toLength: max(34, label.count), withPad: " ", startingAt: 0)
            return String(
                format: "  %@ avg %7.3f ms  max %7.3f ms  total %8.3f ms  n %4d",
                paddedLabel,
                average,
                maximum,
                total,
                bucket.count
            )
        }
        print("Horizontal move profiler:")
        for line in lines {
            print(line)
        }
    }

    private static func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else {
            return 0
        }
        return end - start
    }
}

enum HorizontalMoveRateDiagnostics {
    // Gated on $HORIZON_PROFILE — same flag as HorizontalMoveProfiler above.
    private static let isEnabled = ProcessInfo.processInfo.environment["HORIZON_PROFILE"] != nil

    enum Event {
        case bodyPass
        case cursorEvent
        case cursorNil
        case moveAttempt
        case moveAccepted
        case moveNoop
        case keyMove
        case metalUpdate
        case metalDraw
        case metalForcedDraw
    }

    enum PatchKind {
        case boardMove
        case boardSelection
    }

    enum TimingKind {
        case boardLineBatch
        case boardSelectionBatch
    }

    private struct Counters {
        var bodyPasses = 0
        var cursorEvents = 0
        var cursorNilEvents = 0
        var moveAttempts = 0
        var moveAccepted = 0
        var moveNoops = 0
        var keyMoves = 0
        var metalUpdates = 0
        var metalDraws = 0
        var metalForcedDraws = 0
        var cursorIntervalTotal: UInt64 = 0
        var cursorIntervalMax: UInt64 = 0
        var cursorIntervalCount = 0
        var acceptedIntervalTotal: UInt64 = 0
        var acceptedIntervalMax: UInt64 = 0
        var acceptedIntervalCount = 0
        var boardMovePatchBuilds = 0
        var boardMovePatchTotalNanoseconds: UInt64 = 0
        var boardMovePatchMaxNanoseconds: UInt64 = 0
        var boardSelectionPatchBuilds = 0
        var boardSelectionPatchTotalNanoseconds: UInt64 = 0
        var boardSelectionPatchMaxNanoseconds: UInt64 = 0
        var boardLineBatchBuilds = 0
        var boardLineBatchTotalNanoseconds: UInt64 = 0
        var boardLineBatchMaxNanoseconds: UInt64 = 0
        var boardSelectionBatchBuilds = 0
        var boardSelectionBatchTotalNanoseconds: UInt64 = 0
        var boardSelectionBatchMaxNanoseconds: UInt64 = 0
        var linePatchPrimitives = 0
        var lineEndpointPatches = 0
        var lineTranslationPrimitives = 0
        var trianglePatchPrimitives = 0
        var triangleTranslationPrimitives = 0
        var anchoredRectPatchPrimitives = 0
        var anchoredRectTranslationPrimitives = 0
        var handlePatchPrimitives = 0
        var handleTranslationPrimitives = 0
        var lineRegenerationSamples = [String: Int]()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = false
    nonisolated(unsafe) private static var mode = ""
    nonisolated(unsafe) private static var selectedCount = 0
    nonisolated(unsafe) private static var counters = Counters()
    nonisolated(unsafe) private static var lastFlushNanoseconds = DispatchTime.now().uptimeNanoseconds
    nonisolated(unsafe) private static var lastCursorNanoseconds: UInt64?
    nonisolated(unsafe) private static var lastAcceptedNanoseconds: UInt64?
    private static let flushIntervalNanoseconds: UInt64 = 1_000_000_000

    static func beginMove(tracksCursor: Bool, selectedCount: Int, details: String = "") {
        guard isEnabled else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        active = true
        mode = tracksCursor ? "cursor" : "keyboard"
        Self.selectedCount = selectedCount
        counters = Counters()
        lastFlushNanoseconds = now
        lastCursorNanoseconds = nil
        lastAcceptedNanoseconds = nil
        lock.unlock()
        if details.isEmpty {
            print("Horizontal move rate: begin \(mode) move, selected \(selectedCount)")
        } else {
            print("Horizontal move rate: begin \(mode) move, selected \(selectedCount), \(details)")
        }
    }

    static func endMove(committed: Bool) {
        guard isEnabled else {
            return
        }
        flush(force: true)
        lock.lock()
        let wasActive = active
        let currentMode = mode
        active = false
        mode = ""
        selectedCount = 0
        counters = Counters()
        lastCursorNanoseconds = nil
        lastAcceptedNanoseconds = nil
        lock.unlock()
        if wasActive {
            print("Horizontal move rate: end \(currentMode) move, \(committed ? "committed" : "cancelled")")
        }
    }

    static func mark(_ event: Event, active isActive: Bool = true) {
        guard isEnabled, isActive else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }

        switch event {
        case .bodyPass:
            counters.bodyPasses += 1
        case .cursorEvent:
            counters.cursorEvents += 1
            if let lastCursorNanoseconds {
                let interval = elapsedNanoseconds(from: lastCursorNanoseconds, to: now)
                counters.cursorIntervalTotal += interval
                counters.cursorIntervalMax = max(counters.cursorIntervalMax, interval)
                counters.cursorIntervalCount += 1
            }
            lastCursorNanoseconds = now
        case .cursorNil:
            counters.cursorNilEvents += 1
        case .moveAttempt:
            counters.moveAttempts += 1
        case .moveAccepted:
            counters.moveAccepted += 1
            if let lastAcceptedNanoseconds {
                let interval = elapsedNanoseconds(from: lastAcceptedNanoseconds, to: now)
                counters.acceptedIntervalTotal += interval
                counters.acceptedIntervalMax = max(counters.acceptedIntervalMax, interval)
                counters.acceptedIntervalCount += 1
            }
            lastAcceptedNanoseconds = now
        case .moveNoop:
            counters.moveNoops += 1
        case .keyMove:
            counters.keyMoves += 1
        case .metalUpdate:
            counters.metalUpdates += 1
        case .metalDraw:
            counters.metalDraws += 1
        case .metalForcedDraw:
            counters.metalForcedDraws += 1
        }

        let shouldFlush = elapsedNanoseconds(from: lastFlushNanoseconds, to: now) >= flushIntervalNanoseconds
        lock.unlock()
        if shouldFlush {
            flush(force: false)
        }
    }

    static func recordTiming(_ kind: TimingKind, nanoseconds: UInt64, active isActive: Bool = true) {
        guard isEnabled, isActive else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }

        switch kind {
        case .boardLineBatch:
            counters.boardLineBatchBuilds += 1
            addClamped(nanoseconds, to: &counters.boardLineBatchTotalNanoseconds)
            counters.boardLineBatchMaxNanoseconds = max(counters.boardLineBatchMaxNanoseconds, nanoseconds)
        case .boardSelectionBatch:
            counters.boardSelectionBatchBuilds += 1
            addClamped(nanoseconds, to: &counters.boardSelectionBatchTotalNanoseconds)
            counters.boardSelectionBatchMaxNanoseconds = max(counters.boardSelectionBatchMaxNanoseconds, nanoseconds)
        }

        let shouldFlush = elapsedNanoseconds(from: lastFlushNanoseconds, to: now) >= flushIntervalNanoseconds
        lock.unlock()
        if shouldFlush {
            flush(force: false)
        }
    }

    static func recordMetalPatches(_ kind: PatchKind, nanoseconds: UInt64, patches: HorizontalMetalBufferPatches, active isActive: Bool = true) {
        guard isEnabled, isActive else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }

        switch kind {
        case .boardMove:
            counters.boardMovePatchBuilds += 1
            addClamped(nanoseconds, to: &counters.boardMovePatchTotalNanoseconds)
            counters.boardMovePatchMaxNanoseconds = max(counters.boardMovePatchMaxNanoseconds, nanoseconds)
        case .boardSelection:
            counters.boardSelectionPatchBuilds += 1
            addClamped(nanoseconds, to: &counters.boardSelectionPatchTotalNanoseconds)
            counters.boardSelectionPatchMaxNanoseconds = max(counters.boardSelectionPatchMaxNanoseconds, nanoseconds)
        }

        counters.linePatchPrimitives += patches.linePatches.reduce(0) { $0 + $1.primitives.count }
        counters.lineEndpointPatches += patches.lineEndpointPatches.count
        counters.lineTranslationPrimitives += patches.lineTranslationPatches.reduce(0) { $0 + $1.count }
        counters.trianglePatchPrimitives += patches.trianglePatches.reduce(0) { $0 + $1.primitives.count }
        counters.triangleTranslationPrimitives += patches.triangleTranslationPatches.reduce(0) { $0 + $1.count }
        counters.anchoredRectPatchPrimitives += patches.anchoredRectPatches.reduce(0) { $0 + $1.primitives.count }
        counters.anchoredRectTranslationPrimitives += patches.anchoredRectTranslationPatches.reduce(0) { $0 + $1.count }
        counters.handlePatchPrimitives += patches.handlePatches.reduce(0) { $0 + $1.primitives.count }
        counters.handleTranslationPrimitives += patches.handleTranslationPatches.reduce(0) { $0 + $1.count }

        let shouldFlush = elapsedNanoseconds(from: lastFlushNanoseconds, to: now) >= flushIntervalNanoseconds
        lock.unlock()
        if shouldFlush {
            flush(force: false)
        }
    }

    static func recordLineRegeneration(sample: String, primitiveCount: Int, active isActive: Bool = true) {
        guard isEnabled, isActive, primitiveCount > 0 else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        counters.lineRegenerationSamples[sample, default: 0] += primitiveCount
        let shouldFlush = elapsedNanoseconds(from: lastFlushNanoseconds, to: now) >= flushIntervalNanoseconds
        lock.unlock()
        if shouldFlush {
            flush(force: false)
        }
    }

    private static func flush(force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot: Counters
        let elapsed: UInt64
        let snapshotMode: String
        let snapshotSelectedCount: Int

        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        elapsed = elapsedNanoseconds(from: lastFlushNanoseconds, to: now)
        guard force || elapsed >= flushIntervalNanoseconds else {
            lock.unlock()
            return
        }
        snapshot = counters
        snapshotMode = mode
        snapshotSelectedCount = selectedCount
        counters = Counters()
        lastFlushNanoseconds = now
        lock.unlock()

        let elapsedSeconds = max(Double(elapsed) / 1_000_000_000, 0.001)
        func rate(_ value: Int) -> String {
            String(format: "%6.1f/s", Double(value) / elapsedSeconds)
        }
        func interval(_ total: UInt64, _ count: Int, _ maximum: UInt64) -> String {
            guard count > 0 else {
                return "avg   n/a   max   n/a"
            }
            let averageMs = Double(total) / Double(count) / 1_000_000
            let maximumMs = Double(maximum) / 1_000_000
            return String(format: "avg %6.2f ms  max %6.2f ms", averageMs, maximumMs)
        }
        func timing(_ total: UInt64, _ count: Int, _ maximum: UInt64) -> String {
            guard count > 0 else {
                return "avg   n/a   max   n/a  n    0"
            }
            let averageMs = Double(total) / Double(count) / 1_000_000
            let maximumMs = Double(maximum) / 1_000_000
            return String(format: "avg %6.2f ms  max %6.2f ms  n %4d", averageMs, maximumMs, count)
        }
        let regenerationSamples = snapshot.lineRegenerationSamples
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(4)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: "; ")
        let regenerationSampleLine = regenerationSamples.isEmpty ? "" : "\n                   regen refs \(regenerationSamples)"

        print("""
        Horizontal move rate:
          mode \(snapshotMode), selected \(snapshotSelectedCount), window \(String(format: "%.2f", elapsedSeconds)) s
          input    cursor \(rate(snapshot.cursorEvents))  nil \(rate(snapshot.cursorNilEvents))  key \(rate(snapshot.keyMoves))
          move     attempts \(rate(snapshot.moveAttempts))  accepted \(rate(snapshot.moveAccepted))  no-op \(rate(snapshot.moveNoops))
          pipeline body \(rate(snapshot.bodyPasses))  metal update \(rate(snapshot.metalUpdates))  metal draw \(rate(snapshot.metalDraws))  forced \(rate(snapshot.metalForcedDraws))
          spacing  cursor \(interval(snapshot.cursorIntervalTotal, snapshot.cursorIntervalCount, snapshot.cursorIntervalMax))
          spacing  accepted \(interval(snapshot.acceptedIntervalTotal, snapshot.acceptedIntervalCount, snapshot.acceptedIntervalMax))
          board    line batch \(timing(snapshot.boardLineBatchTotalNanoseconds, snapshot.boardLineBatchBuilds, snapshot.boardLineBatchMaxNanoseconds))
                   selection batch \(timing(snapshot.boardSelectionBatchTotalNanoseconds, snapshot.boardSelectionBatchBuilds, snapshot.boardSelectionBatchMaxNanoseconds))
                   move patches \(timing(snapshot.boardMovePatchTotalNanoseconds, snapshot.boardMovePatchBuilds, snapshot.boardMovePatchMaxNanoseconds))
                   selection patches \(timing(snapshot.boardSelectionPatchTotalNanoseconds, snapshot.boardSelectionPatchBuilds, snapshot.boardSelectionPatchMaxNanoseconds))
                   regen lines \(rate(snapshot.linePatchPrimitives))  endpoint \(rate(snapshot.lineEndpointPatches))  xlate lines \(rate(snapshot.lineTranslationPrimitives))
                   regen tri \(rate(snapshot.trianglePatchPrimitives))  xlate tri \(rate(snapshot.triangleTranslationPrimitives))  regen rect \(rate(snapshot.anchoredRectPatchPrimitives))  xlate rect \(rate(snapshot.anchoredRectTranslationPrimitives))
                   regen handles \(rate(snapshot.handlePatchPrimitives))  xlate handles \(rate(snapshot.handleTranslationPrimitives))\(regenerationSampleLine)
        """)
    }

    private static func addClamped(_ increment: UInt64, to total: inout UInt64) {
        let summed = total.addingReportingOverflow(increment)
        total = summed.overflow ? UInt64.max : summed.partialValue
    }

    private static func elapsedNanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end >= start else {
            return 0
        }
        return end - start
    }
}

enum HorizontalMoveStartDiagnostics {
    // Gated on $HORIZON_PROFILE — dev-only move instrumentation, off by default.
    private static let isEnabled = ProcessInfo.processInfo.environment["HORIZON_PROFILE"] != nil

    static func report(
        modeName: String,
        tracksCursor: Bool,
        selectedCount: Int,
        expandedCount: Int,
        details: String,
        timings: [(String, UInt64)]
    ) {
        guard isEnabled else {
            return
        }

        let total = timings.reduce(UInt64(0)) { partial, timing in
            let summed = partial.addingReportingOverflow(timing.1)
            return summed.overflow ? UInt64.max : summed.partialValue
        }
        let mode = tracksCursor ? "cursor" : "keyboard"
        let timingLines = timings.map { label, nanoseconds in
            let paddedLabel = label.padding(toLength: max(26, label.count), withPad: " ", startingAt: 0)
            return String(format: "  %@ %8.3f ms", paddedLabel, Double(nanoseconds) / 1_000_000)
        }.joined(separator: "\n")

        print("""
        Horizontal move start:
          mode \(modeName) \(mode), selected \(selectedCount), expanded \(expandedCount), total \(String(format: "%.3f", Double(total) / 1_000_000)) ms\(details.isEmpty ? "" : ", \(details)")
        \(timingLines)
        """)
    }
}

enum HorizontalMoveCommitDiagnostics {
    // Gated on $HORIZON_PROFILE — dev-only move instrumentation, off by default.
    private static let isEnabled = ProcessInfo.processInfo.environment["HORIZON_PROFILE"] != nil
    /// The per-edit board-change apply timing is opt-in — it fires on every
    /// board mutation, so it stays off unless explicitly requested.
    private static let isBoardChangeReportEnabled =
        ProcessInfo.processInfo.environment["HORIZON_PROFILE_BOARD_CHANGE"] != nil
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pendingCommitReturnNanoseconds: UInt64?
    nonisolated(unsafe) private static var pendingPostCommitNotes = [String]()

    static func report(
        modeName: String,
        selectedCount: Int,
        details: String,
        timings: [(String, UInt64)]
    ) {
        guard isEnabled else {
            return
        }

        let total = timings.reduce(UInt64(0)) { partial, timing in
            let summed = partial.addingReportingOverflow(timing.1)
            return summed.overflow ? UInt64.max : summed.partialValue
        }
        let timingLines = timings.map { label, nanoseconds in
            let paddedLabel = label.padding(toLength: max(26, label.count), withPad: " ", startingAt: 0)
            return String(format: "  %@ %8.3f ms", paddedLabel, Double(nanoseconds) / 1_000_000)
        }.joined(separator: "\n")

        print("""
        Horizontal move commit:
          mode \(modeName), selected \(selectedCount), total \(String(format: "%.3f", Double(total) / 1_000_000)) ms\(details.isEmpty ? "" : ", \(details)")
        \(timingLines)
        """)
    }

    static func reportProjectBoardChange(timings: [(String, UInt64)]) {
        guard isBoardChangeReportEnabled else {
            return
        }

        let total = timings.reduce(UInt64(0)) { partial, timing in
            let summed = partial.addingReportingOverflow(timing.1)
            return summed.overflow ? UInt64.max : summed.partialValue
        }
        let timingLines = timings.map { label, nanoseconds in
            let paddedLabel = label.padding(toLength: max(26, label.count), withPad: " ", startingAt: 0)
            return String(format: "  %@ %8.3f ms", paddedLabel, Double(nanoseconds) / 1_000_000)
        }.joined(separator: "\n")

        print("""
        Horizontal board change:
          total \(String(format: "%.3f", Double(total) / 1_000_000)) ms
        \(timingLines)
        """)
    }

    static func markCommitReturned() {
        guard isEnabled else {
            return
        }
        lock.lock()
        pendingCommitReturnNanoseconds = DispatchTime.now().uptimeNanoseconds
        pendingPostCommitNotes.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static var hasPendingPostCommitBody: Bool {
        guard isEnabled else {
            return false
        }
        lock.lock()
        let hasPending = pendingCommitReturnNanoseconds != nil
        lock.unlock()
        return hasPending
    }

    static func recordPostCommitBodyNote(_ note: String) {
        guard isEnabled else {
            return
        }
        lock.lock()
        if pendingCommitReturnNanoseconds != nil,
           !pendingPostCommitNotes.contains(note) {
            pendingPostCommitNotes.append(note)
        }
        lock.unlock()
    }

    static func reportPostCommitBody(timings: [(String, UInt64)]) {
        guard isEnabled else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let returnedAt: UInt64?
        let notes: [String]
        lock.lock()
        returnedAt = pendingCommitReturnNanoseconds
        pendingCommitReturnNanoseconds = nil
        notes = pendingPostCommitNotes
        pendingPostCommitNotes.removeAll(keepingCapacity: true)
        lock.unlock()
        guard let returnedAt else {
            return
        }

        let bodyTotal = timings.reduce(UInt64(0)) { partial, timing in
            let summed = partial.addingReportingOverflow(timing.1)
            return summed.overflow ? UInt64.max : summed.partialValue
        }
        let latency = now >= returnedAt ? now - returnedAt : 0
        let timingLines = timings.map { label, nanoseconds in
            let paddedLabel = label.padding(toLength: max(26, label.count), withPad: " ", startingAt: 0)
            return String(format: "  %@ %8.3f ms", paddedLabel, Double(nanoseconds) / 1_000_000)
        }.joined(separator: "\n")
        let noteLines = notes.isEmpty
            ? ""
            : "\n" + notes.map { "  \($0)" }.joined(separator: "\n")

        print("""
        Horizontal post-commit board body:
          latency \(String(format: "%.3f", Double(latency) / 1_000_000)) ms, measured body work \(String(format: "%.3f", Double(bodyTotal) / 1_000_000)) ms
        \(timingLines)\(noteLines)
        """)
    }
}
