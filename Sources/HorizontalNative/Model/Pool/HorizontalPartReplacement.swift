import Foundation
import HorizontalProjectIO

/// Horizon's Assign Part (`ToolAssignPart`), for the Pools pane: the
/// components selected in the workspace, and which parts can take their
/// place. A part fits when it is for the entity the components are on. The
/// entity is what gives a component its gates and pins, so keeping it keeps
/// every connection: Horizon's part browser shows only that entity's parts
/// while assigning ("Only showing parts for Entity …"), and the tool refuses
/// a part for another one ("wrong entity"). Components on different entities
/// have no part in common, as `ImpSchematic::entity_from_selection` has it.
struct HorizontalPartReplacement: Equatable {
    struct Target: Equatable {
        var componentID: String
        var refdes: String
        var entityID: String
        var partID: String?
    }

    /// The selected components the block has, in refdes order.
    var targets: [Target]
    /// The block they are in, nil for the top block, which is the one
    /// `set_part` edits unless told otherwise.
    var blockID: String?

    /// The components among `componentIDs` that `block` (a block file's
    /// JSON) has. Nil when it has none of them.
    init?(componentIDs: Set<String>, block: JSONDictionary, blockID: String? = nil) {
        let wanted = Set(componentIDs.map { $0.lowercased() })
        targets = block.dictionaryMap("components").compactMap { id, component -> Target? in
            guard wanted.contains(id.lowercased()), let entityID = component.string("entity") else {
                return nil
            }
            return Target(
                componentID: id.lowercased(),
                refdes: component.string("refdes") ?? "",
                entityID: entityID.lowercased(),
                partID: component.string("part")?.lowercased()
            )
        }
        .sorted { lhs, rhs in
            let order = lhs.refdes.localizedStandardCompare(rhs.refdes)
            return order == .orderedSame ? lhs.componentID < rhs.componentID : order == .orderedAscending
        }
        guard !targets.isEmpty else {
            return nil
        }
        self.blockID = blockID
    }

    /// The selection as `archive` holds it now: the components of the block
    /// the schematic shows (`preferredBlock`) when it has any of them, else
    /// the top block's.
    static func current(
        componentIDs: Set<String>,
        archive: HorizontalProjectArchive,
        project: HorizontalProject,
        preferredBlock: HorizontalProjectBlock? = nil
    ) -> HorizontalPartReplacement? {
        guard !componentIDs.isEmpty else {
            return nil
        }
        let store = HorizontalArchiveFileStore(archive: archive, baseURL: project.baseURL)
        let top = project.blocks.first(where: \.isTop)
        var blocks = [HorizontalProjectBlock]()
        if let preferredBlock, !preferredBlock.isTop { blocks.append(preferredBlock) }
        if let top { blocks.append(top) }
        for block in blocks {
            let filename = block.blockFilename ?? (block.isTop ? project.blockFilename : nil)
            guard let filename, !filename.isEmpty,
                  let data = try? store.read(project.baseURL.appendingPathComponent(filename)),
                  let json = try? JSONHelper.loadDictionary(from: data),
                  let replacement = HorizontalPartReplacement(componentIDs: componentIDs, block: json,
                                                              blockID: block.isTop ? nil : block.uuid) else {
                continue
            }
            return replacement
        }
        if top == nil, let filename = project.blockFilename,
           let data = try? store.read(project.baseURL.appendingPathComponent(filename)),
           let json = try? JSONHelper.loadDictionary(from: data) {
            return HorizontalPartReplacement(componentIDs: componentIDs, block: json)
        }
        return nil
    }

    /// The entity every target is on, or nil when they are on more than one.
    var entityID: String? {
        let entities = Set(targets.map(\.entityID))
        return entities.count == 1 ? entities.first : nil
    }

    /// What makes one selection the same as another: its components.
    var key: String {
        targets.map(\.componentID).sorted().joined(separator: ",")
    }

    /// The targets' reference designators, "R12, R13", the first few of a
    /// long list and how many more.
    var refdesList: String {
        let names = targets.map { $0.refdes.isEmpty ? String($0.componentID.prefix(8)) : $0.refdes }
        guard names.count > 6 else {
            return names.joined(separator: ", ")
        }
        return names.prefix(5).joined(separator: ", ") + " and \(names.count - 5) more"
    }

    /// Why no part fits them all, when none can.
    var problem: String? {
        guard entityID == nil else {
            return nil
        }
        return "\(refdesList) are on different entities, so no part fits them all. "
            + "Select components of one kind to replace them together."
    }

    /// Whether `item` can take the targets' place: a part for their entity
    /// that isn't a base part, which Horizon's part browser leaves out.
    func isCompatible(_ item: HorizontalPoolLibraryItem) -> Bool {
        guard item.category == .part, !item.isBasePart, let entityID else {
            return false
        }
        return item.partEntityID == entityID
    }

