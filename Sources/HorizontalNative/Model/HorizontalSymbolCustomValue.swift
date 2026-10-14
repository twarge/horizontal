import Foundation

/// One of a part's parametric values as a custom value shows it: Horizon's
/// `Part::parametric_formatted`, the value formatted by its column in the
/// pool's parametric table (`1e-06` reads `1 µF`) under the column's display
/// name.
struct HorizontalParametricField: Hashable {
    /// The column name, lowercased, as `${p:<key>}` names it.
    var key: String
    var displayName: String
    var value: String
}

/// A schematic symbol's custom value: the text that replaces what its
/// `$VALUE` text draws, with `${value}`, `${mpn}`, `${mfr}`, `${desc}`,
/// `${pkg}` and `${p:<column>}` filled in from the component and its part —
/// Horizon's `SchematicSymbol::get_custom_value`. The sheet loader, the
/// canvas, MCP and the Edit Custom Value dialog all go through here, so what
/// the dialog previews is what the sheet draws.
enum HorizontalSymbolCustomValue {
    /// What the editor starts from when a symbol has no custom value yet
    /// (`EditCustomValueDialog`).
    static let initialText = "${value}\n"

    /// A row of the dialog's Insert list: inserting `text` at the cursor.
    struct Insertion: Identifiable, Hashable {
        /// "Param:" for a parametric value, otherwise empty.
        var prefix: String
        var label: String
        var text: String
        var id: String { text }
    }

    /// Horizon's Insert list: the value, and for a component with a part its
    /// MPN, manufacturer, description, package and each parametric value.
    static func insertions(for details: HorizontalComponentDetails) -> [Insertion] {
        var rows = [Insertion(prefix: "", label: "Value", text: "${value}\n")]
        guard details.partID != nil else {
            return rows
        }
        rows += [
            Insertion(prefix: "", label: "MPN", text: "${mpn}\n"),
            Insertion(prefix: "", label: "Manufacturer", text: "${mfr}\n"),
            Insertion(prefix: "", label: "Description", text: "${desc}\n"),
            Insertion(prefix: "", label: "Package", text: "${pkg}\n"),
        ]
        rows += details.parametricFields.map {
            Insertion(prefix: "Param:", label: $0.displayName, text: "${p:\($0.key)}\n")
        }
        return rows
    }

    /// The text the editor opens with: the custom value, or `${value}` and a
    /// line break to build on when there is none.
    static func editorText(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else {
            return initialText
        }
        return stored
    }

    /// What is stored for an edited text: trimmed, as Horizon trims it, and
    /// nil (no custom value) when nothing is left.
    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// What OK stores for the editor's `edited` text, given what the symbol
    /// had. Trimmed, and nothing when the editor was left on the `${value}`
    /// it opens with for a symbol that had none: that draws what no custom
    /// value draws, and storing it would be an edit nobody made.
    static func committedValue(edited: String, stored: String?) -> String? {
        let value = normalized(edited)
        if normalized(stored) == nil, value == normalized(initialText) {
            return nil
        }
        return value
    }

    /// `text` with `snippet` put in place of the UTF-16 range (the cursor
    /// when it is empty), and the UTF-16 offset just after it — how the
    /// dialog's Insert rows add a variable where the cursor is.
    static func inserting(_ snippet: String, into text: String, utf16Range: Range<Int>) -> (text: String, cursor: Int) {
        let utf16 = Array(text.utf16)
        let lower = min(max(utf16Range.lowerBound, 0), utf16.count)
        let upper = min(max(utf16Range.upperBound, lower), utf16.count)
        let edited = String(decoding: utf16[..<lower] + Array(snippet.utf16) + utf16[upper...], as: UTF16.self)
        return (edited, lower + snippet.utf16.count)
    }

