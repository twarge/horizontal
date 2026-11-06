import Foundation

/// What `$key` and `${key}` in a text stand for, and a text with them filled
/// in, read as Horizon's `interpolate_text` reads them: a key runs over
/// letters, digits, `_` and `:`, a braced one to its `}`, and a key with no
/// value stays as it was written. A key answers to itself, all lowercase and
/// all uppercase, so `$REV` draws what `$rev` does.
///
/// The loaders draw a board's and a sheet's texts through this, and an edit
/// through the same one, so a text draws when it is typed what it draws once
/// the design is read again.
struct HorizontalTextVariables: Hashable {
    private(set) var values: [String: String] = [:]
    /// The title-block values among them, keyed as the design has them: what
    /// a text field's Insert Metadata menu offers. Nil where there is no
    /// design to have them, a pool editor's.
    private(set) var metadata: [String: String]?
    /// What a text that is `$VALUE` and nothing else draws where a symbol's
    /// custom value takes its place, as Horizon's SchematicSymbol::replace_text
    /// has it.
    var customValue: String?

    init() {}

    init(_ values: [String: String]) {
        for (key, value) in values {
            set(key, value)
        }
    }

    /// The design's title-block values — project_title, rev and the rest.
    static func project(_ meta: [String: String]) -> Self {
        var variables = Self(meta)
        variables.metadata = meta
        return variables
    }

    /// The Insert Metadata menu's entries.
    var metadataItems: [HorizontalTextVariableItem] {
        metadata.map(HorizontalTextVariableItem.items(for:)) ?? []
    }

    /// A placed component's: its refdes, value, MPN and manufacturer.
    static func component(refdes: String, value: String, mpn: String? = nil, manufacturer: String? = nil) -> Self {
        var variables = Self()
        variables.set("RD", refdes)
        variables.set("REFDES", refdes)
        variables.set("REF", refdes)
        variables.set("VALUE", value)
        variables.set("VAL", value)
        if let mpn {
            variables.set("MPN", mpn)
        }
        if let manufacturer {
            variables.set("MFR", manufacturer)
        }
        return variables
    }

    static func component(_ details: HorizontalComponentDetails) -> Self {
        component(refdes: details.refdes, value: details.value, mpn: details.mpn, manufacturer: details.manufacturer)
    }

    mutating func set(_ key: String, _ value: String) {
        values[key] = value
        values[key.lowercased()] = value
        values[key.uppercased()] = value
    }

    /// These with `other`'s on top.
    func merging(_ other: Self) -> Self {
        var merged = self
        merged.values.merge(other.values) { _, theirs in theirs }
        if let theirs = other.metadata {
            merged.metadata = (metadata ?? [:]).merging(theirs) { _, theirs in theirs }
        }
        merged.customValue = other.customValue ?? customValue
        return merged
    }

    func resolve(_ text: String) -> String {
        if text == "$VALUE", let customValue {
            return customValue
        }
        guard !values.isEmpty, text.contains("$") else {
            return text
        }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "$" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let afterDollar = text.index(after: index)
            if afterDollar < text.endIndex, text[afterDollar] == "{" {
                let nameStart = text.index(after: afterDollar)
                guard let close = text[nameStart...].firstIndex(of: "}") else {
                    // Never closed: as written.
                    out.append(contentsOf: text[index...])
                    break
                }
                let name = String(text[nameStart..<close])
                out.append(values[name] ?? "${\(name)}")
                index = text.index(after: close)
                continue
            }
            var nameEnd = afterDollar
            while nameEnd < text.endIndex, Self.isKeyCharacter(text[nameEnd]) {
                nameEnd = text.index(after: nameEnd)
            }
            guard nameEnd > afterDollar else {
                out.append("$")
                index = afterDollar
                continue
            }
            let name = String(text[afterDollar..<nameEnd])
            out.append(values[name] ?? "$\(name)")
            index = nameEnd
        }
        return out
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character == "_" || character == ":" || (character.isASCII && (character.isLetter || character.isNumber))
    }
}

extension HorizontalText {
    /// What an editor shows and takes for the text: what the file stores,
    /// `$project_title` rather than the title it draws.
    var editableText: String {
        fileText
    }

    /// Makes `stored` what the text stores, drawing it with `variables`
    /// filled in, so `$rev` typed into a text draws the revision at once and
    /// still saves as `$rev`.
    mutating func setStoredText(_ stored: String, variables: HorizontalTextVariables) {
        let drawn = variables.resolve(stored)
        text = drawn
        placeholder = drawn == stored ? nil : HorizontalTextPlaceholder(stored: stored, drawn: drawn)
    }
}

/// One entry of a text field's Insert Metadata menu: the key, as `$key`
/// inserts it, and what it stands for in this design.
struct HorizontalTextVariableItem: Hashable, Identifiable {
    var key: String
    var title: String
    var value: String

    var id: String { key }

    /// What the field gets: `$key`.
    var code: String { "$\(key)" }

    /// The usual title-block keys first, whether or not the design has a
    /// value for them yet, then any other it has, by name, as the Project
    /// Metadata editor lists them.
    static func items(for meta: [String: String]) -> [HorizontalTextVariableItem] {
        let others = meta.keys
            .filter { !preferredKeys.contains($0) && !(meta[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (preferredKeys + others).map {
            HorizontalTextVariableItem(key: $0, title: title(for: $0), value: meta[$0] ?? "")
        }
    }

    static let preferredKeys = ["project_title", "project_name", "rev", "author", "date", "license"]

    static func title(for key: String) -> String {
        switch key {
        case "project_title": "Title"
        case "project_name": "Project"
        case "rev": "Revision"
        case "author": "Author"
        case "date": "Date"
        case "license": "License"
        default:
            key.split(separator: "_")
                .map { $0.localizedCapitalized }
                .joined(separator: " ")
        }
    }
}

extension HorizontalBoard {
    /// What `$key` stands for in the text `id` names: the board's title-block
    /// values, and for a package's text, its own or one smashed out of it,
    /// its component's on top, as the loader draws them.
    func textVariables(forTextID id: String) -> HorizontalTextVariables {
        guard let range = id.range(of: "/text/") else {
            return textVariables
        }
        let packageID = id[..<range.lowerBound].lowercased()
        guard let details = packages.first(where: { $0.id.lowercased() == packageID })?.componentDetails else {
            return textVariables
        }
        return textVariables.merging(.component(details))
    }
}

extension HorizontalSchematicSheet {
    /// What `$key` stands for in the text `id` names: the sheet's title-block
    /// values, and for a text smashed out of a symbol, its component's and
    /// custom value's on top, as the loader draws them.
    func textVariables(forTextID id: String) -> HorizontalTextVariables {
        let normalized = id.lowercased()
        guard let symbol = symbols.first(where: { $0.smashedTextIDs.contains { $0.lowercased() == normalized } }),
              let details = symbol.componentDetails else {
            return textVariables
        }
        return textVariables.merging(HorizontalSchematic.symbolTextVariables(
            refdes: details.refdes,
            value: details.value,
            details: details,
            customValue: symbol.customValue
        ))
    }
}
