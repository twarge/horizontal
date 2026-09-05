import XCTest
@testable import HorizontalNative

/// The Pools pane's search reveals and the package editor's 3D scene.
final class HorizontalPoolsPaneTests: XCTestCase {
    func testTheLibraryPaneIsCalledPoolsAndComesFirst() {
        XCTAssertEqual(HorizontalPane.library.title, "Pools")
        XCTAssertEqual(HorizontalPane.allCases.first, .library)
    }

    func testASearchRevealCarriesItsCategoryAndTerm() {
        let request = HorizontalPoolRevealRequest(search: HorizontalPoolSearch(category: .package, term: "SOT23"))
        XCTAssertEqual(request.category, .package)
        XCTAssertEqual(request.search, "SOT23")
        XCTAssertEqual(request.uuid, "")

        let item = HorizontalPoolRevealRequest(category: .part, uuid: "ABC")
        XCTAssertNil(item.search)
    }

    func testDetailRowsCarryAPoolSearchOnlyWhenAsked() {
        let plain = HorizontalSelectionHUDDetail(label: "Value", value: "10k")
        XCTAssertNil(plain.poolSearch)
        let linked = HorizontalSelectionHUDDetail(
            label: "MPN",
            value: "RC0603FR-0710KL",
            poolSearch: HorizontalPoolSearch(category: .part, term: "RC0603FR-0710KL")
        )
        XCTAssertEqual(linked.poolSearch?.term, "RC0603FR-0710KL")
        XCTAssertEqual(linked.id, "MPN:RC0603FR-0710KL")
    }

    func testPackageSceneBoardGetsASlabAroundTheFootprintAndItsModel() throws {
        let poolURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalPoolsPaneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: poolURL) }
        let modelURL = poolURL.appendingPathComponent("3d_models/r0603.step")
        try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("solid".utf8).write(to: modelURL)

        var package = HorizontalPoolPackage(uuid: "pkg-1", name: "R0603")
        package.models["m1"] = HorizontalPackageModel3D(id: "m1", filename: "3d_models/r0603.step")
        package.models["m2"] = HorizontalPackageModel3D(id: "m2", filename: "3d_models/missing.step")
        package.defaultModelID = "m1"
        let context = HorizontalPoolEditorContext(
            poolURL: poolURL,
            packageDirectoryURL: poolURL.appendingPathComponent("packages/r0603"),
            libraryIndex: HorizontalPoolLibraryIndex(items: [])
        )
        var board = package.makeBoard(context: context)
        board.polygons.append(HorizontalPolygon(
            id: "silk",
            vertices: [
                HorizontalPoint(x: -1_000_000, y: -500_000),
                HorizontalPoint(x: 1_000_000, y: -500_000),
                HorizontalPoint(x: 1_000_000, y: 500_000),
                HorizontalPoint(x: -1_000_000, y: 500_000),
            ],
            layer: HorizontalBoardLayers.topSilkscreen
        ))

        let scene = package.sceneBoard(from: board, poolURL: poolURL)

        // A rectangle of substrate 2 mm beyond the footprint on every side.
        let outline = try XCTUnwrap(scene.polygons.first { $0.layer == HorizontalBoardLayers.outline })
        let bounds = HorizontalRect(points: outline.vertices)
        XCTAssertEqual(bounds.minX, -3_000_000, accuracy: 1)
        XCTAssertEqual(bounds.maxX, 3_000_000, accuracy: 1)
        XCTAssertEqual(bounds.minY, -2_500_000, accuracy: 1)
        XCTAssertEqual(bounds.maxY, 2_500_000, accuracy: 1)
        XCTAssertEqual(scene.physicalBounds, bounds)

        // The package sits at the origin with its default model.
        let placement = try XCTUnwrap(scene.packages.first)
        XCTAssertEqual(placement.id, "pkg-1")
        XCTAssertEqual(placement.position, HorizontalPoint(x: 0, y: 0))
        XCTAssertEqual(placement.modelID, "m1")
        XCTAssertEqual(placement.model3D?.fileURL.standardizedFileURL, modelURL.standardizedFileURL)

        // The editing board is untouched: no outline, no placement.
        XCTAssertFalse(board.polygons.contains { $0.layer == HorizontalBoardLayers.outline })
        XCTAssertTrue(board.packages.isEmpty)

        // A default model whose file is missing leaves a placeholder.
        package.defaultModelID = "m2"
        XCTAssertNil(package.sceneBoard(from: board, poolURL: poolURL).packages.first?.model3D)
    }
}
