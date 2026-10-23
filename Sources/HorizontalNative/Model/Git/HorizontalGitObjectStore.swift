import CryptoKit
import Foundation
import zlib

/// The objects of a repository on disk, read as git reads them: loose ones
/// under `.git/objects/xx/`, and packs beside their version 2 indexes, a
/// delta resolved against a base in its own pack, by offset, or anywhere in
/// the store, by name (`Documentation/gitformat-pack.txt`). A pack just
/// fetched joins it before it is written. Not thread-safe: one task uses it.
final class HorizontalGitObjectStore {
    private let objectsDirectory: URL
    private var packs: [StoredPack]
    private var fetched = [HorizontalGitPack]()

    private var cache = [CacheKey: HorizontalGitPack.Object]()
    private var cacheOrder = [CacheKey]()
    private var cacheBytes = 0
    private let cacheLimit: Int

    private struct CacheKey: Hashable {
        var pack: Int
        var offset: Int
    }

    init(gitDirectory: URL, cacheLimit: Int = 64 << 20) throws {
        objectsDirectory = gitDirectory.appendingPathComponent("objects", isDirectory: true)
        self.cacheLimit = cacheLimit
        let packDirectory = objectsDirectory.appendingPathComponent("pack", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: packDirectory.path)) ?? []
        packs = try names.filter { $0.hasSuffix(".idx") }.sorted().compactMap { name in
            let pack = packDirectory.appendingPathComponent(String(name.dropLast(4)) + ".pack")
            guard FileManager.default.fileExists(atPath: pack.path) else { return nil }
            return try StoredPack(index: packDirectory.appendingPathComponent(name), pack: pack)
        }
    }

    /// A pack fetched into this repository, read before it is written out.
    func add(_ pack: HorizontalGitPack) {
        fetched.append(pack)
    }

    func contains(_ id: Data) -> Bool {
        fetched.contains { $0.contains(id) }
            || packs.contains { $0.offset(of: id) != nil }
            || FileManager.default.fileExists(atPath: loosePath(id).path)
    }

    /// The object named `id`.
    func object(_ id: Data) throws -> HorizontalGitPack.Object {
        for pack in fetched where pack.contains(id) {
            return try pack.object(id)
        }
        for (number, pack) in packs.enumerated() {
            if let offset = pack.offset(of: id) {
                return try object(inPack: number, at: offset, depth: 0)
            }
        }
        let loose = loosePath(id)
        guard let data = try? Data(contentsOf: loose) else {
            throw HorizontalGitCloneError.corruptPack("the object \(HorizontalGitPack.hex(id)) is missing")
        }
        return try Self.looseObject(data)
    }

    /// The parents a commit names.
    func parents(ofCommit id: Data) throws -> [Data] {
        let commit = try object(id)
        guard commit.kind == .commit else {
            throw HorizontalGitCloneError.corruptPack("\(HorizontalGitPack.hex(id)) isn't a commit")
        }
        var parents = [Data]()
        for line in String(decoding: commit.content, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            if line.hasPrefix("parent "), let parent = HorizontalGitPack.id(hex: String(line.dropFirst(7).prefix(40))) {
                parents.append(parent)
            }
        }
        return parents
    }

    /// The committer time a commit records, for walking history newest first.
    func commitTime(_ id: Data) throws -> Int {
        let commit = try object(id)
        for line in String(decoding: commit.content, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("committer ") {
                // "committer Name <email> 1700000000 +0100"
                let fields = line.split(separator: " ")
                if fields.count >= 2, let time = Int(fields[fields.count - 2]) { return time }
            }
            if line.isEmpty { break }
        }
        return 0
    }

    // MARK: - Packs

    private func object(inPack number: Int, at offset: Int, depth: Int) throws -> HorizontalGitPack.Object {
        let key = CacheKey(pack: number, offset: offset)
        if let cached = cache[key] {
            return cached
        }
        guard depth < 10_000 else {
            throw HorizontalGitCloneError.corruptPack("a delta chain doesn't end")
        }
        let pack = packs[number]
        let header = try pack.header(at: offset)
        let content = try pack.inflate(at: header.dataStart, size: header.size)
        let object: HorizontalGitPack.Object
        switch header.type {
        case 1...4:
            object = HorizontalGitPack.Object(kind: HorizontalGitPack.Kind(rawValue: header.type)!, content: content)
        case 6:
            let base = try self.object(inPack: number, at: header.baseOffset!, depth: depth + 1)
            object = HorizontalGitPack.Object(kind: base.kind, content: try HorizontalGitPack.apply(delta: content, to: base.content))
        case 7:
            let base = try self.object(header.baseID!)
            object = HorizontalGitPack.Object(kind: base.kind, content: try HorizontalGitPack.apply(delta: content, to: base.content))
        default:
            throw HorizontalGitCloneError.corruptPack("an object of type \(header.type)")
        }
        remember(key, object)
        return object
    }

    private func remember(_ key: CacheKey, _ object: HorizontalGitPack.Object) {
        let size = object.content.count
        guard size <= cacheLimit / 4 else { return }
        cache[key] = object
        cacheOrder.append(key)
        cacheBytes += size
        var dropped = 0
        while cacheBytes > cacheLimit, dropped < cacheOrder.count {
            if let removed = cache.removeValue(forKey: cacheOrder[dropped]) {
                cacheBytes -= removed.content.count
            }
            dropped += 1
        }
        if dropped > 0 {
            cacheOrder.removeFirst(dropped)
        }
    }

    // MARK: - Loose objects

    private func loosePath(_ id: Data) -> URL {
        let hex = HorizontalGitPack.hex(id)
        return objectsDirectory.appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(hex.dropFirst(2)))
    }

    /// "<type> <size>\0<content>", deflated.
    static func looseObject(_ data: Data) throws -> HorizontalGitPack.Object {
        let raw = try inflateWhole(data)
        guard let space = raw.firstIndex(of: 0x20), let nul = raw[space...].firstIndex(of: 0),
              let size = Int(String(decoding: raw[(space + 1)..<nul], as: UTF8.self)), raw.count - nul - 1 == size else {
            throw HorizontalGitCloneError.corruptPack("a loose object is malformed")
        }
        let kinds: [String: HorizontalGitPack.Kind] = ["commit": .commit, "tree": .tree, "blob": .blob, "tag": .tag]
        guard let kind = kinds[String(decoding: raw[..<space], as: UTF8.self)] else {
            throw HorizontalGitCloneError.corruptPack("a loose object of an unknown type")
        }
        return HorizontalGitPack.Object(kind: kind, content: Array(raw[(nul + 1)...]))
    }

    /// A whole zlib stream whose inflated size isn't known beforehand.
    static func inflateWhole(_ data: Data) throws -> [UInt8] {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HorizontalGitCloneError.corruptPack("zlib wouldn't start")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.baseAddress else { throw HorizontalGitCloneError.corruptPack("an empty loose object") }
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            while status != Z_STREAM_END {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return out.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw HorizontalGitCloneError.corruptPack("a loose object didn't inflate")
                }
                output.append(contentsOf: chunk[0..<produced])
                if status == Z_OK, produced == 0, stream.avail_in == 0 {
                    throw HorizontalGitCloneError.corruptPack("a loose object is cut short")
                }
            }
        }
        return output
    }
}

