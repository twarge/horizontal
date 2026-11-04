import XCTest
@testable import HorizontalNative

/// A selected or hovered track is outlined by Horizon's box round it, not by
/// a dashed line along its middle: a straight track's box is as long as the
/// track with half its width more at each end and as wide as the track,
/// turned with it, and an arc track's is its centre line's bounds with half
/// its width more on every side.
final class BoardTrackSelectionOutlineTests: XCTestCase {
    private static let mm = 1_000_000.0
    /// The slack `HorizontalSelectable.corners` adds to every box, in all.
    private static let cornerSlack = 100.0

    private let color = HorizontalMetalRGBA(red: 1, green: 0, blue: 1, alpha: 1)

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * Self.mm, y: y * Self.mm)
    }

    private func overlay(
        tracks: [HorizontalSegment],
        selected: [HorizontalSelectableRef],
        hovered: HorizontalSelectableRef? = nil,
        arcWidths: [String: Double] = [:]
    ) -> HorizontalCanvasMetalSelectionOverlay {
        let selectables = HorizontalCanvasModeSupport.segmentSelectables(tracks, type: .track, convertsArcSegments: true)
        return HorizontalCanvasModeSupport.metalSelectionOverlay(
            selectablesForRef: { ref in
                selectables.filter { HorizontalCanvasModeSupport.normalizedID($0.ref.id) == HorizontalCanvasModeSupport.normalizedID(ref.id) }
            },
            selectedRefs: selected,
            hoveredRef: hovered,
            style: HorizontalCanvasSelectionOverlayStyle(
                selectedOuterColor: color, selectedInnerColor: color, selectedHandleInnerColor: color,
                hoverOuterColor: color, hoverInnerColor: color, handleShape: .diamond
            ),
            outlineForSelectable: { BoardTrackSelectionOutline.outline(for: $0, arcWidths: arcWidths) }
        )
    }

    /// The overlay's lines longer than `length`: the midpoint's grab handle
    /// keeps the small square every point selectable draws, which this leaves out.
    private func lines(in overlay: HorizontalCanvasMetalSelectionOverlay, longerThan length: Double) -> [HorizontalMetalLinePrimitive] {
        overlay.lines.filter { hypot($0.to.x - $0.from.x, $0.to.y - $0.from.y) > length }
    }

    private func assertSameCorners(
        _ lines: [HorizontalMetalLinePrimitive],
        _ expected: [HorizontalPoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lines.count, 4, "a closed box", file: file, line: line)
        for corner in expected {
            XCTAssertTrue(
                lines.contains { hypot($0.from.x - corner.x, $0.from.y - corner.y) < Self.cornerSlack },
                "an edge starts at (\(corner.x / Self.mm), \(corner.y / Self.mm)) mm",
                file: file,
                line: line
            )
        }
    }

    func testASelectedTrackIsOutlinedByTheBoxRoundIt() {
        // 5 mm long, 1 mm wide, at the angle of a 3-4-5 triangle.
        let track = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(3, 4), width: Self.mm, layer: HorizontalBoardLayers.topCopper
        )
        let ref = HorizontalSelectableRef(id: "T", type: .track, layer: HorizontalBoardLayers.topCopper)
        let overlay = overlay(tracks: [track], selected: [ref])

        let along = HorizontalPoint(x: 0.6, y: 0.8)
        let across = HorizontalPoint(x: -0.8, y: 0.6)
        let center = point(1.5, 2)
        let halfLength = 3 * Self.mm  // half of 5 mm and half the width more
        let halfWidth = 0.5 * Self.mm
        let corners = [(-1.0, -1.0), (-1, 1), (1, 1), (1, -1)].map { u, n in
            center + along * (u * halfLength) + across * (n * halfWidth)
        }
        let box = lines(in: overlay, longerThan: 0.5 * Self.mm)
        assertSameCorners(box, corners)
        XCTAssertTrue(
            box.allSatisfy { $0.normalOffset == -HorizontalSelectable.selectionOutlineScreenMargin },
            "drawn just outside the box, as every boxed selection is"
        )
        XCTAssertFalse(
            overlay.lines.contains { $0.from == track.from && $0.to == track.to },
            "no line along the track's middle"
        )
        XCTAssertTrue(
            overlay.handles.contains { hypot($0.center.x - center.x, $0.center.y - center.y) < 1 },
            "the grab handle stays at the track's middle"
        )
    }

    func testAHoveredTrackIsOutlinedByItsBoxInDashes() {
        let track = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(4, 0), width: 0.5 * Self.mm, layer: HorizontalBoardLayers.topCopper
        )
        let ref = HorizontalSelectableRef(id: "T", type: .track, layer: HorizontalBoardLayers.topCopper)
        let overlay = overlay(tracks: [track], selected: [], hovered: ref)

        let box = lines(in: overlay, longerThan: 0.25 * Self.mm)
        assertSameCorners(box, [point(-0.25, -0.25), point(-0.25, 0.25), point(4.25, 0.25), point(4.25, -0.25)])
        XCTAssertTrue(box.allSatisfy { $0.dashLength > 0 }, "a hovered box is dashed")
    }

    func testAnArcTrackIsOutlinedByItsBoundsWithHalfItsWidthMore() throws {
        // A quarter turn of radius 2 mm about the origin, 1 mm wide.
        let track = HorizontalSegment(
            id: "A", from: point(2, 0), to: point(0, 2), width: Self.mm, layer: HorizontalBoardLayers.topCopper,
            center: point(0, 0)
        )
        let ref = HorizontalSelectableRef(id: "a", type: .track, layer: HorizontalBoardLayers.topCopper)
        let board = board(tracks: [track])
        let arcWidths = BoardTrackSelectionOutline.arcWidths(in: board, refs: [ref])
        XCTAssertEqual(arcWidths, ["a": Self.mm])

        let selectable = try XCTUnwrap(
            HorizontalCanvasModeSupport.segmentSelectables([track], type: .track, convertsArcSegments: true).first
        )
        let bounds = selectable.axisAlignedBounds
        let overlay = overlay(tracks: [track], selected: [ref], arcWidths: arcWidths)
        let box = lines(in: overlay, longerThan: 0.5 * Self.mm)
        let half = 0.5 * Self.mm
        assertSameCorners(box, [
            HorizontalPoint(x: bounds.min.x - half, y: bounds.min.y - half),
            HorizontalPoint(x: bounds.min.x - half, y: bounds.max.y + half),
            HorizontalPoint(x: bounds.max.x + half, y: bounds.max.y + half),
            HorizontalPoint(x: bounds.max.x + half, y: bounds.min.y - half),
        ])
    }

    func testOnlyArcTracksAmongTheRefsAreLookedUp() {
        let straight = HorizontalSegment(
            id: "T", from: point(0, 0), to: point(1, 0), width: Self.mm, layer: HorizontalBoardLayers.topCopper
        )
        let arc = HorizontalSegment(
            id: "A", from: point(2, 0), to: point(0, 2), width: Self.mm, layer: HorizontalBoardLayers.topCopper,
            center: point(0, 0)
        )
        let board = board(tracks: [straight, arc])
        XCTAssertEqual(
            BoardTrackSelectionOutline.arcWidths(in: board, refs: [HorizontalSelectableRef(id: "T", type: .track)]),
            [:]
        )
        XCTAssertEqual(
            BoardTrackSelectionOutline.arcWidths(in: board, refs: [HorizontalSelectableRef(id: "A", type: .via)]),
            [:],
            "a ref of another type is not a track"
        )
    }

    private func board(tracks: [HorizontalSegment]) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/track-outline.hprj"), uuid: "b", name: "track-outline",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [],
            planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }
}
