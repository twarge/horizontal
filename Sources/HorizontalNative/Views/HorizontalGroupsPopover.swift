import SwiftUI

/// The board rail's Groups and Tags button, with its popover: Horizon's Set
/// group, Set tag, Rename, Clear and Highlight for groups and tags, and its
/// Copy placement / Copy tracks between groups (`HorizontalGroupTags`).
/// `groupTags` is read when the popover opens, not on every redraw of the
/// rail. Each edit is one undoable project edit.
struct GroupsToolButton: View {
    var groupTags: () -> HorizontalGroupTags
    var selectedComponentIDs: Set<String>
    var isReadOnly: Bool
    var onEdit: ([JSONDictionary], String) -> Void
    var onHighlight: (Set<String>) -> Void

    @State private var isPresented = false

    var body: some View {
        HorizontalRailHelpLabel(title: "Groups and tags") {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "square.on.square.dashed")
            }
            .help("Group the copies of a circuit, tag their matching parts, and lay one copy out like another")
        }
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            HorizontalGroupsPopover(groupTags: groupTags(), selectedComponentIDs: selectedComponentIDs,
                                    isReadOnly: isReadOnly, onEdit: onEdit, onHighlight: onHighlight)
        }
    }
}

struct HorizontalGroupsPopover: View {
    var groupTags: HorizontalGroupTags
    var selectedComponentIDs: Set<String>
    var isReadOnly: Bool
    var onEdit: ([JSONDictionary], String) -> Void
    var onHighlight: (Set<String>) -> Void

    @State private var groupDraft = ""
    @State private var tagDraft = ""
    @State private var renameDrafts: [String: String] = [:]
    @State private var copySource: String?
    @State private var copyTarget: String?
    @State private var copiesTracks = true

    private var selected: [HorizontalGroupTags.Component] { groupTags.components(selectedComponentIDs) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !isReadOnly { selectionSection }
                setsSection(title: "Groups", sets: groupTags.groups, isGroup: true)
                setsSection(title: "Tags", sets: groupTags.tags, isGroup: false)
                if !isReadOnly { copySection }
            }
            .padding(14)
        }
        .frame(width: 340)
        .frame(maxHeight: 520)
    }

    @ViewBuilder
    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected Parts")
                .font(.headline)
            if selected.isEmpty {
                Text("Select parts on the board or in the schematic to group or tag them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(selected.map(\.refdes).joined(separator: ", "))
                    .font(.callout)
                    .lineLimit(2)
                let ids = Set(selected.map(\.id))
                assignRow("Group", text: $groupDraft, placeholder: commonName(selected.map { $0.group.map(groupTags.groupName) }),
                          set: { send(groupTags.settingGroup(groupDraft, of: ids), "Set Group"); groupDraft = "" },
                          clear: { send(groupTags.settingGroup(nil, of: ids), "Clear Group") })
                assignRow("Tag", text: $tagDraft, placeholder: commonName(selected.map { $0.tag.map(groupTags.tagName) }),
                          set: { send(groupTags.settingTag(tagDraft, of: ids), "Set Tag"); tagDraft = "" },
                          clear: { send(groupTags.settingTag(nil, of: ids), "Clear Tag") })
            }
        }
    }

    private func assignRow(_ label: String, text: Binding<String>, placeholder: String,
                           set: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(set)
            Button("Set", action: set)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Clear", action: clear)
        }
    }

    /// The name the selection has in common, or a hint when it has none or
    /// several.
    private func commonName(_ names: [String?]) -> String {
        let distinct = Set(names.map { $0 ?? "" })
        guard distinct.count == 1, let only = distinct.first else { return "Several" }
        return only.isEmpty ? "None" : only
    }

    private func setsSection(title: String, sets: [HorizontalGroupTags.Grouping], isGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            if sets.isEmpty {
                Text(isGroup ? "No part is in a group." : "No part has a tag.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(sets) { set in
                setRow(set, isGroup: isGroup)
            }
        }
    }

    private func setRow(_ set: HorizontalGroupTags.Grouping, isGroup: Bool) -> some View {
        let key = (isGroup ? "g/" : "t/") + set.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if isReadOnly {
                    Text(set.name).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Name", text: Binding(
                        get: { renameDrafts[key] ?? set.name },
                        set: { renameDrafts[key] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard let name = renameDrafts.removeValue(forKey: key) else { return }
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, trimmed != set.name else { return }
                        send(isGroup ? groupTags.renamingGroup(set.id, to: trimmed) : groupTags.renamingTag(set.id, to: trimmed),
                             isGroup ? "Rename Group" : "Rename Tag")
                    }
                }
                Button {
                    onHighlight(set.memberIDs)
                } label: {
                    Image(systemName: "highlighter")
                }
                .buttonStyle(.borderless)
                .help("Highlight \(set.refdesList)")
                if !isReadOnly {
                    Button {
                        send(isGroup ? groupTags.clearingGroup(set.id) : groupTags.clearingTag(set.id),
                             isGroup ? "Clear Group" : "Clear Tag")
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(isGroup ? "Take every part out of \(set.name)" : "Take \(set.name) off every part")
                }
            }
            Text(set.refdesList)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var copySection: some View {
        let groups = groupTags.groups
        if groups.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Copy Layout")
                    .font(.headline)
                Picker("From", selection: $copySource) {
                    Text("Choose…").tag(String?.none)
                    ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                }
                let targets = copySource.map(groupTags.copyTargets) ?? []
                Picker("To", selection: $copyTarget) {
                    Text("Choose…").tag(String?.none)
                    ForEach(targets) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(targets.isEmpty)
                Toggle("Copy tracks too", isOn: $copiesTracks)
                Button("Copy") {
                    guard let source = copySource, let target = copyTarget else { return }
                    send([groupTags.copyingLayout(from: source, to: target, includeRouting: copiesTracks)],
                         copiesTracks ? "Copy Placement and Tracks" : "Copy Placement")
                }
                .disabled(copySource == nil || copyTarget == nil || !targets.contains { $0.id == copyTarget })
                Text("Places each part of the second group where its tag's part of the first is, relative to the first tag they share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func send(_ ops: [JSONDictionary], _ actionName: String) {
        guard !ops.isEmpty else { return }
        onEdit(ops, actionName)
    }
}
