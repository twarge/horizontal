import XCTest
@testable import HorizontalNative

final class SchematicSymbolBackgroundTests: XCTestCase {
    private let rectangle = [
        HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 4_000_000, y: 0),
        HorizontalPoint(x: 4_000_000, y: 2_000_000), HorizontalPoint(x: 0, y: 2_000_000)
    ]

    private func lines(_ points: [HorizontalPoint], owner: String = "symbol") -> [HorizontalSegment] {
        zip(points, points.dropFirst() + [points[0]]).enumerated().map { index, pair in
            HorizontalSegment(id: "\(owner)/line/\(index)", from: pair.0, to: pair.1, width: 0, layer: nil)
        }
    }

    private func area(_ points: [HorizontalPoint]) -> Double {
        abs(zip(points, points.dropFirst() + [points[0]]).reduce(0) { result, pair in
            result + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        }) / 2
    }

    func testUnorderedReversedRectangleFillsOnceAndRetainsSymbolOwner() throws {
        let outline = lines(rectangle, owner: "block/symbol").reversed().map { line in
            var reversed = line
            swap(&reversed.from, &reversed.to)
            return reversed
        }
        let polygons = SchematicSymbolBackground.polygons(for: outline)
        let polygon = try XCTUnwrap(polygons.first)
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(area(polygon.vertices), 8e12, accuracy: 1)
        XCTAssertEqual(schematicMetalSymbolID(forGeometryID: polygon.id), "block/symbol")
    }

    func testOpenOutlineAndVisibleGapStayUnfilled() {
        XCTAssertTrue(SchematicSymbolBackground.polygons(for: Array(lines(rectangle).dropLast())).isEmpty)
        var gapped = lines(rectangle)
        gapped[0].from.x += 1_000
        XCTAssertTrue(SchematicSymbolBackground.polygons(for: gapped).isEmpty)
    }

    func testTouchingSymbolsCannotCloseEachOthersOutlines() {
        let outline = lines(rectangle)
        var other = Array(outline.suffix(2))
        for index in other.indices { other[index].id = "other/line/\(index)" }
        XCTAssertTrue(SchematicSymbolBackground.polygons(for: Array(outline.prefix(2)) + other).isEmpty)

        let coincident = SchematicSymbolBackground.polygons(for: outline + lines(rectangle, owner: "other"))
        XCTAssertEqual(coincident.count, 2)
        XCTAssertEqual(Set(coincident.compactMap { schematicMetalSymbolID(forGeometryID: $0.id) }), ["symbol", "other"])
    }

    func testConcaveOutlineFillsItsShapeInsteadOfItsBoundingBox() throws {
        let concave = [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 4_000_000, y: 0),
            HorizontalPoint(x: 4_000_000, y: 1_000_000), HorizontalPoint(x: 1_000_000, y: 1_000_000),
            HorizontalPoint(x: 1_000_000, y: 3_000_000), HorizontalPoint(x: 0, y: 3_000_000)
        ]
        let polygons = SchematicSymbolBackground.polygons(for: lines(concave))
        let polygon = try XCTUnwrap(polygons.first)
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(area(polygon.vertices), 6e12, accuracy: 1)
        let triangles = HorizontalMetalTessellator.triangles(for: polygon.vertices, color: HorizontalMetalRGBA(.red))
        XCTAssertEqual(triangles.reduce(0) { $0 + area([$1.a, $1.b, $1.c]) }, 6e12, accuracy: 1)
    }

    func testInternalDividerAndDanglingStrokesDoNotOverlapFills() {
        var outline = lines(rectangle)
        outline.append(HorizontalSegment(id: "symbol/line/diagonal", from: rectangle[0], to: rectangle[2], width: 0, layer: nil))
        outline.append(HorizontalSegment(id: "symbol/line/tail", from: rectangle[1], to: HorizontalPoint(x: 3_000_000, y: 500_000), width: 0, layer: nil))
        outline.append(outline[0]) // Duplicate strokes must not create extra faces.
        let polygons = SchematicSymbolBackground.polygons(for: outline)
        XCTAssertEqual(polygons.count, 2)
        XCTAssertEqual(polygons.reduce(0) { $0 + area($1.vertices) }, 8e12, accuracy: 1)
    }

    func testFlattenedArcClosesAfterRotationAndMirroring() throws {
        let arc = HorizontalArc(
            id: "arc", from: HorizontalPoint(x: 1_000_000, y: 0),
            to: HorizontalPoint(x: -1_000_000, y: 0), center: .zero, width: 0, layer: nil
        )
        let transform = HorizontalPlacementTransform(
            shift: HorizontalPoint(x: 300_000_000, y: -200_000_000), angle: 7_321, mirrored: true
        )
        let points = arc.polyline().map(transform.applying)
        var outline = zip(points, points.dropFirst()).enumerated().map { index, pair in
            HorizontalSegment(id: "symbol/arc/a/\(index)", from: pair.0, to: pair.1, width: 0, layer: nil)
        }
        outline.append(HorizontalSegment(
            id: "symbol/line/diameter", from: transform.applying(to: arc.to),
            to: transform.applying(to: arc.from), width: 0, layer: nil
        ))
        let polygons = SchematicSymbolBackground.polygons(for: outline)
        let polygon = try XCTUnwrap(polygons.first)
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(area(polygon.vertices), Double.pi * 1e12 / 2, accuracy: 2e9)
    }

    @MainActor
    func testPreferenceDefaultsOffAndPersistsIndependentlyOfNetLabels() {
        let suite = "SchematicSymbolBackgroundTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertFalse(settings.shouldFillClosedSymbolBackground)
        settings.closedSymbolBackgroundBinding().wrappedValue = true
        let reloaded = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertTrue(reloaded.shouldFillClosedSymbolBackground)
        XCTAssertFalse(reloaded.shouldFillNetLabelBackground)
        reloaded.closedSymbolBackgroundBinding().wrappedValue = false
        XCTAssertFalse(HorizontalAppearanceSettings(defaults: defaults).shouldFillClosedSymbolBackground)
    }
}
