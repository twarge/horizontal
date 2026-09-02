import Foundation
import SwiftUI

enum HorizontalSelectionPropertyValue: Equatable {
    case text(String)
    case bool(Bool)
    case length(Double)
    case angle(Int)
    case layer(Int?)
    case choice(String)
    case readOnly(String)
}

struct HorizontalSelectionPropertyOption: Identifiable, Equatable {
    var id: String
    var title: String
}

enum HorizontalSelectionPropertyEditor: Equatable {
    case text
    case multilineText
    case bool
    case length
    case angle
    case layer([HorizontalSelectionPropertyOption])
    case choice([HorizontalSelectionPropertyOption])
    case readOnly
}

struct HorizontalSelectionProperty: Identifiable, Equatable {
    var id: String
    var label: String
    var editor: HorizontalSelectionPropertyEditor
    var value: HorizontalSelectionPropertyValue
    /// When set, the row gets an (X) remove button that sends a property
    /// change with this ID (the value is carried along but unused). The
    /// property builder owns the ID scheme, e.g. "removeParam:<key>".
    var removeID: String? = nil

    var isEditable: Bool {
        switch editor {
        case .readOnly:
            false
        default:
            true
        }
    }
}

struct HorizontalSelectionDetailItem: Identifiable, Equatable {
    var ref: HorizontalSelectableRef
    var title: String
    var subtitle: String
    var details: [HorizontalSelectionHUDDetail]
    var properties: [HorizontalSelectionProperty]

    var id: HorizontalSelectableRef { ref }
}

struct HorizontalSelectionDetailGroup: Identifiable, Equatable {
    var type: HorizontalObjectType
    var title: String
    var pluralTitle: String
    var items: [HorizontalSelectionDetailItem]

    var id: HorizontalObjectType { type }
}

struct HorizontalSelectionDetailState: Equatable {
    static let empty = HorizontalSelectionDetailState(hovered: nil, groups: [])

    var hovered: HorizontalSelectionHUDItem?
    var groups: [HorizontalSelectionDetailGroup]

    var hasSelection: Bool {
        !groups.isEmpty
    }
}

struct HorizontalSelectionPropertyChange {
    var ref: HorizontalSelectableRef
    var type: HorizontalObjectType
    var propertyID: String
    var value: HorizontalSelectionPropertyValue
    var applyToAll: Bool
}

struct HorizontalSelectionPropertyChangeCommand: Equatable {
    var id = UUID()
    var change: HorizontalSelectionPropertyChange

    static func == (lhs: HorizontalSelectionPropertyChangeCommand, rhs: HorizontalSelectionPropertyChangeCommand) -> Bool {
        lhs.id == rhs.id
    }
}

struct HorizontalNetSegmentSelectionOption: Identifiable, Equatable {
    var id: String
    var name: String
    var netClassName: String?
    var isPower: Bool
}

struct HorizontalNetSegmentSelectionSidebarState: Identifiable, Equatable {
    var id: UUID
    var currentNetName: String
    var options: [HorizontalNetSegmentSelectionOption]
    var canCreateNewNet: Bool
}

enum HorizontalNetSegmentSelectionCommandAction: Equatable {
    case selectExisting(String)
    case createNew
    case cancel
}

struct HorizontalNetSegmentSelectionCommand: Equatable {
    var id = UUID()
    var selectionID: UUID
    var action: HorizontalNetSegmentSelectionCommandAction
}

private struct HorizontalSelectionApplyAllKey: Hashable {
    var type: HorizontalObjectType
    var propertyID: String
}

enum HorizontalSelectionInspectorChrome {
    case popover
    case sidebar
}

struct HorizontalSelectionPopoverView: View {
    var state: HorizontalSelectionDetailState
    var foregroundColor: Color
    var backgroundColor: Color
    var chrome: HorizontalSelectionInspectorChrome = .popover
    var isReadOnly = false
    var onChange: (HorizontalSelectionPropertyChange) -> Void

    @State private var currentObjects = [HorizontalObjectType: HorizontalSelectableRef]()
    @State private var applyAllProperties = Set<HorizontalSelectionApplyAllKey>()

