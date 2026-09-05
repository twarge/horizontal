#if canImport(AppKit)
import CryptoKit
import Foundation
import HorizontalStepImporter

/// A tessellated STEP model: what `HNStepImport` produces, owned by Swift.
struct HorizontalStepMeshData: Equatable {
    var vertices: [HNStepVertex]
    var indices: [UInt32]

    static func == (lhs: HorizontalStepMeshData, rhs: HorizontalStepMeshData) -> Bool {
        lhs.indices == rhs.indices
            && lhs.vertices.count == rhs.vertices.count
            && zip(lhs.vertices, rhs.vertices).allSatisfy { a, b in
                a.x == b.x && a.y == b.y && a.z == b.z && a.nx == b.nx && a.ny == b.ny && a.nz == b.nz
                    && a.r == b.r && a.g == b.g && a.b == b.b
            }
    }
}

/// Tessellated STEP models kept on disk between launches. Importing a STEP
/// file means reading it with OpenCASCADE and meshing every face, which
/// costs a good fraction of a second per model; the mesh itself is a few
/// hundred kilobytes that load in a millisecond. Entries live in the user's
/// Caches directory and are keyed by the model's path, size and modification
/// date plus the format version, so an edited model or a new importer
/// simply misses the cache and is imported again.
final class HorizontalStepMeshDiskCache: @unchecked Sendable {
    static let shared = HorizontalStepMeshDiskCache()

    /// Bump when the file layout or the importer's output changes.
    static let formatVersion: UInt32 = 1
    private static let magic: UInt32 = 0x4D5A_4848
    private static let headerSize = 16

    let directory: URL?
    private let lock = NSLock()

    init(directory: URL? = HorizontalStepMeshDiskCache.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Horizontal", isDirectory: true)
            .appendingPathComponent("step-meshes", isDirectory: true)
    }

    /// The cache file a model would use, or nil when the model cannot be
    /// stat'ed (no file, no cache).
    func cacheFileURL(for modelURL: URL) -> URL? {
        guard let directory,
              let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path) else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(modelURL.standardizedFileURL.path)\u{0}\(size)\u{0}\(modified)\u{0}v\(Self.formatVersion)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).mesh")
    }

    func mesh(for modelURL: URL) -> HorizontalStepMeshData? {
        guard let fileURL = cacheFileURL(for: modelURL),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return Self.decode(data)
    }

    func store(_ mesh: HorizontalStepMeshData, for modelURL: URL) {
        guard let fileURL = cacheFileURL(for: modelURL), let directory else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encode(mesh).write(to: fileURL, options: [.atomic])
        } catch {
            // A cache that cannot be written only costs the next import.
        }
    }

    // MARK: - Format

    static func encode(_ mesh: HorizontalStepMeshData) -> Data {
        var data = Data()
        data.reserveCapacity(headerSize + mesh.vertices.count * MemoryLayout<HNStepVertex>.stride + mesh.indices.count * 4)
        for value in [magic, formatVersion, UInt32(mesh.vertices.count), UInt32(mesh.indices.count)] {
            var little = value.littleEndian
            data.append(Data(bytes: &little, count: 4))
        }
        mesh.vertices.withUnsafeBytes { data.append(contentsOf: $0) }
        mesh.indices.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func decode(_ data: Data) -> HorizontalStepMeshData? {
        guard data.count >= headerSize else {
            return nil
        }
        func word(_ index: Int) -> UInt32 {
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (index * 4)..<(index * 4 + 4)) }
            return UInt32(littleEndian: value)
        }
        guard word(0) == magic, word(1) == formatVersion else {
            return nil
        }
        let vertexCount = Int(word(2))
        let indexCount = Int(word(3))
        let vertexBytes = vertexCount * MemoryLayout<HNStepVertex>.stride
        let indexBytes = indexCount * 4
        guard vertexCount > 0, indexCount >= 3, indexCount.isMultiple(of: 3),
              data.count == headerSize + vertexBytes + indexBytes else {
            return nil
        }
        let vertices = [HNStepVertex](unsafeUninitializedCapacity: vertexCount) { buffer, initialized in
            _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), from: headerSize..<(headerSize + vertexBytes))
            initialized = vertexCount
        }
        let indices = [UInt32](unsafeUninitializedCapacity: indexCount) { buffer, initialized in
            _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), from: (headerSize + vertexBytes)..<(headerSize + vertexBytes + indexBytes))
            initialized = indexCount
        }
        guard indices.allSatisfy({ Int($0) < vertexCount }) else {
            return nil
        }
        return HorizontalStepMeshData(vertices: vertices, indices: indices)
    }
}
#endif
