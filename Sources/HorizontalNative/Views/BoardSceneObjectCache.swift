import Foundation

/// The board scene build's memory of what each object drew, so a rebuild
/// redraws only what changed and replays the rest.
///
/// A build is a fixed sequence of sections (the panels, each layer's tracks,
/// the vias on a layer, the holes, …), each drawing its objects in order into
/// the buckets it writes. The cache keeps, for each section, what it was drawn
/// from, the primitives it appended to each bucket, and where in those each of
/// its objects' primitives lie. On the next build a section whose source is
/// `==` to last time's appends its primitives whole; otherwise each object
/// whose input is `==` to last time's appends its own, and only the others
/// run their drawing code. Replay keeps the full build's order, so the
/// buckets, and the spans and metadata worked out from them, are exactly what
/// a full build would make (`BoardSceneVerifier` checks this).
///
/// Every build replaces the sections it ran, so what a build no longer draws
/// (a deleted object, a layer no longer rendered) is dropped with it. The
/// cache is cleared when the scene's style changes: its colours and widths.
///
/// Each section's primitives carry a stamp that changes only when they do,
/// and the composite groups they fall in. A build folds them, bucket by
/// bucket, into `BoardMetalElementBuckets.groupStamps`, from which the scene
/// tells the renderer which composite groups changed, so it uploads only
/// those.
final class BoardSceneObjectCache {
    fileprivate struct Chunk {
        var source: Any
        /// What the section appended to each bucket it writes, in `writes`
        /// order, text runs measured from the section's first line.
        var slices: [BoardMetalElementBatch]
        /// `[BoardSceneEntryKey: BoardSceneEntry<Input>]`, or nil for a
        /// section drawn whole.
        var entries: Any?
        /// The objects in the order they were drawn.
        var order: [BoardSceneEntryKey] = []
        /// Changes whenever `slices` does.
        var stamp: Int
        /// The composite groups in each slice.
        var groups: [Set<Int>]
    }

    /// How a build used the cache, for profiling and tests.
    struct Counters: Equatable {
        var sectionsReplayed = 0
        var sectionsBuilt = 0
        var objectsReplayed = 0
        var objectsBuilt = 0
    }

    private var chunks = [BoardSceneChunkKey: Chunk]()
    private var builtChunks = [BoardSceneChunkKey: Chunk]()
    private var styleKey: Int?
    private var nextStamp = 1
    /// Per bucket, per composite group, the stamps of the sections that drew
    /// into it this build, in order, folded together.
    private var groupHashers = [BoardSceneBucket: [Int: Hasher]]()
    private(set) var counters = Counters()

    /// Starts a build in `styleKey`'s style; a new style forgets everything.
    func beginBuild(styleKey: Int) {
        if styleKey != self.styleKey {
            chunks.removeAll()
            self.styleKey = styleKey
        }
        builtChunks.removeAll(keepingCapacity: true)
        groupHashers.removeAll(keepingCapacity: true)
        counters = Counters()
    }

    /// Keeps the sections this build ran, and only those, and returns what
    /// each bucket's composite groups were drawn from (`groupStamps`).
    func endBuild() -> [BoardSceneBucket: [Int: Int]] {
        chunks = builtChunks
        builtChunks.removeAll()
        let stamps = groupHashers.mapValues { $0.mapValues { $0.finalize() } }
        groupHashers.removeAll()
        return stamps
    }

    fileprivate func newStamp() -> Int {
        defer { nextStamp += 1 }
        return nextStamp
    }

    /// Notes that `key`'s section, at `stamp`, drew into `buckets`' groups.
    fileprivate func note(_ key: BoardSceneChunkKey, stamp: Int, writes: [BoardSceneBucket], groups: [Set<Int>]) {
        for (bucket, bucketGroups) in zip(writes, groups) {
            for group in bucketGroups {
                groupHashers[bucket, default: [:]][group, default: Hasher()].combine(key)
                groupHashers[bucket, default: [:]][group, default: Hasher()].combine(stamp)
            }
        }
    }

    func removeAll() {
        chunks.removeAll()
        builtChunks.removeAll()
        styleKey = nil
    }

