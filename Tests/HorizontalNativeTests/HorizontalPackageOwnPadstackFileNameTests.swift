import XCTest
@testable import HorizontalNative

/// A package can carry padstacks of its own, in `padstacks/` beside its
/// `package.json`. Horizon's pool database finds one by the uuid it carries,
/// whatever its file is called: Horizon's project pool caches it as
/// `<uuid>.json`, while a package made in a pool names it for what it is
/// (`padstacks/EP.json`), and Horizontal's import of that package keeps the
/// name. The board loader looked only for `<uuid>.json`, so a pad on a
/// padstack named any other way had no copper, mask or holes, and a plane
/// poured straight through where it should have been.
///
/// These tests write a pool with one package whose exposed pad uses the
/// package's own padstack, place it on a board and load the board through
/// the real `HorizontalBoard.load`.
final class HorizontalPackageOwnPadstackFileNameTests: XCTestCase {
    private typealias Gerber = HorizontalGerberExportFixture

    private let packageID = "bbbbbbbb-0000-4000-8000-000000000001"
    private let partID = "bbbbbbbb-0000-4000-8000-000000000002"
    private let componentID = "bbbbbbbb-0000-4000-8000-000000000003"
    private let boardPackageID = "bbbbbbbb-0000-4000-8000-000000000004"
    private let exposedPadID = "bbbbbbbb-0000-4000-8000-000000000005"
    private let signalPadID = "bbbbbbbb-0000-4000-8000-000000000006"
    /// The package's own padstack, as RMQ's exposed pad has one.
    private let ownPadstackID = "3ae2a5f3-1fdf-43ff-9512-76c593f494e6"
    /// A pool padstack, cached in the project pool as Horizon caches it.
    private let poolPadstackID = "8e762581-e1b1-4fb4-81d3-7f8a1cabb97f"
    /// Another padstack the package keeps but none of its pads uses.
    private let unusedPadstackID = "1e6e176a-46c5-49df-8ec2-0f99d735885a"

    private let mm = 1_000_000.0
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
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func rectangle(layer: Int, side: Int, parameterClass: String = "") -> [String: Any] {
        [
            "form": "rectangle",
            "layer": layer,
            "parameter_class": parameterClass,
            "params": [side, side],
            "placement": ["angle": 0, "mirror": false, "shift": [0, 0]],
        ]
    }

    /// RMQ's exposed pad in small: a 1.9 mm copper square on top copper, a
    /// mask opening and paste, and one plated hole at its middle.
    private func ownPadstack(uuid: String, name: String) -> [String: Any] {
        [
            "type": "padstack",
            "uuid": uuid,
            "name": name,
            "padstack_type": "top",
            "well_known_name": "",
            "parameter_program": "",
            "parameter_set": [String: Any](),
            "parameters_required": [String](),
            "polygons": [String: Any](),
            "shapes": [
                "cccccccc-0000-4000-8000-000000000001": rectangle(layer: HorizontalBoardLayers.topCopper, side: 1_900_000),
                "cccccccc-0000-4000-8000-000000000002": rectangle(layer: 10, side: 2_000_000, parameterClass: "mask"),
                "cccccccc-0000-4000-8000-000000000003": rectangle(layer: 30, side: 1_710_000),
            ],
            "holes": [
                "cccccccc-0000-4000-8000-000000000004": [
                    "diameter": 200_000,
                    "length": 500_000,
                    "parameter_class": "",
                    "placement": ["angle": 0, "mirror": false, "shift": [0, 0]],
                    "plated": true,
                    "shape": "round",
                ] as [String: Any],
            ],
        ]
    }

    private func poolPadstack() -> [String: Any] {
        [
            "type": "padstack",
            "uuid": poolPadstackID,
            "name": "Small pad",
            "padstack_type": "top",
            "well_known_name": "",
            "parameter_program": "",
            "parameter_set": [String: Any](),
            "parameters_required": [String](),
            "polygons": [String: Any](),
            "holes": [String: Any](),
            "shapes": [
                "cccccccc-0000-4000-8000-000000000011": rectangle(layer: HorizontalBoardLayers.topCopper, side: 300_000),
            ],
        ]
    }

