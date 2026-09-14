import Foundation

/// Which sheet a request means.
enum HorizontalSheetRequest: Equatable {
    case number(Int)
    case named(String)
    case next
    case previous
    case first
    case last

    /// The request as a message names it: "there is no sheet 9".
    var spoken: String {
        switch self {
        case .number(let number): "\(number)"
        case .named(let name): "called \(name)"
        case .next: "after this one"
        case .previous: "before this one"
        case .first: "first"
        case .last: "last"
        }
    }
}

/// What a spoken sentence asks for, once it has been read.
enum HorizontalVoiceCommand: Equatable {
    case highlight([HorizontalDesignObject])
    case select([HorizontalDesignObject])
    case clearHighlight
    case clearSelection
    case zoom(HorizontalDesignObject, pane: HorizontalPane?)
    case showPanes(Set<HorizontalPane>)
    case hidePanes(Set<HorizontalPane>)
    case showSheet(HorizontalSheetRequest)
    /// A board layer view: "show the top layer", "all layers", "copper only".
    case showLayers(HorizontalBoardLayerPreset)
    /// "Zoom in", "zoom out": the view, not a thing. 2 is twice as close.
    case zoomBy(Double, pane: HorizontalPane?)
    case undo
    case redo
    /// The verb was clear, but nothing in the design answers to the name.
    case nothingNamed(said: String, family: HorizontalObjectFamily?)
    /// The verb was clear, and several things answer to the name.
    case ambiguous([HorizontalDesignObject], said: String)
    /// Not a command — or not yet a whole one, if more is coming.
    case unrecognized
}

/// What the parser knows about the design: what can be named.
struct HorizontalVoiceVocabulary {
    var objects: [HorizontalDesignObject] = []
    var sheetNames: [String] = []
}

/// Reads a transcript as a command.
///
/// The grammar is a verb and a thing. The verbs are the ones people use for
/// what the app can do — highlight, select, zoom to, show, hide, clear, undo —
/// each with the phrasings speech produces for it; the thing is a component or
/// net resolved by `HorizontalSpokenMatcher`, a pane, or a sheet. Order
/// matters where verbs overlap: "show sheet 2" and "show the board" are read
/// before "show me C123", and "go to the ADC sheet" before "go to C123".
enum HorizontalVoiceCommandParser {
    static func parse(_ transcript: String, vocabulary: HorizontalVoiceVocabulary) -> HorizontalVoiceCommand {
        let text = tidy(transcript)
        guard !text.isEmpty else { return .unrecognized }
        if text == "undo" || text.hasPrefix("undo ") { return .undo }
        if text == "redo" || text.hasPrefix("redo ") { return .redo }
        if let cleared = clearing(text) { return cleared }
        if let step = zoomStep(in: text) { return step }

        let shown = remainder(after: showVerbs + zoomVerbs, in: text)
        if let request = sheetRequest(in: withoutArticles(shown ?? text)) {
            return .showSheet(request)
        }
        if let preset = layerRequest(in: shown ?? text, afterShowVerb: shown != nil) {
            return .showLayers(preset)
        }
        if let hidden = remainder(after: hideVerbs, in: text), let panes = panes(in: hidden) {
            return .hidePanes(panes)
        }
        if let panes = panes(in: shown ?? text) {
            return .showPanes(panes)
        }
        if let rest = remainder(after: zoomVerbs, in: text) {
            let (name, pane) = paneSuffix(in: rest)
            return resolve(name, vocabulary: vocabulary, many: false) { .zoom($0[0], pane: pane) }
        }
        if let rest = remainder(after: selectVerbs, in: text) {
            return resolve(rest, vocabulary: vocabulary, many: true) { .select($0) }
        }
        if let rest = remainder(after: highlightVerbs, in: text) {
            return resolve(rest, vocabulary: vocabulary, many: true) { .highlight($0) }
        }
        return .unrecognized
    }

    // MARK: - Words

    private static let showVerbs = [
        "show me", "show", "open", "display", "switch to", "go to", "view", "bring up", "give me",
        "let me see", "pull up", "take me to", "jump to",
    ]
    private static let hideVerbs = ["hide", "close", "dismiss", "put away", "get rid of"]
    private static let zoomVerbs = [
        "zoom in on", "zoom to", "zoom into", "zoom on", "go to", "jump to", "take me to", "navigate to",
        "center on", "centre on", "focus on", "look at", "find", "frame", "locate", "where is", "where's",
    ]
    private static let selectVerbs = ["select", "pick", "choose"]
    private static let highlightVerbs = ["highlight", "light up", "show me", "show", "mark", "point out", "point to", "point at", "flash"]
    private static let articles: Set<String> = ["the", "a", "an", "all", "every", "of", "my"]
    private static let paneGlue: Set<String> = [
        "the", "a", "and", "with", "plus", "view", "views", "pane", "panes", "me", "only", "just", "too",
        "as", "well", "list", "window", "mode", "of", "them", "both", "again",
    ]