    /// Why Replace can't give the targets `item`, or nil when it can.
    func refusal(for item: HorizontalPoolLibraryItem) -> String? {
        if let problem {
            return problem
        }
        guard item.category == .part else {
            return "Only a part can replace \(refdesList)."
        }
        guard isCompatible(item) else {
            return item.isBasePart
                ? "“\(item.name)” is a base part, there to derive other parts from."
                : "“\(item.name)” is for another entity, so \(refdesList) would lose their connections."
        }
        guard targets.contains(where: { $0.partID != item.uuid.lowercased() }) else {
            return "\(refdesList) already \(targets.count == 1 ? "uses" : "use") “\(item.name)”."
        }
        return nil
    }

    /// Replace as edit operations: `set_part` for every target not already on
    /// `partID`. The entity stays, so `set_part` keeps the connections.
    func operations(partID: String) -> [JSONDictionary] {
        let partID = partID.lowercased()
        return targets.filter { $0.partID != partID }.map {
            ["op": HorizontalEditOperationKind.setPart.rawValue, "component": $0.componentID, "part": partID]
        }
    }

    /// The targets with copper on their pads: a track on the board that ends
    /// on one. `board` is the board file's JSON; only the top block has one.
    func routedTargets(board: JSONDictionary) -> [Target] {
        guard blockID == nil else {
            return []
        }
        var packagesByComponent = [String: Set<String>]()
        for (packageID, package) in board.dictionaryMap("packages") {
            if let component = package.string("component")?.lowercased() {
                packagesByComponent[component, default: []].insert(packageID.lowercased())
            }
        }
        var routedPackages = Set<String>()
        for (_, track) in board.dictionaryMap("tracks") {
            for end in ["from", "to"] {
                if let pad = track.dictionary(end)?.string("pad"),
                   let package = pad.split(separator: "/").first {
                    routedPackages.insert(package.lowercased())
                }
            }
        }
        return targets.filter { !(packagesByComponent[$0.componentID] ?? []).isDisjoint(with: routedPackages) }
    }

    /// Why giving the targets a part in package `newPackageID` can't be done
    /// as `set_part` does it, or nil.
    ///
    /// `set_part` leaves the board alone, and the board takes a component's
    /// package from its part when it loads, as Horizon's does
    /// (`BoardPackage::update_package`). A placed component in another
    /// package simply shows the new footprint where it was. Copper ending
    /// on its pads can't follow: the new package's pads are other pads, and
    /// Horizon drops such a track when it loads the board. So a package
    /// change is refused for a routed component rather than left to lose
    /// its tracks.
    func packageChangeRefusal(
        newPackageID: String?,
        partName: String,
        currentPackageID: (String) -> String?,
        board: JSONDictionary?,
        packageName: (String) -> String
    ) -> String? {
        guard let board else {
            return nil
        }
        let newPackageID = newPackageID?.lowercased()
        let changing = routedTargets(board: board).filter { target in
            guard let partID = target.partID else { return false }
            return currentPackageID(partID)?.lowercased() != newPackageID
        }
        guard let first = changing.first else {
            return nil
        }
        let names = changing.map { $0.refdes.isEmpty ? String($0.componentID.prefix(8)) : $0.refdes }
        let listed = names.count > 6 ? names.prefix(5).joined(separator: ", ") + " and \(names.count - 5) more" : names.joined(separator: ", ")
        let old = first.partID.flatMap(currentPackageID).map(packageName) ?? "its package"
        let new = newPackageID.map(packageName) ?? "no package"
        return "“\(partName)” comes in \(new), not \(old), and \(listed) \(changing.count == 1 ? "has" : "have") tracks on "
            + "\(changing.count == 1 ? "its" : "their") pads, which the new footprint doesn't have. Nothing was changed: "
            + "remove those tracks first, or choose a part in \(old)."
    }

    /// Everything that stops Replace giving the targets `item` as the
    /// project stands in `archive`: `refusal(for:)`, then a change of
    /// package under copper (`packageChangeRefusal`). The targets' parts
    /// are the project pool's, so `project.poolParts` gives their packages.
    func refusal(
        for item: HorizontalPoolLibraryItem,
        packageName: String,
        project: HorizontalProject,
        archive: HorizontalProjectArchive
    ) -> String? {
        if let refusal = refusal(for: item) {
            return refusal
        }
        let parts = Dictionary(project.poolParts.map { ($0.id.lowercased(), $0) }) { first, _ in first }
        var packageNames = [String: String]()
        for part in project.poolParts {
            if let id = part.packageID?.lowercased() { packageNames[id] = part.packageName }
        }
        if !item.packageID.isEmpty { packageNames[item.packageID.lowercased()] = packageName }
        let store = HorizontalArchiveFileStore(archive: archive, baseURL: project.baseURL)
        let board = project.boardFilename
            .flatMap { try? store.read(project.baseURL.appendingPathComponent($0)) }
            .flatMap { try? JSONHelper.loadDictionary(from: $0) }
        return packageChangeRefusal(
            newPackageID: item.packageID.isEmpty ? nil : item.packageID,
            partName: item.name,
            currentPackageID: { parts[$0.lowercased()]?.packageID },
            board: board,
            packageName: { packageNames[$0.lowercased()] ?? String($0.prefix(8)) }
        )
    }
}