    fileprivate func previous(_ key: BoardSceneChunkKey) -> Chunk? {
        chunks[key]
    }

    fileprivate func store(_ key: BoardSceneChunkKey, _ chunk: Chunk) {
        builtChunks[key] = chunk
    }

    fileprivate func count(replayedSection: Bool) {
        if replayedSection {
            counters.sectionsReplayed += 1
        } else {
            counters.sectionsBuilt += 1
        }
    }

    fileprivate func count(replayedObjects: Int, builtObjects: Int) {
        counters.objectsReplayed += replayedObjects
        counters.objectsBuilt += builtObjects
    }
}

/// A section of a scene build: its name and, inside the layer loop, its layer.
struct BoardSceneChunkKey: Hashable {
    var section: String
    var layer: Int?

    init(_ section: String, layer: Int? = nil) {
        self.section = section
        self.layer = layer
    }
}

/// One object of a section, told apart from others with the same id by how
/// many came before it.
struct BoardSceneEntryKey: Hashable {
    var id: String
    var occurrence: Int
}

/// Where one object's primitives lie in its section's slice of a bucket.
struct BoardSceneSliceRange: Equatable {
    var lines: Range<Int>
    var triangles: Range<Int>
    var anchoredRects: Range<Int>
    var textRuns: Range<Int>
}

struct BoardSceneEntry<Input: Equatable> {
    var input: Input
    /// One range per bucket the section writes.
    var ranges: [BoardSceneSliceRange]
}

/// How far a bucket had got when a section or an object started.
struct BoardSceneBatchMark: Equatable {
    var lines: Int
    var triangles: Int
    var anchoredRects: Int
    var textRuns: Int

    init(_ batch: BoardMetalElementBatch) {
        lines = batch.lines.count
        triangles = batch.triangles.count
        anchoredRects = batch.anchoredRects.count
        textRuns = batch.textRuns.count
    }

    /// The range from `self` to `end`, measured from `origin`.
    func range(to end: BoardSceneBatchMark, from origin: BoardSceneBatchMark) -> BoardSceneSliceRange {
        BoardSceneSliceRange(
            lines: (lines - origin.lines)..<(end.lines - origin.lines),
            triangles: (triangles - origin.triangles)..<(end.triangles - origin.triangles),
            anchoredRects: (anchoredRects - origin.anchoredRects)..<(end.anchoredRects - origin.anchoredRects),
            textRuns: (textRuns - origin.textRuns)..<(end.textRuns - origin.textRuns)
        )
    }
}

extension BoardMetalElementBatch {
    /// What was appended since `mark`, its text runs measured from the
    /// mark's first line.
    func slice(since mark: BoardSceneBatchMark) -> BoardMetalElementBatch {
        var slice = BoardMetalElementBatch()
        slice.lines = Array(lines[mark.lines...])
        slice.lineOwners = Array(lineOwners[mark.lines...])
        slice.lineLabelSizes = Array(lineLabelSizes[mark.lines...])
        slice.triangles = Array(triangles[mark.triangles...])
        slice.triangleOwners = Array(triangleOwners[mark.triangles...])
        slice.anchoredRects = Array(anchoredRects[mark.anchoredRects...])
        slice.anchoredRectOwners = Array(anchoredRectOwners[mark.anchoredRects...])
        slice.textRuns = textRuns[mark.textRuns...].map { run in
            var run = run
            run.lineStart -= mark.lines
            return run
        }
        return slice
    }

    /// Appends `range` of `section`, a section's slice, its text runs moved
    /// to where its lines land.
    mutating func append(_ section: BoardMetalElementBatch, range: BoardSceneSliceRange) {
        let lineOffset = lines.count - range.lines.lowerBound
        if !range.textRuns.isEmpty {
            textRuns.append(contentsOf: section.textRuns[range.textRuns].map { run in
                var run = run
                run.lineStart += lineOffset
                return run
            })
        }
        if !range.lines.isEmpty {
            lines.append(contentsOf: section.lines[range.lines])
            lineOwners.append(contentsOf: section.lineOwners[range.lines])
            lineLabelSizes.append(contentsOf: section.lineLabelSizes[range.lines])
        }
        if !range.triangles.isEmpty {
            triangles.append(contentsOf: section.triangles[range.triangles])
            triangleOwners.append(contentsOf: section.triangleOwners[range.triangles])
        }
        if !range.anchoredRects.isEmpty {
            anchoredRects.append(contentsOf: section.anchoredRects[range.anchoredRects])
            anchoredRectOwners.append(contentsOf: section.anchoredRectOwners[range.anchoredRects])
        }
    }
}

