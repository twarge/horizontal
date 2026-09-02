import XCTest
@testable import HorizontalNative

/// A four-layer board with no pool behind it, driven through the real Gerber
/// writer. Shared by the Gerber export tests so each can state what a layer
/// file must (or must not) contain without rebuilding the project scaffolding.
enum HorizontalGerberExportFixture {
    static let top = HorizontalBoardLayers.topCopper
    static let inner1 = HorizontalBoardLayers.in1Copper
    static let inner2 = HorizontalBoardLayers.in2Copper
    static let bottom = HorizontalBoardLayers.bottomCopper

    static func board(
        tracks: [HorizontalSegment] = [],
        keepouts: [HorizontalKeepout] = [],
        vias: [HorizontalMarker] = []
    ) -> HorizontalBoard {
        HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/gerber-fixture/board.json"), uuid: "board", name: "gerber-fixture",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: top, copperThickness: 35_000, substrateThickness: 300_000),
                HorizontalBoardStackupLayer(layer: inner1, copperThickness: 35_000, substrateThickness: 300_000),
                HorizontalBoardStackupLayer(layer: inner2, copperThickness: 35_000, substrateThickness: 300_000),
                HorizontalBoardStackupLayer(layer: bottom, copperThickness: 35_000, substrateThickness: 300_000),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: keepouts, dimensions: [], decals: [], holes: [],
            vias: vias,
            viaHoles: vias.map { via in
                HorizontalHole(
                    id: "\(via.id)/hole", position: via.position, diameter: via.holeSize ?? 0,
                    length: via.holeSize ?? 0, shape: .round, plated: true
                )
            },
            packages: [], packagePads: [], packageHoles: [],
            packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
    }

    static func project(board: HorizontalBoard) -> HorizontalProject {
        let baseURL = URL(fileURLWithPath: "/tmp/gerber-fixture", isDirectory: true)
        return HorizontalProject(
            url: baseURL.appendingPathComponent("gerber-fixture.hprj"),
            projectFileURL: baseURL.appendingPathComponent("gerber-fixture.hprj"),
            baseURL: baseURL,
            uuid: "project",
            title: "Gerber Fixture",
            name: "gerber-fixture",
            projectMeta: [:],
            blocksFilename: "blocks.json",
            boardFilename: "board.json",
            planesFilename: nil,
            schematicFilename: nil,
            blockFilename: nil,
            poolDirectory: nil,
            blocks: [],
            schematics: [],
            diagnostics: [],
            poolParts: [],
            schematic: nil,
            board: board
        )
    }

    /// Writes the Gerber set for `board` into a fresh temporary directory and
    /// returns each layer file's contents keyed by the layer id it was written
    /// for (recovered from the `G04 Horizontal <layer name>*` header). Layers
    /// with nothing on them are not written and so have no entry.
    static func exportGerbers(board: HorizontalBoard, file: StaticString = #filePath, line: UInt = #line) throws -> [Int: String] {
        let project = project(board: board)
        var settings = HorizontalExportSettings(project: project).gerber
        settings.prefix = "fixture"
        settings.zipOutput = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HorizontalGerberExportFixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = try HorizontalExportBackend.exportGerber(project: project, settings: settings, to: directory)
        let namesToLayers = Dictionary(
            settings.layers.map { (HorizontalBoardLayers.name(for: $0.layer), $0.layer) },
            uniquingKeysWith: { first, _ in first }
        )
        var contents = [Int: String]()
        for url in written where url.pathExtension.lowercased() == "gbr" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let header = text.split(separator: "\n").first,
                  header.hasPrefix("G04 Horizontal "), header.hasSuffix("*") else {
                XCTFail("Unexpected Gerber header in \(url.lastPathComponent)", file: file, line: line)
                continue
            }
            let name = String(header.dropFirst("G04 Horizontal ".count).dropLast())
            guard let layer = namesToLayers[name] else {
                XCTFail("Gerber file \(url.lastPathComponent) names unknown layer \(name)", file: file, line: line)
                continue
            }
            contents[layer] = text
        }
        return contents
    }

    /// The `X…Y…` coordinate token the writer emits for a point.
    static func coordinate(_ point: HorizontalPoint) -> String {
        "X\(Int64(point.x.rounded()))Y\(Int64(point.y.rounded()))"
    }
}
