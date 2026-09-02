import XCTest
@testable import HorizontalNative

/// Base-pool discovery and the project-pool cache rebuild: a `horizon-pool`
/// checkout near the project fills in padstacks the project pool lacks, and
/// picking one copies it verbatim into `padstacks/cache/` so the project
/// stays self-contained (openable in Horizon, resolvable by this parser).
final class HorizontalPoolPadstacksTests: XCTestCase {
    private let stockPool = URL(fileURLWithPath: "/Users/kornack/Repositories/horizon-pool")

    private func makeTempPools(
        projectPadstacks: [JSONDictionary] = [],
        basePadstacks: [JSONDictionary] = []
    ) throws -> (root: URL, projectPool: URL, basePool: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolPadstacksTests-\(UUID().uuidString)", isDirectory: true)
        let projectPool = root.appendingPathComponent("project/pool", isDirectory: true)
        let basePool = root.appendingPathComponent("horizon-pool", isDirectory: true)

        func write(_ json: JSONDictionary, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        }

        try write(["type": "pool", "uuid": "aaaa", "pools_included": []], to: projectPool.appendingPathComponent("pool.json"))
        try write(["type": "pool", "uuid": "bbbb", "pools_included": []], to: basePool.appendingPathComponent("pool.json"))
        for padstack in projectPadstacks {
            let id = padstack["uuid"] as? String ?? UUID().uuidString
            try write(padstack, to: projectPool.appendingPathComponent("padstacks/cache/\(id).json"))
        }
        for padstack in basePadstacks {
            let id = padstack["uuid"] as? String ?? UUID().uuidString
            try write(padstack, to: basePool.appendingPathComponent("padstacks/\(id).json"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, projectPool, basePool)
    }

    private func padstack(uuid: String, name: String, type: String) -> JSONDictionary {
        ["uuid": uuid, "name": name, "type": "padstack", "padstack_type": type]
    }

    func testBasePoolFillsInMissingPadstacksAndEnsureCachedCopiesThem() throws {
        let pools = try makeTempPools(
            projectPadstacks: [padstack(uuid: "11111111-aaaa-aaaa-aaaa-111111111111", name: "Tented via", type: "via")],
            basePadstacks: [padstack(uuid: "22222222-bbbb-bbbb-bbbb-222222222222", name: "Open via", type: "via")]
        )

        XCTAssertEqual(
            HorizontalPoolPadstacks.basePoolURLs(for: pools.projectPool).map(\.lastPathComponent),
            ["horizon-pool"]
        )
        let vias = HorizontalPoolPadstacks.padstacks(ofTypes: ["via"], poolURL: pools.projectPool)
        XCTAssertEqual(vias.map(\.name).sorted(), ["Open via", "Tented via"])

        let baseID = "22222222-bbbb-bbbb-bbbb-222222222222"
        XCTAssertTrue(HorizontalPoolPadstacks.ensureCached(id: baseID, poolURL: pools.projectPool))
        let cacheURL = pools.projectPool.appendingPathComponent("padstacks/cache/\(baseID).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path), "picked padstack must land in the project pool cache")
        // Verbatim copy: same bytes as the base pool file.
        let original = try Data(contentsOf: pools.basePool.appendingPathComponent("padstacks/\(baseID).json"))
        XCTAssertEqual(try Data(contentsOf: cacheURL), original)
        // Idempotent.
        XCTAssertTrue(HorizontalPoolPadstacks.ensureCached(id: baseID, poolURL: pools.projectPool))
    }

    func testProjectPoolCopyWinsOverBasePool() throws {
        let shared = "33333333-cccc-cccc-cccc-333333333333"
        let pools = try makeTempPools(
            projectPadstacks: [padstack(uuid: shared, name: "Project copy", type: "via")],
            basePadstacks: [padstack(uuid: shared, name: "Base copy", type: "via")]
        )
        let vias = HorizontalPoolPadstacks.padstacks(ofTypes: ["via"], poolURL: pools.projectPool)
        XCTAssertEqual(vias.map(\.name), ["Project copy"], "a project's own copy must never be shadowed")
        XCTAssertTrue(HorizontalPoolPadstacks.ensureCached(id: shared, poolURL: pools.projectPool))
    }

    // MARK: - Stock padstacks from the real horizon-pool checkout

    private func stockPadstack(_ file: String) throws -> JSONDictionary {
        let url = stockPool.appendingPathComponent("padstacks/\(file)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("horizon-pool checkout not available")
        }
        return try JSONHelper.loadDictionary(from: url)
    }

    func testStockUntentedViaYieldsMaskOpenings() throws {
        // The stock "Circular via" program sets the mask circles to
        // hole_diameter + 2 × via_solder_mask_expansion.
        let expansions = HorizontalBoard.viaMaskExpansions(
            padstackJSON: try stockPadstack("via-round.json"),
            parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000],
            viaDiameter: 600_000,
            ruleMaskExpansion: 100_000
        )
        let expectedOpening = 300_000.0 + 2 * 100_000
        XCTAssertEqual(expansions.top ?? .nan, (expectedOpening - 600_000) / 2, accuracy: 1)
        XCTAssertEqual(expansions.bottom ?? .nan, (expectedOpening - 600_000) / 2, accuracy: 1)

        let via = HorizontalMarker(
            id: "v", position: .zero, size: 600_000, holeSize: 300_000, layer: nil,
            connectedLayers: [HorizontalBoardLayers.topCopper, HorizontalBoardLayers.bottomCopper],
            topMaskExpansion: expansions.top, bottomMaskExpansion: expansions.bottom
        )
        XCTAssertEqual(via.maskDiameter(on: HorizontalBoardLayers.topMask) ?? .nan, expectedOpening, accuracy: 1)
    }

    func testStockTentedViaStaysTented() throws {
        let expansions = HorizontalBoard.viaMaskExpansions(
            padstackJSON: try stockPadstack("via-round-tented.json"),
            parameterSet: ["via_diameter": 600_000, "hole_diameter": 300_000],
            viaDiameter: 600_000,
            ruleMaskExpansion: 100_000
        )
        XCTAssertNil(expansions.top)
        XCTAssertNil(expansions.bottom)
    }
}
