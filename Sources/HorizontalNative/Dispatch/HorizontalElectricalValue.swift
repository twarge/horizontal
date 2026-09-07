import Foundation

enum HorizontalElectricalValue {
    static func parse(_ raw: String, refdes: String) -> JSONDictionary {
        var result: JSONDictionary = ["raw": raw, "status": "unsupported"]
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "μ", with: "u").replacingOccurrences(of: "µ", with: "u").replacingOccurrences(of: "+/-", with: "±")
        let toleranceParts = text.components(separatedBy: "±")
        let value = toleranceParts[0].trimmingCharacters(in: .whitespaces)
        let hint: String? = ["R": "ohm", "C": "F", "L": "H"][String(refdes.prefix(1)).uppercased()]
        let pattern = #"^((?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)([RrKkMmGgunp]?)([0-9]*)(?:\s*(ohms?|Ω|F|H))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return result }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: value).map { String(value[$0]) } ?? "" }
        let suffix = group(2), tail = group(3), explicitUnit = group(4)
        guard tail.isEmpty || (!suffix.isEmpty && !group(1).contains(".") && !group(1).lowercased().contains("e")) else { return result }
        let scales: [String: Double] = ["": 1, "R": 1, "r": 1, "K": 1e3, "k": 1e3, "M": 1e6, "m": 1e-3, "G": 1e9, "g": 1e9, "u": 1e-6, "n": 1e-9, "p": 1e-12]
        guard let number = Double(group(1) + (tail.isEmpty ? "" : "." + tail)), let scale = scales[suffix] else { return result }
        let unit: String?
        if !explicitUnit.isEmpty { unit = ["F", "H"].contains(explicitUnit) ? explicitUnit : "ohm" }
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