    /// What a symbol's `$VALUE` text draws: its custom value filled in, or the
    /// component's value when it has none.
    static func drawnValue(customValue: String?, details: HorizontalComponentDetails?) -> String {
        guard let details else {
            return ""
        }
        // As stored: what the editor writes is already trimmed, and a file
        // written some other way draws the way Horizon draws it.
        guard let customValue, normalized(customValue) != nil else {
            return details.value
        }
        return interpolate(customValue, details: details)
    }

    /// `SchematicSymbol::get_custom_value`. Variables are matched without
    /// regard to case. Without a part, the part's fields read "None"; a
    /// variable that names nothing, or a parametric column the part does not
    /// have, stays as written.
    static func interpolate(_ text: String, details: HorizontalComponentDetails) -> String {
        let hasPart = details.partID != nil
        return interpolateText(text) { variable in
            let key = variable.lowercased()
            switch key {
            case "value":
                // The part's value (its MPN when it stores none) when it has
                // one, which the loader has already put in `value`.
                return details.value
            case "pkg":
                return hasPart ? details.packageName ?? "" : "None"
            case "mpn":
                return hasPart ? details.mpn ?? "" : "None"
            case "mfr":
                return hasPart ? details.manufacturer ?? "" : "None"
            case "desc":
                return hasPart ? details.description ?? "" : "None"
            default:
                guard key.hasPrefix("p:") else {
                    return nil
                }
                guard hasPart else {
                    return "None"
                }
                let column = String(key.dropFirst(2))
                return details.parametricFields.first { $0.key == column }?.value
            }
        }
    }

    /// A part's parametric values as `${p:…}` shows them. With the part's
    /// table among `tables`, Horizon's: the table's columns the part has a
    /// value for, each formatted by its column. A table that can't be found
    /// (a pool the process can't reach) leaves the stored values, every one
    /// but the table name, under their own keys. Ordered by key, as Horizon's
    /// map is.
    static func parametricFields(_ raw: [String: String], tables: [HorizontalParametricTable]) -> [HorizontalParametricField] {
        var values = [String: String]()
        for (key, value) in raw {
            values[key.lowercased()] = value
        }
        let fields: [HorizontalParametricField]
        if let tableName = values["table"], let table = tables.first(where: { $0.name == tableName }) {
            fields = table.columns.compactMap { column in
                let key = column.name.lowercased()
                return values[key].map { HorizontalParametricField(key: key, displayName: column.displayName, value: column.format($0)) }
            }
        } else {
            fields = values.compactMap { key, value in
                key == "table" ? nil : HorizontalParametricField(key: key, displayName: key, value: value)
            }
        }
        return fields.sorted { $0.key < $1.key }
    }

    /// Horizon's `interpolate_text`: `$name` and `${name}` replaced by what
    /// `lookup` gives, and left as written when it gives nothing. A name is
    /// letters, digits, `_` and `:`; a braced one runs to the closing brace.
    static func interpolateText(_ text: String, lookup: (String) -> String?) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "$" else {
                result.append(text[index])
                text.formIndex(after: &index)
                continue
            }

            let dollarIndex = index
            text.formIndex(after: &index)
            guard index < text.endIndex else {
                result.append("$")
                break
            }

            if text[index] == "{" {
                let variableStart = text.index(after: index)
                guard let closeIndex = text[variableStart...].firstIndex(of: "}") else {
                    result.append(contentsOf: text[dollarIndex...])
                    break
                }
                let variable = String(text[variableStart..<closeIndex])
                result.append(lookup(variable) ?? String(text[dollarIndex...closeIndex]))
                index = text.index(after: closeIndex)
                continue
            }

            guard isVariableCharacter(text[index]) else {
                result.append("$")
                result.append(text[index])
                text.formIndex(after: &index)
                continue
            }

            let variableStart = index
            while index < text.endIndex, isVariableCharacter(text[index]) {
                text.formIndex(after: &index)
            }
            let variable = String(text[variableStart..<index])
            result.append(lookup(variable) ?? "$\(variable)")
        }
        return result
    }

    private static func isVariableCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == ":"
        }
    }
}
