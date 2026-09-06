import Foundation
import XCTest
@testable import HorizontalNative

/// The polygon rectangle and circle tools (Horizon's "draw polygon
/// rectangle/circle") and the persisted rectangle placement mode.
final class HorizontalDrawingPrimitiveTests: XCTestCase {
    private let mm = 1_000_000.0

    private func result(
        _ primitive: HorizontalDrawingPrimitive,
        _ points: [HorizontalPoint],
        mode: HorizontalRectanglePlacementMode = .corner
    ) -> HorizontalCanvasDrawGraphicsResult {
        HorizontalCanvasModeSupport.graphicsResult(
            for: primitive,
            points: points,
            rectanglePlacementMode: mode,
            pointKey: { "\($0.x),\($0.y)" },
            makeSegment: { HorizontalSegment(id: "l", from: $0, to: $1, width: 0, layer: 0) },
            makeArc: { HorizontalArc(id: "a", from: $0, to: $1, center: $2, width: 0, layer: 0) },
            makePolygonResult: { HorizontalCanvasDrawGraphicsResult(polygons: [HorizontalPolygon(id: "p", polygonVertices: $0, layer: 100)]) }
        )
    }

    func testPolygonRectangleIsOnePolygonInEitherPlacementMode() throws {
        let corner = result(.polygonRectangle, [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 5 * mm)])
        XCTAssertTrue(corner.lines.isEmpty)
        let cornerPolygon = try XCTUnwrap(corner.polygons.first)
        XCTAssertEqual(cornerPolygon.layer, 100)
        XCTAssertEqual(cornerPolygon.polygonVertices.count, 4)
        XCTAssertTrue(cornerPolygon.polygonVertices.allSatisfy { $0.type == .line })
        XCTAssertEqual(Set(cornerPolygon.vertices.map(\.x)), [0, 10 * mm])
        XCTAssertEqual(Set(cornerPolygon.vertices.map(\.y)), [0, 5 * mm])

