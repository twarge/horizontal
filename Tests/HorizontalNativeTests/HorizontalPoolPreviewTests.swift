import XCTest
@testable import HorizontalNative

/// The library browser's previews: standalone symbol, frame, package,
/// padstack and decal geometry built from pool JSON, and the tables for
/// units, entities and parts.
final class HorizontalPoolPreviewTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolPreviewTests-\(UUID().uuidString)", isDirectory: true)
        HorizontalPoolLibrary.invalidateCache()
    }

    override func tearDownWithError() throws {
        HorizontalPoolLibrary.invalidateCache()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private var poolURL: URL {
        temporaryRoot.appendingPathComponent("pool", isDirectory: true)
    }

    private func write(_ json: JSONDictionary, to relativePath: String) throws {
        let url = temporaryRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func placement(_ x: Int = 0, _ y: Int = 0) -> JSONDictionary {
        ["shift": [x, y], "angle": 0, "mirror": false]
    }

    private func vertex(_ x: Int, _ y: Int) -> JSONDictionary {
        ["type": "line", "position": [x, y], "arc_center": [0, 0], "arc_reverse": false]
    }

    private func bounds(_ points: [HorizontalPoint]) -> HorizontalRect {
        HorizontalRect(points: points)
    }

    // MARK: - Fixtures

    private var throughHolePadstack: JSONDictionary {
        [
            "type": "padstack", "uuid": "ps1", "name": "TH round", "padstack_type": "through",
            "parameter_program": "get-parameter [ hole_diameter ]\ndup\nset-hole [ hole round ]\n\nget-parameter [ pad_diameter ] dup\nset-shape [ copper circle ]\n\nget-parameter [ solder_mask_expansion ] 2 * +\nset-shape [ mask circle ] ",
            "parameter_set": ["hole_diameter": 400_000, "pad_diameter": 600_000, "solder_mask_expansion": 100_000],
            "parameters_required": ["pad_diameter", "hole_diameter"],
            "polygons": JSONDictionary(),
            "shapes": [
                "s-top": ["form": "circle", "layer": 0, "parameter_class": "copper", "params": [600_000], "placement": placement()],
                "s-bottom": ["form": "circle", "layer": -100, "parameter_class": "copper", "params": [600_000], "placement": placement()],
                "s-mask": ["form": "circle", "layer": 10, "parameter_class": "mask", "params": [800_000], "placement": placement()],
            ],
            "holes": [
                "h1": ["diameter": 400_000, "length": 400_000, "shape": "round", "plated": true, "parameter_class": "hole", "placement": placement()],
            ],
        ]
    }

    private var testPackage: JSONDictionary {
        [
            "type": "package", "uuid": "pkg1", "name": "Test package",
            "parameter_set": ["courtyard_expansion": 250_000],
            "junctions": ["j1": ["position": [-1_000_000, 1_500_000]], "j2": ["position": [1_000_000, 1_500_000]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 100_000, "layer": 20]],
            "arcs": JSONDictionary(),
            "polygons": [
                "court": [
                    "layer": 60, "parameter_class": "courtyard",
                    "vertices": [vertex(-2_000_000, -2_000_000), vertex(2_000_000, -2_000_000), vertex(2_000_000, 2_000_000), vertex(-2_000_000, 2_000_000)],
                ],
            ],
            "texts": ["t1": ["text": "$REFDES", "layer": 20, "size": 1_000_000, "width": 100_000, "placement": placement(0, -1_500_000)]],
            "pads": [
                "pad1": ["name": "1", "padstack": "PS1", "parameter_set": ["pad_diameter": 1_200_000], "placement": placement(0, 0)],
            ],
        ]
    }

    // MARK: - Symbols and frames

    func testSymbolPreviewDrawsBodyPinsAndUnitPinNames() throws {
        let symbol: JSONDictionary = [
            "type": "symbol", "uuid": "sym1", "name": "Test symbol", "unit": "u1",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [5_000_000, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 0, "layer": 0]],
            "arcs": JSONDictionary(),
            "polygons": JSONDictionary(),
            "texts": ["t1": ["text": "$REFDES", "size": 1_500_000, "width": 0, "placement": placement(0, 2_000_000)]],
            "pins": [
                "p1": ["position": [-2_500_000, 0], "orientation": "left", "length": 2_500_000, "name_visible": true, "pad_visible": true, "name_orientation": "in_line"],
            ],
        ]
        let unit: JSONDictionary = [
            "type": "unit", "uuid": "u1", "name": "Test unit",
            "pins": ["p1": ["primary_name": "IN", "direction": "input", "names": [], "swap_group": 0]],
        ]

        let artwork = HorizontalSchematic.symbolPreviewArtwork(symbolJSON: symbol, unitJSON: unit, poolURL: poolURL)
        XCTAssertEqual(artwork.lines.count, 1)
        XCTAssertFalse(artwork.pins.isEmpty, "the pin's stem should be drawn")
        XCTAssertTrue(artwork.texts.contains { $0.text == "IN" }, "pin names come from the unit")
        XCTAssertTrue(artwork.texts.contains { $0.text == "$REFDES" }, "no component, so placeholders stay")
        XCTAssertFalse(artwork.points.isEmpty)
    }

    func testSymbolPreviewHonorsTheRequestedOrientation() throws {
        let symbol: JSONDictionary = [
            "type": "symbol", "uuid": "sym1", "name": "Test symbol",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [5_000_000, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 0, "layer": 0]],
        ]
        let rotated = HorizontalSchematic.symbolPreviewArtwork(
            symbolJSON: symbol,
            unitJSON: nil,
            poolURL: poolURL,
            transform: HorizontalPlacementTransform(shift: .zero, angle: 16_384, mirrored: false)
        )
        let line = try XCTUnwrap(rotated.lines.first)
        XCTAssertEqual(abs(line.to.x - line.from.x), 0, accuracy: 1, "a quarter turn makes the line vertical")
        XCTAssertEqual(abs(line.to.y - line.from.y), 5_000_000, accuracy: 1)
    }

    func testFramePreviewAddsThePageBorder() throws {
        let frame: JSONDictionary = [
            "type": "frame", "uuid": "f1", "name": "A4", "width": 297_000_000, "height": 210_000_000,
            "junctions": JSONDictionary(), "lines": JSONDictionary(), "arcs": JSONDictionary(),
            "polygons": JSONDictionary(), "texts": JSONDictionary(),
        ]
        let artwork = HorizontalSchematic.framePreviewArtwork(frameJSON: frame)
        XCTAssertEqual(artwork.lines.count, 4)
        let rect = bounds(artwork.points)
        XCTAssertEqual(rect.width, 297_000_000, accuracy: 1)
        XCTAssertEqual(rect.height, 210_000_000, accuracy: 1)
    }

    // MARK: - Packages, padstacks, decals

    func testPackagePreviewResolvesPadstacksThroughTheResolverAndAppliesPadParameters() throws {
        var resolvedIDs = [String]()
        let geometry = HorizontalBoard.packagePreviewGeometry(
            packageJSON: testPackage,
            packageID: "pkg1",
            poolURL: poolURL
        ) { padstackID in
            resolvedIDs.append(padstackID)
            return throughHolePadstack
        }

        XCTAssertEqual(resolvedIDs, ["PS1"])
        let topCopper = geometry.pads.filter { $0.layer == HorizontalBoardLayers.topCopper }
        XCTAssertFalse(topCopper.isEmpty, "the padstack's copper shape becomes a pad polygon")
        let padBounds = bounds(topCopper.flatMap { $0.renderVertices(arcPrecision: 32) })
        XCTAssertEqual(padBounds.width, 1_200_000, accuracy: 20_000, "the pad's own pad_diameter drives the parameter program")
        XCTAssertEqual(geometry.holes.count, 1)
        XCTAssertEqual(geometry.holes.first?.diameter ?? 0, 400_000, accuracy: 1)
        XCTAssertEqual(geometry.polygons.filter { $0.layer == HorizontalBoardLayers.topCourtyard }.count, 1)
        XCTAssertEqual(geometry.lines.count, 1)
        XCTAssertEqual(geometry.lines.first?.layer, HorizontalBoardLayers.topSilkscreen)
        XCTAssertEqual(geometry.texts.map(\.text), ["$REFDES"], "no component, so the placeholder stays")
    }

    func testPadstackPreviewStandsAloneAtTheOrigin() throws {
        let geometry = HorizontalBoard.padstackPreviewGeometry(padstackJSON: throughHolePadstack, poolURL: poolURL)
        XCTAssertEqual(geometry.holes.count, 1)
        XCTAssertEqual(geometry.holes.first?.position, .zero)
        let layers = Set(geometry.pads.compactMap(\.layer))
        XCTAssertTrue(layers.contains(HorizontalBoardLayers.topCopper))
        XCTAssertTrue(layers.contains(HorizontalBoardLayers.bottomCopper))
        XCTAssertTrue(layers.contains(HorizontalBoardLayers.topMask), "the padstack preview keeps its mask opening")
        let copper = geometry.pads.filter { $0.layer == HorizontalBoardLayers.topCopper }
        let copperBounds = bounds(copper.flatMap { $0.renderVertices(arcPrecision: 32) })
        XCTAssertEqual(copperBounds.width, 600_000, accuracy: 10_000, "default parameters apply")
    }

    func testDecalPreviewDrawsItsOwnGraphics() throws {
        let decal: JSONDictionary = [
            "type": "decal", "uuid": "d1", "name": "Logo",
            "junctions": ["j1": ["position": [0, 0]], "j2": ["position": [3_000_000, 0]]],
            "lines": ["l1": ["from": "j1", "to": "j2", "width": 150_000, "layer": 20]],
            "arcs": JSONDictionary(),
            "polygons": ["p1": ["layer": 20, "parameter_class": "", "vertices": [vertex(0, 1_000_000), vertex(1_000_000, 1_000_000), vertex(500_000, 2_000_000)]]],
            "texts": JSONDictionary(),
        ]
        let geometry = HorizontalBoard.packagePreviewGeometry(packageJSON: decal, packageID: "d1", poolURL: poolURL) { _ in nil }
        XCTAssertEqual(geometry.lines.count, 1)
        XCTAssertEqual(geometry.polygons.count, 1)
        XCTAssertTrue(geometry.pads.isEmpty)
    }

    // MARK: - Builder over a scanned pool

    private func scannedIndex() throws -> (items: [HorizontalPoolLibraryItem], index: HorizontalPoolLibraryIndex) {
        try write(["type": "pool", "uuid": "p", "name": "Test pool"], to: "pool/pool.json")
        try write(throughHolePadstack, to: "pool/padstacks/th.json")
        try write(testPackage, to: "pool/packages/test/package.json")
        try write(
            ["type": "unit", "uuid": "u1", "name": "Test unit", "manufacturer": "",
             "pins": ["p1": ["primary_name": "IN", "direction": "power_input", "names": ["VIN"], "swap_group": 2]]],
            to: "pool/units/test.json"
        )
        try write(
            ["type": "entity", "uuid": "e1", "name": "Test entity", "prefix": "U", "tags": ["test"],
             "gates": ["g1": ["name": "Main", "suffix": "", "swap_group": 0, "unit": "u1"]]],
            to: "pool/entities/test.json"
        )
        try write(
            ["type": "part", "uuid": "base1", "MPN": [false, "BASE-1"], "manufacturer": [false, "ACME"],
             "value": [false, ""], "description": [false, "Base part"], "datasheet": [false, ""],
             "entity": "e1", "package": "pkg1", "tags": ["base"]],
            to: "pool/parts/base.json"
        )
        try write(
            ["type": "part", "uuid": "derived1", "base": "base1", "MPN": [true, ""], "manufacturer": [true, ""],
             "value": [false, "10k"], "description": [true, ""], "datasheet": [true, ""],
             "inherit_tags": true, "tags": ["derived"]],
            to: "pool/parts/derived.json"
        )
        let items = HorizontalPoolLibrary.items(inPool: poolURL, poolName: "Test pool")
        return (items, HorizontalPoolLibraryIndex(items: items))
    }

    private func item(_ category: HorizontalPoolItemCategory, _ uuid: String, in items: [HorizontalPoolLibraryItem]) throws -> HorizontalPoolLibraryItem {
        try XCTUnwrap(items.first { $0.category == category && $0.uuid == uuid })
    }

    func testIndexResolvesItemsAcrossKinds() throws {
        let (_, index) = try scannedIndex()
        XCTAssertEqual(index.name(.unit, uuid: "U1"), "Test unit", "lookups are case-insensitive")
        XCTAssertEqual(index.json(.padstack, uuid: "ps1")?.string("name"), "TH round")
        XCTAssertNil(index.item(.symbol, uuid: "u1"))
    }

    func testItemsCarryTheirPoolRoot() throws {
        let (items, _) = try scannedIndex()
        XCTAssertEqual(Set(items.map(\.poolURL.path)), [poolURL.standardizedFileURL.path])
    }

    func testPackagePreviewFindsPadstacksInTheBrowsedPools() throws {
        let (items, index) = try scannedIndex()
        let package = try item(.package, "pkg1", in: items)
        guard case .board(let geometry, let hidden) = HorizontalPoolPreviewBuilder.preview(for: package, index: index) else {
            return XCTFail("a package previews as board geometry")
        }
        XCTAssertFalse(geometry.pads.isEmpty)
        XCTAssertEqual(geometry.holes.count, 1)
        XCTAssertTrue(hidden.contains(HorizontalBoardLayers.topMask), "footprints hide mask and paste")
    }

    func testUnitAndEntityPreviewAsTables() throws {
        let (items, index) = try scannedIndex()

        guard case .table(let unitTable) = HorizontalPoolPreviewBuilder.preview(for: try item(.unit, "u1", in: items), index: index) else {
            return XCTFail("a unit previews as a table")
        }
        XCTAssertEqual(unitTable.sections.first?.rows, [["IN", "Power input", "VIN", "2"]])

        guard case .table(let entityTable) = HorizontalPoolPreviewBuilder.preview(for: try item(.entity, "e1", in: items), index: index) else {
            return XCTFail("an entity previews as a table")
        }
        XCTAssertEqual(entityTable.sections.first?.rows, [["Main", "", "Test unit", ""]])
        XCTAssertEqual(entityTable.fields.first { $0.label == "Prefix" }?.value, "U")
    }

    func testPartPreviewInheritsFromItsBaseAndShowsItsPackage() throws {
        let (items, index) = try scannedIndex()
        guard case .part(let table, let geometry) = HorizontalPoolPreviewBuilder.preview(for: try item(.part, "derived1", in: items), index: index) else {
            return XCTFail("a part previews as attributes plus package")
        }
        func value(_ label: String) -> String? { table.fields.first { $0.label == label }?.value }
        XCTAssertEqual(value("MPN"), "BASE-1", "an inherited attribute reads through the base part")
        XCTAssertEqual(value("Manufacturer"), "ACME")
        XCTAssertEqual(value("Value"), "10k", "an own attribute wins")
        XCTAssertEqual(value("Package"), "Test package", "the package reference comes from the base")
        XCTAssertEqual(value("Entity"), "Test entity")
        XCTAssertEqual(value("Base part"), "BASE-1")
        XCTAssertEqual(value("Tags"), "derived, base")
        XCTAssertNotNil(geometry, "the part's package draws beside its attributes")
        XCTAssertFalse(geometry?.pads.isEmpty ?? true)
    }

    // MARK: - Real horizon-pool checkout

    func testStockPoolItemsPreviewWithoutBeingEmpty() throws {
        let stockPool = URL(fileURLWithPath: "/Users/kornack/Repositories/horizon-pool")
        guard FileManager.default.fileExists(atPath: stockPool.appendingPathComponent("pool.json").path) else {
            throw XCTSkip("horizon-pool checkout not available")
        }
        let items = HorizontalPoolLibrary.items(inPool: stockPool, poolName: "Horizon pool")
        let index = HorizontalPoolLibraryIndex(items: items)

        let symbol = try XCTUnwrap(items.first { $0.category == .symbol && $0.name.localizedCaseInsensitiveContains("resistor") })
        guard case .symbol(let artwork) = HorizontalPoolPreviewBuilder.preview(for: symbol, index: index) else {
            return XCTFail("symbol")
        }
        XCTAssertFalse(artwork.lines.isEmpty)
        XCTAssertFalse(artwork.pins.isEmpty)

        let package = try XCTUnwrap(items.first { $0.category == .package && $0.name.hasPrefix("0603") })
        guard case .board(let geometry, _) = HorizontalPoolPreviewBuilder.preview(for: package, index: index) else {
            return XCTFail("package")
        }
        // A pad renders as several polygons (shape pieces, label fragments);
        // count the pads they belong to — ids are "preview/pad/<pad>/…".
        let topCopperPads = Set(
            geometry.pads
                .filter { $0.layer == HorizontalBoardLayers.topCopper }
                .compactMap { $0.id.split(separator: "/").dropFirst(2).first }
        )
        XCTAssertEqual(topCopperPads.count, 2, "\(package.name)")

        let via = try XCTUnwrap(items.first { $0.category == .padstack && $0.name == "Circular via" })
        guard case .board(let viaGeometry, _) = HorizontalPoolPreviewBuilder.preview(for: via, index: index) else {
            return XCTFail("padstack")
        }
        XCTAssertFalse(viaGeometry.pads.isEmpty)
        XCTAssertEqual(viaGeometry.holes.count, 1)
    }
}