    /// A transcript with the noise gone: lowercase, punctuation that is not
    /// part of a name, the app addressed by name, politeness.
    static func tidy(_ transcript: String) -> String {
        var s = " \(transcript.lowercased()) "
        for noise in ["hey horizontal", "ok horizontal", "okay horizontal", "horizontal,", "in horizontal", "on horizontal", "please", "can you", "could you", "would you"] {
            s = s.replacingOccurrences(of: " \(noise) ", with: " ")
            s = s.replacingOccurrences(of: " \(noise), ", with: " ")
        }
        s = s.replacingOccurrences(of: "[,!?;:]+", with: " ", options: .regularExpression)
        // A full stop ends a sentence; the one in 3.3 does not.
        s = s.replacingOccurrences(of: "\\.(?!\\d)", with: " ", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What follows the longest of `verbs` that begins `text`, or nil when
    /// none does. A verb has to be whole: "find" does not begin "finder".
    private static func remainder(after verbs: [String], in text: String) -> String? {
        var best: (verb: String, rest: String)?
        for verb in verbs {
            if text == verb {
                if (best?.verb.count ?? -1) < verb.count { best = (verb, "") }
            } else if text.hasPrefix(verb + " "), (best?.verb.count ?? -1) < verb.count {
                best = (verb, String(text.dropFirst(verb.count + 1)))
            }
        }
        return best?.rest
    }

    private static func withoutArticles(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let first = words.first, articles.contains(first) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    // MARK: - Clearing

    private static func clearing(_ text: String) -> HorizontalVoiceCommand? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let rest = words.dropFirst().filter { !paneGlue.contains($0) && !articles.contains($0) }
        let highlightWords: Set<String> = ["highlight", "highlights", "highlighting", "highlighted", "everything"]
        let selectionWords: Set<String> = ["selection", "selected", "select"]
        switch first {
        case "unhighlight":
            return .clearHighlight
        case "deselect", "unselect":
            return .clearSelection
        case "clear", "remove", "cancel", "reset":
            if rest.allSatisfy(selectionWords.contains), !rest.isEmpty { return .clearSelection }
            if rest.allSatisfy(highlightWords.contains), first == "clear" || !rest.isEmpty { return .clearHighlight }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Sheets

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "won": 1, "two": 2, "to": 2, "too": 2, "three": 3, "four": 4, "for": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "ate": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]

    private static func number(_ word: String) -> Int? {
        Int(word) ?? numberWords[word]
    }

    /// "sheet 3", "the ADC sheet", "sheet ADC", "next sheet", "last page".
    static func sheetRequest(in text: String) -> HorizontalSheetRequest? {
        let words = text.split(separator: " ").map(String.init)
        guard let at = words.firstIndex(where: { ["sheet", "page", "sheets", "pages"].contains($0) }) else {
            return nil
        }
        let before = words[..<at].filter { !articles.contains($0) && $0 != "to" }
        let after = words[(at + 1)...].filter { !articles.contains($0) && $0 != "number" && $0 != "called" && $0 != "named" }
        let relative: [String: HorizontalSheetRequest] = [
            "next": .next, "following": .next, "previous": .previous, "prior": .previous, "back": .previous,
            "last": .last, "final": .last, "first": .first,
        ]
        if before.count == 1, let request = relative[before[0]], after.isEmpty {
            return request
        }
        if before.isEmpty, after.count == 1, let request = relative[after[0]] {
            return request
        }
        if before.isEmpty, let first = after.first, after.count == 1, let number = number(first) {
            return .number(number)
        }
        if before.isEmpty, !after.isEmpty {
            return .named(after.joined(separator: " "))
        }
        if !before.isEmpty, after.isEmpty {
            return .named(before.joined(separator: " "))
        }
        return nil
    }

    // MARK: - Zoom steps

    /// "zoom in", "zoom out", "zoom in a lot", "zoom way out", "zoom in on the
    /// board", "closer", "further out". A thing after "zoom in on" is not a
    /// pane and falls through to zoom-to.
    static func zoomStep(in text: String) -> HorizontalVoiceCommand? {
        var words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        var direction: Double?
        var leadingModifiers: [String] = []
        if first == "zoom", words.count >= 2 {
            // "zoom way out": the amount can come before the direction.
            var index = 1
            while index < words.count, ["way", "a", "lot", "much", "right", "further", "farther", "all", "the"].contains(words[index]) {
                leadingModifiers.append(words[index])
                index += 1
            }
            guard index < words.count else { return nil }
            switch words[index] {
            case "in", "closer": direction = 2
            case "out", "away", "back": direction = 0.5
            default: return nil
            }
            words.removeFirst(index + 1)
            words = leadingModifiers + words
        } else if ["closer", "nearer"].contains(first) {
            direction = 2
            words.removeFirst()
        } else if first == "further" || first == "farther" {
            direction = 0.5
            words.removeFirst()
        } else {
            return nil
        }
        guard var factor = direction else { return nil }
        var pane: HorizontalPane?
        var index = 0
        while index < words.count {
            let word = words[index]
            switch word {
            case "a", "lot", "way", "much", "more", "further", "farther", "bit", "little", "the", "please", "again":
                if ["lot", "way", "much"].contains(word) { factor = factor > 1 ? 4 : 0.25 }
                if ["bit", "little"].contains(word) { factor = factor > 1 ? 1.4 : 0.7 }
            case "on", "in", "into", "of", "view", "pane":
                break
            default:
                guard let panes = panes(in: words[index...].joined(separator: " ")), panes.count == 1, let only = panes.first else {
                    return nil
                }
                pane = only
                index = words.count
                continue
            }
            index += 1
        }
        return .zoomBy(factor, pane: pane)
    }

    // MARK: - Layers

    /// "the top layer", "top side", "bottom silkscreen", "top routing", "top
    /// copper", "all layers", "copper only", "clean view". A bare side is the
    /// placement view — copper and courtyard — which is what one looks at
    /// when working on that side; on its own it needs a layer word or a show
    /// verb in front, so a net that happens to be called TOP is still a name.
    static func layerRequest(in text: String, afterShowVerb: Bool = false) -> HorizontalBoardLayerPreset? {
        if ["flip", "flip the board", "flip the view", "flip board", "flip view", "flip it", "turn the board over", "turn it over", "other side", "the other side"].contains(text) {
            return .flipView
        }
        let words = text.split(separator: " ").map(String.init)
            .filter { !paneGlue.contains($0) && !(articles.contains($0) && $0 != "all" && $0 != "every") }
        guard !words.isEmpty else { return nil }
        // "the top layer" is the side's layers; "the top", "the board bottom",
        // "the bottom of the board", "bottom view" is the side itself, seen
        // from that side — so the bottom view mirrors, and a layer view does
        // not.
        let layerWords: Set<String> = ["layer", "layers"]
        let viewWords: Set<String> = ["board", "view", "side", "sides", "from", "underneath", "below", "above"]
        let hasLayerWord = words.contains { layerWords.contains($0) }
        let hasViewWord = words.contains { viewWords.contains($0) }
        var side: String?
        var mode: String?
        var others = 0
        for word in words {
            switch word {
            case "top", "upper", "front": side = "top"
            case "bottom", "lower", "back", "underside": side = "bottom"
            case "silkscreen", "silk", "legend": mode = "silkscreen"
            case "routing", "copper", "traces", "tracks", "route": mode = "routing"
            case "placement", "courtyard", "default", "place": mode = "placement"
            case "layer", "layers", "side", "sides", "view", "board", "from", "underneath", "below", "above", "of": break
            case "clean": mode = "clean"
            case "everything", "every", "all": mode = "all"
            case "only", "just": break
            default: others += 1
            }
        }
        guard others == 0 else { return nil }
        let copperOnly = words.contains("only") || words.contains("just")
        switch (side, mode) {
        case (nil, "all") where hasLayerWord: return .all
        case (nil, "clean"): return .clean
        case (nil, "routing") where copperOnly: return .copperOnly
        case (nil, "routing") where !hasLayerWord && words.allSatisfy({ $0 == "copper" }): return .copperOnly
        // A mode with no side: the side that is up decides, later.
        case (nil, "silkscreen"): return .silkscreen
        case (nil, "routing"): return .routing
        case (nil, "placement"): return .placement
        case ("top", nil) where hasLayerWord: return .topPlacement
        case ("top", nil) where hasViewWord || afterShowVerb: return .topView
        case ("top", "placement"): return .topPlacement
        case ("top", "silkscreen"): return .topSilkscreen
        case ("top", "routing"): return .topRouting
        case ("bottom", nil) where hasLayerWord: return .bottomPlacement
        case ("bottom", nil) where hasViewWord || afterShowVerb: return .bottomView
        case ("bottom", "placement"): return .bottomPlacement
        case ("bottom", "silkscreen"): return .bottomSilkscreen
        case ("bottom", "routing"): return .bottomRouting
        default: return nil
        }
    }

    // MARK: - Panes

    /// The panes `text` names and nothing else, or nil when it says anything
    /// that is not a pane. "the board", "schematic and board", "3D", "both",
    /// "everything".
    static func panes(in text: String) -> Set<HorizontalPane>? {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var panes = Set<HorizontalPane>()
        var index = 0
        while index < words.count {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            switch word {
            case "3d", "3-d", "three-d", "threed", "model":
                panes.insert(.threeD)
                if next == "board" || next == "view" || next == "model" { index += 1 }
            case "three":
                guard next == "d" || next == "dee" || next == "dimensional" else { return nil }
                panes.insert(.threeD)
                index += 1
            case "board", "pcb", "layout":
                panes.insert(.board)
            case "schematic", "schematics", "circuit", "diagram", "sch":
                panes.insert(.schematic)
            case "parts", "part", "bom":
                panes.insert(.parts)
            case "pools", "pool", "library", "libraries":
                panes.insert(.library)
            case "everything", "all":
                panes.formUnion([.schematic, .board, .threeD])
            case "both":
                panes.formUnion([.schematic, .board])
            default:
                guard paneGlue.contains(word) else { return nil }
            }
            index += 1
        }
        return panes.isEmpty ? nil : panes
    }

    /// "… on the board", "… in the schematic": which pane to frame in.
    private static func paneSuffix(in text: String) -> (name: String, pane: HorizontalPane?) {
        let suffixes: [(String, HorizontalPane)] = [
            (" on the board", .board), (" in the board", .board), (" on the pcb", .board), (" on the layout", .board),
            (" on board", .board), (" in the schematic view", .schematic), (" in the schematic", .schematic),
            (" on the schematic", .schematic), (" in schematic", .schematic), (" on the sheet", .schematic),
        ]
        for (suffix, pane) in suffixes where text.hasSuffix(suffix) {
            return (String(text.dropLast(suffix.count)), pane)
        }
        return (text, nil)
    }

    // MARK: - Things

    /// What `said` names in the design, as the command `make` builds from it.
    /// One thing is one thing. A bare kind ("the capacitors", "the nets") is
    /// all of the kind, for verbs that take several; several things that
    /// merely share a number or a word are a question back. A wide kind said
    /// after the name — "the reset net", "the C123 component" — scopes the
    /// search the way a kind said before it does.
    private static func resolve(_ said: String, vocabulary: HorizontalVoiceVocabulary, many: Bool,
                                make: ([HorizontalDesignObject]) -> HorizontalVoiceCommand) -> HorizontalVoiceCommand {
        let name = withoutArticles(said)
        var words = name.split(separator: " ").map(String.init)
        var trailing: HorizontalObjectFamily?
        if let last = words.last,
           let family = [HorizontalObjectFamily.net, .component].first(where: { $0.spokenNames.contains(last) }) {
            trailing = family
            words.removeLast()
        }
        let subject = words.joined(separator: " ")
        guard !subject.isEmpty || trailing != nil else { return .unrecognized }
        var found = trailing.map { HorizontalSpokenMatcher.matches(subject, family: $0, in: vocabulary.objects) }
            ?? HorizontalSpokenMatcher.matches(subject, in: vocabulary.objects)
        if found.isEmpty, words.count > 1 {
            // Transcription pads a command — "zoom to xyz C 50" — and the
            // name is still in there somewhere, said exactly.
            let pool = vocabulary.objects.filter { object in
                switch trailing {
                case .net: object.kind == .net
                case .component: object.kind == .component
                default: true
                }
            }
            if let run = HorizontalSpokenMatcher.exactMatches(inAnyRunOf: words, in: pool) {
                found = run.matches
            }
        }
        switch found.count {
        case 1:
            return make(found)
        case 0:
            let (family, rest) = familyWords(in: subject)
            return .nothingNamed(said: rest.isEmpty ? subject : rest, family: family ?? trailing)
        default:
            let bareKind = subject.isEmpty || HorizontalSpokenMatcher.parseFamily(subject)?.rest.isEmpty == true
            if many, bareKind {
                return make(found)
            }
            return .ambiguous(found, said: subject.isEmpty ? name : subject)
        }
    }

    /// A kind said at the start of `text`, and the words after it as said —
    /// not reduced — so a message can read them back: "capacitor 7" is
    /// (.capacitor, "7").
    private static func familyWords(in text: String) -> (HorizontalObjectFamily?, String) {
        let words = text.split(separator: " ").map(String.init)
        for count in stride(from: min(2, words.count), through: 1, by: -1) {
            let head = words.prefix(count).joined()
            if let family = HorizontalObjectFamily.allCases.first(where: { $0.spokenNames.contains(head) }) {
                return (family, words.dropFirst(count).joined(separator: " "))
            }
        }
        return (nil, text)
    }
}

