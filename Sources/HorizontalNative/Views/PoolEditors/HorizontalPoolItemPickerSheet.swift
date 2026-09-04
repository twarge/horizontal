import SwiftUI

/// Picks one pool item of a kind from the editor's index — the stand-in for
/// Horizon's pool browser dialog when a gate needs a unit, a part an entity,
/// a package, a base part, or a part to copy a pad map from.
struct HorizontalPoolItemPickerSheet: View {
    var title: String
    var category: HorizontalPoolItemCategory
    var index: HorizontalPoolLibraryIndex
    /// Items to leave out (an item can't be its own base or alternate).
    var excludedUUIDs: Set<String> = []
    var onPick: (HorizontalPoolLibraryItem) -> Void
    var onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedItemID: HorizontalPoolLibraryItem.ID?

    private var items: [HorizontalPoolLibraryItem] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        return index.items(in: category).filter { item in
            guard !excludedUUIDs.contains(item.uuid) else {
                return false
            }
            guard !terms.isEmpty else {
                return true
            }
            let haystack = [item.name, item.detail, item.tags, item.poolName].joined(separator: "\n").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    private var selectedItem: HorizontalPoolLibraryItem? {
        items.first { $0.id == selectedItemID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            .padding(12)
            Divider()
            Table(items, selection: $selectedItemID) {
                TableColumn("Name") { item in
                    Text(item.name).lineLimit(1)
                }
                .width(min: 160, ideal: 260)
                TableColumn(category.detailTitle) { item in
                    Text(item.detail).lineLimit(1)
                }
                .width(min: 100, ideal: 180)
                TableColumn("Pool") { item in
                    Text(item.poolName).lineLimit(1)
                }
                .width(min: 90, ideal: 140)
            }
            .contextMenu(forSelectionType: HorizontalPoolLibraryItem.ID.self) { _ in
            } primaryAction: { selection in
                if let item = items.first(where: { selection.contains($0.id) }) {
                    onPick(item)
                }
            }
            Divider()
            HStack {
                Text("\(items.count) \(category.title.lowercased())")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let selectedItem {
                        onPick(selectedItem)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedItem == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

/// Which picker an editor has open, if any.
struct HorizontalPoolItemPickerRequest: Identifiable {
    enum Purpose: Hashable {
        case gateUnit(gateID: String?)
        case partEntity
        case partPackage
        case partBase
        case partCopyPadMap
        case packageAlternate
        case symbolUnit
    }

    var purpose: Purpose
    var category: HorizontalPoolItemCategory
    var title: String
    var excludedUUIDs: Set<String> = []

    var id: String { "\(purpose)|\(category.rawValue)" }
}
