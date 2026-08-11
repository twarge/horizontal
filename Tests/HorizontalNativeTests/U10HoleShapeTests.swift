import XCTest
@testable import HorizontalNative

/// Decisive experiment for the "U10 round holes render as slots" bug: load the
/// real Coriander board through the actual parser and inspect U10's exposed-pad
/// hole shapes. Settles whether the bug is in parsing (shape comes out .slot) or
/// rendering (.round but drawn as a slot).
final class U10HoleShapeTests: XCTestCase {
    func testU10ExposedPadHolesParseAsRound() throws {
        let base = URL(fileURLWithPath: "/Users/kornack/Repositories/coriander/Coriander Horizon")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("Coriander board not available")
        }
        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )

        let u10 = "2712c279-fa4a-4923-8c6a-783933691570"
        let holes = board.packageHoles.filter { $0.id.lowercased().contains(u10) }

        print("=== U10 hole report ===")
        print("packageHoles total: \(board.packageHoles.count), board.holes: \(board.holes.count), viaHoles: \(board.viaHoles.count)")
        print("U10 packageHoles: \(holes.count)")
        for hole in holes.prefix(12) {
            print("  shape=\(hole.shape) dia=\(hole.diameter) len=\(String(describing: hole.length)) eff=\(hole.effectiveLength) plated=\(hole.plated) id=…\(hole.id.suffix(30))")
        }
        // Any other holes in the U10 region that might overlap (viaHoles/holes)?
        let otherU10 = (board.holes + board.viaHoles).filter { $0.id.lowercased().contains(u10) }
        print("U10 holes in board.holes+viaHoles: \(otherU10.count)")
        for hole in otherU10.prefix(12) {
            print("  OTHER shape=\(hole.shape) dia=\(hole.diameter) len=\(String(describing: hole.length)) id=…\(hole.id.suffix(30))")
        }

        // What holes — across ALL collections — sit at U10's exposed pad?
        // U10 placement shift is (45250000, 18250000); the 8 EP holes are within ~2mm.
        let center = HorizontalPoint(x: 43_250_000, y: -500_000)
        print("U10 EP hole positions:", holes.map { "(\($0.position.x),\($0.position.y))" }.joined(separator: " "))
        func near(_ h: HorizontalHole) -> Bool {
            abs(h.position.x - center.x) < 3_000_000 && abs(h.position.y - center.y) < 3_000_000
        }
        print("=== ALL holes near U10 (by position) ===")
        for (name, coll) in [("packageHoles", board.packageHoles), ("viaHoles", board.viaHoles), ("holes", board.holes)] {
            let n = coll.filter(near)
            print("  \(name): \(n.count) near U10")
            for h in n.prefix(12) {
                print("    shape=\(h.shape) dia=\(h.diameter) eff=\(h.effectiveLength) pos=(\(h.position.x),\(h.position.y)) id=…\(h.id.suffix(34))")
            }
        }

        XCTAssertFalse(holes.isEmpty, "expected to find U10 exposed-pad holes")

        // Render-accurate check: what geometry does outlinePoints actually emit?
        // A circle has a ~square bbox (≈diameter on both axes); an obround/slot is
        // elongated to ≈effectiveLength on one axis.
        print("=== outlinePoints geometry per hole ===")
        for hole in holes.prefix(4) {
            let pts = hole.outlinePoints(precision: 32)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = (xs.max() ?? 0) - (xs.min() ?? 0)
            let h = (ys.max() ?? 0) - (ys.min() ?? 0)
            print("  shape=\(hole.shape) outline bbox w=\(w) h=\(h)  (diameter=\(hole.diameter), eff=\(hole.effectiveLength))")
        }

        for hole in holes {
            XCTAssertEqual(hole.shape, .round, "U10 EP hole \(hole.id.suffix(20)) should be round but is \(hole.shape)")
            let pts = hole.outlinePoints(precision: 32)
            let w = (pts.map(\.x).max() ?? 0) - (pts.map(\.x).min() ?? 0)
            let h = (pts.map(\.y).max() ?? 0) - (pts.map(\.y).min() ?? 0)
            let longest = max(w, h)
            XCTAssertLessThan(longest, hole.diameter * 1.2,
                "round hole outline should be a circle (≈diameter), but is elongated to \(longest) vs diameter \(hole.diameter)")
        }
    }
}
