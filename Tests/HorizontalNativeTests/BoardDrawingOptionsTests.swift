import CoreGraphics
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The board drawing's layer colours and its Reverse layers and Specify
/// holes size options, as Horizon's `export_pdf` has them. Each layer is
/// drawn in its own colour, black until one is picked. The drawing is
/// painted one layer at a time, the lowest in the stack first, so the top of
/// the board covers the bottom, and reversed the bottom covers the top.
/// Holes are drawn at their own sizes or all at the one stated, a slot
/// keeping its length.
///
/// The board is `BlockLayoutFixture`'s, with a top and a bottom copper line
/// crossing below its parts and a round and a slotted hole beside them.
final class BoardDrawingOptionsTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var directory: URL!
    private let mm = 1_000_000.0
    private let red = HorizontalRGBColor(red: 1, green: 0, blue: 0)
    private let blue = HorizontalRGBColor(red: 0, green: 0, blue: 1)

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("board-drawing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        fixture?.remove()
        super.tearDown()
    }

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// The fixture's project with the crossing lines and the two holes.
    private func project() throws -> HorizontalProject {
        var project = fixture.project
        var board = try XCTUnwrap(project.board)
        board.lines.append(HorizontalSegment(
            id: "top-line", from: point(2, -6), to: point(8, -6), width: 1 * mm, layer: HorizontalBoardLayers.topCopper))
        board.lines.append(HorizontalSegment(
            id: "bottom-line", from: point(5, -9), to: point(5, -3), width: 1 * mm, layer: HorizontalBoardLayers.bottomCopper))
        board.holes.append(HorizontalHole(id: "round", position: point(2, -12), diameter: 0.6 * mm, plated: false))
        board.holes.append(HorizontalHole(
            id: "slot", position: point(8, -12), diameter: 0.6 * mm, length: 2 * mm, shape: .slot, plated: false))
        // The bounds a load would give it with these on it: the page is
        // laid out for them.
        board.physicalBounds = HorizontalRect(points: [point(-2, -15), point(12, 3)])
        project.board = board
        return project
    }

    /// A board drawing exported and rasterized, to be read at board points.
    private struct Drawing {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var pixelsPerPoint: CGFloat
        var mapping: HorizontalDispatchRender.PageMapping

        func color(at point: HorizontalPoint) -> (red: Int, green: Int, blue: Int) {
            let page = mapping.point(point)
            let x = min(max(Int((page.x * pixelsPerPoint).rounded(.down)), 0), width - 1)
            // The page's y runs up; the bitmap's rows run down.
            let y = min(max(height - 1 - Int((page.y * pixelsPerPoint).rounded(.down)), 0), height - 1)
            let index = (y * width + x) * 4
            return (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
        }

        /// Whether anything is drawn at `point`: not the page's own colour,
        /// which its corner has. A hole's outline is a light grey.
        func isDrawn(at point: HorizontalPoint) -> Bool {
            let here = color(at: point), page = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
            return max(abs(here.red - page.0), abs(here.green - page.1), abs(here.blue - page.2)) > 5
        }
    }

    /// Exports the board drawing with only `layers` enabled, in the colours
    /// given, and whatever `configure` sets besides.
    private func drawing(
        layers: [Int: HorizontalRGBColor] = [:],
        _ configure: (inout HorizontalBoardDrawingExportSettings) -> Void = { _ in }
    ) throws -> Drawing {
        let project = try project()
        var settings = HorizontalExportSettings(project: project)
        settings.targetDirectory = directory.path
        for index in settings.boardDrawing.layers.indices {
            let layer = settings.boardDrawing.layers[index].layer
            settings.boardDrawing.layers[index].enabled = layers[layer] != nil
            settings.boardDrawing.layers[index].mode = .fill
            if let color = layers[layer] {
                settings.boardDrawing.layers[index].color = color
            }
        }
        configure(&settings.boardDrawing)
        let status = HorizontalExportBackend.export(sections: [.boardDrawing], settings: settings, project: project)
        XCTAssertNotEqual(status.kind, .error, status.message)

        let page = try rasterized(directory.appendingPathComponent(settings.boardDrawing.filename))
        let board = try XCTUnwrap(project.board)
        return Drawing(
            pixels: page.pixels, width: page.width, height: page.height, pixelsPerPoint: pixelsPerPoint,
            mapping: HorizontalDispatchRender.PageMapping(
                bounds: HorizontalDispatchRender.boardPageBounds(board), margin: 36, pageSize: page.size,
                mirrored: settings.boardDrawing.mirrored))
    }

    private let pixelsPerPoint: CGFloat = 4

    /// A PDF's first page as pixels, four to the point.
    private func rasterized(_ url: URL) throws -> (pixels: [UInt8], width: Int, height: Int, size: CGSize) {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let width = Int((box.width * pixelsPerPoint).rounded()), height = Int((box.height * pixelsPerPoint).rounded())
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.drawPDFPage(page)
        return (pixels, width, height, box.size)
    }

    private func assertRed(_ color: (red: Int, green: Int, blue: Int), _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(color.red > 200 && color.blue < 80, "\(what) is the top copper's red, not \(color)", file: file, line: line)
    }

    private func assertBlue(_ color: (red: Int, green: Int, blue: Int), _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(color.blue > 200 && color.red < 80, "\(what) is the bottom copper's blue, not \(color)", file: file, line: line)
    }

    private var copper: [Int: HorizontalRGBColor] {
        [HorizontalBoardLayers.topCopper: red, HorizontalBoardLayers.bottomCopper: blue]
    }

    func testEveryLayerIsBlackUntilAColourIsPicked() throws {
        let settings = HorizontalExportSettings(project: try project())
        XCTAssertFalse(settings.boardDrawing.layers.isEmpty)
        XCTAssertTrue(settings.boardDrawing.layers.allSatisfy { $0.color == HorizontalRGBColor(red: 0, green: 0, blue: 0) })
    }

    func testALayerIsDrawnInTheColourPickedForIt() throws {
        // What the sidebar's colour well keeps for a colour picked in it.
        let green = rgbColor(from: Color(red: 0.1, green: 0.8, blue: 0.2))
        XCTAssertEqual(green.red, 0.1, accuracy: 0.02)
        XCTAssertEqual(green.green, 0.8, accuracy: 0.02)
        XCTAssertEqual(green.blue, 0.2, accuracy: 0.02)
        // And the well shows that colour again.
        let shown = rgbColor(from: Binding.constant(green).pickedColor.wrappedValue)
        XCTAssertEqual(shown.red, green.red, accuracy: 0.02)
        XCTAssertEqual(shown.green, green.green, accuracy: 0.02)
        XCTAssertEqual(shown.blue, green.blue, accuracy: 0.02)

        let drawing = try drawing(layers: [HorizontalBoardLayers.topCopper: green])
        let line = drawing.color(at: point(3, -6))
        XCTAssertTrue(line.green > 150 && line.red < 110 && line.blue < 130, "the top line is the green picked, not \(line)")
        XCTAssertFalse(drawing.isDrawn(at: point(5, -8)), "and the bottom copper, switched off, is not drawn")
    }

    func testTheTopOfTheBoardCoversTheBottomWhereTheyCross() throws {
        let drawing = try drawing(layers: copper)
        assertRed(drawing.color(at: point(3, -6)), "the top line")
        assertBlue(drawing.color(at: point(5, -8)), "the bottom line")
        assertRed(drawing.color(at: point(5, -6)), "where they cross")
    }

    func testReversedTheBottomOfTheBoardCoversTheTop() throws {
        let drawing = try drawing(layers: copper) { $0.reverseLayers = true }
        assertRed(drawing.color(at: point(3, -6)), "the top line")
        assertBlue(drawing.color(at: point(5, -8)), "the bottom line")
        assertBlue(drawing.color(at: point(5, -6)), "where they cross")
    }

    func testReversedAndMirroredIsTheBoardSeenFromBelow() throws {
        // The two together are the drawing of the bottom side: the page
        // flipped and the bottom copper on top.
        let drawing = try drawing(layers: copper) {
            $0.reverseLayers = true
            $0.mirrored = true
        }
        assertRed(drawing.color(at: point(3, -6)), "the top line")
        assertBlue(drawing.color(at: point(5, -6)), "where they cross")
        let plain = try self.drawing(layers: copper)
        XCTAssertLessThan(plain.mapping.point(point(3, -6)).x, plain.mapping.point(point(5, -6)).x)
        XCTAssertGreaterThan(drawing.mapping.point(point(3, -6)).x, drawing.mapping.point(point(5, -6)).x,
                             "and what was left of the crossing is right of it")
    }

    func testLayersArePaintedInStackOrderAndOnlyTheEnabledOnes() throws {
        var board = try fixture.board
        // A user layer the board puts between the top copper and its mask.
        board.userLayers = [HorizontalBoardUserLayer(id: HorizontalBoardLayers.user1, colorLayer: HorizontalBoardLayers.user1,
                                                      name: "Stiffener", type: "stiffener", position: 5)]
        func setting(_ layer: Int, enabled: Bool = true) -> HorizontalExportLayerSetting {
            HorizontalExportLayerSetting(layer: layer, name: "", enabled: enabled, filename: "", mode: .fill, color: red)
        }
        let layers = [
            HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomCopper, HorizontalBoardLayers.user1,
            HorizontalBoardLayers.topCopper, HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomSilkscreen,
        ]
        var settings = Dictionary(uniqueKeysWithValues: layers.map { ($0, setting($0)) })
        settings[HorizontalBoardLayers.outline] = setting(HorizontalBoardLayers.outline, enabled: false)

        let order = HorizontalExportBackend.paintOrder(of: settings, board: board, reversed: false).map(\.layer)
        XCTAssertEqual(order, [
            HorizontalBoardLayers.bottomSilkscreen, HorizontalBoardLayers.bottomCopper, HorizontalBoardLayers.topCopper,
            HorizontalBoardLayers.user1, HorizontalBoardLayers.topMask, HorizontalBoardLayers.topSilkscreen,
        ], "the bottom first and the top last, the user layer where the board has it, the layer switched off left out")
        XCTAssertEqual(HorizontalExportBackend.paintOrder(of: settings, board: board, reversed: true).map(\.layer), order.reversed())
    }

    func testHolesAreDrawnAtTheirOwnSizes() throws {
        let drawing = try drawing()
        // The round hole, 0.6 mm across.
        XCTAssertTrue(drawing.isDrawn(at: point(2.3, -12)), "the round hole's edge")
        XCTAssertFalse(drawing.isDrawn(at: point(2, -12)), "nothing inside it")
        XCTAssertFalse(drawing.isDrawn(at: point(3, -12)), "nor a millimetre out")
        // The slot, 0.6 mm wide and 2 mm long: its sides and its end.
        XCTAssertTrue(drawing.isDrawn(at: point(8, -11.7)), "the slot's side")
        XCTAssertTrue(drawing.isDrawn(at: point(9, -12)), "the slot's end")
        XCTAssertFalse(drawing.isDrawn(at: point(8, -11.5)), "nothing beside the slot")
    }

    func testAStatedDiameterIsTheSizeEveryHoleIsDrawnAt() throws {
        let drawing = try drawing {
            $0.useSpecifiedHoleDiameter = true
            $0.holeDiameterMM = 1
        }
        XCTAssertTrue(drawing.isDrawn(at: point(2.5, -12)), "the round hole, now 1 mm across")
        XCTAssertFalse(drawing.isDrawn(at: point(2.3, -12)), "and not at its own size")
        // The slot is as wide as the diameter and as long as it was.
        XCTAssertTrue(drawing.isDrawn(at: point(8, -11.5)), "the slot's side, half a millimetre out")
        XCTAssertFalse(drawing.isDrawn(at: point(8, -11.7)), "and not where it was")
        XCTAssertTrue(drawing.isDrawn(at: point(9, -12)), "the slot's end where it was")

        // A diameter longer than the slot makes it a circle of that size.
        let wide = try self.drawing {
            $0.useSpecifiedHoleDiameter = true
            $0.holeDiameterMM = 3
        }
        XCTAssertTrue(wide.isDrawn(at: point(9.5, -12)))
        XCTAssertTrue(wide.isDrawn(at: point(8, -10.5)))
        XCTAssertFalse(wide.isDrawn(at: point(9, -12)))

        // The diameter is not used while the option is off.
        let off = try self.drawing { $0.holeDiameterMM = 1 }
        XCTAssertTrue(off.isDrawn(at: point(2.3, -12)))
        XCTAssertFalse(off.isDrawn(at: point(2.5, -12)))
    }

    func testTheExportMethodTakesTheDrawingsOptions() throws {
        // A via, so the board has a hole to draw.
        let end = "33333333-3333-4333-8333-333333333331"
        try fixture.addCopper(junctions: [end: point(8, -3)], vias: ["99999999-9999-4999-8999-999999999991": end])
        try fixture.saveToDisk()
        let client = try BlockLayoutDispatchClient(path: fixture.url.path)
        defer { client.close() }
        func page(_ options: JSONDictionary) throws -> [UInt8] {
            let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            _ = try client.result("export", [
                "sections": ["board_drawing"], "target_directory": target.path, "options": ["board_drawing": options],
            ])
            let files = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            return try rasterized(try XCTUnwrap(files.first { $0.pathExtension == "pdf" })).pixels
        }
        let plain = try page([:])
        XCTAssertEqual(try page([:]), plain, "the same drawing twice is the same picture")
        XCTAssertNotEqual(try page(["mirrored": true]), plain, "mirrored")
        XCTAssertNotEqual(try page(["hole_diameter_mm": 2]), plain, "every hole 2 mm across")
        // Every layer is black, so the order they are painted in can't be
        // seen; the option is taken all the same.
        XCTAssertEqual(try page(["reverse_layers": true]), plain)
    }
}
