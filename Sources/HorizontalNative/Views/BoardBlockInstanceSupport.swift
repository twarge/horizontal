import Foundation

/// The board canvas's match of block instances, made again only when the
/// board it was made from changes.
final class BoardBlockLayoutCache {
    struct Key: Equatable {
        var boardID: String
        var revision: Int
        var counts: [Int]
        var packageCount: Int
    }

    private var key: Key?
    private var match: HorizontalBlockLayoutMatch?

    func match(key: Key, build: () -> HorizontalBlockLayoutMatch) -> HorizontalBlockLayoutMatch {
        if let match, self.key == key {
            return match
        }
        let built = build()
        self.key = key
        match = built
        return built
    }

    func invalidate() {
        key = nil
        match = nil
    }
}

/// What the board inspector says of the block instances a package selection
/// is in: which instance of which block, the instances laid out like it and
/// what differs from them, with Select Instance, which selects its parts and
/// its own copper so it moves as one.
enum HorizontalBlockInstanceSummary {
    typealias Instance = HorizontalBoardBlockInstances.Instance

    static let selectActionID = "blockInstance.select"
    static let copyLayoutActionID = "blockInstance.copyLayout"

    /// The innermost instances of blocks used more than once that the
    /// selected packages are parts of, in name order.
    static func instances(ofPackages packageIDs: [String], in match: HorizontalBlockLayoutMatch) -> [Instance] {
        var seen = Set<String>()
        return packageIDs.compactMap { match.instances(ofPackage: $0).first }
            .filter { seen.insert($0.path).inserted }
            .sorted(by: HorizontalBoardBlockInstances.inOrder)
    }

    /// The inspector's rows for `instances`.
    static func details(for instances: [Instance], in match: HorizontalBlockLayoutMatch) -> [HorizontalSelectionHUDDetail] {
        guard let instance = instances.first else {
            return []
        }
        let blockName = match.instances.blockNames[instance.blockID] ?? "a block"
        guard instances.count == 1 else {
            let names = instances.map(\.name).joined(separator: ", ")
            let blocks = Set(instances.map(\.blockID))
            return [HorizontalSelectionHUDDetail(label: "Block instances", value: blocks.count == 1 ? "\(names) of \(blockName)" : names)]
        }
        var rows = [HorizontalSelectionHUDDetail(label: "Block instance", value: "\(instance.name) of \(blockName)")]
        let classmates = match.classmates(of: instance.path).compactMap { match.instances.instances[$0]?.name }
        rows.append(HorizontalSelectionHUDDetail(label: "In sync with", value: classmates.isEmpty ? "No other instance" : classmates.joined(separator: ", ")))
        for sibling in match.instances.siblings(of: instance) {
            guard let pair = match.pair(from: instance.path, to: sibling.path), pair.related, !pair.differs.isEmpty else { continue }
            let parts = pair.differs.compactMap { refdes(of: $0, in: instance, match: match) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            rows.append(HorizontalSelectionHUDDetail(label: "Differs from \(sibling.name)", value: parts.joined(separator: ", ")))
        }
        return rows
    }

    /// The group's buttons: Select Instance, and Copy Layout to Other
    /// Instances where the canvas can copy one.
    static func actions(canCopyLayout: Bool) -> [HorizontalSelectionPropertyOption] {
        var actions = [HorizontalSelectionPropertyOption(id: selectActionID, title: "Select Instance")]
        if canCopyLayout {
            actions.append(HorizontalSelectionPropertyOption(id: copyLayoutActionID, title: "Copy Layout to Other Instances…"))
        }
        return actions
    }

    /// The selectable parts of `instances`: their packages and their own
    /// tracks and vias, picked from `refs`, the canvas's own.
    static func selection(of instances: [Instance], in match: HorizontalBlockLayoutMatch, from refs: [HorizontalSelectableRef]) -> [HorizontalSelectableRef] {
        var packages = Set<String>(), tracks = Set<String>(), vias = Set<String>()
        for instance in instances {
            packages.formUnion(match.layouts[instance.path]?.packageIDs ?? [])
            let owned = match.owned(instance.path)
            tracks.formUnion(owned.tracks)
            vias.formUnion(owned.vias)
        }
        return refs.filter { ref in
            let id = ref.id.lowercased()
            switch ref.type {
            case .boardPackage: return packages.contains(id)
            case .track: return tracks.contains(id)
            case .via: return vias.contains(id)
            default: return false
            }
        }
    }

    /// The refdes of `instance`'s member at local path `local`.
    static func refdes(of local: String, in instance: Instance, match: HorizontalBlockLayoutMatch) -> String? {
        guard let package = match.layouts[instance.path]?.packages[local] else { return nil }
        return package.componentDetails?.refdes ?? package.label
    }
}

/// What a board edit hands its commit for keeping block instances alike: the
/// board as it was before the edit, and what made it.
struct BoardLayoutSyncIntent {
    var baseline: HorizontalBoard
    var kind: HorizontalBlockLayoutSync.Intent.Kind
}
