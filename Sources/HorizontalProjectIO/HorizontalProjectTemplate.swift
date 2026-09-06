import Foundation

/// What a new document's project pool includes: Horizon's `PoolInfo` for
/// the pool at `pool/` — the pools the project draws parts from, and the
/// via and frame defaults, normally those of the first included pool.
public struct HorizontalProjectPoolTemplate: Equatable, Sendable {
    public var includedPoolUUIDs: [String]
    public var defaultViaUUID: String?
    public var defaultFrameUUID: String?

    public init(includedPoolUUIDs: [String] = [], defaultViaUUID: String? = nil, defaultFrameUUID: String? = nil) {
        self.includedPoolUUIDs = includedPoolUUIDs
        self.defaultViaUUID = defaultViaUUID
        self.defaultFrameUUID = defaultFrameUUID
    }
}

public extension HorizontalProjectArchive {
    /// Horizon's uuid for every project pool (`PoolInfo::project_pool_uuid`).
    static let projectPoolUUID = "466088f9-3f15-420d-af8a-fff902537aed"
    /// Horizon parses every uuid it reads and refuses an empty one, so a
    /// default that is not set is the null uuid.
    static let nullUUID = "00000000-0000-0000-0000-000000000000"
    /// Where a project keeps its pool, and Horizon's default when the
    /// project file names none.
    static let projectPoolDirectoryName = "pool"

    /// A project pool's `pool.json`, the keys `PoolInfo::save` writes.
    static func projectPoolJSON(_ pool: HorizontalProjectPoolTemplate = HorizontalProjectPoolTemplate(), name: String = "Project pool") -> [String: Any] {
        [
            "type": "pool",
            "uuid": projectPoolUUID,
            "name": name,
            "default_via": pool.defaultViaUUID ?? nullUUID,
            "default_frame": pool.defaultFrameUUID ?? nullUUID,
            "pools_included": pool.includedPoolUUIDs
        ]
    }

    static func projectPoolData(_ pool: HorizontalProjectPoolTemplate = HorizontalProjectPoolTemplate(), name: String = "Project pool") -> Data {
        jsonData(projectPoolJSON(pool, name: name))
    }
    /// The archive behind a brand-new document — File > New on macOS, Create
    /// Document on iPadOS.
    ///
    /// The tree is the flat single-block layout the loaders treat as canonical:
    /// a `.hprj` beside `blocks.json`, `top_block.json`, `top_schematic.json`,
    /// `top_symbol.json`, `board.json` and `planes.json`. Two constraints shape
    /// the JSON beyond "what the parsers accept":
    ///
    /// - Every collection an editor can add to (`nets`, `components`, sheet
    ///   `junctions`, board `tracks`, …) is present as an empty map. Several
    ///   save-side patchers treat a missing map as "nothing to write back" and
    ///   return without saving, and the block-level patchers throw outright, so
    ///   omitting a key here would silently discard the first edit of that kind.
    /// - Files are serialized exactly the way the save path re-serializes them
    ///   (pretty-printed, sorted keys, unescaped slashes, trailing newline), so
    ///   the first save after an edit rewrites only what actually changed.
    ///
    /// `pool/pool.json` is the project pool, empty until a part placed from
    /// the Pools pane is cached into it (Horizon's project pool layout); the
    /// project file names it as `pool_directory` the way Horizon does.
    static func newProject(named name: String = "Untitled", pool: HorizontalProjectPoolTemplate = HorizontalProjectPoolTemplate()) -> HorizontalProjectArchive {
        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")

        let projectID = newID()
        let blockID = newID()
        let symbolID = newID()
        let schematicID = newID()
        let sheetID = newID()
        let boardID = newID()
        let netClassID = newID()

        let project: [String: Any] = [
            "type": "project",
            "uuid": projectID,
            // Left empty so the window title falls through to the document's
            // filename and follows a rename instead of reading "Untitled" forever.
            "title": "",
            "name": "",
            "blocks_filename": "blocks.json",
            "board_filename": "board.json",
            "planes_filename": "planes.json",
            "pool_directory": projectPoolDirectoryName
        ]

        let blocks: [String: Any] = [
            "top_block": blockID,
            "blocks": [
                blockID: [
                    "block_filename": "top_block.json",
                    "schematic_filename": "top_schematic.json",
                    "symbol_filename": "top_symbol.json"
                ]
            ]
        ]

        let block: [String: Any] = [
            "type": "block",
            "uuid": blockID,
            "name": "Top",
            "nets": [String: Any](),
            "buses": [String: Any](),
            "components": [String: Any](),
            "net_classes": [
                netClassID: ["name": "Default"]
            ],
            "net_class_default": netClassID,
            "net_ties": [String: Any](),
            "block_instances": [String: Any](),
            "group_names": [String: Any](),
            "tag_names": [String: Any](),
            "project_meta": [String: Any]()
        ]

        let sheet: [String: Any] = [
            "name": "Sheet 1",
            "index": 1,
            "junctions": [String: Any](),
            "net_lines": [String: Any](),
            "net_labels": [String: Any](),
            "net_ties": [String: Any](),
            "bus_labels": [String: Any](),
            "bus_rippers": [String: Any](),
            "power_symbols": [String: Any](),
            "block_symbols": [String: Any](),
            "symbols": [String: Any](),
            "lines": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any](),
            "pictures": [String: Any](),
            "title_block_values": [String: Any]()
        ]

