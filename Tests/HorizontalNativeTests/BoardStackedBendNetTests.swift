import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// A bend of one net lying over a bend of another net on another layer. Each
/// is a junction of its own, joining two tracks of its net on its layer, and
/// a board opens with both on their nets and no airwire at either.
///
/// The loader read a junction's net on every layer at its point, found two
/// there and gave the junction neither, so each net was in two pieces at the
/// bend. A board with nine such places opened with twelve airwires. They went
/// with the first pour or edit, whose connectivity pass reads a junction on
/// the layers of the tracks that name it, and came back when the file was
/// opened again.
final class BoardStackedBendNetTests: XCTestCase {
    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    /// The board is one channel of `BlockLayoutFixture`: R1 at the origin,
    /// R2 5 mm right of it and R3 10 mm, pads at ±0.75 mm, all on the top.
    func testABendOverABendOfAnotherNetOpensOnItsOwnNet() throws {
        let fixture = try BlockLayoutFixture(instances: 1)
        defer { fixture.remove() }
        let instance = fixture.instances[0]
        // OUT1 on the top: up from R2's pad 2, across at y = 3, down to R3's.
        let outBend = "a1000000-0000-4000-8000-000000000001", outCorner = "a1000000-0000-4000-8000-000000000002"
        // MID on the bottom between two vias, from R1's pad 2 to R2's pad 1,
        // with a bend under OUT1's first.
        let midVia = "b1000000-0000-4000-8000-000000000001", midBend = "b1000000-0000-4000-8000-000000000002"
        let midVia2 = "b1000000-0000-4000-8000-000000000003"
        let stacked = point(5.75, 3)
        let top = HorizontalBoardLayers.topCopper, bottom = HorizontalBoardLayers.bottomCopper
        try fixture.addCopper(
            junctions: [outBend: stacked, outCorner: point(10.75, 3),
                        midVia: point(0.75, 3), midBend: stacked, midVia2: point(4.25, 1.5)],
            tracks: [
                "d1000000-0000-4000-8000-000000000001": (try fixture.padEnd(instance, "R2", 2), fixture.junctionEnd(outBend), top),
                "d1000000-0000-4000-8000-000000000002": (fixture.junctionEnd(outBend), fixture.junctionEnd(outCorner), top),
                "d1000000-0000-4000-8000-000000000003": (fixture.junctionEnd(outCorner), try fixture.padEnd(instance, "R3", 2), top),
                "d2000000-0000-4000-8000-000000000001": (try fixture.padEnd(instance, "R1", 2), fixture.junctionEnd(midVia), top),
                "d2000000-0000-4000-8000-000000000002": (fixture.junctionEnd(midVia), fixture.junctionEnd(midBend), bottom),
                "d2000000-0000-4000-8000-000000000003": (fixture.junctionEnd(midBend), fixture.junctionEnd(midVia2), bottom),
                "d2000000-0000-4000-8000-000000000004": (fixture.junctionEnd(midVia2), try fixture.padEnd(instance, "R2", 1), top),
            ],
            vias: ["e1000000-0000-4000-8000-000000000001": midVia, "e1000000-0000-4000-8000-000000000002": midVia2])
        try fixture.saveToDisk()

        let board = try XCTUnwrap(try HorizontalProject.load(from: fixture.url).board)
        func net(_ name: String) throws -> String {
            try XCTUnwrap(board.netDetails.first { $0.value.name == name }?.key.lowercased(), "\(board.netDetails.values.map(\.name))")
        }
        func airwires(_ board: HorizontalBoard, on net: String) -> Int {
            board.airwires.filter { $0.netID?.lowercased() == net }.count
        }
        let out = try net("OUT1"), mid = try net("I1/MID")
        XCTAssertEqual(board.junctionNetIDs[outBend]?.lowercased(), out, "the top bend is on its tracks' net")
        XCTAssertEqual(board.junctionNetIDs[midBend]?.lowercased(), mid, "and the bottom bend under it on its own")
        XCTAssertEqual(airwires(board, on: out), 0)
        // R3's pad 1 is the one end of MID no copper reaches.
        XCTAssertEqual(airwires(board, on: mid), 1)

        // The board opens as the editor's pass leaves it, so nothing changes
        // with the first edit or pour.
        var edited = HorizontalBoardConnectivity.recompute(board)
        edited.regenerateAirwires()
        XCTAssertEqual(edited.junctionNetIDs, board.junctionNetIDs)
        XCTAssertEqual(edited.airwires.count, board.airwires.count)
    }
}
