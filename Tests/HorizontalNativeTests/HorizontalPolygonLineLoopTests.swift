import XCTest
@testable import HorizontalNative

/// Guards `HorizontalPolygonLineLoop`, the pure geometry behind Horizon's
/// polygon↔line-loop tools. The decisive test is the arc round-trip: a polygon
/// with an arc edge → line loop → polygon must recover the same rendered shape,
/// which pins the `reverse XOR (node == arc.to)` arc convention.
final class HorizontalPolygonLineLoopTests: XCTestCase {

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    /// Deterministic id generator so results are comparable.
    private func counter() -> () -> String {
        var n = 0
        return { n += 1; return "id-\(n)" }
    }

    private func squarePolygon(layer: Int = 0) -> HorizontalPolygon {
        HorizontalPolygon(
            id: "poly",
            polygonVertices: [
                HorizontalPolygonVertex(position: p(0, 0)),
                HorizontalPolygonVertex(position: p(1_000_000, 0)),
                HorizontalPolygonVertex(position: p(1_000_000, 1_000_000)),
                HorizontalPolygonVertex(position: p(0, 1_000_000)),
            ],
            layer: layer
        )
    }

    // MARK: - Polygon → Line loop

    func testPolygonToLineLoopMakesClosedLoop() {
        let make = counter()
        let result = HorizontalPolygonLineLoop.lineLoop(from: squarePolygon(layer: 3), makeID: make)
        let loop = try! XCTUnwrap(result)

        XCTAssertEqual(loop.lines.count, 4)
        XCTAssertTrue(loop.arcs.isEmpty)
        // Every line is width 0 on the polygon's layer (Horizon's tool).
        XCTAssertTrue(loop.lines.allSatisfy { $0.width == 0 && $0.layer == 3 })

        // The four edges form a closed chain: each line's `to` is the next `from`,
        // and the last closes back to the first.
        for index in loop.lines.indices {
            let next = loop.lines[(index + 1) % loop.lines.count]
            XCTAssertEqual(HorizontalPolygonLineLoop.pointKey(loop.lines[index].to),
                           HorizontalPolygonLineLoop.pointKey(next.from))
        }
    }

    func testPolygonWithFewerThanThreeVerticesIsRejected() {
        let degenerate = HorizontalPolygon(
            id: "x",
            polygonVertices: [HorizontalPolygonVertex(position: p(0, 0)), HorizontalPolygonVertex(position: p(1, 1))],
            layer: 0
        )
        XCTAssertNil(HorizontalPolygonLineLoop.lineLoop(from: degenerate, makeID: counter()))
    }

    // MARK: - Line loop → Polygon

    func testLineLoopToPolygonRecoversSquare() {
        let make = counter()
        let loop = HorizontalPolygonLineLoop.lineLoop(from: squarePolygon(layer: 2), makeID: make)!
        let recovered = HorizontalPolygonLineLoop.polygon(
            startKey: HorizontalPolygonLineLoop.pointKey(p(0, 0)),
            lines: loop.lines,
            arcs: loop.arcs,
            makeID: make
        )
        let result = try! XCTUnwrap(recovered)

        XCTAssertEqual(result.polygon.polygonVertices.count, 4)
        XCTAssertEqual(result.polygon.layer, 2)
        XCTAssertEqual(result.consumedLineIDs.count, 4)
        XCTAssertEqual(result.consumedJunctionKeys.count, 4)
        // Same set of corner positions as the original square.
        let original = Set(squarePolygon().polygonVertices.map { HorizontalPolygonLineLoop.pointKey($0.position) })
        let got = Set(result.polygon.polygonVertices.map { HorizontalPolygonLineLoop.pointKey($0.position) })
        XCTAssertEqual(got, original)
    }

    func testOpenChainHasNoLoop() {
        // Three lines in an open zig-zag (no cycle) → nil.
        let make = counter()
        let lines = [
            HorizontalSegment(id: "a", from: p(0, 0), to: p(1_000_000, 0), width: 0, layer: 0),
            HorizontalSegment(id: "b", from: p(1_000_000, 0), to: p(2_000_000, 0), width: 0, layer: 0),
        ]
        XCTAssertNil(HorizontalPolygonLineLoop.polygon(startKey: HorizontalPolygonLineLoop.pointKey(p(0, 0)), lines: lines, arcs: [], makeID: make))
    }

    // MARK: - Arc round-trip (the convention check)

    /// A triangle whose first edge is an arc must survive polygon → line loop →
    /// polygon with its rendered outline intact. This is what validates the
    /// `reverse XOR (node == to)` bridge between Horizon's flag-less arcs and
    /// `HorizontalArc.reverse`.
    func testArcEdgeRoundTripsShape() {
        for arcReverse in [false, true] {
            let make = counter()
            let polygon = HorizontalPolygon(
                id: "poly",
                polygonVertices: [
                    HorizontalPolygonVertex(type: .arc, position: p(0, 0), arcCenter: p(500_000, 300_000), arcReverse: arcReverse),
                    HorizontalPolygonVertex(position: p(1_000_000, 0)),
                    HorizontalPolygonVertex(position: p(500_000, 1_000_000)),
                ],
                layer: 1
            )

            let loop = try! XCTUnwrap(HorizontalPolygonLineLoop.lineLoop(from: polygon, makeID: make))
            XCTAssertEqual(loop.arcs.count, 1, "the arc edge becomes one arc")
            XCTAssertEqual(loop.lines.count, 2)

            let recovered = try! XCTUnwrap(
                HorizontalPolygonLineLoop.polygon(
                    startKey: HorizontalPolygonLineLoop.pointKey(p(0, 0)),
                    lines: loop.lines,
                    arcs: loop.arcs,
                    makeID: make
                )
            )

            // The recovered polygon renders the same closed outline (same set of
            // sampled points) as the original — direction/start may differ, so
            // compare as position sets at fixed precision.
            let originalShape = Set(polygon.renderVertices(arcPrecision: 24).map(HorizontalPolygonLineLoop.pointKey))
            let recoveredShape = Set(recovered.polygon.renderVertices(arcPrecision: 24).map(HorizontalPolygonLineLoop.pointKey))
            XCTAssertEqual(recoveredShape, originalShape, "arc shape lost on round-trip (arcReverse=\(arcReverse))")

            // And exactly one recovered vertex is an arc, carrying the same center.
            let arcVertices = recovered.polygon.polygonVertices.filter { $0.type == .arc }
            XCTAssertEqual(arcVertices.count, 1)
            XCTAssertEqual(arcVertices.first.map { HorizontalPolygonLineLoop.pointKey($0.arcCenter) },
                           HorizontalPolygonLineLoop.pointKey(p(500_000, 300_000)))
        }
    }
}
