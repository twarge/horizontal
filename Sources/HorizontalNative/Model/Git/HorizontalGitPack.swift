import CryptoKit
import Foundation
import zlib

/// A pack received from a git server, read as `git index-pack` reads one:
/// every object inflated, deltas resolved against their bases, each named by
/// the SHA-1 of its type, size and content, and the CRC of its raw bytes kept
/// for the pack's index (`Documentation/gitformat-pack.txt`). The objects stay
/// in the pack; a bounded cache keeps recently resolved ones, the bases a
/// delta chain comes back to, so a history far bigger than memory reads in
/// one pass.
final class HorizontalGitPack {
    enum Kind: UInt8 {
        case commit = 1, tree = 2, blob = 3, tag = 4

        var name: String {
            switch self {
            case .commit: "commit"
            case .tree: "tree"
            case .blob: "blob"
            case .tag: "tag"
            }
        }
    }

    struct Object {
        var kind: Kind
        var content: [UInt8]
    }

    private struct Entry {
        var offset: Int
        /// 1–4 an object, 6 a delta on the object `baseOffset` bytes back, 7 a
        /// delta on the object named `baseID`.
        var type: UInt8
        var size: Int
        var dataStart: Int
        var end: Int
        var baseOffset: Int?
        var baseID: Data?
    }

    private let bytes: [UInt8]
    private var entries = [Entry]()
    private(set) var objectIDs = [Data]()
    private var crcs = [UInt32]()
    private var entryByOffset = [Int: Int]()
    private var entryByID = [Data: Int]()

    private var cache = [Int: Object]()
    private var cacheOrder = [Int]()
    private var cacheBytes = 0
    private let cacheLimit: Int

    /// The pack's own name: the SHA-1 its last 20 bytes carry.
    let checksum: Data
    let objectCount: Int

