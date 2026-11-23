import Foundation
import HorizontalProjectIO

/// The project's own pool items in a cleanup: the parts, symbols, packages
/// and the rest it keeps outside `cache/`, drawn for the project instead of
/// copied from a library.
///
/// Horizon's cleanup never offers one, and a pool browser's Delete refuses a
/// project pool's items, so a part the design stopped using (an MCU the board
/// was first drawn round) stayed in the Parts pane with its entity, units,
/// symbols and package. They are offered here by the same rule as the cached
/// copies: nothing in the design reaches them. What differs is what removing
/// one costs. A cached copy can be imported again; one of these is the only
/// copy. So they come after the cached copies, a cleanup removes one only
/// when it is chosen, and the sheet starts with them unticked.
extension HorizontalPoolCacheCleanup {
    static let localPrefix = "local|"
    private static let models = "3d_models/"

    /// The project's own items nothing in the design reaches, in the cached
    /// copies' order: parts, entities, units, symbols, packages, padstacks,
    /// frames, decals, then 3D models. `reachedKeys` and `keptModels` are the
    /// cache review's: an item counts as used by kind and uuid, and a used
    /// package keeps its models.
    ///
    /// The pool's own default via and frame stay as well: `pool.json` names
    /// them, and a new via or sheet takes them.
    static func localItems(files: [String: Data], jsons: [String: JSONDictionary],
                           reachedKeys: Set<HorizontalPoolItemReference>, keptModels: Set<String>,
                           partsByID: [String: JSONDictionary]) -> [HorizontalPoolCacheCleanupItem] {
        var used = reachedKeys
        if let pool = jsons["pool.json"] {
            if let via = pool.string("default_via") { used.insert(.init(type: "padstack", uuid: via)) }
            if let frame = pool.string("default_frame") { used.insert(.init(type: "frame", uuid: frame)) }
        }
        func bytes(_ paths: [String]) -> Int {
            paths.reduce(0) { $0 + (files[$1]?.count ?? 0) }
        }

        var items = [HorizontalPoolCacheCleanupItem]()
        for category in cacheKinds {
            let directory = HorizontalPoolItemFactory.directoryName(for: category) + "/"
            let own = files.keys.filter { $0.hasPrefix(directory) && !$0.hasPrefix(directory + "cache/") }.sorted()
            let candidates = category == .package ? own.filter { $0.hasSuffix("/package.json") } : own.filter { $0.hasSuffix(".json") }
            for path in candidates {
                guard let json = jsons[path], json.string("type") == category.rawValue, let uuid = json.string("uuid"),
                      !used.contains(.init(type: category.rawValue, uuid: uuid)) else { continue }
                var paths = [path]
                if category == .package {
                    // A package is its folder, package.json and the padstacks
                    // beside it, as Horizon removes one (`ownsDirectory`): not
                    // `packages/` itself, and not a folder holding another
                    // package below, whose files may be that one's.
                    let folder = String(path.dropLast("package.json".count))
                    if folder != directory, !candidates.contains(where: { $0 != path && $0.hasPrefix(folder) }) {
                        paths = own.filter { $0.hasPrefix(folder) }
                    }
                }
                items.append(.init(id: localPrefix + path, kind: category.rawValue, uuid: uuid.lowercased(),
                                   name: name(of: json, category, uuid: uuid, partsByID: partsByID),
                                   paths: paths, bytes: bytes(paths), isProjectLocal: true))
            }
        }
        // A model inside a package's folder goes with that package.
        let taken = Set(items.flatMap(\.paths))
        for path in files.keys.sorted() where path.hasPrefix(models) && !path.hasPrefix(modelCache)
            && !keptModels.contains(path) && !taken.contains(path) {
            items.append(.init(id: localPrefix + path, kind: "model", uuid: nil, name: URL(fileURLWithPath: path).lastPathComponent,
                               paths: [path], bytes: bytes([path]), isProjectLocal: true))
        }
        return items
    }
}
