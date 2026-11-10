import Foundation

/// The top block's groups and tags, which Horizon uses to lay out identical
/// sub-circuits alike: a component's group says which copy of the circuit it
/// is in, its tag which part of the circuit it is, so R3 of one channel and
/// R13 of the next share a tag in different groups. Horizon's Set group,
/// Set tag, Rename, Clear and Highlight act on them, and Copy placement and
/// Copy tracks lay one group out like another.
///
/// Every edit here is the automation channel's `set_group_tag` (and
/// `copy_group_layout`), which names a group or tag by its name: one with
/// that name already is reused, a new name makes one. `set_group_tag` sets
/// both at once, so each op carries the component's other one as it is.
struct HorizontalGroupTags: Equatable {
    struct Component: Equatable {
        var id: String
        var refdes: String
        /// Ids, lowercased; nil for none (Horizon's null uuid).
        var group: String?
        var tag: String?
    }

    /// A group or a tag with the components that have it.
    struct Grouping: Identifiable, Equatable {
        var id: String
        var name: String
        var members: [Component]

        var memberIDs: Set<String> { Set(members.map(\.id)) }
        var refdesList: String { members.map(\.refdes).joined(separator: ", ") }
    }

    var groupNames: [String: String]
    var tagNames: [String: String]
    var components: [String: Component]

    static let nullUUID = "00000000-0000-0000-0000-000000000000"

    init(block: JSONDictionary) {
        func names(_ key: String) -> [String: String] {
            var names = [String: String]()
            for (id, name) in block[key] as? [String: Any] ?? [:] {
                if let name = name as? String { names[id.lowercased()] = name }
            }
            return names
        }
        func id(_ value: String?) -> String? {
            guard let value = value?.lowercased(), value != Self.nullUUID, !value.isEmpty else { return nil }
            return value
        }
        groupNames = names("group_names")
        tagNames = names("tag_names")
        var components = [String: Component]()
        for (key, component) in block.dictionaryMap("components") {
            let componentID = key.lowercased()
            components[componentID] = Component(id: componentID, refdes: component.string("refdes") ?? String(componentID.prefix(8)),
                                                group: id(component.string("group")), tag: id(component.string("tag")))
        }
        self.components = components
    }

    func groupName(_ id: String) -> String { groupNames[id] ?? "Group \(id.prefix(8))" }
    func tagName(_ id: String) -> String { tagNames[id] ?? "Tag \(id.prefix(8))" }

    /// The groups some component is in, by name, their members by refdes.
    var groups: [Grouping] { sets(\.group, name: groupName) }
    /// The tags some component has, by name.
    var tags: [Grouping] { sets(\.tag, name: tagName) }

    /// The components among `ids` the block has, by refdes.
    func components(_ ids: Set<String>) -> [Component] {
        ids.compactMap { components[$0.lowercased()] }.sorted(by: Self.refdesOrder)
    }

    /// Horizon's Set group (a name) or Clear group (nil) on `ids`.
    func settingGroup(_ name: String?, of ids: Set<String>) -> [JSONDictionary] {
        let name = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        return components(ids).filter { $0.group.map(groupName) != name }.map { op($0, group: name, tag: $0.tag.map(tagName)) }
    }

    /// Horizon's Set tag (a name) or Clear tag (nil) on `ids`.
    func settingTag(_ name: String?, of ids: Set<String>) -> [JSONDictionary] {
        let name = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        return components(ids).filter { $0.tag.map(tagName) != name }.map { op($0, group: $0.group.map(groupName), tag: name) }
    }

    /// Horizon's Rename group: every member of group `id` given the group
    /// named `name`, which is this one renamed, or, where another group has
    /// that name, that one.
    func renamingGroup(_ id: String, to name: String) -> [JSONDictionary] {
        guard let group = groups.first(where: { $0.id == id.lowercased() }) else { return [] }
        return settingGroup(name, of: group.memberIDs)
    }

    func renamingTag(_ id: String, to name: String) -> [JSONDictionary] {
        guard let tag = tags.first(where: { $0.id == id.lowercased() }) else { return [] }
        return settingTag(name, of: tag.memberIDs)
    }

    /// Horizon's Clear group for the whole group: its members in none.
    func clearingGroup(_ id: String) -> [JSONDictionary] {
        guard let group = groups.first(where: { $0.id == id.lowercased() }) else { return [] }
        return settingGroup(nil, of: group.memberIDs)
    }

    func clearingTag(_ id: String) -> [JSONDictionary] {
        guard let tag = tags.first(where: { $0.id == id.lowercased() }) else { return [] }
        return settingTag(nil, of: tag.memberIDs)
    }

    /// The groups `source`'s layout can be copied to: those with a member
    /// sharing a tag with one of its own, which is what Copy placement pairs.
    func copyTargets(for source: String) -> [Grouping] {
        let tags = Set(groups.first { $0.id == source.lowercased() }?.members.compactMap(\.tag) ?? [])
        return groups.filter { $0.id != source.lowercased() && $0.members.contains { $0.tag.map(tags.contains) == true } }
    }

    /// Horizon's Copy placement (and, with `includeRouting`, Copy tracks):
    /// the target group laid out as the source is.
    func copyingLayout(from source: String, to target: String, includeRouting: Bool) -> JSONDictionary {
        ["op": "copy_group_layout", "source": source.lowercased(), "target": target.lowercased(), "include_routing": includeRouting]
    }

    private func op(_ component: Component, group: String?, tag: String?) -> JSONDictionary {
        ["op": "set_group_tag", "component": component.id, "group": group ?? NSNull(), "tag": tag ?? NSNull()]
    }

    private func sets(_ key: KeyPath<Component, String?>, name: (String) -> String) -> [Grouping] {
        Dictionary(grouping: components.values.filter { $0[keyPath: key] != nil }) { $0[keyPath: key] ?? "" }
            .map { id, members in Grouping(id: id, name: name(id), members: members.sorted(by: Self.refdesOrder)) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    private static func refdesOrder(_ lhs: Component, _ rhs: Component) -> Bool {
        let order = lhs.refdes.localizedStandardCompare(rhs.refdes)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
}
