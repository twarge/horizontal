#if os(macOS)
import AppIntents
import Foundation

/// Something in the open design an intent can be pointed at: a component by
/// its reference designator, or a net by its name.
///
/// One entity rather than two, because "highlight R18" and "highlight ground"
/// are the same request with a different subject, and a caller who says a name
/// that is both gets asked which. The id is the name, not the uuid: the
/// dispatch verbs behind these intents take names, and a name is also what
/// the user says. The cost is that renaming a component breaks a saved
/// shortcut that referred to it, which is at least legible when it happens.
struct HorizontalDesignObjectEntity: AppEntity, Identifiable {
    enum Kind: String, AppEnum {
        case component
        case net

        static var typeDisplayRepresentation: TypeDisplayRepresentation { "Kind" }
        static var caseDisplayRepresentations: [Kind: DisplayRepresentation] {
            [.component: "Component", .net: "Net"]
        }
    }

    var kind: Kind
    var name: String
    /// The value for a component, the net class for a net — what tells two
    /// similarly named things apart in a disambiguation list.
    var detail: String

    var id: String { "\(kind.rawValue):\(name)" }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Design Object" }
    static var defaultQuery: HorizontalDesignObjectQuery { HorizontalDesignObjectQuery() }

    var displayRepresentation: DisplayRepresentation {
        let subtitle = detail.isEmpty ? "\(kind == .component ? "Component" : "Net")"
            : "\(kind == .component ? "Component" : "Net") · \(detail)"
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(kind: Kind, name: String, detail: String = "") {
        self.kind = kind
        self.name = name
        self.detail = detail
    }

    /// Rebuilds one from the id a saved shortcut stored, without consulting
    /// the document: a shortcut has to keep meaning something between runs,
    /// and the verbs behind it report a name that is no longer there far
    /// better than a query that quietly drops it.
    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]), !parts[1].isEmpty else {
            return nil
        }
        self.init(kind: kind, name: parts[1])
    }
}

/// Resolves what the user said against the document in front.
///
/// Spoken reference designators arrive in more than one shape — "R18", "R 18",
/// "r18" — so matching ignores case and spaces before falling back to a
/// contains match, which is what makes "highlight ground" find GND_ANALOG when
/// that is the only ground there is.
struct HorizontalDesignObjectQuery: EntityStringQuery {
    func entities(for identifiers: [HorizontalDesignObjectEntity.ID]) async throws -> [HorizontalDesignObjectEntity] {
        let known = await MainActor.run { HorizontalIntentTarget.nameableObjects() }
        return identifiers.compactMap { id in
            known.first { $0.id == id } ?? HorizontalDesignObjectEntity(id: id)
        }
    }

    func entities(matching string: String) async throws -> [HorizontalDesignObjectEntity] {
        let known = await MainActor.run { HorizontalIntentTarget.nameableObjects() }
        return Self.matches(string, in: known)
    }

    func suggestedEntities() async throws -> [HorizontalDesignObjectEntity] {
        await MainActor.run { HorizontalIntentTarget.nameableObjects() }
    }

    /// The matching itself, kept apart from the document so it can be checked
    /// against a known list rather than whatever happens to be open.
    ///
    /// An exact match wins outright: with GND and GND_ANALOG both present,
    /// "ground" is ambiguous but "GND" is not, and returning both there would
    /// make Siri ask a question it does not need to ask.
    static func matches(_ query: String, in known: [HorizontalDesignObjectEntity]) -> [HorizontalDesignObjectEntity] {
        let wanted = spoken(query)
        guard !wanted.isEmpty else { return known }
        let exact = known.filter { spoken($0.name) == wanted }
        return exact.isEmpty ? known.filter { spoken($0.name).contains(wanted) } : exact
    }

    /// A name reduced to what survives being said out loud: case, spaces and
    /// the separators a speaker does not pronounce.
    static func spoken(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
    }
}
#endif