    var body: some View {
        inspectorContent
            .padding(chrome == .popover ? 12 : 0)
            .frame(width: chrome == .popover ? 360 : nil, alignment: .leading)
            .frame(maxWidth: chrome == .sidebar ? .infinity : nil, alignment: .leading)
            .frame(maxHeight: chrome == .popover ? 520 : nil, alignment: .topLeading)
            .background {
                if chrome == .popover {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                }
            }
            .overlay {
                if chrome == .popover {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(foregroundColor.opacity(0.18), lineWidth: 0.7)
                }
            }
            .foregroundStyle(foregroundColor)
            .shadow(color: chrome == .popover ? .black.opacity(0.22) : .clear, radius: 12, y: 5)
    }

    private var inspectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if chrome == .popover {
                ScrollView {
                    inspectorRows
                }
                .scrollIndicators(.visible)
            } else {
                inspectorRows
            }
        }
    }

    private var inspectorRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hovered = state.hovered {
                hoverRow(hovered)
            }

            ForEach(state.groups) { group in
                if let item = currentItem(in: group) {
                    groupView(group, item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectionTitle)
                .font(headerTitleFont)
            Spacer()
            Text(selectionCountText)
                .font(countFont)
                .foregroundStyle(foregroundColor.opacity(0.58))
        }
    }

    private var headerTitleFont: Font {
        chrome == .sidebar ? .body.weight(.semibold) : .headline.weight(.semibold)
    }

    private var countFont: Font {
        chrome == .sidebar ? .body.monospacedDigit() : .caption.monospacedDigit()
    }

    private var eyebrowFont: Font {
        chrome == .sidebar ? .body.weight(.semibold) : .caption2.weight(.semibold)
    }

    private var objectTitleFont: Font {
        chrome == .sidebar ? .body.weight(.semibold) : .caption.weight(.semibold)
    }

    private var objectSubtitleFont: Font {
        chrome == .sidebar ? .body.monospaced() : .caption2.monospaced()
    }

    private var groupTitleFont: Font {
        chrome == .sidebar ? .body.weight(.semibold) : .subheadline.weight(.semibold)
    }

    private var detailLabelFont: Font {
        chrome == .sidebar ? .body.weight(.medium) : .caption2.weight(.medium)
    }

    private var detailValueFont: Font {
        chrome == .sidebar ? .body : .caption2
    }

    private var propertyLabelFont: Font {
        chrome == .sidebar ? .body.weight(.semibold) : .caption2.weight(.semibold)
    }

    private var propertyValueFont: Font {
        chrome == .sidebar ? .body : .caption
    }

    private var editorFont: Font {
        chrome == .sidebar ? .body : .caption
    }

    private var editorMonospacedFont: Font {
        chrome == .sidebar ? .body.monospacedDigit() : .caption.monospacedDigit()
    }

    private var selectionTitle: String {
        let typeCount = state.groups.count
        if typeCount == 1, let group = state.groups.first {
            return group.items.count == 1 ? group.title : group.pluralTitle
        }
        return "Selection"
    }

    private var selectionCountText: String {
        let count = state.groups.reduce(0) { $0 + $1.items.count }
        return "\(count) selected"
    }

    private func hoverRow(_ item: HorizontalSelectionHUDItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hover")
                .font(eyebrowFont)
                .foregroundStyle(foregroundColor.opacity(0.52))
            Text(item.title)
                .font(objectTitleFont)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(objectSubtitleFont)
                    .foregroundStyle(foregroundColor.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
    }

    private func groupView(_ group: HorizontalSelectionDetailGroup, item: HorizontalSelectionDetailItem) -> some View {
        let details = filteredDetails(item.details, properties: item.properties)
        let properties = filteredProperties(item.properties, details: item.details)
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
                .opacity(0.55)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.items.count == 1 ? group.title : group.pluralTitle)
                    .font(groupTitleFont)
                Spacer()
                objectSelector(group, currentItem: item)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(objectTitleFont)
            }

            if !details.isEmpty {
                detailsGrid(details)
            }

            if !properties.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(properties) { property in
                        propertyRow(property, group: group, item: item)
                    }
                }
            }
        }
    }

    private func filteredDetails(
        _ details: [HorizontalSelectionHUDDetail],
        properties: [HorizontalSelectionProperty]
    ) -> [HorizontalSelectionHUDDetail] {
        let editableDetailKeys = Set(
            properties
                .filter(\.isEditable)
                .flatMap(detailKeys(for:))
        )
        guard !editableDetailKeys.isEmpty else {
            return details
        }

        return details.filter { detail in
            !editableDetailKeys.contains(detailKey(for: detail.label))
        }
    }

    private func filteredProperties(
        _ properties: [HorizontalSelectionProperty],
        details: [HorizontalSelectionHUDDetail]
    ) -> [HorizontalSelectionProperty] {
        let detailKeys = Set(details.map { detailKey(for: $0.label) })
        guard !detailKeys.isEmpty else {
            return properties
        }

        return properties.filter { property in
            property.isEditable || !detailKeys.contains(detailKey(for: property.label))
        }
    }

    private func detailKeys(for property: HorizontalSelectionProperty) -> [String] {
        switch property.id {
        case "netClass":
            [detailKey(for: "Net class"), detailKey(for: "Class")]
        case "text" where property.label.caseInsensitiveCompare("Net name") == .orderedSame:
            [detailKey(for: "Net name"), detailKey(for: "Net")]
        case "plated":
            [detailKey(for: "Plated"), detailKey(for: "Plating")]
        case "keepoutClass":
            [detailKey(for: "Keepout class"), detailKey(for: "Class")]
        case "priority":
            [detailKey(for: "Priority"), detailKey(for: property.label)]
        default:
            [detailKey(for: property.label)]
        }
    }

    private func detailKey(for label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    @ViewBuilder
    private func objectSelector(
        _ group: HorizontalSelectionDetailGroup,
        currentItem: HorizontalSelectionDetailItem
    ) -> some View {
        if group.items.count > 1 {
            Menu {
                ForEach(group.items) { item in
                    Button {
                        currentObjects[group.type] = item.ref
                    } label: {
                        Text(item.title)
                    }
                }
            } label: {
                Text(objectPositionText(group, currentItem: currentItem))
                    .font(chrome == .sidebar ? .body.monospacedDigit() : .caption2.monospacedDigit())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func detailsGrid(_ details: [HorizontalSelectionHUDDetail]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(details) { detail in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(detail.label)
                        .font(detailLabelFont)
                        .foregroundStyle(foregroundColor.opacity(0.52))
                        .frame(width: 88, alignment: .leading)
                    detailValueView(for: detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailValueView(for detail: HorizontalSelectionHUDDetail) -> some View {
        if isDatasheetDetail(detail), let url = datasheetURL(detail.value) {
            Link(destination: url) {
                datasheetText(detail.value)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(detail.value)
        } else if isDatasheetDetail(detail) {
            datasheetText(detail.value)
                .foregroundStyle(foregroundColor.opacity(0.78))
        } else {
            Text(detail.value)
                .font(detailValueFont)
                .foregroundStyle(foregroundColor.opacity(0.78))
                .lineLimit(2)
        }
    }

    private func datasheetText(_ value: String) -> some View {
        Text(value)
            .font(detailValueFont)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func isDatasheetDetail(_ detail: HorizontalSelectionHUDDetail) -> Bool {
        detail.label.caseInsensitiveCompare("Datasheet") == .orderedSame
    }

    private func datasheetURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return nil
    }

    private func propertyRow(
        _ property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Text(property.label)
                .font(propertyLabelFont)
                .foregroundStyle(foregroundColor.opacity(0.66))
                .frame(width: chrome == .sidebar ? 120 : 78, alignment: .leading)
                .lineLimit(1)

            if property.isEditable && !isReadOnly {
                editor(for: property, group: group, item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(unitLabel(for: property))
                    .font(detailValueFont)
                    .foregroundStyle(foregroundColor.opacity(0.52))
                    .frame(width: 36, alignment: .leading)

                allToggle(for: property, group: group, item: item)

                removeButton(for: property, group: group, item: item)
            } else {
                Text(displayValue(property.value))
                    .font(propertyValueFont)
                    .foregroundStyle(foregroundColor.opacity(0.78))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func unitLabel(for property: HorizontalSelectionProperty) -> String {
        switch property.editor {
        case .length:
            "mm"
        case .angle:
            "deg"
        default:
            ""
        }
    }

    @ViewBuilder
    private func allToggle(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> some View {
        Toggle("All", isOn: applyAllBinding(for: property, group: group, item: item))
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(chrome == .sidebar ? .small : .mini)
            .disabled(group.items.count < 2)
            .help(
                group.items.count < 2
                    ? "Disabled because only one \(group.title.lowercased()) is selected"
                    : "Apply changes to all selected \(group.pluralTitle.lowercased())"
            )
    }

    /// The (X) remove button for rows carrying a `removeID` (added parameters).
    /// Sends the removal through the normal change funnel; with the row's
    /// "All" toggle on, the removal applies to every selected object of the
    /// group's type, like any other property change.
    @ViewBuilder
    private func removeButton(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> some View {
        if let removeID = property.removeID {
            Button {
                let key = HorizontalSelectionApplyAllKey(type: group.type, propertyID: property.id)
                onChange(HorizontalSelectionPropertyChange(
                    ref: item.ref,
                    type: group.type,
                    propertyID: removeID,
                    value: property.value,
                    applyToAll: applyAllProperties.contains(key)
                ))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(foregroundColor.opacity(0.42))
            }
            .buttonStyle(.plain)
            .controlSize(chrome == .sidebar ? .small : .mini)
            .help("Remove \(property.label)")
            .accessibilityLabel("Remove \(property.label)")
        }
    }

    @ViewBuilder
    private func editor(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> some View {
        switch property.editor {
        case .text:
            TextPropertyField(text: textBinding(for: property, group: group, item: item), font: editorFont)
        case .multilineText:
            TextPropertyField(text: textBinding(for: property, group: group, item: item), font: editorFont)
        case .bool:
            Toggle("", isOn: boolBinding(for: property, group: group, item: item))
                .labelsHidden()
                .controlSize(.small)
        case .length:
            NumericPropertyField(
                value: lengthDisplayValue(property),
                fractionDigits: 3,
                font: editorMonospacedFont
            ) { millimeters in
                sendChange(.length(millimeters * 1_000_000), property: property, group: group, item: item)
            }
        case .angle:
            NumericPropertyField(
                value: angleDisplayValue(property),
                fractionDigits: 1,
                font: editorMonospacedFont
            ) { degrees in
                sendChange(.angle(Int((degrees / 360.0) * 65_536.0)), property: property, group: group, item: item)
            }
        case .layer(let options):
            Picker("", selection: layerBinding(for: property, group: group, item: item)) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            // Keep dropdowns out of the Tab chain so tabbing moves directly
            // between the editable value fields without landing on (and risking a
            // stray change to) the layer / choice menu.
            .focusable(false)
        case .choice(let options):
            Picker("", selection: choiceBinding(for: property, group: group, item: item)) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .focusable(false)
        case .readOnly:
            EmptyView()
        }
    }

    private func currentItem(in group: HorizontalSelectionDetailGroup) -> HorizontalSelectionDetailItem? {
        if let ref = currentObjects[group.type],
           let item = group.items.first(where: { $0.ref == ref }) {
            return item
        }
        return group.items.first
    }

    private func objectPositionText(
        _ group: HorizontalSelectionDetailGroup,
        currentItem: HorizontalSelectionDetailItem
    ) -> String {
        let index = group.items.firstIndex(where: { $0.ref == currentItem.ref }) ?? 0
        return "\(index + 1) of \(group.items.count)"
    }

    private func applyAllBinding(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> Binding<Bool> {
        let key = HorizontalSelectionApplyAllKey(type: group.type, propertyID: property.id)
        return Binding {
            applyAllProperties.contains(key)
        } set: { enabled in
            if enabled {
                applyAllProperties.insert(key)
                sendChange(property.value, property: property, group: group, item: item)
            } else {
                applyAllProperties.remove(key)
            }
        }
    }

    private func textBinding(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> Binding<String> {
        Binding {
            if case .text(let value) = property.value {
                return value
            }
            if case .readOnly(let value) = property.value {
                return value
            }
            return displayValue(property.value)
        } set: { value in
            sendChange(.text(value), property: property, group: group, item: item)
        }
    }

    private func boolBinding(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> Binding<Bool> {
        Binding {
            if case .bool(let value) = property.value {
                return value
            }
            return false
        } set: { value in
            sendChange(.bool(value), property: property, group: group, item: item)
        }
    }

    private func lengthDisplayValue(_ property: HorizontalSelectionProperty) -> Double {
        if case .length(let value) = property.value {
            return value / 1_000_000
        }
        return 0
    }

    private func angleDisplayValue(_ property: HorizontalSelectionProperty) -> Double {
        if case .angle(let value) = property.value {
            return Double(value) / 65_536.0 * 360.0
        }
        return 0
    }

    private func layerBinding(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> Binding<String> {
        Binding {
            if case .layer(let value) = property.value {
                return value.map(String.init) ?? "none"
            }
            return "none"
        } set: { value in
            sendChange(.layer(Int(value)), property: property, group: group, item: item)
        }
    }

    private func choiceBinding(
        for property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) -> Binding<String> {
        Binding {
            if case .choice(let value) = property.value {
                return value
            }
            return ""
        } set: { value in
            sendChange(.choice(value), property: property, group: group, item: item)
        }
    }

    private func sendChange(
        _ value: HorizontalSelectionPropertyValue,
        property: HorizontalSelectionProperty,
        group: HorizontalSelectionDetailGroup,
        item: HorizontalSelectionDetailItem
    ) {
        let key = HorizontalSelectionApplyAllKey(type: group.type, propertyID: property.id)
        onChange(HorizontalSelectionPropertyChange(
            ref: item.ref,
            type: group.type,
            propertyID: property.id,
            value: value,
            applyToAll: applyAllProperties.contains(key)
        ))
    }

    private func displayValue(_ value: HorizontalSelectionPropertyValue) -> String {
        switch value {
        case .text(let value), .choice(let value), .readOnly(let value):
            return value
        case .bool(let value):
            return value ? "Yes" : "No"
        case .length(let value):
            return lengthString(value)
        case .angle(let value):
            let degrees = Double(value) / 65_536.0 * 360.0
            return degrees.formatted(.number.precision(.fractionLength(1))) + " deg"
        case .layer(let value):
            return value.map(String.init) ?? "None"
        }
    }

    private func lengthString(_ value: Double) -> String {
        let millimeters = value / 1_000_000
        if millimeters >= 1 {
            return millimeters.formatted(.number.precision(.fractionLength(2))) + " mm"
        }
        return (millimeters * 1_000).formatted(.number.precision(.fractionLength(0))) + " um"
    }
}

/// A numeric text field backed by a local string buffer. Unlike
/// `TextField(value:format:)`, the displayed text is only re-synced from the
/// model when the field is NOT focused, so a re-render mid-edit (which the board
/// canvas triggers frequently) can't wipe a half-typed value — the bug where a
/// width starting at 0 could never be changed. Commits on Return or focus loss.
private struct NumericPropertyField: View {
    let value: Double
    let fractionDigits: Int
    let font: Font
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    /// The last value pushed to the model, so the Return path (onSubmit) and the
    /// focus-loss path don't both fire `onCommit` for the same value.
    @State private var lastCommitted: Double = .nan
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .focused($focused)
            .onAppear {
                text = Self.format(value, fractionDigits)
                lastCommitted = value
            }
            .onChange(of: value) { _, newValue in
                lastCommitted = newValue
                if !focused {
                    text = Self.format(newValue, fractionDigits)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commit()
                }
            }
            .onSubmit {
                commit()
                // macOS resigns first responder on Return; re-assert focus on the
                // next runloop tick so the cursor stays in the field.
                DispatchQueue.main.async { focused = true }
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            // Reject invalid input by restoring the model value.
            text = Self.format(value, fractionDigits)
            return
        }
        text = Self.format(parsed, fractionDigits)
        if parsed != lastCommitted {
            lastCommitted = parsed
            onCommit(parsed)
        }
    }

    private static func format(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
}

/// A sidebar text field that keeps the cursor in place when the user presses
/// Return (macOS otherwise resigns first responder). Commits live through the
/// bound string, same as a plain TextField.
private struct TextPropertyField: View {
    @Binding var text: String
    let font: Font

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(font)
            .lineLimit(1)
            .focused($focused)
            .onSubmit {
                DispatchQueue.main.async { focused = true }
            }
    }
}
