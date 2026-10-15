import SwiftUI

/// The Pools pane's parametric section, on the left of the parts list behind
/// a disclosure triangle: Horizon's parametric search
/// (`PoolBrowserParametric`). Choosing one of the pools' parametric tables
/// (resistors, capacitors, inductors) narrows the list to that table's parts
/// and grows a filter box for each of its columns and for manufacturer and
/// package, listing the values still left among the parts shown, with the
/// filters applied so far above them.
struct HorizontalPoolParametricFilterView: View {
    @Binding var isExpanded: Bool
    var tables: [HorizontalParametricTable]
    @Binding var tableName: String?
    var columns: [HorizontalParametricFilterColumn]
    var valuesRemaining: [String: [String]]
    @Binding var filters: HorizontalParametricFilters

    static let expandedWidth: CGFloat = 230

    private var table: HorizontalParametricTable? {
        tableName.flatMap { name in tables.first { $0.name == name } }
    }

    var body: some View {
        if isExpanded {
            expanded
                .frame(width: Self.expandedWidth)
        } else {
            collapsed
        }
    }

    /// The triangle, and a filter mark while a table narrows the list.
    private var collapsed: some View {
        VStack(spacing: 10) {
            disclosureButton
            if table != nil {
                Image(systemName: filters.applied.isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Showing \(table?.displayName ?? "") only\(filters.applied.isEmpty ? "" : ", filtered")")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(width: 24)
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the parametric filters" : "Show the parametric filters")
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                disclosureButton
                Text("Parametric")
                    .font(.headline)
                Spacer(minLength: 0)
            }

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
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
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

        let boxes = columns.filter { (valuesRemaining[$0.name]?.count ?? 0) > 1 }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(boxes) { column in
                    filterBox(column, values: valuesRemaining[column.name] ?? [])
                }
                if boxes.isEmpty {
                    Text("Every part shown has the same values.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
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
            .frame(height: min(150, CGFloat(values.count) * 24 + 8))
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
