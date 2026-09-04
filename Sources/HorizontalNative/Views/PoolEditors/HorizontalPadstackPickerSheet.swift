import SwiftUI

/// "Place Pad" starts by choosing a padstack — Horizon's `select_padstack`
/// dialog. The package's own padstacks come first, then the pool's pad-type
/// padstacks; a search field narrows the list.
struct HorizontalPadstackPickerSheet: View {
    var choices: [HorizontalPoolPadstackInfo]
    var onPick: (String) -> Void
    var onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedID: String?

    private var filtered: [HorizontalPoolPadstackInfo] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard !terms.isEmpty else {
            return choices
        }
        return choices.filter { choice in
            let haystack = (choice.name + " " + choice.type).lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Padstack")
                    .font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            .padding(12)
            Divider()
            Table(filtered, selection: $selectedID) {
                TableColumn("Name") { choice in
                    HStack {
                        Text(choice.name).lineLimit(1)
                        if choice.isPackageLocal {
                            Text("package")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Type") { choice in
                    Text(choice.type.capitalized)
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { selection in
                if let id = selection.first {
                    onPick(id)
                }
            }
            Divider()
            HStack {
                Text("\(filtered.count) padstacks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Place") {
                    if let selectedID {
                        onPick(selectedID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear {
            if selectedID == nil {
                selectedID = choices.first?.id
            }
        }
    }
}
