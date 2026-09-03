import SwiftUI

private enum HorizontalPartSearchScope: String, CaseIterable, Identifiable {
    case all
    case mpn
    case value
    case manufacturer
    case description
    case tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .mpn: "MPN"
        case .value: "Value"
        case .manufacturer: "Manufacturer"
        case .description: "Description"
        case .tags: "Tags"
        }
    }
}

struct HorizontalPartBrowserView: View {
    var parts: [HorizontalPoolPart]
    var poolURL: URL?
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var isReadOnly = false
    var onPlacePart: (HorizontalPoolPart) -> Void = { _ in }

    @State private var searchScope: HorizontalPartSearchScope = .all
    @State private var searchText = ""
    @State private var selectedPartID: HorizontalPoolPart.ID?
    @State private var sortOrder = [KeyPathComparator(\HorizontalPoolPart.mpn)]
    @SceneStorage("Horizontal.partBrowser.columnCustomization")
    private var columnCustomization = TableColumnCustomization<HorizontalPoolPart>()

    private var filteredParts: [HorizontalPoolPart] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let filtered = terms.isEmpty
            ? parts
            : parts.filter { part in
                terms.allSatisfy { term in
                    searchableText(for: part).contains(term)
                }
            }
        return filtered.sorted(using: sortOrder)
    }

    private var selectedPart: HorizontalPoolPart? {
        guard let selectedPartID else {
            return nil
        }
        return parts.first { $0.id == selectedPartID }
    }

    private var canPlaceSelectedPart: Bool {
        !isReadOnly && selectedPart?.gates.first?.symbolID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
                .padding(.top, safeAreaInsets.top)
            Divider()
            if parts.isEmpty {
                unavailableView
            } else {
                partTable
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Picker("Search Field", selection: $searchScope) {
                ForEach(HorizontalPartSearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            TextField("Search Parts", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Button {
                placeSelectedPart()
            } label: {
                Label("Place", systemImage: "plus.square.on.square")
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!canPlaceSelectedPart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The sum of the columns' minimum widths (plus row insets): the least
    /// width at which every column is still legible.
    private static let minimumTableWidth: CGFloat = 850

    private var partTable: some View {
        // Table has no horizontal scrolling of its own — when the pane is
        // narrower than the columns it just clips them — so it rides in a
        // horizontal ScrollView pinned to no less than the columns' minimum
        // width. Vertical scrolling stays the table's own.
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                sortableTable
                    .frame(
                        width: max(proxy.size.width, Self.minimumTableWidth),
                        height: proxy.size.height
                    )
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        }
    }

    private var sortableTable: some View {
        Table(
            filteredParts,
            selection: $selectedPartID,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("MPN", value: \.mpn) { part in
                tableText(part.mpn, part: part)
            }
            .width(min: 130, ideal: 180)
            .customizationID("mpn")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Value", value: \.value) { part in
                tableText(part.value, part: part)
            }
            .width(min: 90, ideal: 120)
            .customizationID("value")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Manufacturer", value: \.manufacturer) { part in
                tableText(part.manufacturer, part: part)
            }
            .width(min: 120, ideal: 150)
            .customizationID("manufacturer")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Description", value: \.partDescription) { part in
                tableText(part.partDescription, part: part)
            }
            .width(min: 220, ideal: 360)
            .customizationID("description")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Package", value: \.packageName) { part in
                tableText(part.packageName, part: part)
            }
            .width(min: 110, ideal: 140)
            .customizationID("package")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Tags", value: \.tagList) { part in
                tableText(part.tagList, part: part)
            }
            .width(min: 140, ideal: 220)
            .customizationID("tags")
            .disabledCustomizationBehavior(.visibility)
        }
        // Alternating row backgrounds are a macOS-only Table modifier.
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .textSelection(.enabled)
    }

    private var unavailableView: some View {
        // Greedy frame so the toolbar stays pinned to the top — without it the
        // enclosing VStack hugs its content and floats to the pane's center.
        ContentUnavailableView(
            "No Parts",
            systemImage: "list.bullet.rectangle",
            description: Text(poolURL.map { "No cached parts were found in \($0.path)." } ?? "This project does not declare a pool directory.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tableText(_ value: String, part: HorizontalPoolPart) -> some View {
        Text(value.isEmpty ? "-" : value)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                place(part)
            }
    }

    private func placeSelectedPart() {
        guard let selectedPart else {
            return
        }
        place(selectedPart)
    }

    private func place(_ part: HorizontalPoolPart) {
        guard !isReadOnly,
              part.gates.first?.symbolID != nil else {
            return
        }
        onPlacePart(part)
    }

    private func searchableText(for part: HorizontalPoolPart) -> String {
        switch searchScope {
        case .all:
            return [
                part.mpn,
                part.value,
                part.manufacturer,
                part.partDescription,
                part.packageName,
                part.tagList
            ].joined(separator: "\n").lowercased()
        case .mpn:
            return part.mpn.lowercased()
        case .value:
            return part.value.lowercased()
        case .manufacturer:
            return part.manufacturer.lowercased()
        case .description:
            return part.partDescription.lowercased()
        case .tags:
            return part.tagList.lowercased()
        }
    }
}
