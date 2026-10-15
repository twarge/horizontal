import SwiftUI

/// The Pools pane's parametric bar, under its toolbar and opened by the
/// disclosure triangle at the toolbar's left (130): Horizon's parametric
/// search (`PoolBrowserParametric`). Choosing one of the pools' parametric
/// tables (resistors, capacitors, inductors) narrows the list to that table's
/// parts and grows a filter box for each of its columns and for manufacturer
/// and package, side by side, listing the values still left among the parts
/// shown. Search applies what the boxes choose, and the filters applied so
/// far stay with the controls on the bar's left.
struct HorizontalPoolParametricFilterView: View {
    var tables: [HorizontalParametricTable]
    @Binding var tableName: String?
    var columns: [HorizontalParametricFilterColumn]
    var valuesRemaining: [String: [String]]
    @Binding var filters: HorizontalParametricFilters

    static let controlsWidth: CGFloat = 190
    static let boxWidth: CGFloat = 150
    static let boxListHeight: CGFloat = 112

    private var table: HorizontalParametricTable? {
        tableName.flatMap { name in tables.first { $0.name == name } }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Table", selection: $tableName) {
                    Text("All Parts").tag(String?.none)
                    if !tables.isEmpty {
                        Divider()
                    }
                    ForEach(tables) { table in
                        Text(table.displayName).tag(Optional(table.name))
                    }
                }
                .labelsHidden()
                .help("A parametric table narrows the list to its parts and filters them by value, as Horizon's parametric search does")

                if let table {
                    filterControls(table)
                } else {
                    Text(tables.isEmpty
                         ? "The browsed pools have no parametric tables."
                         : "Choose a table to filter its parts by value, package and manufacturer.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: Self.controlsWidth, alignment: .topLeading)

            if table != nil {
                Divider()
                filterBoxes
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func filterControls(_ table: HorizontalParametricTable) -> some View {
        HStack(spacing: 8) {
            Button("Search") {
                filters.apply()
            }
            .disabled(!filters.hasPending)
            .help("Apply the values chosen below (or double-click one)")
            Button("Reset") {
                filters.reset()
            }
            .disabled(filters.applied.isEmpty && !filters.hasPending)
            .help("Take every filter off")
        }
        .controlSize(.small)

        if !filters.applied.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(columns.filter { filters.applied[$0.name] != nil }) { column in
                    appliedFilter(column, values: filters.applied[column.name] ?? [])
                }
            }
        }
    }

    /// The boxes in a row, scrolling sideways when the pane is narrower than
    /// they are.
    @ViewBuilder
    private var filterBoxes: some View {
        let boxes = columns.filter { (valuesRemaining[$0.name]?.count ?? 0) > 1 }
        if boxes.isEmpty {
            Text("Every part shown has the same values.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(boxes) { column in
                        filterBox(column, values: valuesRemaining[column.name] ?? [])
                            .frame(width: Self.boxWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `FilterAppliedLabel`: the column and how many values it allows, the
    /// values in its help, and a button that takes it off.
    private func appliedFilter(_ column: HorizontalParametricFilterColumn, values: Set<String>) -> some View {
        HStack(spacing: 4) {
            Text("\(column.displayName) (\(values.count))")
                .font(.callout)
                .lineLimit(1)
            Button {
                filters.remove(column.name)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove the \(column.displayName) filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(values.sorted(by: column.precedes).map(column.format).joined(separator: "\n"))
    }

    /// `ParametricFilterBox`: the column's values among the parts shown,
    /// several of which can be chosen at once.
    private func filterBox(_ column: HorizontalParametricFilterColumn, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(column.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            List(selection: Binding(
                get: { filters.pending[column.name] ?? [] },
                set: { filters.pending[column.name] = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(values, id: \.self) { value in
                    HorizontalParametricValueText(column: column, value: value)
                        .tag(value)
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { selection in
                filters.pending[column.name] = selection
                filters.apply()
            }
            #if os(macOS)
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.enabled)
            #else
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            #endif
            .frame(height: Self.boxListHeight)
        }
    }
}

/// A parametric value as Horizon's columns draw it: a quantity's number in
/// tabular digits, then its prefix and unit (`create_tvc`), anything else as
/// its text.
struct HorizontalParametricValueText: View {
    var column: HorizontalParametricFilterColumn
    var value: String

    var body: some View {
        let formatted = column.format(value)
        if column.isQuantity, let space = formatted.firstIndex(of: " ") {
            HStack(spacing: 3) {
                Text(formatted[..<space])
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                Text(formatted[formatted.index(after: space)...])
            }
            .lineLimit(1)
        } else {
            Text(formatted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
