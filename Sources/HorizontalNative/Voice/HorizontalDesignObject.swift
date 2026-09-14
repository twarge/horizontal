import Foundation

/// Something in the open design a spoken request can be pointed at: a
/// component by its reference designator, or a net by its name. The name is
/// the identity, because a name is what gets said and what the dispatch verbs
/// take.
struct HorizontalDesignObject: Hashable {
    enum Kind: String {
        case component
        case net
    }

    var kind: Kind
    var name: String
    /// The value for a component, the net class for a net — what tells two
    /// similarly named things apart when several are read back.
    var detail: String = ""
}

/// What kind of thing a spoken request is about, when it names the kind
/// rather than the thing: "highlight capacitor 123", or "highlight a
/// capacitor" and then "123".
///
/// The families are the reference-designator prefixes the pools actually use
/// (horizon-pool and the project pools were tallied for this list), named the
/// way people say them. `component` and `net` are the wide ones, for when the
/// kind is not worth saying: "highlight a component", then "C 123"; "highlight
/// the net", then "3.3 volts".
enum HorizontalObjectFamily: String, CaseIterable {
    case resistor
    case capacitor
    case inductor
    case diode
    case transistor
    case integratedCircuit
    case connector
    case testPoint
    case relay
    case transformer
    case crystal
    case `switch`
    case fuse
    case battery
    case jumper
    case mechanical
    case fiducial
    case display
    case thermistor
    case speaker
    case antenna
    case component
    case net

    /// The reference-designator prefixes the family covers, uppercase. Empty
    /// for the wide families: `component` takes any prefix, `net` has none.
    /// Disjoint on purpose, so a number is one kind's or another's; where a
    /// pool files something under a neighbour's letter (potentiometers under
    /// R, oscillators under U) the neighbour's name is a spoken name of the
    /// family that owns the letter.
    var prefixes: [String] {
        switch self {
        case .resistor: ["R", "RN", "RV", "POT"]
        case .capacitor: ["C"]
        case .inductor: ["L", "FB"]
        case .diode: ["D", "LED", "Z", "ZD"]
        case .transistor: ["Q", "M"]
        case .integratedCircuit: ["U", "IC", "OK", "OC"]
        case .connector: ["J", "P", "CN", "TB"]
        case .testPoint: ["TP"]
        case .relay: ["K", "RLY"]
        case .transformer: ["T", "TR"]
        case .crystal: ["Y", "X", "XTAL", "OSC"]
        case .switch: ["S", "SW"]
        case .fuse: ["F", "FU"]
        case .battery: ["BT", "BAT", "B"]
        case .jumper: ["JP"]
        case .mechanical: ["MP", "MH", "H", "HS"]
        case .fiducial: ["FID", "FD", "A"]
        case .display: ["DS", "LCD", "DISP"]
        case .thermistor: ["RT", "TH", "NTC"]
        case .speaker: ["LS", "SP", "SPK", "BZ"]
        case .antenna: ["ANT", "AE", "E"]
        case .component, .net: []
        }
    }