        let schematic: [String: Any] = [
            "type": "schematic",
            "uuid": schematicID,
            "block": blockID,
            "name": "Top",
            "sheets": [sheetID: sheet],
            "title_block_values": [String: Any]()
        ]

        let symbol: [String: Any] = [
            "type": "block_symbol",
            "uuid": symbolID,
            "block": blockID,
            "junctions": [String: Any](),
            "lines": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any]()
        ]

        let board: [String: Any] = [
            "type": "board",
            "uuid": boardID,
            "block": blockID,
            "n_inner_layers": 0,
            // Horizon's stock two-layer stackup: 35 µm copper on a 1.6 mm core,
            // in nanometers. A layer's substrate is the dielectric below it,
            // so the bottom copper has none (Horizon's `Board::Board` sets it
            // to zero); giving it one adds a second core's worth of thickness.
            "stackup": [
                "0": ["thickness": 35_000, "substrate_thickness": 1_600_000],
                "-100": ["thickness": 35_000, "substrate_thickness": 0]
            ],
            "rules": [String: Any](),
            "junctions": [String: Any](),
            "packages": [String: Any](),
            "tracks": [String: Any](),
            "vias": [String: Any](),
            "polygons": [String: Any](),
            "planes": [String: Any](),
            "keepouts": [String: Any](),
            "holes": [String: Any](),
            "lines": [String: Any](),
            "arcs": [String: Any](),
            "texts": [String: Any](),
            "dimensions": [String: Any](),
            "net_ties": [String: Any](),
            "connection_lines": [String: Any](),
            "decals": [String: Any](),
            "pictures": [String: Any](),
            "included_boards": [String: Any](),
            "board_panels": [String: Any]()
        ]

        let planes: [String: Any] = [
            "planes": [String: Any]()
        ]

        return HorizontalProjectArchive(
            root: .directory([
                "\(safeName).hprj": .regularFile(jsonData(project)),
                "blocks.json": .regularFile(jsonData(blocks)),
                "top_block.json": .regularFile(jsonData(block)),
                "top_schematic.json": .regularFile(jsonData(schematic)),
                "top_symbol.json": .regularFile(jsonData(symbol)),
                "board.json": .regularFile(jsonData(board)),
                "planes.json": .regularFile(jsonData(planes)),
                projectPoolDirectoryName: .directory([
                    "pool.json": .regularFile(projectPoolData(pool))
                ])
            ]),
            suggestedFilename: "\(safeName).horizontal"
        )
    }
}

private func newID() -> String {
    UUID().uuidString.lowercased()
}

/// The exact serialization the save path uses, so an unchanged file round-trips
/// byte-for-byte. The template dictionaries are plist-safe literals, so
/// serialization cannot actually fail; the fallback keeps the file valid JSON
/// rather than crashing document creation.
private func jsonData(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}
