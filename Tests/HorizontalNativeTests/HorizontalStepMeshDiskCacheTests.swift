#if os(macOS)
import HorizontalStepImporter
import XCTest
@testable import HorizontalNative

/// Tessellated STEP models survive on disk between launches, keyed by the
/// model file's identity, and a damaged entry is ignored rather than drawn.
final class HorizontalStepMeshDiskCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalStepMeshDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mesh() -> HorizontalStepMeshData {
        HorizontalStepMeshData(
            vertices: [
                HNStepVertex(x: 0, y: 0, z: 0, nx: 0, ny: 0, nz: 1, r: 0.2, g: 0.6, b: 0.1),
                HNStepVertex(x: 1, y: 0, z: 0, nx: 0, ny: 0, nz: 1, r: 0.2, g: 0.6, b: 0.1),
                HNStepVertex(x: 0, y: 1, z: 0.5, nx: 0, ny: 0, nz: 1, r: 0.2, g: 0.6, b: 0.1),
            ],
            indices: [0, 1, 2]
        )
    }

    func testMeshRoundTripsThroughTheCache() throws {
        let modelURL = root.appendingPathComponent("model.step")
        try Data("ISO-10303-21;".utf8).write(to: modelURL)
        let cache = HorizontalStepMeshDiskCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        XCTAssertNil(cache.mesh(for: modelURL), "nothing cached yet")

        cache.store(mesh(), for: modelURL)
        XCTAssertEqual(cache.mesh(for: modelURL), mesh())

        let fileURL = try XCTUnwrap(cache.cacheFileURL(for: modelURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fileURL.pathExtension, "mesh")
    }

    func testAnEditedModelMissesTheCache() throws {
        let modelURL = root.appendingPathComponent("model.step")
        try Data("ISO-10303-21;".utf8).write(to: modelURL)
        let cache = HorizontalStepMeshDiskCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        cache.store(mesh(), for: modelURL)
        let before = try XCTUnwrap(cache.cacheFileURL(for: modelURL))

        // A different size or modification date is a different key.
        try Data("ISO-10303-21; edited".utf8).write(to: modelURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: modelURL.path)
        XCTAssertNotEqual(cache.cacheFileURL(for: modelURL), before)
        XCTAssertNil(cache.mesh(for: modelURL))
        XCTAssertNil(cache.cacheFileURL(for: root.appendingPathComponent("missing.step")))
    }

    func testDamagedEntriesAreIgnored() {
        let encoded = HorizontalStepMeshDiskCache.encode(mesh())
        XCTAssertEqual(HorizontalStepMeshDiskCache.decode(encoded), mesh())
        XCTAssertNil(HorizontalStepMeshDiskCache.decode(encoded.dropLast(4)), "truncated")
        var wrongMagic = encoded
        wrongMagic[0] = 0
        XCTAssertNil(HorizontalStepMeshDiskCache.decode(wrongMagic))
        var badIndex = encoded
        badIndex[encoded.count - 4] = 9
        XCTAssertNil(HorizontalStepMeshDiskCache.decode(badIndex), "index past the vertex count")
        XCTAssertNil(HorizontalStepMeshDiskCache.decode(Data()))
    }
}
#endif