/// A pack on disk and its index, read in place: the index finds an
/// object's offset, the pack is mapped rather than read.
private final class StoredPack {
    struct Header {
        var type: UInt8
        var size: Int
        var dataStart: Int
        var baseOffset: Int?
        var baseID: Data?
    }

    private let index: Data
    private let pack: Data
    private let count: Int

    init(index indexURL: URL, pack packURL: URL) throws {
        index = try Data(contentsOf: indexURL, options: .alwaysMapped)
        pack = try Data(contentsOf: packURL, options: .alwaysMapped)
        guard index.count >= 8 + 1024, index.prefix(8).elementsEqual([0xFF, 0x74, 0x4F, 0x63, 0, 0, 0, 2]) else {
            throw HorizontalGitCloneError.corruptPack("\(indexURL.lastPathComponent) isn't a version 2 pack index")
        }
        guard pack.count >= 32, pack.prefix(4).elementsEqual([0x50, 0x41, 0x43, 0x4B]) else {
            throw HorizontalGitCloneError.corruptPack("\(packURL.lastPathComponent) isn't a pack")
        }
        count = Int(Self.word(index, 8 + 255 * 4))
        guard index.count >= 8 + 1024 + count * 28 + 40 else {
            throw HorizontalGitCloneError.corruptPack("\(indexURL.lastPathComponent) is cut short")
        }
    }

