import SwiftUI

/// The components fitted with a part, block by block: what a part's row in
/// the Parts pane selects in the other views, spotlights, and gives another
/// part. A part is replaced one block at a time, as a block file is edited
/// (`HorizontalPartReplacement`), so a part two blocks use has two groups.
struct HorizontalPartUseGroup: Identifiable, Equatable {
    /// The block's uuid, lowercased; empty for a project with one block.
    var id: String
    var blockName: String
    /// Its components as their block names them, lowercased.
    var componentIDs: Set<String>

    /// The groups for the part `partID`: the top block's first, then the
    /// others by name. Empty where no component has the part.
    static func groups(usingPart partID: String, in project: HorizontalProject) -> [HorizontalPartUseGroup] {
        // One of a block instance's components, read through the instance,
        // is its block's component again.
        let components = HorizontalDesignIndex(project: project).sortedComponents.filter { $0.instanceOf == nil }
        return groups(usingPart: partID, components: components.map { ($0.id, $0.partID, $0.blockID) }, blocks: project.blocks)
    }

    /// `components` are each a component's id, its part and its block, nil
    /// for the top block's.
    static func groups(
        usingPart partID: String,
        components: [(id: String, partID: String?, blockID: String?)],
        blocks: [HorizontalProjectBlock]
    ) -> [HorizontalPartUseGroup] {
        let top = blocks.first(where: \.isTop)
        var byBlock = [String: Set<String>]()
        for component in components where component.partID?.caseInsensitiveCompare(partID) == .orderedSame {
            let blockID = component.blockID?.lowercased() ?? top?.uuid.lowercased() ?? ""
            byBlock[blockID, default: []].insert(component.id.lowercased())
        }
        func block(_ id: String) -> HorizontalProjectBlock? {
            blocks.first { $0.uuid.lowercased() == id }
        }
        return byBlock.map { id, componentIDs in
            HorizontalPartUseGroup(id: id, blockName: block(id)?.displayName ?? "Top", componentIDs: componentIDs)
        }
        .sorted { lhs, rhs in
            let lhsTop = block(lhs.id)?.isTop ?? true, rhsTop = block(rhs.id)?.isTop ?? true
            if lhsTop != rhsTop { return lhsTop }
            let order = lhs.blockName.localizedStandardCompare(rhs.blockName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Every component in `groups`.
    static func componentIDs(in groups: [HorizontalPartUseGroup]) -> Set<String> {
        groups.reduce(into: Set<String>()) { $0.formUnion($1.componentIDs) }
    }
}

/// Replace and Change Value in a SwiftUI menu, as a canvas's right-click
/// lists them (`HorizontalPartReplaceMenu`): for a part's row in the Parts
/// pane. A part in use has its checkmark, one the project pool holds its
/// "In Project" under the title, and Change Value gives way to Change
/// Value, Same Footprint while Option is held, both listed where there is no
/// Option key.
struct HorizontalPartRowMenuEntries: View {
    var entries: [HorizontalTargetItemMenuEntry]
    /// Gives the components the part (`HorizontalPartReplaceActions.replace`).
    var replace: (_ partID: String, _ componentIDs: [String]) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            HorizontalPartRowMenuEntry(entry: entry, replace: replace)
        }
    }
}

private struct HorizontalPartRowMenuEntry: View {
    var entry: HorizontalTargetItemMenuEntry
    var replace: (_ partID: String, _ componentIDs: [String]) -> Void

    var body: some View {
        switch entry {
        case .choice(let title, let badge, _, let isOn, .replacePart(let part, let components)):
            // A toggle draws the checkmark a menu gives the part in use.
            Toggle(isOn: Binding(get: { isOn }, set: { _ in replace(part, components) })) {
                Text(title)
                if let badge {
                    Text(badge)
                }
            }
        case .submenu(let title, let children):
            Menu(title) {
                HorizontalPartRowMenuEntries(entries: children, replace: replace)
            }
        case .unavailable(let title, _):
            Button(title) {}
                .disabled(true)
        case .optionAlternate(let usual, let withOption):
            #if os(macOS)
            HorizontalPartRowMenuEntry(entry: usual, replace: replace)
                .modifierKeyAlternate(.option) {
                    HorizontalPartRowMenuEntry(entry: withOption, replace: replace)
                }
            #else
            HorizontalPartRowMenuEntry(entry: usual, replace: replace)
            HorizontalPartRowMenuEntry(entry: withOption, replace: replace)
            #endif
        case .separator:
            Divider()
        default:
            // Nothing else is listed for a part's row.
            EmptyView()
        }
    }
}
