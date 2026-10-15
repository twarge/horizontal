import Foundation

/// A column a parametric search filters on: one of the table's, or one of
/// the two Horizon adds to every table, manufacturer and package
/// (`PoolParametric::get_extra_columns`), which are plain text.
struct HorizontalParametricFilterColumn: Identifiable, Hashable {
    static let manufacturerName = "_manufacturer"
    static let packageName = "_package"

    var name: String
    var displayName: String
    /// The table's column, nil for the two extra ones.
    var column: HorizontalParametricColumn?

    var id: String { name }

    static let manufacturer = HorizontalParametricFilterColumn(name: manufacturerName, displayName: "Manufacturer")
    static let package = HorizontalParametricFilterColumn(name: packageName, displayName: "Package")

    init(name: String, displayName: String, column: HorizontalParametricColumn? = nil) {
        self.name = name
        self.displayName = displayName
        self.column = column
    }

    init(_ column: HorizontalParametricColumn) {
        self.init(name: column.name, displayName: column.displayName, column: column)
    }

    var isQuantity: Bool {
        column?.kind == .quantity
    }

    /// `Column::format`: "N/A" for no value, a quantity with its prefix and
    /// unit, the rest as it is.
    func format(_ value: String) -> String {
        if let column {
            return column.format(value)
        }
        return value.isEmpty ? "N/A" : value
    }

    /// The order of a filter box's values (`ParametricFilterBox`'s sort
    /// functions): no value first, then quantities by number and everything
    /// else in natural order.
    func precedes(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty {
            return a.isEmpty && !b.isEmpty
        }
        if isQuantity {
            return HorizontalPoolParametricTables.leadingNumber(a) < HorizontalPoolParametricTables.leadingNumber(b)
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }
}

/// One part as a parametric table holds it.
struct HorizontalParametricRow: Identifiable, Hashable {
    var item: HorizontalPoolLibraryItem
    var packageName: String
    /// Each table column's value as the table stores it: a quantity as a
    /// number, written as Swift writes a `Double`, so 4.7e3 and 4700 are one
    /// value, as they are one number in Horizon's database; "" for none.
    var values: [String: String]

    var id: String { item.id }

    /// A column's value, the two extra columns included.
    func value(_ column: String) -> String {
        switch column {
        case HorizontalParametricFilterColumn.manufacturerName: item.manufacturer
        case HorizontalParametricFilterColumn.packageName: packageName
        default: values[column] ?? ""
        }
    }
}

/// Horizon's parametric search (`PoolBrowserParametric`): the parts of one
/// parametric table, narrowed column by column to the values chosen for
/// each, with the values still left in every column to choose from.
enum HorizontalPoolParametricSearch {
    /// The extra columns, then the table's, as Horizon lays out its filter
    /// boxes.
    static func filterColumns(of table: HorizontalParametricTable) -> [HorizontalParametricFilterColumn] {
        [.manufacturer, .package] + table.columns.map(HorizontalParametricFilterColumn.init)
    }

    /// The parts among `items` the table holds, as the pool update fills it
    /// (`PoolUpdaterParametric::update_part`): a part naming the table, unless
    /// one of its values doesn't fit its column, a quantity that isn't wholly
    /// a number or an enum value the column doesn't list, which leaves the
    /// part out. A value the part doesn't give is "", required or not.
    static func rows(
        _ items: [HorizontalPoolLibraryItem],
        table: HorizontalParametricTable,
        packageName: (String) -> String
    ) -> [HorizontalParametricRow] {
        items.compactMap { item -> HorizontalParametricRow? in
            guard item.category == .part, item.parametric["table"] == table.name else {
                return nil
            }
            var values = [String: String]()
            for column in table.columns {
                let raw = item.parametric[column.name] ?? ""
                guard !raw.isEmpty else {
                    values[column.name] = ""
                    continue
                }
                switch column.kind {
                case .quantity:
                    guard let number = storedNumber(raw) else { return nil }
                    values[column.name] = String(number)
                case .enumeration:
                    guard column.items.contains(raw) else { return nil }
                    values[column.name] = raw
                }
            }
            return HorizontalParametricRow(item: item, packageName: packageName(item.packageID), values: values)
        }
    }

