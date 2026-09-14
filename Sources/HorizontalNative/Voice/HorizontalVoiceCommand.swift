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

/// The verbs that take a thing, remembered so the next sentence can lean on
/// them: "highlight C50", then "zoom" means C50, and then "R12" means
/// highlight R12.
enum HorizontalVoiceVerb: Equatable {
    case highlight
    case select
    case zoom
}

/// What a spoken sentence asks for, once it has been read.
enum HorizontalVoiceCommand: Equatable {
    case highlight([HorizontalDesignObject])
    case select([HorizontalDesignObject])
    case clearHighlight
    case clearSelection
    /// One thing framed, or several framed together.
    case zoom([HorizontalDesignObject], pane: HorizontalPane?)
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
    /// The nets connecting these parts to each other: "the nets between C48
    /// and C50", "the nets connecting them" after three were named.
    case among(HorizontalVoiceVerb, [HorizontalDesignObject])
    /// A verb that wants a thing, with nothing said and nothing remembered.
    case noSubject(HorizontalVoiceVerb)
    /// Not a command — or not yet a whole one, if more is coming.
    case unrecognized
}

/// Why one side of "between A and B" did not come to one thing, as the command
/// that says so.
enum HorizontalVoiceCommandFailure: Error {
    case nothingNamed(said: String, family: HorizontalObjectFamily?)
    case ambiguous([HorizontalDesignObject], said: String)
}

private extension HorizontalVoiceCommand {
    init(_ failure: HorizontalVoiceCommandFailure) {
        switch failure {
        case .nothingNamed(let said, let family): self = .nothingNamed(said: said, family: family)
        case .ambiguous(let found, let said): self = .ambiguous(found, said: said)
        }
    }
}

