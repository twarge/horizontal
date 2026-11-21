import Foundation

/// A part's value as what it is, however it is written: "10k", "10 kΩ" and
/// a resistors table's 10000 are one value, and so are "LM358" and "lm358".
/// A part with no value has none, and that matches only another with none.
struct HorizontalPartValue: Equatable, Sendable {
    /// The number the value gives: the one the part declares in its
    /// parametric table (Horizon's tables keep it in a `value` column), else
    /// the one its notation reads as.
    var number: Double?
    /// The value as text, lowercased with its spaces out, for values that
    /// are no number ("8 MHz", "LM358").
    var text: String

    init(_ raw: String, parametric: [String: String] = [:]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(trimmed.lowercased().filter { !$0.isWhitespace })
        number = parametric["value"].flatMap(HorizontalPoolParametricSearch.storedNumber)
            ?? HorizontalElectricalValue.number(trimmed)
    }

    /// Whether the two are one value: the same number, to nine digits, so
    /// 100e-9 is 0.1e-6; or, where neither is a number, the same text.
    func matches(_ other: HorizontalPartValue) -> Bool {
        if let number, let otherNumber = other.number {
            return abs(number - otherNumber) <= 1e-9 * max(abs(number), abs(otherNumber))
        }
        return number == nil && other.number == nil && text == other.text
    }
}

/// The parts a project can draw on, by the entity each is for: what a
/// component's Replace menu chooses from. Built from one scan of the project
/// pool and the pools behind it, so asking it for a component's alternates
/// is a lookup, quick enough for a right-click.
struct HorizontalPartAlternatesCatalog: Sendable {
    struct Part: Equatable, Sendable {
        /// The part as Replace takes it: the project pool's copy when it
        /// has one, as the Pools pane lists it.
        var item: HorizontalPoolLibraryItem
        var packageName: String
        var value: HorizontalPartValue
        /// Whether the project pool already holds the part, so replacing
        /// with it adds nothing to the project.
        var isInProjectPool: Bool

        var uuid: String { item.uuid }
    }

    fileprivate var parts = [String: Part]()
    fileprivate var partIDsByEntity = [String: [String]]()

    /// `items` as a scan of the pools gives them, the project pool's first
    /// and inheritance resolved (`HorizontalPoolLibrary.resolvingInheritance`).
    init(items: [HorizontalPoolLibraryItem], projectPoolURL: URL?) {
        let projectPoolPath = projectPoolURL.map { HorizontalPoolLibrary.canonicalURL($0).path }
        var packageNames = [String: String]()
        for item in items where item.category == .package && packageNames[item.uuid] == nil {
            packageNames[item.uuid] = item.name
        }
        for item in items where item.category == .part {
            let isInProjectPool = projectPoolPath != nil && item.poolURL.standardizedFileURL.path == projectPoolPath
            if parts[item.uuid] != nil {
                if isInProjectPool { parts[item.uuid]?.isInProjectPool = true }
                continue
            }
            parts[item.uuid] = Part(
                item: item,
                packageName: packageNames[item.packageID] ?? "",
                value: HorizontalPartValue(item.value, parametric: item.parametric),
                isInProjectPool: isInProjectPool
            )
            if !item.partEntityID.isEmpty {
                partIDsByEntity[item.partEntityID, default: []].append(item.uuid)
            }
        }
    }

    func part(_ uuid: String) -> Part? {
        parts[uuid.lowercased()]
    }