typealias BoardSceneBucket = ReferenceWritableKeyPath<BoardMetalElementBuckets, BoardMetalElementBatch>

/// One scene build's use of the cache. With no cache (a partial build, the
/// verifier's) every section and object is drawn.
struct BoardSceneBuild {
    let cache: BoardSceneObjectCache?
    let buckets: BoardMetalElementBuckets

    /// Ends the build: the buckets learn what their composite groups were
    /// drawn from, so the scene can upload only the groups that changed.
    func finish() {
        guard let cache else {
            return
        }
        buckets.groupStamps = cache.endBuild()
    }

    /// A section drawn whole from `source`: replayed while `source` is
    /// unchanged, else drawn by `build`.
    func section<Source: Equatable>(
        _ key: BoardSceneChunkKey,
        writes: [BoardSceneBucket],
        source: Source,
        _ build: () -> Void
    ) {
        guard let cache else {
            build()
            return
        }
        if replay(key, writes: writes, source: source, in: cache) {
            return
        }
        let marks = writes.map { BoardSceneBatchMark(buckets[keyPath: $0]) }
        build()
        let slices = zip(writes, marks).map { buckets[keyPath: $0.0].slice(since: $0.1) }
        store(key, writes: writes, in: cache, chunk: BoardSceneObjectCache.Chunk(
            source: source,
            slices: slices,
            entries: nil,
            stamp: cache.newStamp(),
            groups: slices.map(\.compositeGroups)
        ))
        cache.count(replayedSection: false)
    }

    /// A section of objects drawn from `source`: replayed whole while
    /// `source` is unchanged; else `build` draws each object through the
    /// `BoardSceneObjects` it is handed, which replays an object whose input
    /// is unchanged.
    func section<Source: Equatable, Input: Equatable>(
        _ key: BoardSceneChunkKey,
        writes: [BoardSceneBucket],
        source: Source,
        objects _: Input.Type,
        _ build: (BoardSceneObjects<Input>) -> Void
    ) {
        guard let cache else {
            build(BoardSceneObjects<Input>(buckets: buckets, writes: writes, marks: nil, previous: nil))
            return
        }
        if replay(key, writes: writes, source: source, in: cache) {
            return
        }
        let marks = writes.map { BoardSceneBatchMark(buckets[keyPath: $0]) }
        let previousChunk = cache.previous(key)
        let previous = previousChunk.flatMap { chunk -> (slices: [BoardMetalElementBatch], entries: [BoardSceneEntryKey: BoardSceneEntry<Input>])? in
            guard let entries = chunk.entries as? [BoardSceneEntryKey: BoardSceneEntry<Input>],
                  chunk.slices.count == writes.count else {
                return nil
            }
            return (chunk.slices, entries)
        }
        let objects = BoardSceneObjects<Input>(buckets: buckets, writes: writes, marks: marks, previous: previous)
        build(objects)
        cache.count(replayedSection: false)
        cache.count(replayedObjects: objects.replayed, builtObjects: objects.built)
        // Every object replayed, in the same order: the section drew what it
        // drew last time, whatever its source, and keeps its stamp, so its
        // composite groups need no upload.
        if objects.built == 0, let previousChunk, previous != nil, objects.order == previousChunk.order {
            var chunk = previousChunk
            chunk.source = source
            chunk.entries = objects.entries
            store(key, writes: writes, in: cache, chunk: chunk)
            return
        }
        let slices = zip(writes, marks).map { buckets[keyPath: $0.0].slice(since: $0.1) }
        store(key, writes: writes, in: cache, chunk: BoardSceneObjectCache.Chunk(
            source: source,
            slices: slices,
            entries: objects.entries,
            order: objects.order,
            stamp: cache.newStamp(),
            groups: slices.map(\.compositeGroups)
        ))
    }