/// What the parser knows about the design — what can be named — and about the
/// conversation: what was named last, and what was done to it.
struct HorizontalVoiceVocabulary {
    var objects: [HorizontalDesignObject] = []
    var sheetNames: [String] = []
    /// The thing or things the last command named, for "zoom" and "it".
    var previousSubject: [HorizontalDesignObject] = []
    /// The verb of the last command that named something, for a bare name.
    var previousVerb: HorizontalVoiceVerb?
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
        if let fit = fitRequest(in: text, vocabulary: vocabulary) { return fit }

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
            return resolve(name, vocabulary: vocabulary, many: true) { .zoom($0, pane: pane) }
        }
        if let rest = remainder(after: selectVerbs, in: text) {
            return resolve(rest, vocabulary: vocabulary, many: true) { .select($0) }
        }
        if let rest = remainder(after: highlightVerbs, in: text) {
            return resolve(rest, vocabulary: vocabulary, many: true) { .highlight($0) }
        }
        // A name on its own, after a verb was used: the same verb again.
        // "Highlight C123", then "R12", is two highlights.
        if let verb = vocabulary.previousVerb {
            let again = resolve(text, vocabulary: vocabulary, many: true) { command(verb, $0) }
            switch again {
            case .highlight, .select, .zoom, .ambiguous:
                return again
            default:
                break
            }
        }
        return .unrecognized
    }

    private static func command(_ verb: HorizontalVoiceVerb, _ objects: [HorizontalDesignObject], pane: HorizontalPane? = nil) -> HorizontalVoiceCommand {
        switch verb {
        case .highlight: .highlight(objects)
        case .select: .select(objects)
        case .zoom: .zoom(objects, pane: pane)
        }
    }

    /// What the last thing named means to `verb` now.
    private static func previous(_ verb: HorizontalVoiceVerb, vocabulary: HorizontalVoiceVocabulary, pane: HorizontalPane? = nil) -> HorizontalVoiceCommand {
        let subject = vocabulary.previousSubject
        guard !subject.isEmpty else { return .noSubject(verb) }
        return command(verb, subject, pane: pane)
    }

    private static let pronouns: Set<String> = ["it", "that", "this", "them", "those", "these", "the same", "same", "again", "that one", "this one"]

    // MARK: - Fit

    /// "Zoom", "zoom to fit", "fit", "zoom to it": the last thing named, when
    /// there is one, else the whole view. "Zoom to everything", "zoom to the
    /// whole board": the whole view regardless.
    static func fitRequest(in text: String, vocabulary: HorizontalVoiceVocabulary) -> HorizontalVoiceCommand? {
        let (core, pane) = paneSuffix(in: text)
        let words = core.split(separator: " ").map(String.init)
        guard let first = words.first, ["zoom", "fit", "frame"].contains(first) else { return nil }
        let rest = words.dropFirst().filter { !["to", "the", "a", "on", "in", "view", "screen", "window"].contains($0) }
        let wholeWords: Set<String> = ["everything", "all", "whole", "entire", "board", "schematic", "design", "page", "sheet"]
        if !rest.isEmpty, rest.allSatisfy(wholeWords.contains) {
            let where_: HorizontalPane? = pane ?? (rest.contains("board") ? .board : rest.contains("schematic") || rest.contains("sheet") || rest.contains("page") ? .schematic : nil)
            return .zoomBy(0, pane: where_)
        }
        let remainder = rest.joined(separator: " ")
        if remainder.isEmpty || remainder == "fit" || remainder == "fit fit" {
            // "Zoom", "fit", "zoom to fit": the last thing, else the whole view.
            return vocabulary.previousSubject.isEmpty ? .zoomBy(0, pane: pane) : previous(.zoom, vocabulary: vocabulary, pane: pane)
        }
        if pronouns.contains(remainder) {
            return previous(.zoom, vocabulary: vocabulary, pane: pane)
        }
        return nil
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
        // A comma between things is an "and": "C123, R12 and TP5".
        s = s.replacingOccurrences(of: ",", with: " and ")
        s = s.replacingOccurrences(of: "[!?;:]+", with: " ", options: .regularExpression)
        // A full stop ends a sentence; the one in 3.3 does not.
        s = s.replacingOccurrences(of: "\\.(?!\\d)", with: " ", options: .regularExpression)
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { !hesitations.contains($0) }
        // "and" twice, or at either end, is punctuation that became a word.
        words = words.enumerated().filter { index, word in word != "and" || (index > 0 && words[index - 1] != "and") }.map(\.element)
        while words.first == "and" { words.removeFirst() }
        while words.last == "and" { words.removeLast() }
        // "So, highlight C12", "okay zoom in": what leads in is not the command.
        while let first = words.first, openers.contains(first) { words.removeFirst() }
        // The verb in the one form the grammar knows: "highlights",
        // "highlighting", "highlighted" are all "highlight".
        if let first = words.first, let base = verbLemmas[first] {
            words[0] = base
        }
        return words.joined(separator: " ")
    }

    /// Sounds a speaker makes between words and a transcriber writes down.
    /// Never part of a name, so they go wherever they are.
    private static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "hm", "ah", "mm"]
    /// Words that lead into a command without being part of it.
    private static let openers: Set<String> = ["so", "now", "then", "okay", "ok", "well", "yeah", "yes", "and", "please", "also"]
    /// Words a transcriber puts between the verb and the name, or a speaker
    /// says there while thinking of it: "highlight what C113", "zoom to like
    /// U3". Only the front of what follows the verb is read this way, and
    /// "what connects" stays, being a question.
    private static let fillers: Set<String> = openers.union(["what", "like", "here", "erm", "the thing", "that thing"])

    /// Every form speech gives a verb — "highlights", "highlighting",
    /// "highlighted", "went", "lit", "shown" — mapped back to the one the
    /// grammar knows. Only a transcript's first word is read this way: that
    /// is where the verb is, and "displays" or "switches" later in a sentence
    /// may well be parts. The regular forms are made by rule, with the
    /// consonant both doubled and not ("fitting", "opening") since a wrong
    /// form here matches nothing and costs nothing; the irregular ones are
    /// listed.
    private static let verbLemmas: [String: String] = {
        let irregular: [String: [String]] = [
            "go": ["went", "gone"], "find": ["found"], "light": ["lit"], "choose": ["chose", "chosen"],
            "show": ["shown"], "hide": ["hid", "hidden"], "take": ["took", "taken"], "bring": ["brought"],
            "give": ["gave", "given"], "get": ["got", "gotten"], "undo": ["undid", "undone"],
            "redo": ["redid", "redone"], "put": ["put"], "let": ["let"], "fit": ["fit"], "reset": ["reset"],
        ]
        let phrases = showVerbs + hideVerbs + zoomVerbs + selectVerbs + highlightVerbs
        let bases = Set(phrases.compactMap { $0.split(separator: " ").first.map(String.init) })
            .union(["zoom", "fit", "frame", "clear", "remove", "cancel", "reset", "unhighlight", "deselect", "unselect", "undo", "redo", "flip", "turn"])
            .filter { $0.allSatisfy(\.isLetter) }
        var lemmas: [String: String] = [:]
        for base in bases {
            var forms = irregular[base] ?? []
            let last = base.last!
            let stem = base.hasSuffix("e") && !base.hasSuffix("ee") ? String(base.dropLast()) : base
            let esEnding = ["s", "x", "z", "o"].contains(String(last)) || base.hasSuffix("sh") || base.hasSuffix("ch")
            forms.append(esEnding ? base + "es" : base + "s")
            forms.append(contentsOf: [stem + "ing", stem + "ed"])
            if last.isLetter, !"aeiouwxy".contains(last) {
                forms.append(contentsOf: [base + String(last) + "ing", base + String(last) + "ed"])
            }
            for form in forms where form != base {
                lemmas[form] = base
            }
        }
        return lemmas
    }()

    /// Whether `transcript` opens with a verb the grammar knows, whatever
    /// follows it: a settled fragment that was no command yet — "highlight
    /// what", "select the, um" — is the first half of one.
    static func beginsWithVerb(_ transcript: String) -> Bool {
        let text = tidy(transcript)
        guard !text.isEmpty else { return false }
        let verbs = showVerbs + hideVerbs + zoomVerbs + selectVerbs + highlightVerbs
        return remainder(after: verbs, in: text) != nil || ["zoom", "fit", "frame"].contains(text.split(separator: " ").first.map(String.init) ?? "")
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

    /// `text` without the articles and fillers at its front, and whether a
    /// filler was there: "what C113" is "C113", said with a word in the way;
    /// "what" alone is nothing, said with the name still to come.
    private static func withoutLeadingNoise(_ text: String) -> (rest: String, hadFiller: Bool) {
        var words = text.split(separator: " ").map(String.init)
        var hadFiller = false
        while let first = words.first {
            if articles.contains(first) {
                words.removeFirst()
                continue
            }
            guard fillers.contains(first) else { break }
            if first == "what", words.count > 1, ["connects", "joins", "links", "is", "are"].contains(words[1]) { break }
            words.removeFirst()
            hadFiller = true
        }
        return (words.joined(separator: " "), hadFiller)
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
        let (name, hadFiller) = withoutLeadingNoise(said)
        let verb: HorizontalVoiceVerb = {
            switch make([HorizontalDesignObject(kind: .component, name: "")]) {
            case .select: return .select
            case .zoom: return .zoom
            default: return .highlight
            }
        }()
        // "Highlight what", "select the, um": a verb with a word in the way
        // and no name yet is half a sentence, not the bare verb that means
        // the last thing again.
        if name.isEmpty, hadFiller {
            return .unrecognized
        }
        if pronouns.contains(name) || name.isEmpty && !vocabulary.previousSubject.isEmpty {
            return previous(verb, vocabulary: vocabulary)
        }
        // "The nets between C48 and C50", "the nets connecting them": what
        // those parts share. Each part is resolved on its own and has to be
        // one thing; a pronoun is the parts named last. "C48 and C50" alone
        // is both parts.
        if let parts = amongParts(in: name) {
            if parts.count == 1, pronouns.contains(parts[0]) {
                let subject = vocabulary.previousSubject
                return subject.count >= 2 ? .among(verb, subject) : (subject.isEmpty ? .noSubject(verb) : .among(verb, subject))
            }
            var objects: [HorizontalDesignObject] = []
            for part in parts {
                switch one(part, vocabulary: vocabulary) {
                case .success(let object): objects.append(object)
                case .failure(let problem): return HorizontalVoiceCommand(problem)
                }
            }
            return objects.count >= 2 ? .among(verb, objects) : .nothingNamed(said: name, family: nil)
        }
        if name.contains(" and "), !name.hasPrefix("between") {
            let parts = name.components(separatedBy: " and ").map { withoutLeadingNoise($0).rest }.filter { !$0.isEmpty }
            if parts.count > 1 {
                var union: [HorizontalDesignObject] = []
                var whole = true
                for part in parts {
                    let found = HorizontalSpokenMatcher.matches(part, in: vocabulary.objects)
                    let bareKind = HorizontalSpokenMatcher.parseFamily(part)?.rest.isEmpty == true
                    guard found.count == 1 || (found.count > 1 && bareKind && many) else {
                        whole = false
                        break
                    }
                    union.append(contentsOf: found.filter { !union.contains($0) })
                }
                if whole, !union.isEmpty {
                    return make(union)
                }
            }
        }
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

    /// "the nets between A and B", "nets from A to B", "what connects A, B and
    /// C", "the connections among them": the things named, as said — or one
    /// pronoun, for the things named last.
    static func amongParts(in text: String) -> [String]? {
        let patterns = [
            "^(?:what connects |what joins |the |all |)(?:nets?|connections?|wires?|signals?|traces?|links?)?\\s*(?:between|from|connecting|linking|joining|shared by|among|amongst)\\s+(.+)$",
            "^what (?:connects|joins|links) (.+)$",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let rest = String(text[range])
            if pronouns.contains(rest) {
                return [rest]
            }
            var parts = rest.components(separatedBy: " and ")
            if parts.count == 1 {
                parts = rest.components(separatedBy: " to ")
            }
            if parts.count == 1 {
                parts = rest.components(separatedBy: " with ")
            }
            return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return nil
    }

    /// Exactly one thing for `said`, or the command that says why not.
    private static func one(_ said: String, vocabulary: HorizontalVoiceVocabulary) -> Result<HorizontalDesignObject, HorizontalVoiceCommandFailure> {
        let name = withoutArticles(said)
        var found = HorizontalSpokenMatcher.matches(name, in: vocabulary.objects)
        if found.isEmpty {
            let words = name.split(separator: " ").map(String.init)
            if words.count > 1, let run = HorizontalSpokenMatcher.exactMatches(inAnyRunOf: words, in: vocabulary.objects) {
                found = run.matches
            }
        }
        switch found.count {
        case 1: return .success(found[0])
        case 0: return .failure(.nothingNamed(said: name, family: HorizontalSpokenMatcher.parseFamily(name)?.family))
        default: return .failure(.ambiguous(found, said: name))
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

