import Foundation

/// Serialises a JSON object the way Horizon EDA writes its own files.
///
/// Horizon saves every pool item and project file with nlohmann::json's
/// `dump(4)`: four-space indentation, keys in byte order (its objects are
/// `std::map`s), `/` left unescaped, non-ASCII kept as raw UTF-8, `{}` and
/// `[]` for empty containers, and NO trailing newline. Foundation's
/// `JSONSerialization` can't reproduce that (two-space indent, and it appends
/// nothing but also escapes differently), so a file written by this app would
/// otherwise show up in a pool's `git diff` as a whole-file rewrite. Matching
/// the format byte for byte keeps an unchanged item unchanged on disk.
///
/// Numbers are the load-bearing part. `JSONSerialization` hands back
/// `NSNumber`s, and Swift's bridging casts are lenient (`1.0 as? Int` succeeds,
/// `1 as? Bool` succeeds), so the kind of a value is read from the number
/// itself — a CFBoolean is a bool, an `objCType` of `d`/`f` is a float,
/// anything else an integer — never from a cast. Floats print in nlohmann's
/// shortest-round-trip style (`50.0`, `0.5`, `1e-05`).
public enum HorizontalHorizonJSONWriter {
    public enum WriteError: Error, Equatable {
        case unsupportedValue(String)
        case invalidUTF8
    }

    public static func data(_ object: [String: Any]) throws -> Data {
        guard let data = try string(object).data(using: .utf8) else {
            throw WriteError.invalidUTF8
        }
        return data
    }

    public static func string(_ object: [String: Any]) throws -> String {
        var output = ""
        try append(object, indent: 0, to: &output)
        return output
    }

    // MARK: - Values

    private static let indentUnit = "    "

    private static func append(_ value: Any, indent: Int, to output: inout String) throws {
        switch value {
        case let string as String:
            appendString(string, to: &output)
        case let dictionary as [String: Any]:
            try appendObject(dictionary, indent: indent, to: &output)
        case let array as [Any]:
            try appendArray(array, indent: indent, to: &output)
        case is NSNull:
            output += "null"
        case let number as NSNumber:
            appendNumber(number, to: &output)
        default:
            throw WriteError.unsupportedValue(String(describing: type(of: value)))
        }
    }

    private static func appendObject(_ object: [String: Any], indent: Int, to output: inout String) throws {
        guard !object.isEmpty else {
            output += "{}"
            return
        }
        // std::map<std::string, …> orders keys by byte value, so "MPN" sorts
        // before "base" and "Z" before "a"; a locale-aware sort would not.
        let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let inner = String(repeating: indentUnit, count: indent + 1)
        output += "{\n"
        for (index, key) in keys.enumerated() {
            output += inner
            appendString(key, to: &output)
            output += ": "
            try append(object[key]!, indent: indent + 1, to: &output)
            output += index == keys.count - 1 ? "\n" : ",\n"
        }
        output += String(repeating: indentUnit, count: indent)
        output += "}"
    }

    private static func appendArray(_ array: [Any], indent: Int, to output: inout String) throws {
        guard !array.isEmpty else {
            output += "[]"
            return
        }
        let inner = String(repeating: indentUnit, count: indent + 1)
        output += "[\n"
        for (index, element) in array.enumerated() {
            output += inner
            try append(element, indent: indent + 1, to: &output)
            output += index == array.count - 1 ? "\n" : ",\n"
        }
        output += String(repeating: indentUnit, count: indent)
        output += "]"
    }

    // MARK: - Strings

    private static func appendString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                if scalar.value < 0x20 {
                    // nlohmann's escape table uses lowercase hex digits.
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    // MARK: - Numbers

    private static func appendNumber(_ number: NSNumber, to output: inout String) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            output += number.boolValue ? "true" : "false"
            return
        }
        switch String(cString: number.objCType) {
        case "d", "f":
            output += formatFloat(number.doubleValue)
        case "Q":
            output += String(number.uint64Value)
        default:
            output += String(number.int64Value)
        }
    }

    /// nlohmann::detail::dtoa's `format_buffer`: shortest round-trip digits
    /// laid out as an integer with `.0`, a plain decimal, or `d.ddde±XX`
    /// depending on where the decimal point lands.
    public static func formatFloat(_ value: Double) -> String {
        guard value.isFinite else {
            return "null"
        }
        if value == 0 {
            return value.sign == .minus ? "-0.0" : "0.0"
        }

        var (digits, decimalExponent) = shortestDigits(of: value.magnitude)
        // Guard against a degenerate description; never emit an empty mantissa.
        if digits.isEmpty {
            digits = "0"
            decimalExponent = 0
        }
        let k = digits.count
        let n = k + decimalExponent
        let minExp = -4
        let maxExp = 15

        var result = value < 0 ? "-" : ""
        if k <= n, n <= maxExp {
            // digits[000].0
            result += digits + String(repeating: "0", count: n - k) + ".0"
        } else if n > 0, n <= maxExp {
            // dd.ddd
            let split = digits.index(digits.startIndex, offsetBy: n)
            result += digits[..<split] + "." + digits[split...]
        } else if n > minExp, n <= 0 {
            // 0.00ddd
            result += "0." + String(repeating: "0", count: -n) + digits
        } else {
            // d.ddde±XX
            result += String(digits.first!)
            if k > 1 {
                result += "." + digits.dropFirst()
            }
            let exponent = n - 1
            result += exponent < 0 ? "e-" : "e+"
            let magnitude = abs(exponent)
            result += magnitude < 10 ? "0\(magnitude)" : String(magnitude)
        }
        return result
    }

    /// Swift's `description` already prints the shortest digit string that
    /// round-trips; this pulls those digits out along with the power of ten
    /// of the last digit (value = digits × 10^exponent), which is the form
    /// nlohmann's formatter works from.
    private static func shortestDigits(of magnitude: Double) -> (digits: String, exponent: Int) {
        let description = magnitude.description
        var mantissa = Substring(description)
        var exponent = 0
        if let eIndex = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = description[..<eIndex]
            exponent = Int(description[description.index(after: eIndex)...]) ?? 0
        }

        var digits = ""
        var fractionDigits = 0
        var seenPoint = false
        for character in mantissa {
            if character == "." {
                seenPoint = true
            } else if character.isNumber {
                digits.append(character)
                if seenPoint {
                    fractionDigits += 1
                }
            }
        }
        exponent -= fractionDigits

        // Trailing zeros belong to the exponent, leading zeros to nothing.
        while digits.count > 1, digits.hasSuffix("0") {
            digits.removeLast()
            exponent += 1
        }
        while digits.count > 1, digits.hasPrefix("0") {
            digits.removeFirst()
        }
        return (digits, exponent)
    }
}
