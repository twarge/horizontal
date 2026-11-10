import SwiftUI

/// The board's selection filter in the rail's Selection popover: a switch
/// for each kind of object a click or a box can pick (`BoardSelectionFilter`),
/// with All, and an Only on each to pick that kind alone.
struct BoardSelectionFilterSection: View {
    @Binding var filter: BoardSelectionFilter

    var body: some View {
        LayerControlSection(title: "Selects") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(BoardSelectionKind.allCases) { kind in
                    HStack(spacing: 6) {
                        Toggle(kind.title, isOn: binding(for: kind))
                        Spacer(minLength: 8)
                        Button("Only") {
                            filter.only(kind)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Select \(kind.title.lowercased()) alone")
                    }
                }
                Button("All") {
                    filter.excluded = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!filter.isFiltering)
            }
            Text(filter.isFiltering
                 ? "A click, a box and Select All pick only the kinds switched on."
                 : "A click, a box and Select All pick every kind.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(for kind: BoardSelectionKind) -> Binding<Bool> {
        Binding {
            filter.admits(kind)
        } set: { admitted in
            filter.set(kind, admitted: admitted)
        }
    }
}
