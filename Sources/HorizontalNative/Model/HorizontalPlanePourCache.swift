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

    init() {}

    /// The fill last poured for `planeID` from inputs matching `signature`, or
    /// nil when this plane has to be poured again.
    func fragments(for planeID: String, signature: Int) -> [HorizontalPlaneFragment]? {
        guard let entry = entries[planeID], entry.signature == signature else {
            return nil
        }
        return entry.fragments
    }

    mutating func store(planeID: String, signature: Int, fragments: [HorizontalPlaneFragment]) {
        entries[planeID] = Entry(signature: signature, fragments: fragments)
    }

    /// Drops planes that no longer exist, so deleting one cannot keep its fill
    /// alive in memory.
    mutating func retain(planeIDs: Set<String>) {
        entries = entries.filter { planeIDs.contains($0.key) }
    }

    var count: Int { entries.count }
}

/// Collects one priority tier's poured planes from several threads.
///
/// Results are stored by index and read back in tier order, so a pour does not
/// depend on which thread finished first: the same board must produce the same
/// fills every time, not merely correct ones.
final class PlaneTierResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [(plane: HorizontalPlane, signature: Int)?]
    private var finished = 0

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func store(_ outcome: (plane: HorizontalPlane, signature: Int), at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        slots[index] = outcome
    }

    /// Counts one finished plane and reports it. Progress is a count, so it can
    /// be ordered by completion even while the results are not.
    func reportCompletion(_ onProgress: (@Sendable (Int, Int) -> Void)?, total: Int, base: Int) {
        lock.lock()
        finished += 1
        let done = base + finished
        lock.unlock()
        onProgress?(done, total)
    }

    func ordered() -> [(plane: HorizontalPlane, signature: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}
