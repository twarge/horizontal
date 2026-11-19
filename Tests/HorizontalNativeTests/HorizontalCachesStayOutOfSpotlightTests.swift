import Foundation
import XCTest
@testable import HorizontalNative

/// Horizontal's caches live in a folder Spotlight skips, and the meshes and
/// stock records cached before keep working from there.
final class HorizontalCachesStayOutOfSpotlightTests: XCTestCase {
    private var caches: URL!

    override func setUpWithError() throws {
        caches = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-caches-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: caches)
    }

    func testTheCachesFolderIsOneSpotlightSkips() {
        XCTAssertEqual(HorizontalCachesDirectory.directory(in: caches).pathExtension, "noindex")
        XCTAssertEqual(HorizontalStepMeshDiskCache.defaultDirectory()?.deletingLastPathComponent().lastPathComponent,
                       HorizontalCachesDirectory.name)
        XCTAssertEqual(HorizontalDigiKeyStockMonitor.defaultCacheURL()?.deletingLastPathComponent().lastPathComponent,
                       HorizontalCachesDirectory.name)
    }

    func testWhatWasCachedBeforeMovesIntoTheFolder() throws {
        let legacy = caches.appendingPathComponent(HorizontalCachesDirectory.legacyName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("step-meshes"), withIntermediateDirectories: true)
        try Data("mesh".utf8).write(to: legacy.appendingPathComponent("step-meshes/a.mesh"))
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("digikey-stock.json"))

        let directory = HorizontalCachesDirectory.directory(in: caches)

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("step-meshes/a.mesh")), Data("mesh".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("digikey-stock.json")), Data("{}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "nothing is left where Spotlight indexes it")
    }

    func testAnOldFolderDoesNotReplaceTheCurrentOne() throws {
        let current = caches.appendingPathComponent(HorizontalCachesDirectory.name, isDirectory: true)
        let legacy = caches.appendingPathComponent(HorizontalCachesDirectory.legacyName, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("digikey-stock.json"))
        try Data("old".utf8).write(to: legacy.appendingPathComponent("digikey-stock.json"))

        let directory = HorizontalCachesDirectory.directory(in: caches)

        XCTAssertEqual(directory.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("digikey-stock.json")), Data("new".utf8))
    }
}
