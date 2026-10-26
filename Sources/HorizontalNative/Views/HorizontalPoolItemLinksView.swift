import SwiftUI

/// What clicking a pool item link does where it is shown: the Pools pane
/// goes to the item in its list, an item editor opens the item's own editor.
struct HorizontalPoolItemLinkActions {
    var open: (HorizontalPoolItemLink) -> Void
    /// Lists everything a field leaves out past its first links; nil where
    /// nothing can list them, and the field then only says how many.
    var showMore: ((HorizontalPoolSearch) -> Void)?
    /// What a link's help says it does: "Show the unit “Opamp” in the list",
    /// "Open the unit “Opamp”".
    var help: (HorizontalPoolItemLink) -> String

    /// "the unit “Opamp”", for the help texts.
    static func describe(_ link: HorizontalPoolItemLink) -> String {
        "the \(link.role.menuTitle.lowercased()) “\(link.name)”"
    }
}

/// How an item editor opens another pool item: on the Mac the item's own
/// document window, on iPad its editor pushed onto the cover's stack. Nil
/// where items can't be opened.
private struct HorizontalPoolOpenItemActionKey: EnvironmentKey {
    static var defaultValue: ((HorizontalPoolLibraryItem) -> Void)? { nil }
}

/// The link actions an item editor's link rows use, built from the
/// session's index and the open action.
private struct HorizontalPoolItemLinkActionsKey: EnvironmentKey {
    static var defaultValue: HorizontalPoolItemLinkActions? { nil }
}

extension EnvironmentValues {
    var horizonPoolOpenItemAction: ((HorizontalPoolLibraryItem) -> Void)? {
        get { self[HorizontalPoolOpenItemActionKey.self] }
        set { self[HorizontalPoolOpenItemActionKey.self] = newValue }
    }

    var horizonPoolItemLinkActions: HorizontalPoolItemLinkActions? {
        get { self[HorizontalPoolItemLinkActionsKey.self] }
        set { self[HorizontalPoolItemLinkActionsKey.self] = newValue }
    }
}

/// One linked item, as the Parts pane draws its links: the name in the
/// accent colour, the pointing hand over it, and what tells it apart after
/// it. One no browsed pool has, or with nothing to do, stays plain text.
struct HorizontalPoolItemLinkButton: View {
    var link: HorizontalPoolItemLink
    var actions: HorizontalPoolItemLinkActions?

    var body: some View {
        let note = link.note.isEmpty ? nil : Text(link.note).foregroundStyle(.secondary)
        if link.isResolved, let actions {
            Button {
                actions.open(link)
            } label: {
                HStack(spacing: 4) {
                    Text(link.name)
                        .foregroundStyle(Color.accentColor)
                    note
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .help(actions.help(link))
        } else {
            HStack(spacing: 4) {
                Text(link.name)
                note
            }
            .help(link.isResolved ? "" : "No browsed pool has this \(link.role.menuTitle.lowercased()) (\(link.uuid)).")
        }
    }
}

/// A field's links wrapped into rows, then how many more there are: a link
/// that lists them all where the field says how, else the count.
struct HorizontalPoolItemLinkFlow: View {
    var field: HorizontalPoolItemPreviewTable.Field
    var actions: HorizontalPoolItemLinkActions?

    var body: some View {
        HorizontalPoolPreviewFlowLayout(spacing: 10, lineSpacing: 3) {
            ForEach(field.links) { link in
                HorizontalPoolItemLinkButton(link: link, actions: actions)
            }
            if field.moreLinks > 0 {
                more
            }
        }
    }

    @ViewBuilder
    private var more: some View {
        let text = "and \(field.moreLinks.formatted()) more"
        if let search = field.moreSearch, let showMore = actions?.showMore {
            Button {
                showMore(search)
            } label: {
                Text(text + "…")
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .help("List every one of them")
        } else {
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// Link fields as rows of a label/value `Grid`: the label trailing, the
/// links beside it.
struct HorizontalPoolItemLinkRows: View {
    var fields: [HorizontalPoolItemPreviewTable.Field]
    var actions: HorizontalPoolItemLinkActions?
    /// The preview greys its labels; an editor's read as its fields' do.
    var secondaryLabels = false

    var body: some View {
        ForEach(fields) { field in
            GridRow {
                Text(field.label)
                    .foregroundStyle(secondaryLabels ? .secondary : .primary)
                    .gridColumnAlignment(.trailing)
                HorizontalPoolItemLinkFlow(field: field, actions: actions)
            }
        }
    }
}

extension HorizontalPoolItemEditorSession {
    /// What the item names and what names it, as its editor's link rows show
    /// them, from the model as edited.
    var linkFields: [HorizontalPoolItemPreviewTable.Field] {
        HorizontalPoolPreviewBuilder.linkFields(
            HorizontalPoolPreviewBuilder.links(category: category, uuid: model.uuid, json: model.json(), index: index),
            owner: libraryItem
        )
    }

    /// The link actions for this session's editor: each link opens its item
    /// through `open`, found in the session's index.
    func linkActions(open: ((HorizontalPoolLibraryItem) -> Void)?) -> HorizontalPoolItemLinkActions? {
        guard let open else {
            return nil
        }
        let index = index
        return HorizontalPoolItemLinkActions(
            open: { link in
                if let item = index.item(link.category, uuid: link.uuid) {
                    open(item)
                }
            },
            showMore: nil,
            help: { "Open " + HorizontalPoolItemLinkActions.describe($0) }
        )
    }
}