    /// What a speaker calls the family, reduced the way
    /// `HorizontalSpokenMatcher.spoken` reduces names, longest first so "test
    /// point" is found before "test" could be.
    var spokenNames: [String] {
        switch self {
        case .resistor: ["potentiometers", "potentiometer", "resistors", "resistor", "trimmer", "res", "pot"]
        case .capacitor: ["capacitors", "capacitor", "caps", "cap"]
        case .inductor: ["inductors", "inductor", "ferrite", "choke", "coil"]
        case .diode: ["diodes", "diode", "zener", "leds", "led", "tvs"]
        case .transistor: ["transistors", "transistor", "mosfet", "triac", "fet"]
        case .integratedCircuit: ["integratedcircuit", "optocoupler", "regulator", "sensor", "chips", "chip", "ics", "ic"]
        case .connector: ["connectors", "connector", "terminal", "header", "socket", "jack", "plug"]
        case .testPoint: ["testpoints", "testpoint", "testpad"]
        case .relay: ["relays", "relay"]
        case .transformer: ["transformers", "transformer", "balun"]
        case .crystal: ["oscillators", "oscillator", "resonator", "crystals", "crystal", "xtal"]
        case .switch: ["pushbutton", "switches", "switch", "button"]
        case .fuse: ["fuses", "fuse"]
        case .battery: ["batteries", "battery", "cell"]
        case .jumper: ["jumpers", "jumper"]
        case .mechanical: ["mountingholes", "mountinghole", "screwhole", "mechanical", "hardware", "standoff", "lightpipe", "hole"]
        case .fiducial: ["fiducials", "fiducial"]
        case .display: ["displays", "display", "screen", "lcd"]
        case .thermistor: ["thermistors", "thermistor", "ntc", "ptc"]
        case .speaker: ["loudspeaker", "speakers", "speaker", "buzzer"]
        case .antenna: ["antennas", "antenna", "aerial"]
        case .component: ["components", "component", "parts", "part"]
        case .net: ["powerrail", "signal", "rails", "rail", "nets", "net", "wire"]
        }
    }

    /// The family as a message names it: "there is no capacitor 123".
    var spokenTitle: String {
        switch self {
        case .integratedCircuit: "chip"
        case .testPoint: "test point"
        case .mechanical: "mechanical part"
        default: rawValue
        }
    }

    /// Whether a component with this reference designator belongs here.
    func covers(refdes: String) -> Bool {
        switch self {
        case .net:
            return false
        case .component:
            return true
        default:
            let prefix = HorizontalSpokenMatcher.prefix(of: refdes).uppercased()
            return prefixes.contains(prefix)
        }
    }
}

/// Resolves what the user said against the design's names.
///
/// Spoken reference designators arrive in more than one shape — "R18", "R 18",
/// "r18", "resistor 18" — so matching ignores case, spaces and separators,
/// understands a kind said in words, and only then falls back to a contains
/// match, which is what makes "highlight ground" find GND_ANALOG when that is
/// the only ground there is. Net names get the same treatment on both sides:
/// see `spoken`.
enum HorizontalSpokenMatcher {
    /// An exact match wins outright: with GND and GND_ANALOG both present,
    /// "ground" is ambiguous but "GND" is not, and offering both there would
    /// be a question that does not need asking. A kind said in words
    /// ("capacitor 123") is read as one, and a bare number is a component's
    /// number before it is a substring of anything.
    static func matches(_ query: String, in known: [HorizontalDesignObject]) -> [HorizontalDesignObject] {
        if let parsed = parseFamily(query) {
            let scoped = matches(within: parsed.family, parsed.rest, in: known)
            if !scoped.isEmpty {
                return scoped
            }
        }
        let wanted = spoken(query)
        guard !wanted.isEmpty else { return known }
        if wanted.allSatisfy(\.isNumber) {
            let numbered = known.filter { $0.kind == .component && number(of: $0.name) == wanted }
            if !numbered.isEmpty {
                return numbered
            }
        }
        let exact = known.filter { spoken($0.name) == wanted }
        return exact.isEmpty ? known.filter { spoken($0.name).contains(wanted) } : exact
    }

    /// Exact matching only — a whole name however it was said, or a kind and
    /// a number — with no contains fallback. What a run of words has to do to
    /// count as a name inside a longer phrase.
    static func exactMatches(_ query: String, in known: [HorizontalDesignObject]) -> [HorizontalDesignObject] {
        if let parsed = parseFamily(query), !parsed.rest.isEmpty {
            let pool = known.filter { $0.kind == .component && parsed.family.covers(refdes: $0.name) }
            if parsed.rest.allSatisfy(\.isNumber) {
                return pool.filter { number(of: $0.name) == parsed.rest }
            }
            return known.filter { spoken($0.name) == parsed.rest }
        }
        let wanted = spoken(query)
        guard !wanted.isEmpty else { return [] }
        if wanted.allSatisfy(\.isNumber) {
            return known.filter { $0.kind == .component && number(of: $0.name) == wanted }
        }
        return known.filter { spoken($0.name) == wanted }
    }