    private func store(
        _ key: BoardSceneChunkKey,
        writes: [BoardSceneBucket],
        in cache: BoardSceneObjectCache,
        chunk: BoardSceneObjectCache.Chunk
    ) {
        cache.store(key, chunk)
        cache.note(key, stamp: chunk.stamp, writes: writes, groups: chunk.groups)
    }

    private func replay<Source: Equatable>(
        _ key: BoardSceneChunkKey,
        writes: [BoardSceneBucket],
        source: Source,
        in cache: BoardSceneObjectCache
    ) -> Bool {
        guard let previous = cache.previous(key),
              previous.slices.count == writes.count,
              let previousSource = previous.source as? Source,
              previousSource == source else {
            return false
        }
        for (keyPath, slice) in zip(writes, previous.slices) {
            buckets[keyPath: keyPath].append(contentsOf: slice)
        }
        store(key, writes: writes, in: cache, chunk: previous)
        cache.count(replayedSection: true)
        return true
    }
}

extension BoardMetalElementBatch {
    /// The composite groups the batch's primitives fall in.
    var compositeGroups: Set<Int> {
        var groups = Set<Int>()
        for line in lines { groups.insert(line.compositeGroup) }
        for triangle in triangles { groups.insert(triangle.compositeGroup) }
        for rect in anchoredRects { groups.insert(rect.compositeGroup) }
        return groups
    }
}

/// The objects of one section of a build. Calling it with an object's id and
/// input draws the object with `body`, or, when last build drew an object of
/// that id (and occurrence) from an `==` input, appends what it drew then.
final class BoardSceneObjects<Input: Equatable> {
    private let buckets: BoardMetalElementBuckets
    private let writes: [BoardSceneBucket]
    private let marks: [BoardSceneBatchMark]?
    private let previous: (slices: [BoardMetalElementBatch], entries: [BoardSceneEntryKey: BoardSceneEntry<Input>])?
    private var occurrences = [String: Int]()
    fileprivate private(set) var entries = [BoardSceneEntryKey: BoardSceneEntry<Input>]()
    fileprivate private(set) var order = [BoardSceneEntryKey]()
    fileprivate private(set) var replayed = 0
    fileprivate private(set) var built = 0

    fileprivate init(
        buckets: BoardMetalElementBuckets,
        writes: [BoardSceneBucket],
        marks: [BoardSceneBatchMark]?,
        previous: (slices: [BoardMetalElementBatch], entries: [BoardSceneEntryKey: BoardSceneEntry<Input>])?
    ) {
        self.buckets = buckets
        self.writes = writes
        self.marks = marks
        self.previous = previous
    }

    func callAsFunction(_ id: String, _ input: Input, _ body: () -> Void) {
        guard let marks else {
            body()
            return
        }
        let occurrence = occurrences[id, default: 0]
        occurrences[id] = occurrence + 1
        let key = BoardSceneEntryKey(id: id, occurrence: occurrence)
        let starts = writes.map { BoardSceneBatchMark(buckets[keyPath: $0]) }
        if let previous, let entry = previous.entries[key], entry.input == input {
            for index in writes.indices {
                buckets[keyPath: writes[index]].append(previous.slices[index], range: entry.ranges[index])
            }
            replayed += 1
        } else {
            body()
            built += 1
        }
        var ranges = [BoardSceneSliceRange]()
        ranges.reserveCapacity(writes.count)
        for index in writes.indices {
            let end = BoardSceneBatchMark(buckets[keyPath: writes[index]])
            ranges.append(starts[index].range(to: end, from: marks[index]))
        }
        entries[key] = BoardSceneEntry(input: input, ranges: ranges)
        order.append(key)
    }
}

/// A package's omit flags, as the scene build hides its geometry by them.
struct BoardScenePackageOmit: Equatable {
    var silk: Bool
    var outline: Bool
}

/// What the scene build draws a plane from (`planeSceneInput`).
struct BoardScenePlaneInput: Equatable {
    var fragments: [HorizontalPlaneFragment]
    /// The outline drawn while the plane has no fills.
    var outline: [HorizontalPoint]?
    var tessellated: Bool
}
