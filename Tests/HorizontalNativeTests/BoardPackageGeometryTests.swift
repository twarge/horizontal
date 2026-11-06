import XCTest
@testable import HorizontalNative

/// `BoardPackageGeometry.index` finds, in one pass for many packages, what a
/// package's move, turn or mirror found by scanning every array for it alone:
/// each geometry item whose id names the package
/// (`BoardMovePlanner.geometryID(_:belongsToPackage:)`) and each pad position
/// under "packageID/".
final class BoardPackageGeometryTests: XCTestCase {
    private func square(_ id: String) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [
            HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 100, y: 0),
            HorizontalPoint(x: 100, y: 100), HorizontalPoint(x: 0, y: 100),
        ], layer: HorizontalBoardLayers.topCopper)
    }

    private func segment(_ id: String) -> HorizontalSegment {
        HorizontalSegment(id: id, from: .zero, to: HorizontalPoint(x: 100, y: 0), width: 10, layer: HorizontalBoardLayers.topSilkscreen)
    }

    /// Packages `pa`, `pb` and `blk/pc` (a block instance's path, its id
    /// holding a slash), geometry for each in every array, some written in
    /// capitals, and a free hole, keepout and polygon of no package.
    private func board() -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/package-geometry.hprj"), uuid: "b", name: "package geometry",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_500_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 1_500_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [], netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [],
            keepouts: ["pa/keepout/k", "free-keepout", "BLK/PC/keepout/k"].map {
                HorizontalKeepout(id: $0, polygonID: $0, polygon: square($0), keepoutClass: "",
                                  allCopperLayers: false, exposedCopperOnly: false, copperPatchTypes: [])
            },
            dimensions: [], decals: [], holes: [], vias: [], viaHoles: [],
            packages: ["pa", "pb", "blk/pc"].map {
                HorizontalPlacement(id: $0, position: .zero, angle: 0, mirrored: false, label: $0)
            },
            packagePads: ["pa/pad/1/shape/s", "PB/pad/1/shape/s", "pa/pad/2/shape/s", "blk/pc/pad/1/shape/s"].map(square),
            packageHoles: ["pb/hole/h", "free-hole", "pa/hole/h"].map {
                HorizontalHole(id: $0, position: .zero, diameter: 50, plated: true, netID: nil)
            },
            packagePolygons: ["pb/polygon/p", "pa/polygon/p"].map(square),
            packageLines: ["pa/line/l", "blk/pc/line/l", "pb/line/l"].map(segment),
            packageArcs: ["pb/arc/a", "pa/arc/a"].map {
                HorizontalArc(id: $0, from: .zero, to: HorizontalPoint(x: 100, y: 0), center: HorizontalPoint(x: 50, y: 0),
                              width: 10, layer: HorizontalBoardLayers.topSilkscreen)
            },
            packageTexts: ["pa/text/rd", "pb/text/rd", "PA/text/val"].map {
                HorizontalText(id: $0, text: "R", position: .zero, size: 1_000_000, layer: HorizontalBoardLayers.topSilkscreen)
            },
            texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.packagePadPositions = ["pa/1": .zero, "pa/2": .zero, "pb/1": .zero, "blk/pc/1": .zero, "pab/1": .zero]
        return board
    }

    /// What scanning for one package alone found.
    private func scanned(_ packageID: String, in board: HorizontalBoard) -> BoardPackageGeometry {
        func indices(_ ids: [String]) -> [Int] {
            ids.indices.filter { BoardMovePlanner.geometryID(ids[$0], belongsToPackage: packageID) }
        }
        var geometry = BoardPackageGeometry()
        geometry.pads = indices(board.packagePads.map(\.id))
        geometry.holes = indices(board.packageHoles.map(\.id))
        geometry.polygons = indices(board.packagePolygons.map(\.id))
        geometry.lines = indices(board.packageLines.map(\.id))
        geometry.arcs = indices(board.packageArcs.map(\.id))
        geometry.texts = indices(board.packageTexts.map(\.id))
        geometry.keepouts = indices(board.keepouts.map(\.id))
        geometry.padPositionKeys = board.packagePadPositions.keys.filter { $0.hasPrefix(packageID + "/") }.sorted()
        return geometry
    }

    private func assertSame(_ found: BoardPackageGeometry?, _ expected: BoardPackageGeometry, _ packageID: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let found else {
            return XCTFail("nothing found for \(packageID)", file: file, line: line)
        }
        XCTAssertEqual(found.pads, expected.pads, "\(packageID) pads", file: file, line: line)
        XCTAssertEqual(found.holes, expected.holes, "\(packageID) holes", file: file, line: line)
        XCTAssertEqual(found.polygons, expected.polygons, "\(packageID) polygons", file: file, line: line)
        XCTAssertEqual(found.lines, expected.lines, "\(packageID) lines", file: file, line: line)
        XCTAssertEqual(found.arcs, expected.arcs, "\(packageID) arcs", file: file, line: line)
        XCTAssertEqual(found.texts, expected.texts, "\(packageID) texts", file: file, line: line)
        XCTAssertEqual(found.keepouts, expected.keepouts, "\(packageID) keepouts", file: file, line: line)
        XCTAssertEqual(found.padPositionKeys.sorted(), expected.padPositionKeys, "\(packageID) pad positions", file: file, line: line)
    }

    func testTheIndexFindsWhatEachPackagesScanFound() {
        let board = board()
        let packageIDs: Set<String> = ["pa", "pb", "blk/pc"]
        let index = BoardPackageGeometry.index(of: board, packageIDs: packageIDs)
        XCTAssertEqual(Set(index.keys), packageIDs)
        for packageID in packageIDs {
            assertSame(index[packageID], scanned(packageID, in: board), packageID)
            assertSame(BoardPackageGeometry(packageID: packageID.uppercased(), in: board), scanned(packageID, in: board), packageID)
        }
        // The scans' answers, spelt out for pa.
        let pa = index["pa"]
        XCTAssertEqual(pa?.pads, [0, 2])
        XCTAssertEqual(pa?.holes, [2])
        XCTAssertEqual(pa?.texts, [0, 2], "PA/text/val is pa's")
        XCTAssertEqual(pa?.keepouts, [0])
        XCTAssertEqual(pa?.padPositionKeys.sorted(), ["pa/1", "pa/2"], "not pab's")
        XCTAssertEqual(index["blk/pc"]?.padPositionKeys, ["blk/pc/1"])
        XCTAssertEqual(index["blk/pc"]?.keepouts, [2])
    }

    func testAPackageWithNoGeometryHasAnEmptyEntryAndNoneAreAskedForNothing() {
        let board = board()
        let index = BoardPackageGeometry.index(of: board, packageIDs: ["gone", "pa"])
        let gone = index["gone"]
        XCTAssertNotNil(gone)
        XCTAssertEqual(gone?.pads, [])
        XCTAssertEqual(gone?.padPositionKeys, [])
        XCTAssertTrue(BoardPackageGeometry.index(of: board, packageIDs: []).isEmpty)
    }
}
