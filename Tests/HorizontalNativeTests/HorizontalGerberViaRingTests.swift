import XCTest
@testable import HorizontalNative

/// Vias must reach the fabrication output as copper. A via's padstack is a
/// circle of `via_diameter` on every copper layer of its span (Horizon's pool
/// via padstacks place the same circle on top, inner and bottom), and the
/// Gerber layer collector used to emit only package pads, so boards went out
/// with drill hits and no annular rings. These tests drive the real Gerber
/// writer and read the files back.
final class HorizontalGerberViaRingTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture
    private let top = HorizontalGerberExportFixture.top
    private let inner1 = HorizontalGerberExportFixture.inner1
    private let inner2 = HorizontalGerberExportFixture.inner2
    private let bottom = HorizontalGerberExportFixture.bottom

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x, y: y)
    }

    private func via(_ id: String, at position: HorizontalPoint, size: Double, layers: [Int]) -> HorizontalMarker {
        HorizontalMarker(
            id: id,
            position: position,
            size: size,
            holeSize: size / 2,
            layer: nil,
            connectedLayers: layers
        )
    }

    /// The region a ring is written as starts at angle 0, i.e. at
    /// (x + radius, y); this is the `D02` move that opens its G36 block.
    private func ringStart(_ via: HorizontalMarker) -> String {
        "X\(Int64(via.position.x + via.size / 2))Y\(Int64(via.position.y))D02*"
    }

    private func assertRing(_ via: HorizontalMarker, in gerber: String?, layer: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let gerber else {
            XCTFail("No Gerber written for layer \(HorizontalBoardLayers.name(for: layer))", file: file, line: line)
            return
        }
        XCTAssertTrue(
            gerber.contains("G36*\n\(ringStart(via))"),
            "\(via.id) ring missing on \(HorizontalBoardLayers.name(for: layer))",
            file: file, line: line
        )
    }

    private func assertNoRing(_ via: HorizontalMarker, in gerber: String?, layer: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            gerber?.contains(ringStart(via)) ?? false,
            "\(via.id) ring must not appear on \(HorizontalBoardLayers.name(for: layer))",
            file: file, line: line
        )
    }

    func testThroughViaRingLandsOnEveryCopperLayer() throws {
        let through = via("v-through", at: point(10_000_000, 5_000_000), size: 600_000,
                          layers: [top, inner1, inner2, bottom])
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [through]))

        for layer in [top, inner1, inner2, bottom] {
            assertRing(through, in: gerbers[layer], layer: layer)
        }
    }

    func testBlindViaRingStopsAtItsSpan() throws {
        let blind = via("v-blind", at: point(20_000_000, 5_000_000), size: 500_000, layers: [top, inner1])
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [blind]))

        assertRing(blind, in: gerbers[top], layer: top)
        assertRing(blind, in: gerbers[inner1], layer: inner1)
        assertNoRing(blind, in: gerbers[inner2], layer: inner2)
        assertNoRing(blind, in: gerbers[bottom], layer: bottom)
    }

    /// A via with no span recorded (older in-app vias) is treated as sitting on
    /// the layer it was placed on, top copper by default — the same rule the
    /// canvas uses.
    func testViaWithoutSpanRingsTopCopperOnly() throws {
        let legacy = via("v-legacy", at: point(30_000_000, 5_000_000), size: 400_000, layers: [])
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [legacy]))

        assertRing(legacy, in: gerbers[top], layer: top)
        for layer in [inner1, inner2, bottom] {
            assertNoRing(legacy, in: gerbers[layer], layer: layer)
        }
    }

    /// Tented vias have no mask opening, and nothing else about a via belongs
    /// on a non-copper layer, so the ring must stay off mask, paste, silk and
    /// outline files.
    func testRingsStayOffNonCopperLayers() throws {
        let through = via("v-through", at: point(10_000_000, 5_000_000), size: 600_000,
                          layers: [top, inner1, inner2, bottom])
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [through]))

        for (layer, gerber) in gerbers where !HorizontalBoardLayers.isCopper(layer) {
            assertNoRing(through, in: gerber, layer: layer)
        }
    }

    func testRingOutlineIsAClosedCircleOfTheViaDiameter() {
        let marker = via("v", at: point(1_000_000, 2_000_000), size: 500_000, layers: [top, bottom])
        let ring = marker.ringOutline()

        XCTAssertEqual(ring.count, 32)
        for vertex in ring {
            let dx = vertex.x - 1_000_000
            let dy = vertex.y - 2_000_000
            XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 250_000, accuracy: 1)
        }
        XCTAssertEqual(marker.copperLayers, [bottom, top])
        XCTAssertTrue(via("empty", at: .zero, size: 0, layers: [top]).ringOutline().isEmpty)
    }
}
