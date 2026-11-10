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
///
/// With `allowsOtherEntities`, a part for another entity fits too: the
/// components are remapped onto it (`remap_part`), their pins matched by
/// name, so the connections and symbols carry over where the new entity has
/// pins of those names, and the remap is refused, saying which, where it
/// hasn't.
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
    /// Parts for other entities are offered as well, and remap the
    /// components onto them (the Pools pane's Other Entities).
    var allowsOtherEntities = false

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
        return allowsOtherEntities || item.partEntityID == entityID
    }

    /// The undo title for giving the targets `item`.
    func actionName(for item: HorizontalPoolLibraryItem) -> String {
        (remaps(item) ? "Remap Part" : "Replace Part") + (targets.count == 1 ? "" : "s")
    }

    /// Whether giving the targets `item` remaps them onto another entity
    /// rather than keeping theirs.
    func remaps(_ item: HorizontalPoolLibraryItem) -> Bool {
        item.category == .part && entityID != nil && item.partEntityID != entityID
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
                : "“\(item.name)” is for another entity, so \(refdesList) would lose their connections. "
                    + "Turn on Other Entities to remap them onto it, their pins matched by name."
        }
        guard targets.contains(where: { $0.partID != item.uuid.lowercased() }) else {
            return "\(refdesList) already \(targets.count == 1 ? "uses" : "use") “\(item.name)”."
        }
        return nil
    }

    /// Replace as edit operations: `set_part` for every target not already on
    /// `partID`. The entity stays, so `set_part` keeps the connections. A part
    /// in another package breaks the board connections of pads the new
    /// footprint doesn't have, their copper left on junctions where the pads
    /// were (`set_part`). A part for another entity (`entityID`, the part's)
    /// is a `remap_part` instead, which matches the pins by name.
    func operations(partID: String, entityID: String? = nil) -> [JSONDictionary] {
        let partID = partID.lowercased(), entityID = entityID?.lowercased()
        return targets.filter { $0.partID != partID }.map { target in
            let remaps = entityID.map { !$0.isEmpty && $0 != target.entityID } ?? false
            let kind: HorizontalEditOperationKind = remaps ? .remapPart : .setPart
            return ["op": kind.rawValue, "component": target.componentID, "part": partID]
        }
    }
}