    /// The longest run of consecutive words in `words` that names something
    /// exactly, and what it names. Transcription pads a command with words
    /// that were not said, or were said and were not the command — "zoom to
    /// xyz C 50" — and the name is still in there.
    static func exactMatches(inAnyRunOf words: [String], in known: [HorizontalDesignObject]) -> (matches: [HorizontalDesignObject], said: String)? {
        guard !words.isEmpty else { return nil }
        for length in stride(from: min(4, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) {
                let phrase = words[start..<(start + length)].joined(separator: " ")
                let found = exactMatches(phrase, in: known)
                if !found.isEmpty {
                    return (found, phrase)
                }
            }
        }
        return nil
    }

    /// Matching for the request that named the kind first and the thing
    /// second: "a capacitor", then "123".
    ///
    /// A bare number is read within the kind — "123" after "a capacitor" is
    /// C123, and R123 is not offered. A name is read against everything of the
    /// kind's class, because someone who says "C 123" after "a resistor" meant
    /// C123, and refusing them over the mismatch helps no one. An answer that
    /// names a kind itself ("capacitor 123" after "a component") is the more
    /// specific statement, and wins.
    static func matches(_ query: String, family: HorizontalObjectFamily, in known: [HorizontalDesignObject]) -> [HorizontalDesignObject] {
        if let parsed = parseFamily(query) {
            let scoped = matches(within: parsed.family, parsed.rest, in: known)
            if !scoped.isEmpty || parsed.family == family {
                return scoped
            }
        }
        return matches(within: family, spoken(query), in: known)
    }

    private static func matches(within family: HorizontalObjectFamily, _ rest: String, in known: [HorizontalDesignObject]) -> [HorizontalDesignObject] {
        let pool = known.filter { family == .net ? $0.kind == .net : $0.kind == .component }
        guard !rest.isEmpty else {
            // Just the kind: everything of it, for the caller to choose from.
            return pool.filter { family == .net || family.covers(refdes: $0.name) }
        }
        if family != .net, rest.allSatisfy(\.isNumber) {
            return pool.filter { family.covers(refdes: $0.name) && number(of: $0.name) == rest }
        }
        let exact = pool.filter { spoken($0.name) == rest }
        return exact.isEmpty ? pool.filter { spoken($0.name).contains(rest) } : exact
    }

    /// Splits off a kind said in words at the start of a phrase: "capacitor
    /// 123" is (.capacitor, "123") and "cap123" is too; "C 123" and "LED Red"
    /// are not split — the first because "c" names no kind, the second because
    /// that is a caller's problem to sort out by trying the whole name when the
    /// split finds nothing. Only leading words count, and at most two of them
    /// ("test point", "integrated circuit").
    static func parseFamily(_ text: String) -> (family: HorizontalObjectFamily, rest: String)? {
        let words = text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .map(String.init)
        guard let first = words.first else { return nil }
        for count in stride(from: min(2, words.count), through: 1, by: -1) {
            let head = words.prefix(count).joined()
            if let family = HorizontalObjectFamily.allCases.first(where: { $0.spokenNames.contains(head) }) {
                return (family, spoken(words.dropFirst(count).joined(separator: " ")))
            }
        }
        // "cap123": the kind and the number said as one word.
        for family in HorizontalObjectFamily.allCases {
            for name in family.spokenNames where first.hasPrefix(name) {
                let rest = first.dropFirst(name.count)
                if !rest.isEmpty, rest.allSatisfy(\.isNumber) {
                    return (family, spoken(([String(rest)] + words.dropFirst()).joined(separator: " ")))
                }
            }
        }
        return nil
    }