    /// What a component is, for finding its like: its part's value, or the
    /// value it stores itself while it has no part (or one no pool has).
    fileprivate func value(of target: HorizontalPartReplacement.Target) -> (value: HorizontalPartValue, text: String) {
        if let part = target.partID.flatMap({ self.part($0) }) {
            return (part.value, part.item.value)
        }
        return (HorizontalPartValue(target.value), target.value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The parts that can stand in for the components' as they are: for the
    /// entity they share and of the value they share, in whatever package,
    /// so a 10 kΩ 0603 resistor can become a 10 kΩ 0402. The parts they have
    /// now are among them. Base parts are left out, as Replace refuses them.
    /// Nil when the components are on different entities or have different
    /// values, which no one list can answer.
    func offer(for replacement: HorizontalPartReplacement) -> HorizontalPartAlternatesOffer? {
        guard let entityID = replacement.entityID, let first = replacement.targets.first else {
            return nil
        }
        let wanted = value(of: first)
        guard replacement.targets.allSatisfy({ value(of: $0).value.matches(wanted.value) }) else {
            return nil
        }
        let fitting = (partIDsByEntity[entityID] ?? [])
            .compactMap { parts[$0] }
            .filter { !$0.item.isBasePart && $0.value.matches(wanted.value) }
            .sorted { lhs, rhs in
                let package = lhs.packageName.localizedStandardCompare(rhs.packageName)
                if package != .orderedSame { return package == .orderedAscending }
                if lhs.isInProjectPool != rhs.isInProjectPool { return lhs.isInProjectPool }
                let name = lhs.item.name.localizedStandardCompare(rhs.item.name)
                return name == .orderedSame ? lhs.uuid < rhs.uuid : name == .orderedAscending
            }
        return HorizontalPartAlternatesOffer(replacement: replacement, value: wanted.text, parts: fitting)
    }
}

/// What Replace offers some components: the parts for their entity and of
/// their value.
struct HorizontalPartAlternatesOffer: Equatable {
    var replacement: HorizontalPartReplacement
    /// The value they share, as the first of them writes it; empty when
    /// they have none.
    var value: String
    /// By package, the project pool's before another pool's, then by name.
    var parts: [HorizontalPartAlternatesCatalog.Part]

    /// Whether every one of the components has `part` already.
    func isCurrent(_ part: HorizontalPartAlternatesCatalog.Part) -> Bool {
        replacement.targets.allSatisfy { $0.partID == part.uuid }
    }

    /// The parts that would change something: all but the one every
    /// component already has.
    var others: [HorizontalPartAlternatesCatalog.Part] {
        parts.filter { !isCurrent($0) }
    }
}

/// What Change Value offers some components: the parts for their entity of
/// every other value, so a 10 kΩ resistor can become a 4.7 kΩ one. Value by
/// value, each with the parts that have it.
struct HorizontalPartValuesOffer: Equatable {
    struct Value: Equatable {
        /// The value as the first of its parts writes it.
        var text: String
        /// The number it gives, nil for one that is no number ("LM358").
        var number: Double?
        /// In the components' own package first, then by package, the
        /// project pool's before another pool's, then by name.
        var parts: [HorizontalPartAlternatesCatalog.Part]
    }

    var replacement: HorizontalPartReplacement
    /// Only parts in the package the components have now.
    var samePackage: Bool
    /// Numbers first, rising, then the rest by their text.
    var values: [Value]
}

extension HorizontalPartAlternatesCatalog {
    /// The package every one of the components' parts has, nil when one has
    /// no part a pool holds, or they are in more than one.
    func package(of replacement: HorizontalPartReplacement) -> String? {
        let packages = Set(replacement.targets.map { $0.partID.flatMap { part($0) }?.item.packageID ?? "" })
        guard packages.count == 1, let package = packages.first, !package.isEmpty else {
            return nil
        }
        return package
    }

    /// The parts for the entity the components share, of every value but
    /// the one they all have already, grouped by value. With `samePackage`,
    /// only those in the package the components have now. Parts with no
    /// value, and base parts, are left out. Nil when the components are on
    /// different entities or, for `samePackage`, share no package.
    func values(for replacement: HorizontalPartReplacement, samePackage: Bool) -> HorizontalPartValuesOffer? {
        guard let entityID = replacement.entityID else {
            return nil
        }
        let package = package(of: replacement)
        if samePackage, package == nil {
            return nil
        }
        let current = replacement.targets.map { value(of: $0).value }
        let fitting = (partIDsByEntity[entityID] ?? [])
            .compactMap { parts[$0] }
            .filter { part in
                !part.item.isBasePart && !part.value.text.isEmpty
                    && (!samePackage || part.item.packageID == package)
                    && !current.allSatisfy { $0.matches(part.value) }
            }
            .sorted { lhs, rhs in
                switch (lhs.value.number, rhs.value.number) {
                case let (l?, r?) where l != r: return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil) where lhs.value.text != rhs.value.text: return lhs.value.text < rhs.value.text
                default: break
                }
                let lhsOwn = lhs.item.packageID == package, rhsOwn = rhs.item.packageID == package
                if lhsOwn != rhsOwn { return lhsOwn }
                let byPackage = lhs.packageName.localizedStandardCompare(rhs.packageName)
                if byPackage != .orderedSame { return byPackage == .orderedAscending }
                if lhs.isInProjectPool != rhs.isInProjectPool { return lhs.isInProjectPool }
                let name = lhs.item.name.localizedStandardCompare(rhs.item.name)
                return name == .orderedSame ? lhs.uuid < rhs.uuid : name == .orderedAscending
            }
        var values = [HorizontalPartValuesOffer.Value]()
        for part in fitting {
            if let last = values.last, let first = last.parts.first, first.value.matches(part.value) {
                values[values.count - 1].parts.append(part)
            } else {
                values.append(.init(
                    text: part.item.value.trimmingCharacters(in: .whitespacesAndNewlines),
                    number: part.value.number, parts: [part]))
            }
        }
        return HorizontalPartValuesOffer(replacement: replacement, samePackage: samePackage, values: values)
    }
}
