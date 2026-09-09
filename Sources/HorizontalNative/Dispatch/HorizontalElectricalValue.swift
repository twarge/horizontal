import Foundation

enum HorizontalElectricalValue {
    /// The quantities a part can declare outright, and the unit each is in.
    /// A declared number is evidence; a value string is notation that may or
    /// may not carry one.
    private static let parametricUnits = ["capacitance": "F", "inductance": "H", "resistance": "ohm"]

    static func parse(_ raw: String, refdes: String, parametric: [String: String] = [:]) -> JSONDictionary {
        let result = parseText(raw, refdes: refdes)
        guard result["value_si"] == nil else { return result }
        // The notation carried no number this parser understands. A part that
        // declares the quantity outright still does, and reading that is not a
        // guess — but say where the number came from.
        return declared(parametric, refdes: refdes) ?? result
    }

    /// The value a part declares in its parametric table, when it names the
    /// quantity this kind of component is measured in.
    private static func declared(_ parametric: [String: String], refdes: String) -> JSONDictionary? {
        let hint: String? = ["R": "ohm", "C": "F", "L": "H"][String(refdes.prefix(1)).uppercased()]
        for (key, unit) in parametricUnits.sorted(by: { $0.key < $1.key }) {
            guard hint == nil || hint == unit,
                  let text = parametric[key]?.trimmingCharacters(in: .whitespaces),
                  let number = Double(text), number.isFinite else {
                continue
            }
            return ["raw": text, "status": "parsed", "value_si": number, "unit": unit,
                    "unit_source": "explicit", "source": "parametric", "parametric_key": key]
        }
        return nil
    }

    private static func parseText(_ raw: String, refdes: String) -> JSONDictionary {
        var result: JSONDictionary = ["raw": raw, "status": "unsupported", "source": "text"]
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "µ", with: "u")
            // U+2126 OHM SIGN and U+03A9 GREEK CAPITAL OMEGA both spell ohms.
            .replacingOccurrences(of: "Ω", with: "Ω")
            .replacingOccurrences(of: "+/-", with: "±")
        let toleranceParts = text.components(separatedBy: "±")
        let value = toleranceParts[0].trimmingCharacters(in: .whitespaces)
        let hint: String? = ["R": "ohm", "C": "F", "L": "H"][String(refdes.prefix(1)).uppercased()]
        // A space may sit between the number and its multiplier ("1 kOhm"),
        // and the unit may be spelled in any case. The multiplier's case is
        // load-bearing, though: M is mega where m is milli.
        let pattern = #"^((?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*([RrKkMmGgunp]?)([0-9]*)(?:\s*([Oo][Hh][Mm][Ss]?|Ω|[Ff]|[Hh]))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return result }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: value).map { String(value[$0]) } ?? "" }
        let suffix = group(2), tail = group(3), explicitUnit = group(4)
        guard tail.isEmpty || (!suffix.isEmpty && !group(1).contains(".") && !group(1).lowercased().contains("e")) else { return result }
        let scales: [String: Double] = ["": 1, "R": 1, "r": 1, "K": 1e3, "k": 1e3, "M": 1e6, "m": 1e-3, "G": 1e9, "g": 1e9, "u": 1e-6, "n": 1e-9, "p": 1e-12]
        guard let number = Double(group(1) + (tail.isEmpty ? "" : "." + tail)), let scale = scales[suffix] else { return result }
        let unit: String?
        if !explicitUnit.isEmpty { unit = ["f", "h"].contains(explicitUnit.lowercased()) ? explicitUnit.uppercased() : "ohm" }
        else if suffix == "R" || suffix == "r" { unit = "ohm" }
        else { unit = hint }
        guard let unit else { result["status"] = "ambiguous"; return result }
        guard (number * scale).isFinite else { return result }
        result.merge(["status": "parsed", "value_si": number * scale, "unit": unit,
                      "unit_source": explicitUnit.isEmpty ? "refdes_or_notation" : "explicit"]) { _, new in new }
        if toleranceParts.count == 2, toleranceParts[1].trimmingCharacters(in: .whitespaces).hasSuffix("%"),
           let tolerance = Double(toleranceParts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), (0...100).contains(tolerance) {
            result["tolerance_fraction"] = tolerance / 100
        } else if toleranceParts.count > 1 { result["status"] = "unsupported"; result.removeValue(forKey: "value_si") }
        return result
    }
}
