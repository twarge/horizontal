import Foundation
import HorizontalProjectIO

/// A board package whose component no block gives any more.
///
/// It is left behind by a component deleted from a block without its board
/// package: the placement stays in the board file, labelled with the component
/// uuid it names, and draws no footprint, because the loader gives a package
/// its pads only through a component some block has. Horizon EDA leaves such a
/// package out when it opens the board.
struct HorizontalOrphanedPackage: Identifiable, Hashable, Sendable {
    /// The package's uuid as the board file keys it: what `remove_placement`
    /// takes, lowercased there.
    var id: String
    /// The flat component uuid the package names, which no block gives.
    var componentID: String
    /// Where the package sits, in nanometres as the board file has it.
    var position: HorizontalPoint
}

/// The board's orphaned packages, and whether they can be removed.
///
/// Removal is offered only when nothing says it would be a mistake:
///  - every block of the project loaded. A block file that did not load takes
///    its components with it, so the packages of those components look
///    orphaned just as a deleted component's do; removing them would delete a
///    layout the files still hold.
///  - no track ends on one of their pads. The pad's position is what a track's
///    end becomes a junction at, and an orphan has no footprint to give one, so
///    removing it would drop that track.
struct HorizontalOrphanedPackages: Equatable, Sendable {
    static let none = HorizontalOrphanedPackages(packages: [], refusal: nil)

    var packages: [HorizontalOrphanedPackage]
    /// Why `packages` must stay on the board, as a clause without a full stop;
    /// nil when they may be removed.
    var refusal: String?

    /// Whether `packages` may be removed: there are some, and nothing refuses it.
    var canRemove: Bool {
        !packages.isEmpty && refusal == nil
    }

    /// The `remove_placement` operations that take `packages` off the board,
    /// one each, as one edit.
    var removalOperations: [JSONDictionary] {
        packages.map { ["op": "remove_placement", "component": $0.id.lowercased()] }
    }

    /// The load diagnostic that says what was found and whether it can be
    /// removed. Nil when there is nothing to say.
    var diagnosticMessage: String? {
        guard !packages.isEmpty else {
            return nil
        }
        let count = packages.count
        let places = packages.prefix(3).map { package in
            "(\(Self.millimetres(package.position.x)), \(Self.millimetres(package.position.y)))"
        }.joined(separator: ", ")
        let more = count > 3 ? " and \(count - 3) more" : ""
        var message = "\(count) board \(count == 1 ? "package names" : "packages name") a component no block has, "
            + "so \(count == 1 ? "its footprint isn't" : "their footprints aren't") drawn: at \(places)\(more) mm."
        if let refusal {
            message += " Not offering to remove \(count == 1 ? "it" : "them"): \(refusal)."
        } else {
            message += " Remove Orphaned Packages takes \(count == 1 ? "it" : "them") off the board as one edit."
        }
        return message
    }

    /// The packages of `board` whose component the design does not give, and
    /// what, if anything, stops them from being removed.
    ///
    /// A placement is orphaned when it names a component and the loader found
    /// no details for it: the same lookup that decides whether a package gets
    /// its footprint, so what this lists is what draws nothing.
    static func scan(
        board: HorizontalBoard?,
        blocks: [HorizontalProjectBlock],
        topBlockFilename: String?,
        boardFilename: String?,
        baseURL: URL
    ) -> HorizontalOrphanedPackages {
        guard let board else {
            return .none
        }
        // The board file says which packages are this board's. `board.packages`
        // holds the packages of included panels too, and those name components
        // of their own boards: they are not this file's to remove.
        guard let boardFilename, !boardFilename.isEmpty,
              let file = try? JSONHelper.loadDictionary(from: baseURL.appendingPathComponent(boardFilename)) else {
            return .none
        }
        let owned = Set(file.dictionaryMap("packages").keys.map { $0.lowercased() })
        let packages = board.packages.compactMap { placement -> HorizontalOrphanedPackage? in
            guard owned.contains(placement.id.lowercased()),
                  let componentID = placement.componentID, placement.componentDetails == nil else {
                return nil
            }
            return HorizontalOrphanedPackage(id: placement.id, componentID: componentID, position: placement.position)
        }
        guard !packages.isEmpty else {
            return .none
        }
        let sorted = packages.sorted { $0.id < $1.id }
        let refusal = blockRefusal(blocks: blocks, topBlockFilename: topBlockFilename, baseURL: baseURL)
            ?? copperRefusal(of: sorted, board: file)
        return HorizontalOrphanedPackages(packages: sorted, refusal: refusal)
    }

