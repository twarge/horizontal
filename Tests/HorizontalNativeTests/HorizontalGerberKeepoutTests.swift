import XCTest
@testable import HorizontalNative

/// Keepouts are design-rule regions the router and DRC honour; they are not
/// copper, mask or artwork, and Horizon's Gerber export leaves them out. The
/// layer collector used to trace each keepout as a thin closed polyline on its
/// layer, which fabricated as a hairline of copper around every keepout.
final class HorizontalGerberKeepoutTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x, y: y)
    }

    private func keepout(_ id: String, layer: Int, corners: [HorizontalPoint]) -> HorizontalKeepout {
        HorizontalKeepout(
            id: id,
            polygonID: "\(id)/polygon",
            polygon: HorizontalPolygon(id: "\(id)/polygon", vertices: corners, layer: layer),
            keepoutClass: "",
            allCopperLayers: false,
            exposedCopperOnly: false,
            copperPatchTypes: []
        )
    }

    private let corners = [
        HorizontalPoint(x: 1_000_000, y: 1_000_000),
        HorizontalPoint(x: 9_000_000, y: 1_000_000),
        HorizontalPoint(x: 9_000_000, y: 7_000_000),
        HorizontalPoint(x: 1_000_000, y: 7_000_000),
    ]

    /// A keepout on a copper layer that also carries a track: the track keeps
    /// the layer file alive, and none of the keepout's corners may be drawn
    /// into it.
    func testKeepoutOutlineIsNotDrawnOnItsCopperLayer() throws {
        let track = HorizontalSegment(
            id: "t", from: point(20_000_000, 0), to: point(30_000_000, 0),
            width: 200_000, layer: Fixture.top, netID: nil
        )
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(
            tracks: [track],
            keepouts: [keepout("k-top", layer: Fixture.top, corners: corners)]
        ))

        let topCopper = try XCTUnwrap(gerbers[Fixture.top], "the track must still produce a top copper file")
        XCTAssertTrue(topCopper.contains("\(Fixture.coordinate(track.from))D02*"))
        for corner in corners {
            XCTAssertFalse(topCopper.contains(Fixture.coordinate(corner)), "keepout corner \(corner) reached top copper")
        }
    }

    /// A keepout that is the only thing on its layer leaves that layer empty,
    /// so no file is written for it at all. A track on top copper keeps the
    /// export itself non-empty (an export with no layers and no drills is an
    /// error by design).
    func testKeepoutAloneOnALayerProducesNoFileForIt() throws {
        let track = HorizontalSegment(
            id: "t", from: point(20_000_000, 0), to: point(30_000_000, 0),
            width: 200_000, layer: Fixture.top, netID: nil
        )
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(
            tracks: [track],
            keepouts: [
                keepout("k-inner", layer: Fixture.inner1, corners: corners),
                keepout("k-bottom", layer: Fixture.bottom, corners: corners),
            ]
        ))

        XCTAssertNotNil(gerbers[Fixture.top])
        XCTAssertNil(gerbers[Fixture.inner1])
        XCTAssertNil(gerbers[Fixture.bottom])
        for (layer, gerber) in gerbers {
            for corner in corners {
                XCTAssertFalse(gerber.contains(Fixture.coordinate(corner)),
                               "keepout corner \(corner) reached \(HorizontalBoardLayers.name(for: layer))")
            }
        }
    }
}
