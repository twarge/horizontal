import Foundation

/// A pool's `tables.json`: the parametric tables parts can belong to
/// (resistors, capacitors…), each with typed columns. Values live on the
/// part as strings under `parametric` (`table` names the table).
struct HorizontalParametricColumn: Hashable, Identifiable {
    enum Kind: String, Hashable {
        case quantity
        case enumeration = "enum"
    }

    var name: String
    var displayName: String
    var kind: Kind
    var required = true
    var unit = ""
    var digits = 3
    var usesSI = true
    var noMilli = false
    var items: [String] = []

    var id: String { name }

    init?(json: JSONDictionary) {
        guard let name = json.string("name"), let kindRaw = json.string("type"),
              let kind = Kind(rawValue: kindRaw) else {
            return nil
        }
        self.name = name
        displayName = json.string("display_name") ?? name
        self.kind = kind
        required = json.bool("required") ?? true
        unit = json.string("unit") ?? ""
        digits = json.int("digits") ?? 3
        usesSI = json.bool("use_si") ?? true
        noMilli = json.bool("no_milli") ?? false
        items = (json["items"] as? [String]) ?? []
    }

    /// `PoolParametric::Column::format(const std::string &)`: "N/A" for no
    /// value, a quantity read as a number (0 when it isn't one, as
    /// `istringstream` leaves it) and formatted, anything else as stored.
    func format(_ raw: String) -> String {
        if raw.isEmpty {
            return "N/A"
        }
        guard kind == .quantity else {
            return raw
        }
        return HorizontalPoolParametricTables.formatQuantity(
            HorizontalPoolParametricTables.leadingNumber(raw), unit: unit, digits: digits, usesSI: usesSI, noMilli: noMilli
        )
    }
}

struct HorizontalParametricTable: Hashable, Identifiable {
    var name: String
    var displayName: String
    var columns: [HorizontalParametricColumn]

    var id: String { name }

    init?(name: String, json: JSONDictionary) {
        self.name = name
        displayName = json.string("display_name") ?? name
        columns = json.dictionaryArray("columns").compactMap(HorizontalParametricColumn.init(json:))
    }
}

enum HorizontalPoolParametricTables {
    /// The tables of every pool in `poolURLs`, later pools overriding
    /// earlier ones by name (pass the item's own pool last).
    static func load(poolURLs: [URL]) -> [HorizontalParametricTable] {
        var byName = [String: HorizontalParametricTable]()
        var order = [String]()
        for poolURL in poolURLs {
            let url = poolURL.appendingPathComponent("tables.json")
            guard let json = try? JSONHelper.loadDictionary(from: url) else {
                continue
            }
            for (name, tableJSON) in json.dictionaryMap("tables") {
                guard let table = HorizontalParametricTable(name: name, json: tableJSON) else {
                    continue
                }
                if byName[name] == nil {
                    order.append(name)
                }
                byName[name] = table
            }
        }
        return order.compactMap { byName[$0] }.sorted { $0.displayName < $1.displayName }
    }

    private static let prefixes: [(exponent: Int, symbol: String)] = [
        (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"), (0, ""), (3, "k"), (6, "M"), (9, "G"), (12, "T"),
    ]

    /// `PoolParametric::Column::format(double)`. With `use_si` the value is
    /// scaled to an SI prefix and printed fixed to `digits` places, trailing
    /// zeros kept ("4.70 kΩ"); without, `digits` is significant digits, as
    /// `%g` prints them. A `no_milli` column turns milli into micro below 100
    /// and into the plain unit from 100 up. The number, a space, then the
    /// prefix and unit, even when both are empty. Horizon prints with the
    /// classic locale but the user's decimal separator, and so does this.
    static func formatQuantity(_ value: Double, unit: String, digits: Int, usesSI: Bool, noMilli: Bool,
                               decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String {
        let negative = value < 0
        var magnitude = abs(value)
        var exponent = 0
        if usesSI {
            // Horizon's loop runs to 10^15, which has no prefix and throws;
            // this stops at tera.
            while magnitude >= 1e3, exponent < 12 {
                magnitude /= 1e3
                exponent += 3
            }
            if magnitude > 1e-15 {
                while magnitude < 1, exponent >= -12 {
                    magnitude *= 1e3
                    exponent -= 3
                }
            }
        }
        if exponent == -3, noMilli {
            if magnitude < 100 {
                magnitude *= 1e3
                exponent -= 3
            } else {
                magnitude /= 1e3
                exponent += 3
            }
        }
        let prefix = prefixes.first { $0.exponent == exponent }?.symbol ?? ""
        let precision = digits >= 0 ? digits : 6
        var number = String(format: usesSI ? "%.\(precision)f" : "%.\(precision)g", magnitude)
        if decimalSeparator != "." {
            number = number.replacingOccurrences(of: ".", with: decimalSeparator)
        }
        return (negative ? "-" : "") + number + " " + prefix + unit
    }

    /// The number a stored value starts with, read as `istringstream` with
    /// the classic locale reads it; 0 when there is none.
    static func leadingNumber(_ text: String) -> Double {
        let scanner = Scanner(string: text)
        scanner.locale = nil
        return scanner.scanDouble() ?? 0
    }

    /// Parses a typed quantity ("4.7k", "10 µ", "22n", "1M") into a plain
    /// number, the form stored on the part.
    static func parseQuantity(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        // Strip a trailing unit word (Ω, F, H, W, V, A, %…) but keep the prefix.
        var multiplier = 1.0
        while let last = trimmed.last, !last.isNumber {
            let symbol = String(last)
            if let prefix = prefixes.first(where: { $0.symbol == symbol || ($0.symbol == "µ" && (symbol == "u" || symbol == "μ")) }),
               !prefix.symbol.isEmpty || symbol == "u" {
                multiplier = pow(10, Double(prefix.exponent))
                trimmed.removeLast()
                break
            }
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        // A prefix may sit before a unit ("4.7kΩ"): after removing the unit,
        // try once more for the prefix.
        if multiplier == 1, let last = trimmed.last, !last.isNumber {
            let symbol = String(last)
            if let prefix = prefixes.first(where: { $0.symbol == symbol || ($0.symbol == "µ" && (symbol == "u" || symbol == "μ")) }) {
                multiplier = pow(10, Double(prefix.exponent))
                trimmed.removeLast()
            }
        }
        guard let number = Double(trimmed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        return number * multiplier
    }

    /// The stored spelling of a quantity: an integer when whole, else the
    /// shortest decimal.
    static func storedQuantity(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}