    /// What stops the blocks from being all there, or nil when the top block
    /// and every block its instances use loaded, and some of them have
    /// components. Block files are read again here rather than trusted to the
    /// flattener, which leaves out a block that does not load without a word.
    private static func blockRefusal(
        blocks: [HorizontalProjectBlock],
        topBlockFilename: String?,
        baseURL: URL
    ) -> String? {
        // Keyed by the block's lowercased uuid; a project with no block list
        // has only its top block, under the empty key, which no instance names.
        var loaded = [String: JSONDictionary]()
        let topKey: String
        if blocks.isEmpty {
            guard let topBlockFilename, !topBlockFilename.isEmpty else {
                return "the project names no block file"
            }
            guard let json = try? JSONHelper.loadDictionary(from: baseURL.appendingPathComponent(topBlockFilename)) else {
                return "\(topBlockFilename) did not load"
            }
            loaded[""] = json
            topKey = ""
        } else {
            for block in blocks {
                guard let filename = block.blockFilename, !filename.isEmpty else {
                    return "block \(block.displayName) names no block file"
                }
                guard let json = try? JSONHelper.loadDictionary(from: baseURL.appendingPathComponent(filename)) else {
                    return "\(filename) did not load"
                }
                loaded[block.uuid.lowercased()] = json
            }
            guard let top = blocks.first(where: \.isTop) else {
                return "the project names no top block"
            }
            topKey = top.uuid.lowercased()
        }

        // Every block an instance uses, however deep, must have loaded: the
        // flattener would otherwise drop its components silently.
        var componentCount = 0
        var pending = [topKey]
        var visited = Set<String>()
        while let key = pending.popLast() {
            guard visited.insert(key).inserted, let json = loaded[key] else {
                continue
            }
            componentCount += json.dictionaryMap("components").count
            for instance in json.dictionaryMap("block_instances").values {
                let target = instance.string("block")?.lowercased() ?? ""
                guard !target.isEmpty, loaded[target] != nil else {
                    return "a block instance uses block \(target.isEmpty ? "(none)" : target), which did not load"
                }
                pending.append(target)
            }
        }
        return componentCount > 0 ? nil : "the blocks have no components"
    }

    /// What would be lost by removing `packages`: the track ends that reach
    /// one of their pads. Each such end would become a junction at the pad's
    /// position, which the orphan does not have, so the track would go with it.
    private static func copperRefusal(of packages: [HorizontalOrphanedPackage], board: JSONDictionary) -> String? {
        let ids = Set(packages.map { $0.id.lowercased() })
        var ends = 0
        for track in board.dictionaryMap("tracks").values {
            for end in ["from", "to"] {
                let pad = track.dictionary(end)?.string("pad")?.lowercased() ?? ""
                if let package = pad.split(separator: "/", maxSplits: 1).first, ids.contains(String(package)) {
                    ends += 1
                }
            }
        }
        guard ends > 0 else {
            return nil
        }
        return "\(ends) track \(ends == 1 ? "end is" : "ends are") on \(packages.count == 1 ? "its" : "their") pads, "
            + "and removing \(packages.count == 1 ? "it" : "them") would drop that copper"
    }

    private static func millimetres(_ nanometres: Double) -> String {
        String(format: "%.2f", nanometres / 1_000_000)
    }
}
