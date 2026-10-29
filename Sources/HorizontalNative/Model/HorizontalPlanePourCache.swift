import Foundation

/// Remembers what each plane was poured from, so a re-pour only redoes the
/// planes an edit could actually have changed.
///
/// A pour is per-plane independent (within a priority tier), and most edits
/// touch one layer, so most planes usually have nothing to recompute. The entry
/// keeps the fill as well as the fingerprint: reusing the stored fragments is
/// exactly what re-pouring identical inputs would produce, and it means the
/// cache does not depend on the board it is handed still carrying the last
/// fill — undo, or a Clear All Planes, cannot make a skip serve the wrong
/// geometry.
struct HorizontalPlanePourCache: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var signature: Int
        var fragments: [HorizontalPlaneFragment]
    }

    private var entries: [String: Entry] = [:]
    /// Each plane's fill before its latest, so Undo, which puts the board
    /// back as it was a step ago, finds that fill rather than pouring it
    /// again. Only an exact match on the inputs is ever served from here.
    private var previousEntries: [String: Entry] = [:]

    init() {}

    /// The fill last poured for `planeID` from inputs matching `signature`, or
    /// nil when this plane has to be poured again.
    func fragments(for planeID: String, signature: Int) -> [HorizontalPlaneFragment]? {
        if let entry = entries[planeID], entry.signature == signature {
            return entry.fragments
        }
        if let entry = previousEntries[planeID], entry.signature == signature {
            return entry.fragments
        }
        return nil
    }

    mutating func store(planeID: String, signature: Int, fragments: [HorizontalPlaneFragment]) {
        if let current = entries[planeID], current.signature != signature {
            previousEntries[planeID] = current
        }
        entries[planeID] = Entry(signature: signature, fragments: fragments)
    }

    /// Drops planes that no longer exist, so deleting one cannot keep its fill
    /// alive in memory.
    mutating func retain(planeIDs: Set<String>) {
        entries = entries.filter { planeIDs.contains($0.key) }
        previousEntries = previousEntries.filter { planeIDs.contains($0.key) }
    }

    var count: Int { entries.count }
}

/// Collects one priority tier's poured planes from several threads.
///
/// Results are stored by index and read back in tier order, so a pour does not
/// depend on which thread finished first: the same board must produce the same
/// fills every time, not merely correct ones.
final class PlaneTierResults: @unchecked Sendable {
    /// One plane's fill, the inputs it was poured from, and whether it was
    /// poured afresh (false: taken from the cache).
    struct Outcome {
        var plane: HorizontalPlane
        var signature: Int
        var poured: Bool
    }

    private let lock = NSLock()
    private var slots: [Outcome?]
    private var finished = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func store(_ outcome: Outcome, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        slots[index] = outcome
    }

    /// Counts one finished plane and reports it. Progress is a count, so it can
    /// be ordered by completion even while the results are not. The report is
    /// made under the lock: made after it, two planes finishing together could
    /// report 3 before 2, and the pour's ring stepped back. The app's callbacks
    /// only yield to a stream, so holding the lock through one costs nothing.
    func reportCompletion(_ onProgress: (@Sendable (Int, Int) -> Void)?, total: Int, base: Int) {
        lock.lock()
        defer { lock.unlock() }
        finished += 1
        onProgress?(base + finished, total)
    }

    /// Every slot in tier order, nil where a cancelled pour left a plane out.
    func slotsInOrder() -> [Outcome?] {
        lock.lock()
        defer { lock.unlock() }
        return slots
    }
}