    /// A quantity as the pool update reads it, `istringstream >> double` to
    /// the end of the text: leading space allowed, nothing after the number.
    static func storedNumber(_ raw: String) -> Double? {
        let text = raw.drop(while: \.isWhitespace)
        guard !text.isEmpty, text.allSatisfy({ "0123456789+-.eE".contains($0) }) else {
            return nil
        }
        return Double(text)
    }

    /// The rows every filter lets through: for each filtered column, a row
    /// whose value is one of the chosen ones (the search's `IN` clauses).
    static func filter(_ rows: [HorizontalParametricRow], by filters: [String: Set<String>]) -> [HorizontalParametricRow] {
        let active = filters.filter { !$0.value.isEmpty }
        guard !active.isEmpty else {
            return rows
        }
        return rows.filter { row in
            active.allSatisfy { column, values in values.contains(row.value(column)) }
        }
    }

    /// Every column's distinct values among `rows`, in its filter box's
    /// order (`values_remaining`).
    static func valuesRemaining(
        _ rows: [HorizontalParametricRow],
        columns: [HorizontalParametricFilterColumn]
    ) -> [String: [String]] {
        var result = [String: [String]]()
        for column in columns {
            result[column.name] = Set(rows.map { $0.value(column.name) }).sorted(by: column.precedes)
        }
        return result
    }
}

/// A parametric search's filters, as Horizon's filter boxes work them: the
/// values chosen in each column's box wait (`pending`) until Search applies
/// them, or a double-click on one does. Applying a box's values replaces
/// that column's filter and clears every box (`apply_filters`); each applied
/// filter can be taken off on its own, and Reset takes them all off.
struct HorizontalParametricFilters: Equatable {
    var pending: [String: Set<String>] = [:]
    var applied: [String: Set<String>] = [:]

    var hasPending: Bool {
        pending.values.contains { !$0.isEmpty }
    }

    mutating func apply() {
        for (column, values) in pending where !values.isEmpty {
            applied[column] = values
        }
        pending = [:]
    }

    mutating func remove(_ column: String) {
        pending[column] = nil
        applied[column] = nil
    }

    mutating func reset() {
        pending = [:]
        applied = [:]
    }
}

/// The parametric list's sort: Horizon orders it in its database, by one
/// column with natural collation (`SortController::get_order_by`). A
/// quantity sorts by number there, and a part without one ("", text) after
/// every number; text sorts naturally, "" first. Ties keep MPN order.
struct HorizontalParametricRowComparator: SortComparator, Hashable {
    static let mpn = "_mpn"
    static let pool = "_pool"

    /// The column: `mpn`, `pool`, an extra column's name or a table column's.
    var key: String
    var isQuantity = false
    var order: SortOrder = .forward

    func compare(_ lhs: HorizontalParametricRow, _ rhs: HorizontalParametricRow) -> ComparisonResult {
        let result = ascending(lhs, rhs)
        return order == .forward ? result : result.reversed
    }

    private func ascending(_ lhs: HorizontalParametricRow, _ rhs: HorizontalParametricRow) -> ComparisonResult {
        let primary: ComparisonResult
        switch key {
        case Self.mpn:
            primary = lhs.item.name.localizedStandardCompare(rhs.item.name)
        case Self.pool:
            primary = lhs.item.poolsLabel.localizedStandardCompare(rhs.item.poolsLabel)
        default:
            let a = lhs.value(key), b = rhs.value(key)
            if isQuantity {
                switch (a.isEmpty, b.isEmpty) {
                case (true, true): primary = .orderedSame
                case (true, false): primary = .orderedDescending
                case (false, true): primary = .orderedAscending
                case (false, false):
                    let x = HorizontalPoolParametricTables.leadingNumber(a), y = HorizontalPoolParametricTables.leadingNumber(b)
                    primary = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
                }
            } else {
                primary = a.localizedStandardCompare(b)
            }
        }
        guard primary == .orderedSame else {
            return primary
        }
        let byName = lhs.item.name.localizedStandardCompare(rhs.item.name)
        return byName == .orderedSame ? lhs.item.id.compare(rhs.item.id) : byName
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
