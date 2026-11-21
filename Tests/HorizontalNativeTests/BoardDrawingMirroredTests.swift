import CoreGraphics
import ImageIO
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The board drawing's Mirrored option, which `render_board`'s `mirrored`
/// sets: the board seen from below, the page flipped left to right as
/// Horizon's `export_pdf` flips it. A region shows the same part of the
/// board either way, and highlights and overlays land on what they mark.
///
/// The board is one channel of `BlockLayoutFixture`, R1 at the origin, R2
/// 5 mm right of it and R3 10 mm, with copper on one side of it only, so it
/// is not its own mirror image.
final class BoardDrawingMirroredTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private var client: BlockLayoutDispatchClient!
    private var instance: String { fixture.instances[0] }
    private let corner = "33333333-3333-4333-8333-333333333331", end = "33333333-3333-4333-8333-333333333332"
    private let stub = "44444444-4444-4444-8444-444444444441", run = "44444444-4444-4444-8444-444444444442"

    override func setUpWithError() throws {
        fixture = try BlockLayoutFixture(instances: 1)
        try fixture.addCopper(
            junctions: [corner: HorizontalPoint(x: 10_750_000, y: -1_500_000), end: HorizontalPoint(x: 8_000_000, y: -3_000_000)],
            tracks: [stub: (try fixture.padEnd(instance, "R3", 2), fixture.junctionEnd(corner), 0),
                     run: (fixture.junctionEnd(corner), fixture.junctionEnd(end), 0)],
            vias: ["99999999-9999-4999-8999-999999999991": end])
        try fixture.saveToDisk()
        client = try BlockLayoutDispatchClient(path: fixture.url.path)
    }

    override func tearDown() {
        client?.close()
        fixture?.remove()
        super.tearDown()
    }

    /// A render as rows of pixels marked where something is drawn: anything
    /// that is not the page's own colour, taken from its corner.
    private struct Picture {
        var width: Int
        var height: Int
        var ink: [Bool]

        var inkCount: Int { ink.filter { $0 }.count }

        var flipped: Picture {
            var result = self
            for y in 0..<height {
                for x in 0..<width {
                    result.ink[y * width + x] = ink[y * width + (width - 1 - x)]
                }
            }
            return result
        }

        /// How many drawn pixels of either picture have none drawn within a
        /// pixel of them in the other: an edge can fall a pixel either way
        /// when a page is rasterized the other way round.
        func mismatch(with other: Picture) -> Int {
            guard width == other.width, height == other.height else { return .max }
            func unmatched(_ a: Picture, _ b: Picture) -> Int {
                var count = 0
                for y in 0..<a.height {
                    for x in 0..<a.width where a.ink[y * a.width + x] {
                        var found = false
                        for dy in -1...1 where !found {
                            for dx in -1...1 {
                                let nx = x + dx, ny = y + dy
                                if nx >= 0, ny >= 0, nx < b.width, ny < b.height, b.ink[ny * b.width + nx] {
                                    found = true
                                    break
                                }
                            }
                        }
                        if !found { count += 1 }
                    }
                }
                return count
            }
            return unmatched(self, other) + unmatched(other, self)
        }
    }

    /// `contrast` is how far from the page's colour a pixel is before it
    /// counts as drawn; a grid line is faint and may straddle two columns.
    private func picture(_ more: JSONDictionary, contrast: Int = 60) throws -> Picture {
        var params: JSONDictionary = ["dpi": 100]
        params.merge(more) { _, new in new }
        let reply = try XCTUnwrap(try client.result("render_board", params) as? JSONDictionary)
        let png = try XCTUnwrap(reply.string("png_base64").flatMap { Data(base64Encoded: $0) })
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let page = (Int(pixels[0]), Int(pixels[1]), Int(pixels[2]))
        let ink = stride(from: 0, to: pixels.count, by: 4).map { index in
            max(abs(Int(pixels[index]) - page.0), abs(Int(pixels[index + 1]) - page.1), abs(Int(pixels[index + 2]) - page.2)) > contrast
        }
        return Picture(width: image.width, height: image.height, ink: ink)
    }

    /// The mirrored picture is the plain one flipped left to right, to
    /// within a pixel at the edges of what is drawn, and is not the plain
    /// one itself.
    private func assertMirrors(_ mirrored: Picture, _ plain: Picture, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mirrored.width, plain.width, what, file: file, line: line)
        XCTAssertEqual(mirrored.height, plain.height, what, file: file, line: line)
        XCTAssertGreaterThan(plain.inkCount, 200, "\(what): something is drawn", file: file, line: line)
        let allowed = max(plain.inkCount / 100, 4)
        XCTAssertLessThanOrEqual(mirrored.mismatch(with: plain.flipped), allowed,
                                 "\(what): the mirrored drawing is the drawing flipped left to right", file: file, line: line)
        XCTAssertGreaterThan(mirrored.mismatch(with: plain), plain.inkCount / 5,
                             "\(what): and not the drawing as it is seen from above", file: file, line: line)
    }

    func testAMirroredRenderIsTheBoardSeenFromBelow() throws {
        assertMirrors(try picture(["mirrored": true]), try picture([:]), "the whole board")
    }

    func testAMirroredRenderOfARegionShowsTheSamePartOfTheBoard() throws {
        // Off the board's middle, where a crop left on the unmirrored side
        // of the page would show another part of it.
        let region: JSONDictionary = ["min_x_mm": 6, "min_y_mm": -4, "max_x_mm": 12, "max_y_mm": 2]
        let plain = try picture(["region": region, "dpi": 300])
        assertMirrors(try picture(["region": region, "dpi": 300, "mirrored": true]), plain, "a region")
    }

    func testHighlightsAndOverlaysFollowAMirroredRender() throws {
        // Copper off, so only what is picked out and drawn over is in the
        // picture: it lies where the mirrored board has it.
        let marks: JSONDictionary = [
            "layer_ids": [HorizontalBoardLayers.outline],
            "highlight": [run],
            "overlay": [["via": ["x_mm": 2, "y_mm": 1, "diameter_mm": 0.6]],
                        ["track": ["points_mm": [[2, 1], [4, 2]], "width_mm": 0.2]],
                        ["box_mm": [8, -2, 11, -1]]],
            "region": ["min_x_mm": -2, "min_y_mm": -4, "max_x_mm": 12, "max_y_mm": 3],
            "dpi": 200,
        ]
        var mirroredMarks = marks
        mirroredMarks["mirrored"] = true
        assertMirrors(try picture(mirroredMarks), try picture(marks), "highlights and overlays")
    }

    func testAMirroredGridCountsBoardMillimetresFromTheRight() throws {
        // Grid lines are where the mirrored board's millimetres are: the
        // mirrored grid is the grid flipped, but for its labels, which read
        // the right way round on both.
        let region: JSONDictionary = ["min_x_mm": 0.5, "min_y_mm": -4, "max_x_mm": 11, "max_y_mm": 3]
        let grid: JSONDictionary = ["layer_ids": [HorizontalBoardLayers.outline], "grid_mm": 5, "region": region, "dpi": 200]
        var mirroredGrid = grid
        mirroredGrid["mirrored"] = true
        let plain = try picture(grid, contrast: 15), mirrored = try picture(mirroredGrid, contrast: 15)
        XCTAssertEqual(mirrored.width, plain.width)
        // The x = 5 and x = 10 lines stand 4.5 mm and 9.5 mm from the left
        // edge, and from the right edge when mirrored. A column that is a
        // grid line is drawn nearly all the way up.
        func lineColumns(_ picture: Picture) -> [Int] {
            (0..<picture.width).filter { x in
                (0..<picture.height).filter { picture.ink[$0 * picture.width + x] }.count > picture.height * 3 / 4
            }
        }
        let plainColumns = lineColumns(plain), mirroredColumns = lineColumns(mirrored)
        XCTAssertFalse(plainColumns.isEmpty)
        let perMM = Double(plain.width) / 10.5
        for expected in [4.5, 9.5] {
            XCTAssertTrue(plainColumns.contains { abs(Double($0) - expected * perMM) <= 2 },
                          "plain \(plainColumns) of \(plain.width) has a line \(expected) mm in")
            XCTAssertTrue(mirroredColumns.contains { abs(Double(plain.width - 1 - $0) - expected * perMM) <= 2 },
                          "mirrored \(mirroredColumns) of \(plain.width) has a line \(expected) mm from the right")
        }
    }
}
