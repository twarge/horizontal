import Foundation

/// Find, as the navigator runs it over what a sheet draws: the components
/// whose reference designator, value, MPN, manufacturer or description hold
/// every word searched for. Horizon's own Find only looks at sheet names;
/// a part is found by what it is, so a search for an MPN or a refdes lists
/// the components under the sheets that draw them.
struct HorizontalNavigatorComponentMatch: Identifiable, Hashable {
    var componentID: String
    var refdes: String
    /// Value and MPN, as the row's second line reads them.
    var detail: String?
    /// Where the component's first symbol on the sheet stands, for framing.
    var position: HorizontalPoint

    var id: String { componentID }
}

enum HorizontalNavigatorComponentSearch {
    /// Words as the navigator splits a search: on spaces and commas,
    /// compared without case.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { String($0).lowercased() }
    }

    /// The components on `sheet` matching every token, once each however
    /// many of their gates the sheet draws, in refdes order.
    static func matches(on sheet: HorizontalSchematicSheet, tokens: [String]) -> [HorizontalNavigatorComponentMatch] {
        guard !tokens.isEmpty else { return [] }
        var seen = Set<String>()
        var result = [HorizontalNavigatorComponentMatch]()
        for symbol in sheet.symbols {
            guard let details = symbol.componentDetails,
                  let componentID = (symbol.componentID ?? details.componentID)?.lowercased(),
                  !seen.contains(componentID) else { continue }
            let fields = [details.refdes, details.value, details.mpn, details.manufacturer, details.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let haystack = fields.joined(separator: " ").lowercased()
            guard tokens.allSatisfy(haystack.contains) else { continue }
            seen.insert(componentID)
            var detailFields = [String]()
            for field in [details.value, details.mpn ?? ""] {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !detailFields.contains(trimmed) { detailFields.append(trimmed) }
            }
            result.append(HorizontalNavigatorComponentMatch(
                componentID: componentID,
                refdes: details.refdes,
                detail: detailFields.isEmpty ? nil : detailFields.joined(separator: " · "),
                position: symbol.position
            ))
        }
        return result.sorted { $0.refdes.localizedStandardCompare($1.refdes) == .orderedAscending }
    }
}
