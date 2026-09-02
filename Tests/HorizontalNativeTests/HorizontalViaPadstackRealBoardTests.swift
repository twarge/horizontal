import XCTest
@testable import HorizontalNative

/// Regression tests against the real Coriander board (skipped when it isn't on
/// this machine). Its 443 vias all use the pool's "Circular via (tented)"
/// padstack — no mask shapes — and Horizon's own fabrication output confirms
/// the semantics: `Coriander Gerbers Top Mask.gbr` contains no via openings.
/// So the parse must (a) resolve the padstack and its type for the inspector's
/// picker, and (b) leave the mask expansions nil rather than inventing
/// openings a tented padstack doesn't have.
final class HorizontalViaPadstackRealBoardTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/kornack/Repositories/coriander/Coriander Horizon")
    private let tentedViaPadstack = "8b6dee4b-af88-4c0f-b38b-c5364649e65e"

    private func loadBoard() throws -> HorizontalBoard {
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("Coriander board not available")
        }
        var diagnostics = [HorizontalDiagnostic]()
        return try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )
    }

    func testViasParseWithPadstackAndParameters() throws {
        let board = try loadBoard()
        XCTAssertFalse(board.vias.isEmpty)
        for via in board.vias {
            XCTAssertEqual(via.padstackID?.lowercased(), tentedViaPadstack)
            XCTAssertEqual(via.parameterSet["via_diameter"], via.size)
            XCTAssertEqual(via.parameterSet["hole_diameter"], via.holeSize)
        }
        // The board has exactly one locally-edited via; every other via takes
        // its parameters from the rules.
        XCTAssertEqual(board.vias.filter { !$0.fromRules }.count, 1)
    }

    /// Every inspector commit funnels the board through the connectivity
    /// recompute, which used to strip the net (and its display name) off every
    /// `net_set` via — 398 of Coriander's 443. A recompute must keep them.
    func testRecomputeKeepsNetSetViaNets() throws {
        let board = try loadBoard()
        let pinned = board.vias.filter { $0.netSetID != nil }
        XCTAssertFalse(pinned.isEmpty, "Coriander's vias are almost all net_set on disk")

        let recomputed = HorizontalBoardConnectivity.recompute(board)
        for via in recomputed.vias where via.netSetID != nil {
            XCTAssertEqual(
                via.netID?.lowercased(), via.netSetID?.lowercased(),
                "via \(via.id) lost its pinned net on recompute"
            )
        }
        let lostNets = zip(board.vias, recomputed.vias).filter { $0.0.netID != nil && $0.1.netID == nil }
        XCTAssertTrue(lostNets.isEmpty, "no via may lose its net to a recompute: \(lostNets.map(\.0.id))")
    }

    func testTentedPadstackYieldsNoMaskOpenings() throws {
        let board = try loadBoard()
        for via in board.vias {
            XCTAssertNil(via.topMaskExpansion, "tented padstack must not open the top mask (\(via.id))")
            XCTAssertNil(via.bottomMaskExpansion)
            XCTAssertEqual(via.maskLayers, [])
        }
    }

    func testPoolCatalogListsTheViaPadstackUnderItsRealType() throws {
        _ = try loadBoard()
        let poolURL = base.appendingPathComponent("pool")
        let viaPadstacks = HorizontalPoolPadstacks.padstacks(ofTypes: ["via"], poolURL: poolURL)
        XCTAssertTrue(viaPadstacks.contains { $0.id == tentedViaPadstack && $0.name == "Circular via (tented)" })

        let holePadstacks = HorizontalPoolPadstacks.padstacks(ofTypes: ["hole", "mechanical"], poolURL: poolURL)
        XCTAssertFalse(holePadstacks.isEmpty, "the pool's mechanical hole padstacks must be offered to board holes")

        // With the horizon-pool checkout next to the projects, the catalog also
        // offers the stock untented "Circular via" so vias can be un-tented.
        if FileManager.default.fileExists(
            atPath: "/Users/kornack/Repositories/horizon-pool/padstacks/via-round.json"
        ) {
            XCTAssertTrue(
                viaPadstacks.contains { $0.name == "Circular via" },
                "base-pool via padstacks must be offered alongside the project pool's"
            )
        }
    }
}
