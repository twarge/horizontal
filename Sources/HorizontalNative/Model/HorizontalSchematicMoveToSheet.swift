import Foundation

/// A sheet Move to Other Sheet can take a selection to, as a menu lists it:
/// its page number and name, as Horizon's sheet chooser shows them.
struct HorizontalCanvasSheetTarget: Identifiable, Hashable {
    var id: String
    var title: String
}

/// What the host hands the canvas after Move to Other Sheet: the sheet the
/// items went to and their refs there, which the canvas selects, then starts
/// moving, as Horizon begins its Move tool on what it brought across.
struct HorizontalSchematicMoveRequest: Identifiable, Equatable {
    var id = UUID()
    var sheetID: String
    var refs: [HorizontalSelectableRef]
}

/// The canvas's side of `move_to_other_sheet`: which selected refs are sheet
/// objects the op can carry, by the ids the sheet's JSON stores them under,
/// and the refs the reply's `moved` names on the other sheet.
enum HorizontalSchematicMoveToSheet {
    /// The op's collections, as the canvas selects their objects.
    static let collectionTypes: [String: HorizontalObjectType] = [
        "symbols": .schematicSymbol, "block_symbols": .schematicBlockSymbol, "junctions": .junction,
        "net_lines": .lineNet, "net_labels": .netLabel, "power_symbols": .powerSymbol, "bus_labels": .busLabel,
        "bus_rippers": .busRipper, "net_ties": .schematicNetTie, "texts": .text, "lines": .drawingLine, "arcs": .drawingArc
    ]

    /// A sheet's graphic lines and arcs are selected as `sheet/line/<uuid>`
    /// and `sheet/arc/<uuid>`; everything else by its uuid.
    private static let prefixes: [HorizontalObjectType: String] = [.drawingLine: "sheet/line/", .drawingArc: "sheet/arc/"]

    /// The ids `move_to_other_sheet` takes for these refs, leaving out what
    /// isn't a sheet object of its own: a pin, a block symbol's port or text.
    static func items(for refs: [HorizontalSelectableRef]) -> [String] {
        let movable = Set(collectionTypes.values)
        var seen = Set<String>()
        return refs.compactMap { ref -> String? in
            guard movable.contains(ref.type) else { return nil }
            var id = ref.id
            if let prefix = prefixes[ref.type] {
                guard id.hasPrefix(prefix) else { return nil }
                id.removeFirst(prefix.count)
            }
            guard !id.contains("/"), seen.insert(id.lowercased()).inserted else { return nil }
            return id
        }
    }

    /// The refs a `move_to_other_sheet` change's `moved` names.
    static func refs(moved: JSONDictionary) -> [HorizontalSelectableRef] {
        moved.keys.sorted().flatMap { key -> [HorizontalSelectableRef] in
            guard let type = collectionTypes[key] else { return [] }
            return (moved[key] as? [String] ?? []).map { HorizontalSelectableRef(id: (prefixes[type] ?? "") + $0, type: type) }
        }
    }

    /// The sheets other than `current`, in page order, titled as Horizon's
    /// chooser titles them.
    static func targets(in sheets: [HorizontalSchematicSheet], excluding current: String) -> [HorizontalCanvasSheetTarget] {
        sheets.filter { $0.id.caseInsensitiveCompare(current) != .orderedSame }
            .sorted { $0.index < $1.index }
            .map { HorizontalCanvasSheetTarget(id: $0.id, title: "\($0.index) \($0.name)") }
    }
}