    /// Writes the pool and a board placing the package at `shift`, with the
    /// package's own padstack in `ownPadstackFile` (nil for none) and every
    /// file of `extraPadstackFiles` beside it, then loads the board.
    private func loadBoard(
        shift: HorizontalPoint = HorizontalPoint(x: 10_000_000, y: 5_000_000),
        ownPadstackFile: String?,
        extraPadstackFiles: [String: [String: Any]] = [:],
        exposedPadstackID: String? = nil
    ) throws -> HorizontalBoard {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPackageOwnPadstackFileNameTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(base)
        let pool = base.appendingPathComponent("pool", isDirectory: true)
        let packageDirectory = pool.appendingPathComponent("packages/cache/\(packageID)", isDirectory: true)

        let package: [String: Any] = [
            "uuid": packageID,
            "name": "RMQ",
            "type": "package",
            "manufacturer": "",
            "tags": [String](),
            "parameter_set": [String: Any](),
            "parameter_program": "",
            "pads": [
                exposedPadID: [
                    "name": "25",
                    "padstack": exposedPadstackID ?? ownPadstackID,
                    "parameter_set": [String: Any](),
                    "placement": ["angle": 0, "mirror": false, "shift": [0, 0]],
                ] as [String: Any],
                signalPadID: [
                    "name": "1",
                    "padstack": poolPadstackID,
                    "parameter_set": [String: Any](),
                    "placement": ["angle": 0, "mirror": false, "shift": [-1_500_000, 0]],
                ] as [String: Any],
            ],
            "junctions": [String: Any](),
            "lines": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any](),
            "polygons": [String: Any](),
        ]
        try writeJSON(package, to: packageDirectory.appendingPathComponent("package.json"))
        if let ownPadstackFile {
            try writeJSON(ownPadstack(uuid: ownPadstackID, name: "EP RMQ"),
                          to: packageDirectory.appendingPathComponent("padstacks/\(ownPadstackFile)"))
        }
        for (file, json) in extraPadstackFiles {
            try writeJSON(json, to: packageDirectory.appendingPathComponent("padstacks/\(file)"))
        }
        try writeJSON(poolPadstack(), to: pool.appendingPathComponent("padstacks/cache/\(poolPadstackID).json"))
        try writeJSON(
            ["uuid": partID, "type": "part", "package": packageID, "MPN": ["", "RMQ-1"], "value": ["", ""]],
            to: pool.appendingPathComponent("parts/cache/\(partID).json")
        )
        try writeJSON(
            [
                "type": "block",
                "components": [
                    componentID: ["part": partID, "refdes": "U1", "connections": [String: Any]()] as [String: Any],
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
                        "placement": ["shift": [shift.x, shift.y], "angle": 0, "mirror": false],
                        "flip": false,
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

    private func exposedPadPolygons(_ board: HorizontalBoard, layer: Int) -> [HorizontalPolygon] {
        let prefix = "\(boardPackageID)/pad/\(exposedPadID)/".lowercased()
        return board.packagePads.filter { $0.id.lowercased().hasPrefix(prefix) && $0.layer == layer }
    }

    /// The exposed pad is drawn as its padstack has it: the 1.9 mm square of
    /// copper centred on the placement, the mask opening, the paste, and the
    /// padstack's plated hole.
    private func assertExposedPadDrawn(_ board: HorizontalBoard, shift: HorizontalPoint, _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let copper = exposedPadPolygons(board, layer: HorizontalBoardLayers.topCopper)
        XCTAssertEqual(copper.count, 1, "\(what): the exposed pad has its copper", file: file, line: line)
        let bounds = try XCTUnwrap(copper.first.map { HorizontalRect(points: $0.vertices) }, file: file, line: line)
        XCTAssertEqual(bounds.maxX - bounds.minX, 1_900_000, accuracy: 1, what, file: file, line: line)
        XCTAssertEqual(bounds.maxY - bounds.minY, 1_900_000, accuracy: 1, what, file: file, line: line)
        XCTAssertEqual(bounds.center.x, shift.x, accuracy: 1, what, file: file, line: line)
        XCTAssertEqual(bounds.center.y, shift.y, accuracy: 1, what, file: file, line: line)
        XCTAssertEqual(exposedPadPolygons(board, layer: 10).count, 1, "\(what): its mask opening", file: file, line: line)
        XCTAssertEqual(exposedPadPolygons(board, layer: 30).count, 1, "\(what): its paste", file: file, line: line)

        let holePrefix = "\(boardPackageID)/pad/\(exposedPadID)/hole".lowercased()
        let holes = board.packageHoles.filter { $0.id.lowercased().hasPrefix(holePrefix) }
        XCTAssertEqual(holes.map(\.diameter), [200_000], "\(what): the padstack's plated hole", file: file, line: line)
        XCTAssertEqual(holes.first?.plated, true, what, file: file, line: line)

        // The pool padstack's pad beside it still resolves through the pool.
        let signalPrefix = "\(boardPackageID)/pad/\(signalPadID)/".lowercased()
        let signal = board.packagePads.filter {
            $0.id.lowercased().hasPrefix(signalPrefix) && $0.layer == HorizontalBoardLayers.topCopper
        }
        XCTAssertEqual(signal.count, 1, "\(what): the pool padstack's pad", file: file, line: line)
        let signalBounds = try XCTUnwrap(signal.first.map { HorizontalRect(points: $0.vertices) }, file: file, line: line)
        XCTAssertEqual(signalBounds.maxX - signalBounds.minX, 300_000, accuracy: 1, what, file: file, line: line)
    }

    // MARK: - Tests

    /// A fresh import names the package's own padstack for its source file.
    func testAPadOnItsPackagesOwnPadstackNamedForItsSourceHasItsCopper() throws {
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        let board = try loadBoard(shift: shift, ownPadstackFile: "EP.json")
        try assertExposedPadDrawn(board, shift: shift, "padstacks/EP.json")
    }

    /// Horizon's project pool caches it under its uuid.
    func testAPadOnItsPackagesOwnPadstackNamedForItsUUIDHasItsCopper() throws {
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        let board = try loadBoard(shift: shift, ownPadstackFile: "\(ownPadstackID).json")
        try assertExposedPadDrawn(board, shift: shift, "padstacks/<uuid>.json")

        let upper = try loadBoard(shift: shift, ownPadstackFile: "\(ownPadstackID.uppercased()).json")
        try assertExposedPadDrawn(upper, shift: shift, "padstacks/<UUID>.json")
    }

    /// A file named for its source is found by the uuid inside it, so
    /// another padstack the package keeps (DSG's `padstack.json`) doesn't
    /// stand in for the one a pad names, nor does a file of another kind
    /// carrying its uuid, and a pad naming a padstack nobody has stays
    /// without copper rather than taking the first file found.
    func testAPackagesOtherPadstacksDoNotStandInForTheOneAPadNames() throws {
        let unused = ownPadstack(uuid: unusedPadstackID, name: "DSG0008A")
        let board = try loadBoard(
            ownPadstackFile: "EP.json",
            extraPadstackFiles: ["padstack.json": unused, "A unit.json": ["type": "unit", "uuid": ownPadstackID]]
        )
        try assertExposedPadDrawn(board, shift: HorizontalPoint(x: 10_000_000, y: 5_000_000), "beside other files")

        let missing = try loadBoard(
            ownPadstackFile: nil,
            extraPadstackFiles: ["padstack.json": unused],
            exposedPadstackID: ownPadstackID
        )
        XCTAssertEqual(exposedPadPolygons(missing, layer: HorizontalBoardLayers.topCopper), [],
                       "a padstack the package doesn't have isn't one it has under another uuid")
    }

    /// An older padstack names its own kind under `type` ("top") rather than
    /// "padstack"; Horizon reads it all the same.
    func testAnOlderPackagePadstackGivingItsKindAsItsTypeIsFound() throws {
        var older = ownPadstack(uuid: ownPadstackID, name: "EP RMQ")
        older["type"] = "top"
        older.removeValue(forKey: "padstack_type")
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        let board = try loadBoard(shift: shift, ownPadstackFile: nil, extraPadstackFiles: ["EP.json": older])
        XCTAssertEqual(exposedPadPolygons(board, layer: HorizontalBoardLayers.topCopper).count, 1)
    }

    /// The package editor finds the padstack the board does, under either
    /// name, and offers it once when both files carry it.
    func testThePackageEditorFindsThePackagesOwnPadstackUnderEitherName() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPackageOwnPadstackFileNameTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(base)
        let packageDirectory = base.appendingPathComponent("pool/packages/RMQ", isDirectory: true)
        try writeJSON(ownPadstack(uuid: ownPadstackID, name: "EP RMQ"), to: packageDirectory.appendingPathComponent("padstacks/EP.json"))
        let context = HorizontalPoolEditorContext(poolURL: base.appendingPathComponent("pool"), packageDirectoryURL: packageDirectory)
        XCTAssertEqual(context.padstackJSON(id: ownPadstackID.uppercased())?.string("name"), "EP RMQ")
        XCTAssertEqual(context.padstackChoices().filter(\.isPackageLocal).map(\.id), [ownPadstackID])

        try writeJSON(ownPadstack(uuid: ownPadstackID, name: "EP RMQ, as Horizon caches it"),
                      to: packageDirectory.appendingPathComponent("padstacks/\(ownPadstackID).json"))
        XCTAssertEqual(context.padstackJSON(id: ownPadstackID)?.string("name"), "EP RMQ, as Horizon caches it")
        XCTAssertEqual(context.padstackChoices().filter(\.isPackageLocal).map(\.name), ["EP RMQ, as Horizon caches it"])
    }

    /// The pad reaches what draws from the board's pads: the top copper
    /// Gerber has its square, and a plane poured over the package is cut
    /// round it instead of running through it.
    func testThePadReachesTheGerbersAndAPlanePouredOverIt() throws {
        let shift = HorizontalPoint(x: 10_000_000, y: 5_000_000)
        let board = try loadBoard(shift: shift, ownPadstackFile: "EP.json")

        let gerbers = try Gerber.exportGerbers(board: board)
        let topCopper = try XCTUnwrap(gerbers[HorizontalBoardLayers.topCopper])
        for corner in [HorizontalPoint(x: -950_000, y: -950_000), HorizontalPoint(x: 950_000, y: 950_000)] {
            XCTAssertTrue(topCopper.contains(Gerber.coordinate(corner + shift)),
                          "the exposed pad's corner \(corner) reaches top copper")
        }

        func square(_ id: String, x: Double = 0, y: Double = 0, half: Double, layer: Int) -> HorizontalPolygon {
            HorizontalPolygon(id: id, vertices: [
                HorizontalPoint(x: shift.x + (x - half) * mm, y: shift.y + (y - half) * mm),
                HorizontalPoint(x: shift.x + (x + half) * mm, y: shift.y + (y - half) * mm),
                HorizontalPoint(x: shift.x + (x + half) * mm, y: shift.y + (y + half) * mm),
                HorizontalPoint(x: shift.x + (x - half) * mm, y: shift.y + (y + half) * mm),
            ], layer: layer, netID: layer == HorizontalBoardLayers.outline ? nil : "gnd")
        }
        var poured = board
        poured.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        poured.polygons.append(square("outline", half: 10, layer: HorizontalBoardLayers.outline))
        // A pad of GND in the plane's corner, so its fill isn't an orphan.
        poured.packagePads.append(square("anchor/pad/9/shape/a", x: 6, y: 6, half: 0.5, layer: HorizontalBoardLayers.topCopper))
        var plane = HorizontalPlane(id: "plane", netID: "gnd", polygonID: "poly", layer: HorizontalBoardLayers.topCopper,
                                    priority: 0, fillStyle: "solid", minWidth: 200_000, keepOrphans: true, fragments: [])
        plane.fallbackPolygon = square("poly", half: 8, layer: HorizontalBoardLayers.topCopper)
        plane.fromRules = false
        poured.planes = [plane]
        poured.planes = HorizontalBoardPlaneUpdater.updateAllPlanes(in: poured).planes

        let fragments = try XCTUnwrap(poured.planes.first?.fragments)
        XCTAssertFalse(fragments.isEmpty, "the plane pours")
        // The fill doesn't reach into the pad: it is cut round the pad, which
        // belongs to no net and so keeps the plane's clearance. The point is
        // inside the pad's square, clear of the padstack's hole at its middle.
        let middle = shift + HorizontalPoint(x: 0.8 * mm, y: 0)
        let covering = fragments.filter { fragment in
            guard let outer = fragment.paths.first, HorizontalBoardOutlines.contains(middle, in: outer) else {
                return false
            }
            return !fragment.paths.dropFirst().contains { HorizontalBoardOutlines.contains(middle, in: $0) }
        }
        XCTAssertEqual(covering.count, 0, "the plane doesn't pour through the exposed pad")
    }
}
