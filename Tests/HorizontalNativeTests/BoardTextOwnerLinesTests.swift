import XCTest
@testable import HorizontalNative

/// A selected smashed text is drawn a line to its package, and a selected
/// package one to each of its smashed texts that shows, as Horizon's text
/// owner annotation draws them.
final class BoardTextOwnerLinesTests: XCTestCase {
    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x, y: y) }

    private func text(_ id: String, at point: HorizontalPoint, layer: Int, smashed: Bool = true) -> HorizontalText {
        HorizontalText(id: id, text: "R1", position: point, size: 1_000_000, layer: layer, fromSmash: smashed)
    }

    private let topSilk = HorizontalBoardLayers.topSilkscreen
    private let topAssembly = HorizontalBoardLayers.topAssembly

    private func makeBoard() -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/t.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [],
            packages: [
                HorizontalPlacement(id: "PKG1", position: p(0, 0), angle: 0, mirrored: false, label: "R1"),
                HorizontalPlacement(id: "pkg2", position: p(9_000_000, 0), angle: 0, mirrored: false, label: "R2")
            ],
            packagePads: [], packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [],
            packageTexts: [
                text("PKG1/text/refdes", at: p(0, 3_000_000), layer: topSilk),
                text("pkg1/text/value", at: p(2_000_000, 3_000_000), layer: topSilk),
                text("pkg1/text/assembly", at: p(0, -1_000_000), layer: topAssembly, smashed: false),
                text("pkg2/text/refdes", at: p(9_000_000, 3_000_000), layer: topSilk),
                text("pkg2/text/on-origin", at: p(9_000_000, 0), layer: topSilk)
            ],
            texts: [text("board-text", at: p(5_000_000, 5_000_000), layer: topSilk, smashed: false)],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    private func lines(_ refs: [HorizontalSelectableRef], shows: @escaping (HorizontalText) -> Bool = { _ in true }) -> [BoardTextOwnerLines.Line] {
        BoardTextOwnerLines.lines(in: makeBoard(), selectedRefs: refs, showsText: shows)
    }

    func testASelectedSmashedTextIsDrawnALineToItsPackage() {
        let drawn = lines([HorizontalSelectableRef(id: "pkg1/text/refdes", type: .text, layer: topSilk)])
        XCTAssertEqual(drawn, [BoardTextOwnerLines.Line(text: p(0, 3_000_000), package: p(0, 0))], "ids are matched lowercased")
    }

    func testASelectedPackageIsDrawnALineToEachOfItsSmashedTexts() {
        let drawn = lines([HorizontalSelectableRef(id: "pkg1", type: .boardPackage)])
        XCTAssertEqual(drawn, [
            BoardTextOwnerLines.Line(text: p(0, 3_000_000), package: p(0, 0)),
            BoardTextOwnerLines.Line(text: p(2_000_000, 3_000_000), package: p(0, 0))
        ], "the package's own text, never smashed, goes with it unannotated")
    }

    func testAPackagesHiddenTextsAreLeftOutButASelectedTextIsNot() {
        let hidden: (HorizontalText) -> Bool = { $0.id != "pkg1/text/value" && $0.id != "PKG1/text/refdes" }
        XCTAssertTrue(lines([HorizontalSelectableRef(id: "pkg1", type: .boardPackage)], shows: hidden).isEmpty)
        XCTAssertEqual(
            lines([HorizontalSelectableRef(id: "pkg1/text/refdes", type: .text, layer: topSilk)], shows: { _ in false }).count, 1,
            "a selected text is annotated whatever the layers show, as Horizon's is"
        )
    }

    func testATextAndItsPackageSelectedTogetherDrawOneLine() {
        let drawn = lines([
            HorizontalSelectableRef(id: "pkg1/text/refdes", type: .text, layer: topSilk),
            HorizontalSelectableRef(id: "pkg1", type: .boardPackage)
        ])
        XCTAssertEqual(drawn.count, 2, "refdes and value, the refdes once")
    }

    func testNothingIsDrawnForBoardTextATextOnItsOriginOrAnUnrelatedSelection() {
        XCTAssertTrue(lines([HorizontalSelectableRef(id: "board-text", type: .text, layer: topSilk)]).isEmpty)
        XCTAssertTrue(lines([HorizontalSelectableRef(id: "pkg2/text/on-origin", type: .text, layer: topSilk)]).isEmpty)
        XCTAssertTrue(lines([HorizontalSelectableRef(id: "t1", type: .track, layer: 0)]).isEmpty)
        XCTAssertTrue(lines([]).isEmpty)
    }
}