    /// Where in the pack `id` starts, by the index's fan-out and a binary
    /// search of its sorted names.
    func offset(of id: Data) -> Int? {
        guard id.count == 20 else { return nil }
        let first = Int(id[id.startIndex])
        var low = first == 0 ? 0 : Int(Self.word(index, 8 + (first - 1) * 4))
        var high = Int(Self.word(index, 8 + first * 4))
        let names = 8 + 1024
        let found: Int? = index.withUnsafeBytes { raw in
            id.withUnsafeBytes { wanted in
                while low < high {
                    let middle = (low + high) / 2
                    let order = memcmp(raw.baseAddress! + names + middle * 20, wanted.baseAddress!, 20)
                    if order == 0 { return middle }
                    if order < 0 { low = middle + 1 } else { high = middle }
                }
                return nil
            }
        }
        guard let found else { return nil }
        let offsets = names + count * 24
        let small = Self.word(index, offsets + found * 4)
        if small & 0x8000_0000 == 0 {
            return Int(small)
        }
        let large = offsets + count * 4 + Int(small & 0x7FFF_FFFF) * 8
        return Int(UInt64(Self.word(index, large)) << 32 | UInt64(Self.word(index, large + 4)))
    }

    func header(at offset: Int) throws -> Header {
        try pack.withUnsafeBytes { raw -> Header in
            let bytes = raw.bindMemory(to: UInt8.self)
            var cursor = offset
            func next() throws -> UInt8 {
                guard cursor < bytes.count - 20 else { throw HorizontalGitCloneError.corruptPack("an object runs past its pack") }
                defer { cursor += 1 }
                return bytes[cursor]
            }
            var byte = try next()
            let type = (byte >> 4) & 0x07
            var size = Int(byte & 0x0F)
            var shift = 4
            while byte & 0x80 != 0 {
                byte = try next()
                size |= Int(byte & 0x7F) << shift
                shift += 7
            }
            var header = Header(type: type, size: size, dataStart: 0)
            if type == 6 {
                byte = try next()
                var distance = Int(byte & 0x7F)
                while byte & 0x80 != 0 {
                    byte = try next()
                    distance = ((distance + 1) << 7) | Int(byte & 0x7F)
                }
                guard distance > 0, distance <= offset else {
                    throw HorizontalGitCloneError.corruptPack("a delta's base is outside the pack")
                }
                header.baseOffset = offset - distance
            } else if type == 7 {
                guard cursor + 20 <= bytes.count - 20 else { throw HorizontalGitCloneError.corruptPack("an object runs past its pack") }
                header.baseID = Data(bytes[cursor..<cursor + 20])
                cursor += 20
            }
            header.dataStart = cursor
            return header
        }
    }

    func inflate(at start: Int, size: Int) throws -> [UInt8] {
        try pack.withUnsafeBytes { try HorizontalGitPack.inflate($0, at: start, size: size).0 }
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            var value: UInt32 = 0
            for index in offset..<offset + 4 {
                value = value << 8 | UInt32(raw[index])
            }
            return value
        }
    }
}