    /// A name reduced to what survives being said out loud, applied to both
    /// sides of every comparison so the two only have to agree after it.
    ///
    /// Case, spaces and the separators a speaker does not pronounce go. The
    /// rest is how people say net names: "ground" for GND and "analog ground"
    /// for AGND; a rail as "3.3 volts", "3.3V" or "3V3", which are one rail
    /// and read as one here; a sign in front of a rail as the P or N its name
    /// uses, and a sign anywhere else as the word ("coil plus"); and the words
    /// a name abbreviates — "chip select", "clock", "reset", "enable",
    /// "transmit", "receive", "input", "output".
    static func spoken(_ text: String) -> String {
        // Underscores are the spaces of a written name; a regex word boundary
        // would otherwise not see "reset" in "DAC_RESET".
        var s = " \(text.lowercased().replacingOccurrences(of: "_", with: " ")) "
        for (pattern, replacement) in spokenRewrites {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // A rail the way a name writes it: 3.3V is 3V3, 5.0V is 5V.
        s = s.replacingOccurrences(of: "(\\d)\\s*point\\s*(\\d)", with: "$1.$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\d+)\\.0+\\s*v", with: "$1v", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\d+)\\.(\\d+)\\s*v", with: "$1v$2", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\d)\\s+v(?![a-z])", with: "$1v", options: .regularExpression)
        // A decimal with no unit is read as a rail too — "1.8" for +1.8V_UC —
        // and since both sides go through this, "24.576 MHz" still matches
        // itself.
        s = s.replacingOccurrences(of: "(\\d+)\\.0+(?!\\d)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\d+)\\.(\\d+)", with: "$1v$2", options: .regularExpression)
        // A sign before a rail is its name's P or N; anywhere else it is said.
        s = s.replacingOccurrences(of: "\\+\\s*(?=\\d+(v|\\.\\d))", with: "p", options: .regularExpression)
        s = s.replacingOccurrences(of: "-\\s*(?=\\d+(v|\\.\\d))", with: "n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\+", with: "plus")
        s = s.replacingOccurrences(of: "(?<![a-z0-9])-(?=[a-z])", with: "minus", options: .regularExpression)
        s = s.replacingOccurrences(of: "-(?![a-z0-9])", with: "minus", options: .regularExpression)
        return s.filter { $0.isLetter || $0.isNumber }
    }

    /// Whole words a speaker says for what a name writes otherwise. Order
    /// matters only where one is part of another.
    private static let spokenRewrites: [(String, String)] = [
        ("\\bpositive\\b", "+"), ("\\bplus\\b", "+"), ("\\bnegative\\b", "-"), ("\\bminus\\b", "-"),
        ("volts?\\b", "v"),
        ("\\bmegahertz\\b", "mhz"), ("\\bkilohertz\\b", "khz"),
        ("\\banalog ground\\b", "agnd"), ("\\bdigital ground\\b", "dgnd"),
        ("\\bpower ground\\b", "pgnd"), ("\\bchassis ground\\b", "cgnd"), ("\\bground\\b", "gnd"),
        ("\\bchip select\\b", "cs"), ("\\bclock\\b", "clk"), ("\\breset\\b", "rst"), ("\\benable\\b", "en"),
        ("\\btransmit\\b", "tx"), ("\\breceive\\b", "rx"), ("\\binput\\b", "in"), ("\\boutput\\b", "out"),
    ]

    /// "C" of "C123": the letters before the first digit.
    static func prefix(of refdes: String) -> String {
        String(refdes.prefix { !$0.isNumber })
    }

    /// "123" of "C123": the first run of digits, or "" when there is none.
    static func number(of refdes: String) -> String {
        String(refdes.drop { !$0.isNumber }.prefix { $0.isNumber })
    }
}
