import SwiftUI

/// What the Edit Custom Value dialog edits: one drawn symbol and the
/// component it draws.
struct HorizontalCustomValueEditTarget: Identifiable {
    var ref: HorizontalSelectableRef
    var details: HorizontalComponentDetails
    var customValue: String?
    var id: String { ref.id }
}

/// Horizon's Edit Custom Value dialog (`EditCustomValueDialog`): what a
/// symbol's `$VALUE` text draws in place of the value. Three columns: rows
/// that insert a variable at the cursor, the text, and what it draws.
struct HorizontalCustomValueSheet: View {
    var target: HorizontalCustomValueEditTarget
    var isReadOnly: Bool
    /// The value to store (nil clears it), once OK is pressed.
    var onCommit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var editorFocused: Bool

    private var insertions: [HorizontalSymbolCustomValue.Insertion] {
        HorizontalSymbolCustomValue.insertions(for: target.details)
    }

    private var preview: String {
        HorizontalSymbolCustomValue.drawnValue(customValue: HorizontalSymbolCustomValue.normalized(text), details: target.details)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Custom Value").font(.headline)
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                insertColumn
                    .frame(width: 210)
                Divider()
                column("Edit") {
                    TextEditor(text: $text, selection: $selection)
                        .font(.body.monospaced())
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .disabled(isReadOnly)
                }
                .frame(minWidth: 220, maxWidth: .infinity)
                Divider()
                column("Preview") {
                    ScrollView {
                        Text(preview.isEmpty ? " " : preview)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                }
                .frame(minWidth: 180, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text("Leave it empty to draw the value again.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    onCommit(HorizontalSymbolCustomValue.committedValue(edited: text, stored: target.customValue))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isReadOnly)
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 380, idealHeight: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .onAppear {
            text = HorizontalSymbolCustomValue.editorText(target.customValue)
            selection = TextSelection(insertionPoint: text.endIndex)
            editorFocused = true
        }
    }

    private var subtitle: String {
        var parts = [target.details.displayLabel]
        if let mpn = target.details.mpn, !mpn.isEmpty { parts.append(mpn) }
        return parts.joined(separator: " · ")
            + ": what the symbol's value text draws. ${value}, ${mpn} and the rest are filled in from the component and its part."
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(10)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var insertColumn: some View {
        column("Insert") {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(insertions) { row in
                        Button {
                            insert(row.text)
                        } label: {
                            HStack(spacing: 6) {
                                if !row.prefix.isEmpty {
                                    Text(row.prefix).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(row.label).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isReadOnly)
                        .help("Insert \(row.text.trimmingCharacters(in: .newlines))")
                        Divider()
                    }
                }
            }
        }
    }

    /// Puts `snippet` where the cursor is (over the selection, if any), as
    /// Horizon's list rows do, and leaves the cursor after it.
    private func insert(_ snippet: String) {
        let utf16Count = text.utf16.count
        var lower = utf16Count
        var upper = utf16Count
        if let selection, case .selection(let range) = selection.indices {
            lower = min(max(range.lowerBound.utf16Offset(in: text), 0), utf16Count)
            upper = min(max(range.upperBound.utf16Offset(in: text), lower), utf16Count)
        }
        let (edited, cursor) = HorizontalSymbolCustomValue.inserting(snippet, into: text, utf16Range: lower..<upper)
        text = edited
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: cursor, in: edited))
        editorFocused = true
    }
}
