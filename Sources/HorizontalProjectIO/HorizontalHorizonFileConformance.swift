import Foundation

/// A project file as Horizon EDA's own save would leave it, so one Horizontal
/// wrote opens in Horizon as one Horizon wrote: with no "created with an older
/// version" bar, and a save there changing nothing it need not.
///
/// Horizon stamps every board, schematic and project it saves with its own
/// file version (`FileVersion::serialize`), and its serializers write some
/// keys whatever the loader found, with the defaults the loader takes for
/// them: a symbol's `smashed`, `expand` and the rest, a net label's
/// `show_port`, a line's `width`. Horizontal's writers patch the files they
/// load, so an object one of them added without such a key, or a file an older
/// Horizon wrote, kept its gaps and its version. This fills both in, and drops
/// the empty `net_ties` maps Horizon writes only when they hold something,
/// and the tag and group names no component uses any more, which Horizon's
/// `Block::vacuum_group_tag_names` clears on every expand.
///
/// The versions are those of Horizon 2.7.2, the latest release: board 21,
/// schematic 9, project 3. Its master branch writes later ones (board 24,
/// schematic 10) for features no release has, and a released Horizon opens a
/// file stating those read-only, as "created with a newer version", so a file
/// already stating a later version keeps it and nothing raises one past the
/// release.
public enum HorizontalHorizonFileConformance {
    public static let boardVersion = 21
    public static let schematicVersion = 9
    public static let projectVersion = 3

    /// The file conformed, told apart by what it is: a board, schematic or
    /// project by its `type`, a block by its nets, components and default net
    /// class (Horizon writes a block no type). Anything else is left as it is.
    public static func conformed(_ json: [String: Any]) -> [String: Any] {
        var json = json
        switch json["type"] as? String {
        case "board":
            stampVersion(&json, boardVersion)
            conformBoard(&json)
        case "schematic_block", "schematic":
            stampVersion(&json, schematicVersion)
            // Horizon reads a schematic of either type and writes this one.
            json["type"] = "schematic_block"
            conformSchematic(&json)
        case "project":
            stampVersion(&json, projectVersion)
        case nil, "block":
            if json["net_class_default"] != nil, json["components"] is [String: Any], json["nets"] is [String: Any] {
                conformBlock(&json)
            }
        default:
            break
        }
        return json
    }

    private static func stampVersion(_ json: inout [String: Any], _ version: Int) {
        let stated = (json["version"] as? NSNumber)?.intValue ?? 0
        json["version"] = max(stated, version)
    }

    // MARK: - Board

    private static func conformBoard(_ json: inout [String: Any]) {
        conformLines(in: &json)
        guard var rules = json["rules"] as? [String: Any] else {
            return
        }
        // Horizon reads a padstack as a uuid and refuses an empty one, losing
        // the via rule or definition that names it; the null uuid is its own
        // for none.
        if var viaRules = rules["via"] as? [String: Any] {
            for (id, value) in viaRules {
                guard var rule = value as? [String: Any], (rule["padstack"] as? String)?.isEmpty == true else { continue }
                rule["padstack"] = HorizontalProjectArchive.nullUUID
                viaRules[id] = rule
            }
            rules["via"] = viaRules
        }
        if var definitionsRule = rules["via_definitions"] as? [String: Any],
           var definitions = definitionsRule["via_definitions"] as? [String: Any] {
            for (id, value) in definitions {
                guard var definition = value as? [String: Any], (definition["padstack"] as? String)?.isEmpty == true else { continue }
                definition["padstack"] = HorizontalProjectArchive.nullUUID
                definitions[id] = definition
            }
            definitionsRule["via_definitions"] = definitions
            rules["via_definitions"] = definitionsRule
        }
        json["rules"] = rules
    }

    /// `Line::serialize` writes a width and a layer; `Line` reads 0 for either
    /// left out.
    private static func conformLines(in json: inout [String: Any]) {
        guard var lines = json["lines"] as? [String: Any] else {
            return
        }
        for (id, value) in lines {
            guard var line = value as? [String: Any] else { continue }
            setDefault(&line, "width", 0)
            setDefault(&line, "layer", 0)
            lines[id] = line
        }
        json["lines"] = lines
    }

    // MARK: - Schematic

    private static func conformSchematic(_ json: inout [String: Any]) {
        guard var sheets = json["sheets"] as? [String: Any] else {
            return
        }
        for (id, value) in sheets {
            guard var sheet = value as? [String: Any] else { continue }
            conformMap(&sheet, "symbols") { symbol in
                // SchematicSymbol's loader defaults, which its serializer
                // writes back.
                setDefault(&symbol, "smashed", false)
                setDefault(&symbol, "pin_display_mode", "selected_only")
                setDefault(&symbol, "display_directions", false)
                setDefault(&symbol, "display_all_pads", true)
                setDefault(&symbol, "expand", 0)
                setDefault(&symbol, "texts", [Any]())
            }
            conformMap(&sheet, "net_labels") { label in
                setDefault(&label, "size", 2_500_000)
                setDefault(&label, "offsheet_refs", true)
                setDefault(&label, "show_port", false)
            }
            conformLines(in: &sheet)
            removeIfEmpty(&sheet, "net_ties")
            sheets[id] = sheet
        }
        json["sheets"] = sheets
    }

    // MARK: - Block

    private static func conformBlock(_ json: inout [String: Any]) {
        removeIfEmpty(&json, "net_ties")
        var groups = Set<String>()
        var tags = Set<String>()
        for value in (json["components"] as? [String: Any] ?? [:]).values {
            guard let component = value as? [String: Any] else { continue }
            if let group = component["group"] as? String { groups.insert(group.lowercased()) }
            if let tag = component["tag"] as? String { tags.insert(tag.lowercased()) }
        }
        groups.remove(HorizontalProjectArchive.nullUUID)
        tags.remove(HorizontalProjectArchive.nullUUID)
        for (key, used) in [("group_names", groups), ("tag_names", tags)] {
            guard let names = json[key] as? [String: Any] else { continue }
            json[key] = names.filter { used.contains($0.key.lowercased()) }
        }
    }

    // MARK: - Helpers

    private static func conformMap(_ json: inout [String: Any], _ key: String, _ conform: (inout [String: Any]) -> Void) {
        guard var map = json[key] as? [String: Any] else {
            return
        }
        for (id, value) in map {
            guard var item = value as? [String: Any] else { continue }
            conform(&item)
            map[id] = item
        }
        json[key] = map
    }

    private static func setDefault(_ json: inout [String: Any], _ key: String, _ value: Any) {
        if json[key] == nil {
            json[key] = value
        }
    }

    private static func removeIfEmpty(_ json: inout [String: Any], _ key: String) {
        if let map = json[key] as? [String: Any], map.isEmpty {
            json.removeValue(forKey: key)
        }
    }
}