        let center = result(.polygonRectangle, [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 5 * mm)], mode: .center)
        let centerPolygon = try XCTUnwrap(center.polygons.first)
        XCTAssertEqual(Set(centerPolygon.vertices.map(\.x)), [-10 * mm, 10 * mm])
        XCTAssertEqual(Set(centerPolygon.vertices.map(\.y)), [-5 * mm, 5 * mm])

        // The line version is still four lines.
        let lines = result(.rectangle, [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 10 * mm, y: 5 * mm)])
        XCTAssertEqual(lines.lines.count, 4)
        XCTAssertTrue(lines.polygons.isEmpty)
    }

    func testPolygonCircleIsTwoHalfCircleArcVertices() throws {
        let center = HorizontalPoint(x: 3 * mm, y: 4 * mm)
        let circle = result(.polygonCircle, [center, HorizontalPoint(x: 5 * mm, y: 4 * mm)])
        let polygon = try XCTUnwrap(circle.polygons.first)
        XCTAssertEqual(polygon.polygonVertices.count, 2)
        XCTAssertEqual(polygon.polygonVertices[0].type, .arc)
        XCTAssertEqual(polygon.polygonVertices[1].type, .arc)
        XCTAssertEqual(polygon.polygonVertices[0].position, HorizontalPoint(x: 5 * mm, y: 4 * mm))
        XCTAssertEqual(polygon.polygonVertices[1].position, HorizontalPoint(x: mm, y: 4 * mm))
        XCTAssertEqual(polygon.polygonVertices[0].arcCenter, center)
        XCTAssertEqual(polygon.polygonVertices[1].arcCenter, center)
        XCTAssertFalse(polygon.polygonVertices[0].arcReverse)
        // It renders as a full circle.
        let rendered = polygon.renderVertices(arcPrecision: 16)
        XCTAssertGreaterThan(rendered.count, 8)
        for point in rendered {
            XCTAssertEqual((point - center).length, 2 * mm, accuracy: 10)
        }
        // A zero radius is nothing.
        XCTAssertTrue(result(.polygonCircle, [center, center]).isEmpty)
    }

    func testCanvasesWithoutPolygonsGetTheOutlineAsLinesAndArcs() {
        let center = HorizontalPoint(x: 0, y: 0)
        let vertices = [
            HorizontalPolygonVertex(type: .arc, position: HorizontalPoint(x: mm, y: 0), arcCenter: center),
            HorizontalPolygonVertex(type: .arc, position: HorizontalPoint(x: -mm, y: 0), arcCenter: center, arcReverse: true),
        ]
        let outline = HorizontalCanvasModeSupport.outlineResult(
            vertices: vertices,
            makeSegment: { HorizontalSegment(id: "l", from: $0, to: $1, width: 0, layer: 0) },
            makeArc: { HorizontalArc(id: "a", from: $0, to: $1, center: $2, width: 0, layer: 0) }
        )
        XCTAssertTrue(outline.lines.isEmpty)
        XCTAssertEqual(outline.arcs.count, 2)
        XCTAssertEqual(outline.arcs[0].from, HorizontalPoint(x: mm, y: 0))
        XCTAssertEqual(outline.arcs[0].to, HorizontalPoint(x: -mm, y: 0))
        // A reversed vertex runs its arc the other way round.
        XCTAssertEqual(outline.arcs[1].from, HorizontalPoint(x: mm, y: 0))
        XCTAssertEqual(outline.arcs[1].to, HorizontalPoint(x: -mm, y: 0))

        let square = HorizontalCanvasModeSupport.outlineResult(
            vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: mm, y: 0), HorizontalPoint(x: mm, y: mm)].map { HorizontalPolygonVertex(position: $0) },
            makeSegment: { HorizontalSegment(id: "l", from: $0, to: $1, width: 0, layer: 0) },
            makeArc: { HorizontalArc(id: "a", from: $0, to: $1, center: $2, width: 0, layer: 0) }
        )
        XCTAssertEqual(square.lines.count, 3)
        XCTAssertEqual(square.lines.last?.to, HorizontalPoint(x: 0, y: 0))
    }

    func testPolygonShapesNeedTwoPointsLikeTheLineOnes() {
        let one = [HorizontalPoint(x: 0, y: 0)]
        let two = one + [HorizontalPoint(x: mm, y: mm)]
        for primitive in [HorizontalDrawingPrimitive.polygonRectangle, .polygonCircle, .rectangle, .circle] {
            XCTAssertNil(HorizontalCanvasModeSupport.finalizedGraphicsResult(for: primitive, points: one) { _, _, _ in HorizontalCanvasDrawGraphicsResult() })
            XCTAssertNotNil(HorizontalCanvasModeSupport.finalizedGraphicsResult(for: primitive, points: two) { _, _, _ in HorizontalCanvasDrawGraphicsResult() })
        }
        XCTAssertTrue(HorizontalDrawingPrimitive.polygonRectangle.isRectangle)
        XCTAssertTrue(HorizontalDrawingPrimitive.rectangle.isRectangle)
        XCTAssertFalse(HorizontalDrawingPrimitive.polygonCircle.isRectangle)
        XCTAssertEqual(HorizontalDrawingPrimitive.allCases.filter(\.producesPolygon), [.polygon, .polygonRectangle, .polygonCircle])
        XCTAssertTrue(HorizontalCanvasModeSupport.drawingToolStatusText(for: .polygonRectangle, rectanglePlacementMode: .center).contains("Center"))
    }

    func testRailsOfferPolygonShapesWherePolygonsExist() {
        XCTAssertEqual(HorizontalDrawingPrimitive.polygonRail, [.line, .polygonRectangle, .polygonCircle, .arc, .polygon])
        XCTAssertEqual(HorizontalDrawingPrimitive.lineRail, [.line, .rectangle, .circle, .arc])
    }

    func testRectanglePlacementModeDefaultsToCenterAndPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "drawing-tool-settings-\(UUID().uuidString)"))
        XCTAssertEqual(HorizontalDrawingToolSettings.rectanglePlacementMode(in: defaults), .center)
        HorizontalDrawingToolSettings.setRectanglePlacementMode(.corner, in: defaults)
        XCTAssertEqual(HorizontalDrawingToolSettings.rectanglePlacementMode(in: defaults), .corner)
        defaults.set("garbage", forKey: HorizontalDrawingToolSettings.rectanglePlacementModeKey)
        XCTAssertEqual(HorizontalDrawingToolSettings.rectanglePlacementMode(in: defaults), .center)
    }
}
