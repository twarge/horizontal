import XCTest
@testable import HorizontalNative

/// The clip-silkscreen-to-solder-mask mode: silkscreen within the clearance
/// of a mask opening is cut away, everything else is left untouched.
final class HorizontalSilkscreenClipperTests: XCTestCase {
    private let mm = 1_000_000.0

    /// An empty board with one 2 × 2 mm pad mask opening at the origin.
    private func board() -> HorizontalBoard {
        var board = HorizontalBoard.poolEditorBoard(
            uuid: "board",
            name: "Silk",
            url: URL(fileURLWithPath: "/tmp/silk")
        )
        board.packagePads.append(HorizontalPolygon(
            id: "pkg/pad/p1/shape/s1/layer/10",
            vertices: [
                HorizontalPoint(x: -mm, y: -mm),
                HorizontalPoint(x: mm, y: -mm),
                HorizontalPoint(x: mm, y: mm),
                HorizontalPoint(x: -mm, y: mm),
            ],
            layer: HorizontalBoardLayers.topMask
        ))
        return board
    }

    private func line(_ id: String, from: HorizontalPoint, to: HorizontalPoint, layer: Int = HorizontalBoardLayers.topSilkscreen) -> HorizontalSegment {
        HorizontalSegment(id: id, from: from, to: to, width: 0.2 * mm, layer: layer)
    }

    private func covers(_ fragments: [[[HorizontalPoint]]], _ point: HorizontalPoint) -> Bool {
        fragments.contains { fragment in
            guard let outer = fragment.first, contains(outer, point) else {
                return false
            }
            return !fragment.dropFirst().contains { contains($0, point) }
        }
    }

    private func contains(_ polygon: [HorizontalPoint], _ point: HorizontalPoint) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    func testALineAcrossAPadLosesTheOpeningAndItsClearance() throws {
        var board = board()
        board.lines.append(line("across", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0)))
        board.lines.append(line("far", from: HorizontalPoint(x: -5 * mm, y: 4 * mm), to: HorizontalPoint(x: 5 * mm, y: 4 * mm)))

