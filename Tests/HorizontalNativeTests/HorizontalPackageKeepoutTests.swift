import XCTest
@testable import HorizontalNative

/// A package footprint can carry its own keepouts (Horizon `Package::keepouts`),
/// each referencing one of the package's polygons. Horizon gives that polygon
/// a Keepout usage: it renders as a keepout region and never reaches the
/// fabrication output. The loader used to treat it as an ordinary package
/// polygon, so it rendered and exported as filled copper.
///
/// These tests write a minimal pool (one part, one package) plus a board that
/// places it, load through the real `HorizontalBoard.load`, and check both the
/// model and the Gerber output.
final class HorizontalPackageKeepoutTests: XCTestCase {
    private typealias Gerber = HorizontalGerberExportFixture

    private let packageID = "aaaaaaaa-0000-4000-8000-000000000001"
    private let partID = "aaaaaaaa-0000-4000-8000-000000000002"
    private let componentID = "aaaaaaaa-0000-4000-8000-000000000003"
    private let boardPackageID = "aaaaaaaa-0000-4000-8000-000000000004"
    private let polygonID = "aaaaaaaa-0000-4000-8000-000000000005"
    private let keepoutID = "aaaaaaaa-0000-4000-8000-000000000006"

    /// Package-local corners of the keepout polygon (a 2 x 1 mm rectangle).
    private let localCorners = [
        HorizontalPoint(x: -1_000_000, y: -500_000),
        HorizontalPoint(x: 1_000_000, y: -500_000),
        HorizontalPoint(x: 1_000_000, y: 500_000),
        HorizontalPoint(x: -1_000_000, y: 500_000),
    ]

