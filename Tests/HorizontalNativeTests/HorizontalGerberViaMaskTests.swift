import XCTest
@testable import HorizontalNative

/// Via solder-mask openings. A via padstack with mask shapes produces a circle
/// of `via_diameter + 2 * via_solder_mask_expansion` on the mask sides its
/// span reaches; a tented padstack (no mask shapes → nil expansion) produces
/// nothing — verified against Horizon's own fabrication output, whose mask
/// Gerbers contain no openings for tented vias. These tests drive the real
/// Gerber writer and read the files back.
final class HorizontalGerberViaMaskTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture
    private let top = HorizontalGerberExportFixture.top
    private let inner1 = HorizontalGerberExportFixture.inner1
    private let bottom = HorizontalGerberExportFixture.bottom
    private let topMask = HorizontalBoardLayers.topMask
    private let bottomMask = HorizontalBoardLayers.bottomMask

    private func via(
        _ id: String,
        at position: HorizontalPoint,
        size: Double,
        layers: [Int],
        maskExpansion: Double? = nil
    ) -> HorizontalMarker {
        HorizontalMarker(
            id: id,
            position: position,
            size: size,
            holeSize: size / 2,
            layer: nil,
            connectedLayers: layers,
            topMaskExpansion: maskExpansion,
            bottomMaskExpansion: maskExpansion
        )
    }

    /// The opening region's opening `D02` move: first vertex at angle 0, i.e.
    /// (x + openingRadius, y) — the same convention the ring tests use.
    private func openingStart(_ via: HorizontalMarker, on layer: Int) -> String {
        let diameter = via.maskDiameter(on: layer) ?? 0
        return "X\(Int64(via.position.x + diameter / 2))Y\(Int64(via.position.y))D02*"
    }

    func testThroughViaOpensBothMasks() throws {
        let through = via(
            "v-through", at: HorizontalPoint(x: 10_000_000, y: 5_000_000),
            size: 600_000, layers: [top, inner1, bottom], maskExpansion: 100_000
        )
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [through]))

        for layer in [topMask, bottomMask] {
            guard let gerber = gerbers[layer] else {
                XCTFail("no mask Gerber written for \(HorizontalBoardLayers.name(for: layer) ?? "\(layer)")")
                continue
            }
            XCTAssertTrue(
                gerber.contains("G36*\n\(openingStart(through, on: layer))"),
                "mask opening missing on \(HorizontalBoardLayers.name(for: layer) ?? "\(layer)")"
            )
        }
        // Opening diameter = via diameter + 2 × expansion.
        XCTAssertEqual(through.maskDiameter(on: topMask), 800_000)
    }

    func testBlindViaOpensOnlyTheSideItReaches() throws {
        let blind = via(
            "v-blind", at: HorizontalPoint(x: 20_000_000, y: 5_000_000),
            size: 500_000, layers: [top, inner1], maskExpansion: 100_000
        )
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [blind]))

        XCTAssertNotNil(blind.maskDiameter(on: topMask))
        XCTAssertNil(blind.maskDiameter(on: bottomMask), "a blind via must not open the far-side mask")
        XCTAssertTrue(gerbers[topMask]?.contains(openingStart(blind, on: topMask)) ?? false)
        let bottomDiameter = blind.size + 2 * 100_000
        let phantomStart = "X\(Int64(blind.position.x + bottomDiameter / 2))Y\(Int64(blind.position.y))D02*"
        XCTAssertFalse(gerbers[bottomMask]?.contains(phantomStart) ?? false)
    }

    func testTentedViaWritesNoMaskOpenings() throws {
        let tented = via(
            "v-tented", at: HorizontalPoint(x: 30_000_000, y: 5_000_000),
            size: 600_000, layers: [top, inner1, bottom], maskExpansion: nil
        )
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(vias: [tented]))

        XCTAssertEqual(tented.maskLayers, [])
        XCTAssertNil(gerbers[topMask], "a tented-only board must not even write a mask file")
        XCTAssertNil(gerbers[bottomMask])
    }

    func testMaskOutlineIsEmptyOffMaskLayers() {
        let through = via(
            "v", at: .zero, size: 600_000,
            layers: [top, bottom], maskExpansion: 50_000
        )
        XCTAssertTrue(through.maskOutline(on: top).isEmpty)
        XCTAssertEqual(through.maskOutline(on: topMask).count, 32)
        XCTAssertEqual(through.maskLayers, [topMask, bottomMask])
    }
}