        let clipping = HorizontalSilkscreenClipping()
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: clipping))

        XCTAssertNil(layer.object("far"), "a line nowhere near an opening is left alone")
        let across = try XCTUnwrap(layer.object("across"))
        XCTAssertEqual(across.fragments.count, 2, "the opening splits the line in two")
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: -4 * mm, y: 0)))
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: 4 * mm, y: 0)))
        XCTAssertFalse(covers(across.fragments, HorizontalPoint(x: 0, y: 0)), "over the pad")
        XCTAssertFalse(covers(across.fragments, HorizontalPoint(x: 1.05 * mm, y: 0)), "inside the clearance")
        XCTAssertTrue(covers(across.fragments, HorizontalPoint(x: 1.2 * mm, y: 0)), "just beyond the clearance")

        // Both silkscreen layers come back; the bottom one has no openings.
        let both = HorizontalSilkscreenClipper.clip(board: board, clipping: clipping)
        XCTAssertEqual(Set(both.keys), [HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen])
        XCTAssertTrue(both[HorizontalBoardLayers.bottomSilkscreen]?.clipped.isEmpty ?? false)
    }

    /// The board canvas keeps a clip across edits, so a clipped object is
    /// only served for the geometry it was made from: a line moved since
    /// draws unclipped instead of from fragments left where it was.
    func testAClipIsOnlyServedForTheObjectItWasMadeFrom() throws {
        var board = board()
        let across = line("across", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0))
        board.lines.append(across)
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(
            HorizontalBoardLayers.topSilkscreen,
            board: board,
            clipping: HorizontalSilkscreenClipping()
        ))

        XCTAssertNotNil(layer.object("across", matching: across))
        var moved = across
        moved.from = moved.from + HorizontalPoint(x: 0, y: 3 * mm)
        moved.to = moved.to + HorizontalPoint(x: 0, y: 3 * mm)
        XCTAssertNil(layer.object("across", matching: moved))
    }

    func testALineEntirelyOverAPadVanishes() throws {
        var board = board()
        board.lines.append(line("inside", from: HorizontalPoint(x: -0.5 * mm, y: 0), to: HorizontalPoint(x: 0.5 * mm, y: 0)))
        board.rules.clearanceSilkscreenExposedCopper.clearanceTop = 0
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: HorizontalSilkscreenClipping()))
        let inside = try XCTUnwrap(layer.object("inside"))
        XCTAssertTrue(inside.fragments.isEmpty)
    }

    func testTextAndTheOtherSideAreHandled() throws {
        var board = board()
        board.texts.append(HorizontalText(
            id: "label",
            text: "R1",
            position: HorizontalPoint(x: 0, y: 0),
            size: 1.5 * mm,
            layer: HorizontalBoardLayers.topSilkscreen,
            width: 0.15 * mm
        ))
        board.lines.append(line("bottom", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0), layer: HorizontalBoardLayers.bottomSilkscreen))
        let clipping = HorizontalSilkscreenClipping()
        let top = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: clipping))
        let label = try XCTUnwrap(top.object("label"), "text over the pad is clipped")
        XCTAssertFalse(covers(label.fragments, HorizontalPoint(x: 0, y: 0)))

        // The bottom line only meets bottom mask openings, and there are none.
        let bottom = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.bottomSilkscreen, board: board, clipping: clipping))
        XCTAssertNil(bottom.object("bottom"))
        XCTAssertNil(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topCopper, board: board, clipping: clipping))
    }

    func testSilkscreenIsClippedAtTheBoardEdgeAndItsCutouts() throws {
        var board = board()
        // A 20 × 20 mm board with a 4 × 4 mm cutout at (6, 6).
        board.polygons.append(HorizontalPolygon(
            id: "outline",
            vertices: [
                HorizontalPoint(x: -10 * mm, y: -10 * mm), HorizontalPoint(x: 10 * mm, y: -10 * mm),
                HorizontalPoint(x: 10 * mm, y: 10 * mm), HorizontalPoint(x: -10 * mm, y: 10 * mm),
            ],
            layer: HorizontalBoardLayers.outline
        ))
        board.polygons.append(HorizontalPolygon(
            id: "cutout",
            vertices: [
                HorizontalPoint(x: 4 * mm, y: 4 * mm), HorizontalPoint(x: 8 * mm, y: 4 * mm),
                HorizontalPoint(x: 8 * mm, y: 8 * mm), HorizontalPoint(x: 4 * mm, y: 8 * mm),
            ],
            layer: HorizontalBoardLayers.outline
        ))
        board.lines.append(line("over edge", from: HorizontalPoint(x: 0, y: -5 * mm), to: HorizontalPoint(x: 20 * mm, y: -5 * mm)))
        board.lines.append(line("over cutout", from: HorizontalPoint(x: 0, y: 6 * mm), to: HorizontalPoint(x: 9.5 * mm, y: 6 * mm)))
        board.lines.append(line("well inside", from: HorizontalPoint(x: -8 * mm, y: -8 * mm), to: HorizontalPoint(x: -4 * mm, y: -8 * mm)))
        board.lines.append(line("outside", from: HorizontalPoint(x: 15 * mm, y: 0), to: HorizontalPoint(x: 18 * mm, y: 0)))

        board.rules.clearanceSilkscreenExposedCopper.clearanceTop = 0.2 * mm
        let clipping = HorizontalSilkscreenClipping()
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(HorizontalBoardLayers.topSilkscreen, board: board, clipping: clipping))

        XCTAssertNil(layer.object("well inside"), "far from every edge, pad and cutout: untouched")

        let overEdge = try XCTUnwrap(layer.object("over edge"))
        XCTAssertTrue(covers(overEdge.fragments, HorizontalPoint(x: 5 * mm, y: -5 * mm)))
        XCTAssertFalse(covers(overEdge.fragments, HorizontalPoint(x: 9.9 * mm, y: -5 * mm)), "within the clearance of the edge")
        XCTAssertFalse(covers(overEdge.fragments, HorizontalPoint(x: 12 * mm, y: -5 * mm)), "off the board")

        let overCutout = try XCTUnwrap(layer.object("over cutout"))
        XCTAssertTrue(covers(overCutout.fragments, HorizontalPoint(x: 2 * mm, y: 6 * mm)))
        XCTAssertFalse(covers(overCutout.fragments, HorizontalPoint(x: 6 * mm, y: 6 * mm)), "over the cutout")
        XCTAssertTrue(covers(overCutout.fragments, HorizontalPoint(x: 9 * mm, y: 6 * mm)), "between the cutout and the edge")

        let outside = try XCTUnwrap(layer.object("outside"))
        XCTAssertTrue(outside.fragments.isEmpty, "silkscreen entirely off the board vanishes")
    }

    /// A clipped stroke keeps what is left of its centerline, cut where its
    /// fill is, so the canvas can hold it to an unclipped stroke's weight.
    func testAClippedLineKeepsItsCenterlineWhereItsFillIs() throws {
        var board = board()
        board.lines.append(line("across", from: HorizontalPoint(x: -5 * mm, y: 0), to: HorizontalPoint(x: 5 * mm, y: 0)))
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(
            HorizontalBoardLayers.topSilkscreen,
            board: board,
            clipping: HorizontalSilkscreenClipping()
        ))
        let across = try XCTUnwrap(layer.object("across"))
        XCTAssertEqual(across.centerlines.count, across.fragments.count, "one list per fragment")

        var spans = [(Double, Double)]()
        for index in across.fragments.indices {
            let pieces = across.centerlines(inFragment: index)
            XCTAssertEqual(pieces.count, 1, "each half of the line has one piece")
            for piece in pieces {
                XCTAssertEqual(piece.count, 2)
                XCTAssertTrue(piece.allSatisfy { abs($0.y) < 1 }, "on the line")
                XCTAssertTrue(covers([across.fragments[index]], HorizontalPoint(x: (piece[0].x + piece[1].x) / 2, y: 0)), "inside its own fragment")
                spans.append((min(piece[0].x, piece[1].x), max(piece[0].x, piece[1].x)))
            }
        }
        spans.sort { $0.0 < $1.0 }
        XCTAssertEqual(spans.count, 2)
        let tolerance = 0.005 * mm
        XCTAssertEqual(spans[0].0, -5 * mm, accuracy: tolerance)
        XCTAssertEqual(spans[0].1, -1.1 * mm, accuracy: tolerance, "cut at the opening's clearance")
        XCTAssertEqual(spans[1].0, 1.1 * mm, accuracy: tolerance, "cut at the opening's clearance")
        XCTAssertEqual(spans[1].1, 5 * mm, accuracy: tolerance)
    }

    func testAClippedTextKeepsItsCenterlinesOutOfTheOpening() throws {
        var board = board()
        // "C5" ending a little over the pad's right edge.
        board.texts.append(HorizontalText(
            id: "label",
            text: "C5",
            position: HorizontalPoint(x: 0.6 * mm, y: 0),
            size: 0.75 * mm,
            layer: HorizontalBoardLayers.topSilkscreen,
            width: 0.15 * mm
        ))
        let clearance = 0.1 * mm
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(
            HorizontalBoardLayers.topSilkscreen,
            board: board,
            clipping: HorizontalSilkscreenClipping()
        ))
        let label = try XCTUnwrap(layer.object("label"))
        let pieces = label.fragments.indices.flatMap { label.centerlines(inFragment: $0) }
        XCTAssertFalse(pieces.isEmpty, "the part of the text clear of the pad keeps its centerline")
        let reach = mm + clearance - 0.005 * mm
        for piece in pieces {
            let middle = HorizontalPoint(x: (piece[0].x + piece[1].x) / 2, y: (piece[0].y + piece[1].y) / 2)
            XCTAssertFalse(abs(middle.x) < reach && abs(middle.y) < reach, "no centerline inside the opening or its clearance")
        }
    }

    func testAPolygonHasNoCenterline() throws {
        var board = board()
        board.polygons.append(HorizontalPolygon(
            id: "logo",
            vertices: [
                HorizontalPoint(x: 0, y: -0.5 * mm), HorizontalPoint(x: 3 * mm, y: -0.5 * mm),
                HorizontalPoint(x: 3 * mm, y: 0.5 * mm), HorizontalPoint(x: 0, y: 0.5 * mm),
            ],
            layer: HorizontalBoardLayers.topSilkscreen
        ))
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(
            HorizontalBoardLayers.topSilkscreen,
            board: board,
            clipping: HorizontalSilkscreenClipping()
        ))
        let logo = try XCTUnwrap(layer.object("logo"))
        XCTAssertFalse(logo.fragments.isEmpty)
        XCTAssertTrue(logo.centerlines.isEmpty, "a polygon keeps its outline")
    }

    /// A line whose centerline runs inside the clearance leaves only a sliver
    /// off its side: that fragment has no centerline, so the canvas outlines
    /// it as before rather than letting it vanish when zoomed out.
    func testASliverOffTheSideOfAStrokeHasNoCenterline() throws {
        var board = board()
        board.lines.append(line("grazing", from: HorizontalPoint(x: -0.5 * mm, y: 1.05 * mm), to: HorizontalPoint(x: 0.5 * mm, y: 1.05 * mm)))
        let layer = try XCTUnwrap(HorizontalSilkscreenClipper.clippedLayer(
            HorizontalBoardLayers.topSilkscreen,
            board: board,
            clipping: HorizontalSilkscreenClipping()
        ))
        let grazing = try XCTUnwrap(layer.object("grazing"))
        XCTAssertFalse(grazing.fragments.isEmpty, "the stroke's far side is beyond the clearance")
        XCTAssertTrue(grazing.fragments.indices.allSatisfy { grazing.centerlines(inFragment: $0).isEmpty })
    }

    func testCenterlinePiecesSkipAFragmentsHoles() {
        let outer = [
            HorizontalPoint(x: -3 * mm, y: -3 * mm), HorizontalPoint(x: 3 * mm, y: -3 * mm),
            HorizontalPoint(x: 3 * mm, y: 3 * mm), HorizontalPoint(x: -3 * mm, y: 3 * mm),
        ]
        let hole = [
            HorizontalPoint(x: -mm, y: -mm), HorizontalPoint(x: mm, y: -mm),
            HorizontalPoint(x: mm, y: mm), HorizontalPoint(x: -mm, y: mm),
        ]
        let across = (HorizontalPoint(x: -5 * mm, y: 0), HorizontalPoint(x: 5 * mm, y: 0))
        let pieces = HorizontalSilkscreenClipper.pieces(of: [across], inside: [outer, hole])
            .map { (min($0[0].x, $0[1].x), max($0[0].x, $0[1].x)) }
            .sorted { $0.0 < $1.0 }
        XCTAssertEqual(pieces.count, 2, "split by the hole, trimmed to the outer contour")
        XCTAssertEqual(pieces[0].0, -3 * mm, accuracy: 1)
        XCTAssertEqual(pieces[0].1, -mm, accuracy: 1)
        XCTAssertEqual(pieces[1].0, mm, accuracy: 1)
        XCTAssertEqual(pieces[1].1, 3 * mm, accuracy: 1)

        let insideHole = (HorizontalPoint(x: -0.5 * mm, y: 0), HorizontalPoint(x: 0.5 * mm, y: 0))
        XCTAssertTrue(HorizontalSilkscreenClipper.pieces(of: [insideHole], inside: [outer, hole]).isEmpty)
        let whole = (HorizontalPoint(x: -2.5 * mm, y: 2 * mm), HorizontalPoint(x: 2.5 * mm, y: 2 * mm))
        XCTAssertEqual(HorizontalSilkscreenClipper.pieces(of: [whole], inside: [outer, hole]).count, 1, "a segment wholly inside stays one piece")
    }

    func testBridgedContourKeepsHolesOpen() {
        let outer = [
            HorizontalPoint(x: -3 * mm, y: -3 * mm),
            HorizontalPoint(x: 3 * mm, y: -3 * mm),
            HorizontalPoint(x: 3 * mm, y: 3 * mm),
            HorizontalPoint(x: -3 * mm, y: 3 * mm),
        ]
        let hole = [
            HorizontalPoint(x: -mm, y: -mm),
            HorizontalPoint(x: mm, y: -mm),
            HorizontalPoint(x: mm, y: mm),
            HorizontalPoint(x: -mm, y: mm),
        ]
        let contour = HorizontalSilkscreenClipper.bridgedContour([outer, hole])
        XCTAssertEqual(contour.count, outer.count + hole.count + 2)
        XCTAssertTrue(contains(contour, HorizontalPoint(x: 2.5 * mm, y: 2.5 * mm)), "the ring is filled")
        XCTAssertFalse(contains(contour, HorizontalPoint(x: 0, y: 0)), "the hole stays open")
        XCTAssertTrue(HorizontalSilkscreenClipper.bridgedContour([]).isEmpty)
    }

    func testCapsuleCoversTheStroke() {
        let capsule = HorizontalSilkscreenClipper.capsule(from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 2 * mm, y: 0), width: 0.4 * mm)
        XCTAssertTrue(contains(capsule, HorizontalPoint(x: mm, y: 0.15 * mm)))
        XCTAssertTrue(contains(capsule, HorizontalPoint(x: -0.15 * mm, y: 0)), "round cap")
        XCTAssertFalse(contains(capsule, HorizontalPoint(x: mm, y: 0.3 * mm)))
        XCTAssertFalse(contains(capsule, HorizontalPoint(x: -0.25 * mm, y: 0)))
    }

    @MainActor
    func testThePreferenceTurnsClippingOnAndIsKept() {
        let defaults = UserDefaults(suiteName: "HorizontalSilkscreenClipperTests-\(UUID().uuidString)")!
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertNil(settings.silkscreenClipping, "off by default")
        settings.clipSilkscreenToSolderMaskBinding().wrappedValue = true
        XCTAssertNotNil(settings.silkscreenClipping)
        XCTAssertNotNil(HorizontalAppearanceSettings(defaults: defaults).silkscreenClipping)
    }

    func testTheClearanceIsTheBoardRulesForEachSide() {
        var board = board()
        board.rules.clearanceSilkscreenExposedCopper.clearanceTop = 0.25 * mm
        board.rules.clearanceSilkscreenExposedCopper.clearanceBottom = 0.4 * mm
        // The check's switches don't change what is stripped.
        board.rules.clearanceSilkscreenExposedCopper.enabled = false
        let clipping = HorizontalSilkscreenClipping()
        XCTAssertEqual(clipping.clearance(forSilkscreen: HorizontalBoardLayers.topSilkscreen, of: board), 0.25 * mm)
        XCTAssertEqual(clipping.clearance(forSilkscreen: HorizontalBoardLayers.bottomSilkscreen, of: board), 0.4 * mm)
    }
}
