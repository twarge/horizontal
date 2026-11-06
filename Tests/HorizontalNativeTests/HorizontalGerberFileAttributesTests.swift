import XCTest
@testable import HorizontalNative

/// Each Gerber file says in its header what it is, in Gerber X2's file
/// attributes, so a fab's CAM need not guess from the file name: a copper
/// layer's number counted from the top, the side of a mask, legend or paste,
/// the board profile, and whether the image is the material or its absence.
/// The files used to carry only a G04 comment naming the layer.
final class HorizontalGerberFileAttributesTests: XCTestCase {
    private typealias Fixture = HorizontalGerberExportFixture
    private typealias Attributes = HorizontalGerberFileAttributes

    private func point(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func line(on layer: Int) -> HorizontalSegment {
        HorizontalSegment(id: "line-\(layer)", from: point(0, 0), to: point(5, 0), width: 200_000, layer: layer, netID: nil)
    }

    /// The file's `%TF` lines, after checking each stands in the header:
    /// before the format statement and the first operation code.
    private func attributes(_ gerber: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let lines = gerber.split(separator: "\n").map(String.init)
        let attributeIndices = lines.indices.filter { lines[$0].hasPrefix("%TF.") }
        let format = lines.firstIndex(of: "%FSLAX46Y46*%") ?? lines.endIndex
        let operation = lines.firstIndex { $0.hasSuffix("D01*") || $0.hasSuffix("D02*") || $0.hasSuffix("D03*") } ?? lines.endIndex
        for index in attributeIndices {
            XCTAssertLessThan(index, min(format, operation), "\(lines[index]) is not in the header", file: file, line: line)
        }
        return attributeIndices.map { lines[$0] }
    }

    private func value(_ name: String, in attributes: [String]) -> String? {
        let prefix = "%TF.\(name),"
        return attributes.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).dropLast(2)) }
    }

    /// A four-layer board's copper runs L1 to L4, top to bottom, where
    /// Horizon names the middle two Inner 1 and Inner 2.
    func testFourLayerCopperIsNumberedFromTheTop() throws {
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(
            lines: [Fixture.top, Fixture.inner1, Fixture.inner2, Fixture.bottom].map(line(on:))
        ))

        let expected = [
            Fixture.top: "Copper,L1,Top",
            Fixture.inner1: "Copper,L2,Inr",
            Fixture.inner2: "Copper,L3,Inr",
            Fixture.bottom: "Copper,L4,Bot",
        ]
        for (layer, function) in expected {
            let name = HorizontalBoardLayers.name(for: layer)
            let attributes = attributes(try XCTUnwrap(gerbers[layer], name))
            XCTAssertEqual(value("FileFunction", in: attributes), function, name)
            XCTAssertEqual(value("FilePolarity", in: attributes), "Positive", name)
            XCTAssertTrue(attributes.contains("%TF.SameCoordinates*%"), name)
        }
    }

    /// With no inner layers the bottom copper is L2.
    func testTwoLayerBottomCopperIsL2() throws {
        var board = Fixture.board(lines: [line(on: Fixture.top), line(on: Fixture.bottom)])
        board.stackupLayers.removeAll { $0.layer != Fixture.top && $0.layer != Fixture.bottom }
        let gerbers = try Fixture.exportGerbers(board: board)

        XCTAssertEqual(value("FileFunction", in: attributes(try XCTUnwrap(gerbers[Fixture.top]))), "Copper,L1,Top")
        XCTAssertEqual(value("FileFunction", in: attributes(try XCTUnwrap(gerbers[Fixture.bottom]))), "Copper,L2,Bot")
    }

    /// Mask, legend and paste name their side. A mask file draws the openings,
    /// the absence of mask, so it is negative; the outline is the profile, not
    /// a material, and has no polarity.
    func testMaskLegendPasteAndProfile() throws {
        let layers = [
            HorizontalBoardLayers.topMask, HorizontalBoardLayers.bottomMask,
            HorizontalBoardLayers.topSilkscreen, HorizontalBoardLayers.bottomSilkscreen,
            HorizontalBoardLayers.topPaste, HorizontalBoardLayers.bottomPaste,
        ]
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(
            lines: layers.map(line(on:)),
            polygons: [HorizontalPolygon(
                id: "outline", vertices: [point(0, 0), point(20, 0), point(20, 10), point(0, 10)],
                layer: HorizontalBoardLayers.outline
            )]
        ))

        let expected: [Int: (function: String, polarity: String?)] = [
            HorizontalBoardLayers.topMask: ("Soldermask,Top", "Negative"),
            HorizontalBoardLayers.bottomMask: ("Soldermask,Bot", "Negative"),
            HorizontalBoardLayers.topSilkscreen: ("Legend,Top", "Positive"),
            HorizontalBoardLayers.bottomSilkscreen: ("Legend,Bot", "Positive"),
            HorizontalBoardLayers.topPaste: ("Paste,Top", "Positive"),
            HorizontalBoardLayers.bottomPaste: ("Paste,Bot", "Positive"),
            HorizontalBoardLayers.outline: ("Profile,NP", nil),
        ]
        for (layer, want) in expected {
            let name = HorizontalBoardLayers.name(for: layer)
            let attributes = attributes(try XCTUnwrap(gerbers[layer], name))
            XCTAssertEqual(value("FileFunction", in: attributes), want.function, name)
            XCTAssertEqual(value("FilePolarity", in: attributes), want.polarity, name)
        }
    }

    /// A documentation user layer and the dimensions are drawings; a user
    /// layer of material the spec has no function for, a stiffener, is Other.
    /// Each carries its name, its comma escaped as the field syntax asks.
    func testUserLayersAndDimensionsAreNamed() throws {
        let documentation = HorizontalBoardLayers.user1
        let stiffener = HorizontalBoardLayers.user2
        let gerbers = try Fixture.exportGerbers(board: Fixture.board(
            lines: [line(on: documentation), line(on: stiffener)],
            dimensions: [HorizontalDimension(
                id: "d", p0: point(0, 0), p1: point(10, 0), labelDistance: 2_000_000, labelSize: 1_000_000, mode: .distance
            )],
            userLayers: [
                HorizontalBoardUserLayer(id: documentation, colorLayer: documentation, name: "Fab notes", type: "documentation", position: nil),
                HorizontalBoardUserLayer(id: stiffener, colorLayer: stiffener, name: "Stiffener, 0.2 mm", type: "stiffener", position: nil),
            ]
        ))

        XCTAssertEqual(value("FileFunction", in: attributes(try XCTUnwrap(gerbers[documentation]))), "OtherDrawing,Fab notes")
        XCTAssertEqual(value("FileFunction", in: attributes(try XCTUnwrap(gerbers[stiffener]))), "Other,Stiffener\\u002C 0.2 mm")
        let dimensions = attributes(try XCTUnwrap(gerbers[HorizontalBoardLayers.dimensions]))
        XCTAssertEqual(value("FileFunction", in: dimensions), "OtherDrawing,Dimensions")
        XCTAssertNil(value("FilePolarity", in: dimensions))
    }

    /// The software and its version lead the attributes when the version is
    /// known, and are left out when it isn't, since the attribute needs one.
    func testGenerationSoftwareNeedsAVersion() {
        XCTAssertEqual(
            Attributes.header(for: Fixture.top, innerLayerCount: 2, userLayer: nil, softwareVersion: "1.2 (34)"),
            [
                "%TF.GenerationSoftware,Horizontal,Horizontal,1.2 (34)*%",
                "%TF.SameCoordinates*%",
                "%TF.FileFunction,Copper,L1,Top*%",
                "%TF.FilePolarity,Positive*%",
            ]
        )
        XCTAssertEqual(
            Attributes.header(for: Fixture.bottom, innerLayerCount: 2, userLayer: nil, softwareVersion: nil),
            ["%TF.SameCoordinates*%", "%TF.FileFunction,Copper,L4,Bot*%", "%TF.FilePolarity,Positive*%"]
        )
    }

    /// A field escapes the Gerber delimiters, the escape character, its comma
    /// separator and anything past printable ASCII; a comment's string keeps
    /// its commas.
    func testFieldsAndStringsEscape() {
        XCTAssertEqual(
            Attributes.field("10% *off*, a\\b Côté 🛠"),
            "10\\u0025 \\u002Aoff\\u002A\\u002C a\\u005Cb C\\u00F4t\\u00E9 \\U0001F6E0"
        )
        XCTAssertEqual(Attributes.string("Top, *Copper*"), "Top, \\u002ACopper\\u002A")
    }
}
