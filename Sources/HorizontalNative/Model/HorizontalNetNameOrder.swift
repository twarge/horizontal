import Foundation

/// The order net names are listed in: Finder's (`D2` before `D10`, case only
/// to break a tie) with one change. Finder puts `-` among the first of the
/// punctuation and `+` among the last, so `-5V` came before `+5V`, `USB_D-`
/// before `USB_D+`, and whatever started with `/` or `.` fell between the
/// negative rails and the positive ones. Here `+` sorts where Finder sorts
/// `-`, and `-` right after it; every other character keeps its place.
enum HorizontalNetNameOrder {
    /// How `lhs` and `rhs` compare; `.orderedSame` only for the same name.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let order = key(lhs).localizedStandardCompare(key(rhs))
        if order != .orderedSame || lhs == rhs {
            return order
        }
        // Names Finder finds the same, by their characters: `+` is before
        // `-` there too.
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Whether `lhs` is listed before `rhs`, as `sorted(by:)` asks.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// `name` as Finder is asked to compare it: `+` as a hyphen-minus and
    /// `-` as U+2010, the hyphen its order puts straight after. Comparing
    /// the whole rewritten names keeps one order for all of them, which
    /// deciding `+` against `-` pair by pair would not.
    private static func key(_ name: String) -> String {
        guard name.utf8.contains(where: { $0 == plus || $0 == minus }) else {
            return name
        }
        var key = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "+": key.append("-")
            case "-": key.append("\u{2010}")
            default: key.append(scalar)
            }
        }
        return String(key)
    }

    private static let plus = UInt8(ascii: "+")
    private static let minus = UInt8(ascii: "-")
}
