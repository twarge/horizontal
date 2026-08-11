import Foundation

enum BoardLoadTimer {
    private final class TimingScope {
        var title: String
        var start = DispatchTime.now().uptimeNanoseconds
        var records = [TimingRecord]()

        init(title: String) {
            self.title = title
        }
    }

    private struct TimingRecord {
        var label: String
        var nanoseconds: UInt64
    }

    private struct Canvas2DProfile {
        var id: String
        var title: String
        var start = DispatchTime.now().uptimeNanoseconds
        var bodyCount = 0
        var drawCount = 0
        var records = [TimingRecord]()
        var notes = [String]()
        var reported = false
    }

    private static let scopeKey = "com.twarge.horizontal.load-profile.scope"
    private static let emitsModelLoadProfiles = false
    private static let emitsStandaloneLoadTiming = false
    private static let emitsCanvas2DLoadProfiles: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["HORIZONTAL_PROFILE_2D_LOAD"] == "1"
            || CommandLine.arguments.contains("--profile-2d-load")
        #else
        return false
        #endif
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var canvas2DProfile: Canvas2DProfile?

    static var isCanvas2DProfilingEnabled: Bool {
        emitsCanvas2DLoadProfiles
    }

    @discardableResult
    static func profile<T>(_ title: String, _ body: () throws -> T) rethrows -> T {
        guard emitsModelLoadProfiles else {
            return try body()
        }
        if activeScope != nil {
            return try measure(title, body)
        }

        let scope = TimingScope(title: title)
        Thread.current.threadDictionary[scopeKey] = scope
        defer {
            Thread.current.threadDictionary.removeObject(forKey: scopeKey)
            printSummary(title: scope.title, totalNanoseconds: elapsedNanoseconds(since: scope.start), records: scope.records)
        }
        return try body()
    }

    @discardableResult
    static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let elapsed = elapsedNanoseconds(since: start)
        activeScope?.records.append(TimingRecord(label: label, nanoseconds: elapsed))
        recordBoard2DStep(label, nanoseconds: elapsed)
        return value
    }

    @discardableResult
    static func measureStandalone<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard emitsStandaloneLoadTiming else {
            return try body()
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        recordStandalone(label, nanoseconds: elapsedNanoseconds(since: start))
        return value
    }

    static func timingStart() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &- start
    }

    static func recordStandalone(_ label: String, nanoseconds: UInt64) {
        guard emitsStandaloneLoadTiming else {
            return
        }
        print("Horizontal load timing: \(label) \(milliseconds(nanoseconds)) ms")
    }

    static func beginBoard2DLoad(id: String, summary: String) {
        beginCanvas2DLoad(id: id, title: "Horizontal board 2D load profile: \(summary)")
    }

    static func beginSchematic2DLoad(id: String, summary: String) {
        beginCanvas2DLoad(id: id, title: "Horizontal schematic 2D load profile: \(summary)")
    }

    private static func beginCanvas2DLoad(id: String, title: String) {
        guard emitsCanvas2DLoadProfiles else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = canvas2DProfile,
           existing.id == id {
            return
        }
        canvas2DProfile = Canvas2DProfile(id: id, title: title)
    }

    static func recordBoard2DStep(_ label: String, nanoseconds: UInt64, id: String? = nil) {
        guard emitsCanvas2DLoadProfiles else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard var profile = canvas2DProfile,
              !profile.reported,
              id == nil || profile.id == id else {
            return
        }
        profile.records.append(TimingRecord(label: label, nanoseconds: nanoseconds))
        canvas2DProfile = profile
    }

    static func recordBoard2DNote(_ note: String, id: String? = nil) {
        guard emitsCanvas2DLoadProfiles else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard var profile = canvas2DProfile,
              !profile.reported,
              id == nil || profile.id == id else {
            return
        }
        if !profile.notes.contains(note) {
            profile.notes.append(note)
        }
        canvas2DProfile = profile
    }

    @discardableResult
    static func recordPlaneTessellation<T>(_ body: () -> T) -> T {
        body()
    }

    static func flushPlaneTessellationSummary() {}
    static func markBodyEntered() {}
    static func markBodyExited() {}

    static func markFirstMetalDraw(_ id: String? = nil) {
        guard emitsCanvas2DLoadProfiles else {
            return
        }
        guard let id else {
            return
        }
        var summary: (title: String, total: UInt64, records: [TimingRecord], notes: [String])?

        lock.lock()
        if var profile = canvas2DProfile,
           !profile.reported,
           profile.id == id {
            profile.drawCount += 1
            profile.records.append(TimingRecord(label: "first Metal draw", nanoseconds: elapsedNanoseconds(since: profile.start)))
            profile.reported = true
            canvas2DProfile = profile
            summary = (
                profile.title,
                elapsedNanoseconds(since: profile.start),
                profile.records,
                profile.notes
            )
        }
        lock.unlock()

        if let summary {
            printSummary(
                title: summary.title,
                totalNanoseconds: summary.total,
                records: summary.records,
                notes: summary.notes
            )
        }
    }

    static func tickBody() {}
    static func tickBodyStart() -> DispatchTime { DispatchTime.now() }
    static func tickBodyEnd(_ start: DispatchTime) {
        guard emitsCanvas2DLoadProfiles else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard var profile = canvas2DProfile,
              !profile.reported else {
            return
        }
        profile.bodyCount += 1
        profile.records.append(
            TimingRecord(
                label: "SwiftUI body pass \(profile.bodyCount)",
                nanoseconds: elapsedNanoseconds(since: start.uptimeNanoseconds)
            )
        )
        canvas2DProfile = profile
    }

    static func tickDrawStart() -> DispatchTime { DispatchTime.now() }
    static func tickDrawEnd(_ start: DispatchTime) {}

    private static var activeScope: TimingScope? {
        Thread.current.threadDictionary[scopeKey] as? TimingScope
    }

    private static func printSummary(
        title: String,
        totalNanoseconds: UInt64,
        records: [TimingRecord],
        notes: [String] = []
    ) {
        print("\(title):")
        print("  total \(milliseconds(totalNanoseconds)) ms")

        var order = [String]()
        var groups = [String: (count: Int, total: UInt64, max: UInt64)]()
        for record in records {
            if groups[record.label] == nil {
                order.append(record.label)
                groups[record.label] = (0, 0, 0)
            }
            var group = groups[record.label] ?? (0, 0, 0)
            group.count += 1
            group.total &+= record.nanoseconds
            group.max = max(group.max, record.nanoseconds)
            groups[record.label] = group
        }

        for label in order {
            guard let group = groups[label] else { continue }
            let suffix = group.count > 1
                ? "  n \(group.count)  avg \(milliseconds(group.total / UInt64(group.count))) ms  max \(milliseconds(group.max)) ms"
                : ""
            print("  \(label.padding(toLength: 56, withPad: " ", startingAt: 0)) \(milliseconds(group.total)) ms\(suffix)")
        }

        for note in notes {
            print("  \(note)")
        }
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }
}
