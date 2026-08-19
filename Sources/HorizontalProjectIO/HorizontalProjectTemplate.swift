import Foundation

public extension HorizontalProjectArchive {
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
    /// There is no `pool/`: the app ships no parts pool, so a new project starts
    /// with schematic and board only and the parts pane stays hidden.
    static func newProject(named name: String = "Untitled") -> HorizontalProjectArchive {
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
            "planes_filename": "planes.json"
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
            // in nanometers.
            "stackup": [
                "0": ["thickness": 35_000, "substrate_thickness": 1_600_000],
                "-100": ["thickness": 35_000, "substrate_thickness": 1_600_000]
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
                "planes.json": .regularFile(jsonData(planes))
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
