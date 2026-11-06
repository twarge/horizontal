import SwiftUI

/// Picks one of the board's nets — Horizon's select-net dialog, which Set
/// Net… and Place Via… open. A board can have hundreds, so a search field
/// narrows the list, and a double-click or Return takes the one selected.
struct HorizontalNetPickerSheet: View {
    var title: String
    var message: String
    var confirmTitle: String
    var nets: [HorizontalSelectionPropertyOption]
    var onPick: (String) -> Void
    var onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedID: String?

    private var filtered: [HorizontalSelectionPropertyOption] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard !terms.isEmpty else {
            return nets
        }
        return nets.filter { net in
            terms.allSatisfy(net.title.lowercased().contains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            Divider()
            Table(filtered, selection: $selectedID) {
                TableColumn("Net") { net in
                    Text(net.title).lineLimit(1)
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { selection in
                if let id = selection.first {
                    onPick(id)
                }
            }
            Divider()
            HStack {
                Text("\(filtered.count) nets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    if let selectedID {
                        onPick(selectedID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID.map { id in filtered.contains { $0.id == id } } != true)
            }
            .padding(12)
        }
        .frame(minWidth: 360, minHeight: 380)
        .onChange(of: searchText) { _, _ in
            // What the search leaves is what Return takes: the selection
            // follows it to the first match when it hides the one selected.
            if !filtered.contains(where: { $0.id == selectedID }) {
                selectedID = filtered.first?.id
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = nets.first?.id
            }
        }
    }
}