    init(_ data: Data, cacheLimit: Int = 64 << 20) throws {
        bytes = [UInt8](data)
        self.cacheLimit = cacheLimit
        guard bytes.count >= 32, bytes[0..<4].elementsEqual([0x50, 0x41, 0x43, 0x4B]) else {
            throw HorizontalGitCloneError.corruptPack("it isn't a pack")
        }
        let version = Self.bigEndian(bytes, 4)
        guard version == 2 || version == 3 else {
            throw HorizontalGitCloneError.corruptPack("pack version \(version)")
        }
        objectCount = Int(Self.bigEndian(bytes, 8))
        checksum = Data(bytes[(bytes.count - 20)...])
        let computed = bytes.withUnsafeBufferPointer { buffer in
            Data(Insecure.SHA1.hash(data: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: buffer[0..<(buffer.count - 20)]))))
        }
        guard computed == checksum else {
            throw HorizontalGitCloneError.corruptPack("its checksum doesn't match")
        }
    }

    /// Reads every object: where it ends, what it is and its name. Call once.
    func index(progress: (Int, Int) -> Void = { _, _ in }) throws {
        var cursor = 12
        var deferred = [Int]()
        for number in 0..<objectCount {
            if number % 256 == 0 {
                try Task.checkCancellation()
                progress(number, objectCount)
            }
            guard cursor < bytes.count - 20 else {
                throw HorizontalGitCloneError.corruptPack("it ends before its last object")
            }
            let offset = cursor
            var byte = bytes[cursor]
            cursor += 1
            let type = (byte >> 4) & 0x07
            var size = Int(byte & 0x0F)
            var shift = 4
            while byte & 0x80 != 0 {
                byte = bytes[cursor]
                cursor += 1
                size |= Int(byte & 0x7F) << shift
                shift += 7
            }
            var entry = Entry(offset: offset, type: type, size: size, dataStart: 0, end: 0)
            switch type {
            case 1...4:
                break
            case 6:
                // The distance back to the base, big-endian in 7-bit groups,
                // each continued group one more than it reads.
                byte = bytes[cursor]
                cursor += 1
                var distance = Int(byte & 0x7F)
                while byte & 0x80 != 0 {
                    byte = bytes[cursor]
                    cursor += 1
                    distance = ((distance + 1) << 7) | Int(byte & 0x7F)
                }
                guard distance > 0, distance <= offset else {
                    throw HorizontalGitCloneError.corruptPack("a delta's base is outside the pack")
                }
                entry.baseOffset = offset - distance
            case 7:
                entry.baseID = Data(bytes[cursor..<cursor + 20])
                cursor += 20
            default:
                throw HorizontalGitCloneError.corruptPack("an object of type \(type)")
            }
            entry.dataStart = cursor
            let (content, consumed) = try inflate(at: cursor, size: size)
            cursor += consumed
            entry.end = cursor
            let index = entries.count
            entries.append(entry)
            entryByOffset[offset] = index
            objectIDs.append(Data())
            crcs.append(bytes.withUnsafeBufferPointer { buffer in
                UInt32(crc32(0, buffer.baseAddress! + offset, uInt(cursor - offset)))
            })
            if type <= 4 {
                let object = Object(kind: Kind(rawValue: type)!, content: content)
                name(index, object)
                remember(index, object)
            } else if canResolve(entry) {
                let object = try resolve(index, delta: content)
                name(index, object)
            } else {
                deferred.append(index)
            }
        }
        guard cursor == bytes.count - 20 else {
            throw HorizontalGitCloneError.corruptPack("it has bytes after its last object")
        }
        // Deltas on a base later in the pack, named by id: each pass resolves
        // the ones whose base has a name by now.
        while !deferred.isEmpty {
            let before = deferred.count
            deferred = try deferred.filter { index in
                guard canResolve(entries[index]) else { return true }
                name(index, try object(atEntry: index))
                return false
            }
            guard deferred.count < before else {
                throw HorizontalGitCloneError.corruptPack("a delta's base isn't in the pack")
            }
        }
        progress(objectCount, objectCount)
    }

    /// The object named `id`.
    func object(_ id: Data) throws -> Object {
        guard let index = entryByID[id] else {
            throw HorizontalGitCloneError.corruptPack("the object \(Self.hex(id)) is missing")
        }
        return try object(atEntry: index)
    }

    /// Git's pack index, version 2, for this pack: what `git index-pack`
    /// writes beside it.
    func indexFile() -> Data {
        let order = objectIDs.indices.sorted { objectIDs[$0].lexicographicallyPrecedes(objectIDs[$1]) }
        var out = Data([0xFF, 0x74, 0x4F, 0x63, 0, 0, 0, 2])
        var fanout = [UInt32](repeating: 0, count: 256)
        for id in objectIDs {
            fanout[Int(id[id.startIndex])] += 1
        }
        var running: UInt32 = 0
        for first in 0..<256 {
            running += fanout[first]
            Self.append(running, to: &out)
        }
        for index in order { out.append(objectIDs[index]) }
        for index in order { Self.append(crcs[index], to: &out) }
        var large = [UInt64]()
        for index in order {
            let offset = entries[index].offset
            if offset < 0x8000_0000 {
                Self.append(UInt32(offset), to: &out)
            } else {
                Self.append(0x8000_0000 | UInt32(large.count), to: &out)
                large.append(UInt64(offset))
            }
        }
        for offset in large {
            Self.append(UInt32(offset >> 32), to: &out)
            Self.append(UInt32(offset & 0xFFFF_FFFF), to: &out)
        }
        out.append(checksum)
        out.append(Data(Insecure.SHA1.hash(data: out)))
        return out
    }

    /// The SHA-1 git names an object by.
    static func id(of object: Object) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("\(object.kind.name) \(object.content.count)\0".utf8))
        object.content.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return Data(hasher.finalize())
    }

    static func hex(_ id: Data) -> String {
        id.map { String(format: "%02x", $0) }.joined()
    }

    static func id(hex: String) -> Data? {
        guard hex.count == 40 else { return nil }
        var data = Data(capacity: 20)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    // MARK: - Resolving

    private func name(_ index: Int, _ object: Object) {
        let id = Self.id(of: object)
        objectIDs[index] = id
        entryByID[id] = index
    }

    private func canResolve(_ entry: Entry) -> Bool {
        if let baseID = entry.baseID {
            return entryByID[baseID] != nil
        }
        return true
    }

    private func object(atEntry index: Int) throws -> Object {
        if let cached = cache[index] {
            return cached
        }
        let entry = entries[index]
        let (content, _) = try inflate(at: entry.dataStart, size: entry.size)
        if entry.type <= 4 {
            let object = Object(kind: Kind(rawValue: entry.type)!, content: content)
            remember(index, object)
            return object
        }
        return try resolve(index, delta: content)
    }

    private func resolve(_ index: Int, delta: [UInt8]) throws -> Object {
        let entry = entries[index]
        let baseIndex: Int
        if let baseOffset = entry.baseOffset {
            guard let found = entryByOffset[baseOffset] else {
                throw HorizontalGitCloneError.corruptPack("a delta's base isn't an object")
            }
            baseIndex = found
        } else if let baseID = entry.baseID, let found = entryByID[baseID] {
            baseIndex = found
        } else {
            throw HorizontalGitCloneError.corruptPack("a delta's base isn't in the pack")
        }
        let base = try object(atEntry: baseIndex)
        let object = Object(kind: base.kind, content: try Self.apply(delta: delta, to: base.content))
        remember(index, object)
        return object
    }

    private func remember(_ index: Int, _ object: Object) {
        let size = object.content.count
        guard size <= cacheLimit / 4, cache[index] == nil else { return }
        cache[index] = object
        cacheOrder.append(index)
        cacheBytes += size
        var dropped = 0
        while cacheBytes > cacheLimit, dropped < cacheOrder.count {
            let oldest = cacheOrder[dropped]
            dropped += 1
            if let removed = cache.removeValue(forKey: oldest) {
                cacheBytes -= removed.content.count
            }
        }
        if dropped > 0 {
            cacheOrder.removeFirst(dropped)
        }
    }

    /// Git's delta format: the base's and the result's sizes, then copies
    /// from the base and insertions of new bytes.
    static func apply(delta: [UInt8], to base: [UInt8]) throws -> [UInt8] {
        var cursor = 0
        func size() throws -> Int {
            var value = 0
            var shift = 0
            var byte: UInt8
            repeat {
                guard cursor < delta.count else { throw HorizontalGitCloneError.corruptPack("a delta is cut short") }
                byte = delta[cursor]
                cursor += 1
                value |= Int(byte & 0x7F) << shift
                shift += 7
            } while byte & 0x80 != 0
            return value
        }
        let baseSize = try size()
        let resultSize = try size()
        guard baseSize == base.count else {
            throw HorizontalGitCloneError.corruptPack("a delta's base has the wrong size")
        }
        var result = [UInt8]()
        result.reserveCapacity(resultSize)
        while cursor < delta.count {
            let op = delta[cursor]
            cursor += 1
            if op & 0x80 != 0 {
                var offset = 0
                var length = 0
                for bit in 0..<4 where op & (1 << bit) != 0 {
                    guard cursor < delta.count else { throw HorizontalGitCloneError.corruptPack("a delta is cut short") }
                    offset |= Int(delta[cursor]) << (8 * bit)
                    cursor += 1
                }
                for bit in 0..<3 where op & (0x10 << bit) != 0 {
                    guard cursor < delta.count else { throw HorizontalGitCloneError.corruptPack("a delta is cut short") }
                    length |= Int(delta[cursor]) << (8 * bit)
                    cursor += 1
                }
                if length == 0 { length = 0x10000 }
                guard offset + length <= base.count else {
                    throw HorizontalGitCloneError.corruptPack("a delta copies past its base")
                }
                result.append(contentsOf: base[offset..<offset + length])
            } else if op != 0 {
                let length = Int(op)
                guard cursor + length <= delta.count else {
                    throw HorizontalGitCloneError.corruptPack("a delta is cut short")
                }
                result.append(contentsOf: delta[cursor..<cursor + length])
                cursor += length
            } else {
                throw HorizontalGitCloneError.corruptPack("a delta has an empty instruction")
            }
        }
        guard result.count == resultSize else {
            throw HorizontalGitCloneError.corruptPack("a delta made the wrong size")
        }
        return result
    }

    // MARK: - Bytes

    /// Inflates the zlib stream at `start`, which holds `size` bytes, and says
    /// how many bytes of the pack it took: a pack records no lengths, so the
    /// next object starts where zlib stopped.
    private func inflate(at start: Int, size: Int) throws -> ([UInt8], consumed: Int) {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HorizontalGitCloneError.corruptPack("zlib wouldn't start")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: max(size, 1))
        let status: Int32 = bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress! + start)
                stream.avail_in = uInt(input.count - start)
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == size else {
            throw HorizontalGitCloneError.corruptPack("an object didn't inflate to its size")
        }
        if size == 0 { output.removeAll() }
        return (output, Int(stream.total_in))
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