    private var temporaryDirectories = [URL]()

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Writes the pool + board and loads the board. `withKeepout` false leaves
    /// the polygon as plain package artwork, which is the control for the
    /// "same placement as a polygon" comparisons.
    private func loadBoard(
        shift: HorizontalPoint,
        angle: Int,
        mirrored: Bool,
        withKeepout: Bool
    ) throws -> HorizontalBoard {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPackageKeepoutTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(base)
        let pool = base.appendingPathComponent("pool", isDirectory: true)

        var package: [String: Any] = [
            "uuid": packageID,
            "name": "Keepout Package",
            "type": "package",
            "manufacturer": "",
            "tags": [String](),
            "parameter_set": [String: Any](),
            "parameter_program": "",
            "pads": [String: Any](),
            "junctions": [String: Any](),
            "lines": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any](),
            "polygons": [
                polygonID: [
                    "layer": HorizontalBoardLayers.topCopper,
                    "parameter_class": "",
                    "vertices": localCorners.map { corner in
                        [
                            "type": "line",
                            "position": [corner.x, corner.y],
                            "arc_center": [0, 0],
                            "arc_reverse": false,
                        ] as [String: Any]
                    },
                ] as [String: Any],
            ],
        ]
        if withKeepout {
            package["keepouts"] = [
                keepoutID: [
                    "polygon": polygonID,
                    "keepout_class": "no-copper",
                    "all_cu_layers": false,
                    "exposed_cu_only": false,
                    "patch_types_cu": [String](),
                ] as [String: Any],
            ]
        }
        try writeJSON(package, to: pool.appendingPathComponent("packages/cache/\(packageID)/package.json"))
        try writeJSON(
            ["uuid": partID, "type": "part", "package": packageID, "MPN": ["", "KEEPOUT-1"], "value": ["", ""]],
            to: pool.appendingPathComponent("parts/cache/\(partID).json")
        )
        try writeJSON(
            [
                "type": "block",
                "components": [
                    componentID: ["part": partID, "refdes": "K1", "connections": [String: Any]()] as [String: Any],
                ],
                "nets": [String: Any](),
                "net_classes": [String: Any](),
            ],
            to: base.appendingPathComponent("top_block.json")
        )
        try writeJSON(
            [
                "type": "board",
                "n_inner_layers": 0,
                "stackup": [
                    "0": ["thickness": 35_000, "substrate_thickness": 1_500_000],
                    "-100": ["thickness": 35_000, "substrate_thickness": 1_500_000],
                ],
                "packages": [
                    boardPackageID: [
                        "component": componentID,
                        "placement": ["shift": [shift.x, shift.y], "angle": angle, "mirror": mirrored],
                        "flip": mirrored,
                    ] as [String: Any],
                ],
            ],
            to: base.appendingPathComponent("board.json")
        )

        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: nil,
            poolURL: pool,
            diagnostics: &diagnostics
        )
        XCTAssertEqual(board.packages.count, 1, "fixture package did not place: \(diagnostics.map(\.message))")
        return board
    }

    private func assertSameVertices(_ lhs: [HorizontalPoint], _ rhs: [HorizontalPoint],
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, "vertex count", file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a.x, b.x, accuracy: 1, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1, file: file, line: line)
        }
    }

    // MARK: - Tests

    func testPackageKeepoutLoadsAsABoardKeepoutAndNotAsCopper() throws {
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        let board = try loadBoard(shift: shift, angle: 0, mirrored: false, withKeepout: true)

        XCTAssertTrue(board.packagePolygons.isEmpty, "the keepout's polygon must not be package artwork")
        let keepout = try XCTUnwrap(board.keepouts.first)
        XCTAssertEqual(board.keepouts.count, 1)
        XCTAssertEqual(keepout.id.lowercased(), "\(boardPackageID)/keepout/\(keepoutID)")
        XCTAssertEqual(keepout.polygonID.lowercased(), "\(boardPackageID)/polygon/\(polygonID)")
        XCTAssertEqual(keepout.keepoutClass, "no-copper")
        XCTAssertFalse(keepout.allCopperLayers)
        XCTAssertEqual(keepout.polygon.layer, HorizontalBoardLayers.topCopper)
        assertSameVertices(keepout.polygon.vertices, localCorners.map { $0 + shift })

        // The package editing paths find a package's geometry by id prefix; the
        // keepout must resolve to its package like a pad or polygon does.
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: keepout.id), boardPackageID)
    }

    func testPackageKeepoutStaysOutOfTheGerbers() throws {
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        var board = try loadBoard(shift: shift, angle: 0, mirrored: false, withKeepout: true)
        // Something else on top copper so the layer file is written at all.
        board.tracks.append(HorizontalSegment(
            id: "t", from: HorizontalPoint(x: 20_000_000, y: 0), to: HorizontalPoint(x: 30_000_000, y: 0),
            width: 200_000, layer: HorizontalBoardLayers.topCopper, netID: nil
        ))

        let gerbers = try Gerber.exportGerbers(board: board)
        let topCopper = try XCTUnwrap(gerbers[HorizontalBoardLayers.topCopper])
        XCTAssertFalse(topCopper.contains("G36*"), "no region at all belongs on top copper, the keepout was the only polygon")
        for (layer, gerber) in gerbers {
            for corner in localCorners.map({ $0 + shift }) {
                XCTAssertFalse(gerber.contains(Gerber.coordinate(corner)),
                               "package keepout corner reached \(HorizontalBoardLayers.name(for: layer))")
            }
        }
    }

    /// Flipped and rotated, a package keepout lands exactly where the same
    /// polygon lands when it is plain package artwork: same layer (bottom
    /// copper after the flip), same vertices.
    func testPackageKeepoutFollowsThePlacementLikeAPackagePolygon() throws {
        let shift = HorizontalPoint(x: 3_000_000, y: -1_500_000)
        let angle = 16_384 // 90°
        let asKeepout = try loadBoard(shift: shift, angle: angle, mirrored: true, withKeepout: true)
        let asArtwork = try loadBoard(shift: shift, angle: angle, mirrored: true, withKeepout: false)

        XCTAssertTrue(asArtwork.keepouts.isEmpty)
        XCTAssertTrue(asKeepout.packagePolygons.isEmpty)
        let keepout = try XCTUnwrap(asKeepout.keepouts.first)
        let polygon = try XCTUnwrap(asArtwork.packagePolygons.first)

        XCTAssertEqual(polygon.layer, HorizontalBoardLayers.bottomCopper, "flip moves the polygon to bottom copper")
        XCTAssertEqual(keepout.polygon.layer, polygon.layer)
        XCTAssertEqual(keepout.polygonID.lowercased(), polygon.id.lowercased())
        assertSameVertices(keepout.polygon.vertices, polygon.vertices)
        assertSameVertices(
            keepout.polygon.vertices,
            localCorners.map { HorizontalPlacementTransform(shift: shift, angle: angle, mirrored: true).applying(to: $0) }
        )
    }
}
