import Combine
import SwiftUI

/// A symbol's or package's Replace submenu: the parts that can stand in for
/// its component's as it is, for its entity and of its value, so a
/// right-click on a 10 kΩ 0603 resistor offers the 10 kΩ 0402. Each is
/// listed by its package, and one the project pool already holds is badged
/// "In Project": choosing it adds nothing to the project. The part the
/// component has now is checked. Alternate Parts…, the Pools pane on every
/// part for the entity, closes the list.
///
/// A right-click on one of several selected components replaces them all,
/// where one list answers them (one entity, one value), and the submenu's
/// title names them. Otherwise it is about the one right-clicked.
enum HorizontalPartReplaceMenu {
    /// What the submenu is called and lists, before Alternate Parts….
    struct Content {
        var title: String
        var entries: [HorizontalTargetItemMenuEntry]
    }

    /// The most parts a submenu lists; Alternate Parts… has the rest.
    static let limit = 24
    static let inProjectBadge = "In Project"
    static let browseTitle = "Alternate Parts…"

    /// The submenu while the pools are still being read, moments after a
    /// window opens.
    static var loading: Content {
        Content(title: "Replace", entries: [
            .unavailable(title: "Reading the Pools…", reason: "The pools’ parts are still being read. Try again in a moment."),
        ])
    }

    /// The submenu for the component right-clicked. `selection` is the
    /// components selected with it, empty when it isn't among them.
    /// `replacement` finds components in their block. Nil for a component
    /// no block has.
    static func content(
        catalog: HorizontalPartAlternatesCatalog,
        componentID: String,
        selection: Set<String>,
        replacement: (Set<String>) -> HorizontalPartReplacement?
    ) -> Content? {
        var candidates = [Set<String>]()
        if selection.count > 1, selection.contains(componentID) {
            candidates.append(selection)
        }
        candidates.append([componentID])
        for componentIDs in candidates {
            if let replacement = replacement(componentIDs), let offer = catalog.offer(for: replacement) {
                return content(for: offer)
            }
        }
        return nil
    }

    static func content(for offer: HorizontalPartAlternatesOffer, limit: Int = limit) -> Content {
        let replacement = offer.replacement
        let title = replacement.targets.count == 1 ? "Replace" : "Replace \(replacement.refdesList)"
        guard !offer.others.isEmpty else {
            let what = offer.value.isEmpty ? "the same entity" : "the same entity with the value “\(offer.value)”"
            return Content(title: title, entries: [
                .unavailable(title: "No Other Parts", reason: "No pool this project draws on has another part for \(what)."),
            ])
        }

        // A long list keeps what the components have and what the project
        // already holds, then the rest in order.
        var shown = offer.parts
        if shown.count > limit {
            var kept = Set<String>()
            let preferred = shown.filter { offer.isCurrent($0) } + shown.filter(\.isInProjectPool) + shown
            for part in preferred where kept.count < limit {
                kept.insert(part.uuid)
            }
            shown = shown.filter { kept.contains($0.uuid) }
        }
        let componentIDs = replacement.targets.map(\.componentID)
        var entries: [HorizontalTargetItemMenuEntry] = shown.map { part in
            .choice(
                title: Self.title(of: part),
                badge: part.isInProjectPool ? inProjectBadge : nil,
                help: help(for: part),
                isOn: offer.isCurrent(part),
                .replacePart(part: part.uuid, components: componentIDs)
            )
        }
        let hidden = offer.parts.count - shown.count
        if hidden > 0 {
            entries.append(.unavailable(title: "\(hidden) More…", reason: "\(browseTitle) lists every part that fits."))
        }
        return Content(title: title, entries: entries)
    }

    /// The package first, which is what tells one alternate from the next:
    /// "0402 · RC0402FR-0710KL · Yageo". A package named for its one part,
    /// as a connector's often is, is not said twice.
    static func title(of part: HorizontalPartAlternatesCatalog.Part) -> String {
        var words = [String]()
        for word in [part.packageName, part.item.name, part.item.manufacturer] {
            let word = word.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                words.append(word)
            }
        }
        return words.joined(separator: " · ")
    }

    private static func help(for part: HorizontalPartAlternatesCatalog.Part) -> String {
        let pool = part.isInProjectPool
            ? "Already in the project pool."
            : "From \(part.item.poolName). Replace copies it into the project pool."
        let description = part.item.partDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? pool : description + "\n" + pool
    }

    /// The menu's entry: the Replace submenu closing with Alternate Parts…
    /// where there is a Pools pane to show them (`browses`), or Alternate
    /// Parts… alone where nothing can be replaced.
    static func entry(_ content: Content?, browses: Bool) -> HorizontalTargetItemMenuEntry? {
        let browse = HorizontalTargetItemMenuEntry.command(title: browseTitle, .showAlternateParts)
        guard let content else {
            return browses ? browse : nil
        }
        return .submenu(title: content.title, content.entries + (browses ? [.separator, browse] : []))
    }
}

/// What a canvas needs to offer Replace on a component, from the window
/// that can find the component's block and edit it.
struct HorizontalPartReplaceActions {
    /// The submenu for the component right-clicked, with the components
    /// selected along with it (empty when it isn't selected), each by uuid.
    var content: (_ componentID: String, _ selection: Set<String>) -> HorizontalPartReplaceMenu.Content?
    /// Gives the components the part, as one undoable edit.
    var replace: (_ partID: String, _ componentIDs: [String]) -> Void
}

/// Nil where no component can be replaced: a pool window, a locked document.
private struct HorizontalPartReplaceActionsKey: EnvironmentKey {
    static var defaultValue: HorizontalPartReplaceActions? { nil }
}

extension EnvironmentValues {
    var horizonPartReplaceActions: HorizontalPartReplaceActions? {
        get { self[HorizontalPartReplaceActionsKey.self] }
        set { self[HorizontalPartReplaceActionsKey.self] = newValue }
    }
}

/// A project window's catalog of the parts its pools hold, read off the main
/// thread when the window opens and again when a pool changes, so a
/// right-click has it at hand. The catalog it had stays until the next one
/// is ready.
@MainActor
final class HorizontalPartAlternatesStore: ObservableObject {
    private(set) var catalog: HorizontalPartAlternatesCatalog?
    private var task: Task<Void, Never>?

    /// Reads the pools in a moment, once for every request until then: a
    /// write's own invalidation and its save notice make one read.
    func reload(projectPoolURL: URL?) {
        let pools = HorizontalPoolBrowserView.browsedPools(for: .project(poolURL: projectPoolURL))
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else {
                return
            }
            let catalog = await Task.detached(priority: .utility) {
                HorizontalPartAlternatesCatalog(
                    items: HorizontalPoolLibrary.resolvingInheritance(pools.flatMap { pool in
                        HorizontalPoolLibrary.items(inPool: pool.url, poolName: pool.name)
                    }),
                    projectPoolURL: projectPoolURL
                )
            }.value
            guard !Task.isCancelled else {
                return
            }
            self?.catalog = catalog
        }
    }
}

/// Gives the canvases under it Replace (`horizonPartReplaceActions`), from
/// the pools a project at `projectPoolURL` draws on.
struct HorizontalPartReplaceMenuSource: ViewModifier {
    var projectPoolURL: URL?
    /// False where the document can't be edited: no Replace then.
    var isEnabled: Bool
    /// The components a canvas names, as their block has them.
    var replacement: (Set<String>) -> HorizontalPartReplacement?
    /// Replace, as the Pools pane's: the part cached into the project pool
    /// and given to the components.
    var replace: (HorizontalPoolLibraryItem, HorizontalPartReplacement) -> Void

    @StateObject private var store = HorizontalPartAlternatesStore()
    @ObservedObject private var registry = HorizontalPoolRegistry.shared

    func body(content: Content) -> some View {
        content
            .environment(\.horizonPartReplaceActions, isEnabled ? actions : nil)
            .task(id: projectPoolURL) {
                store.reload(projectPoolURL: projectPoolURL)
            }
            .onChange(of: registry.pools) { _, _ in
                store.reload(projectPoolURL: projectPoolURL)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: HorizontalPoolLibrary.poolsDidChangeNotification)
                    .merge(with: NotificationCenter.default.publisher(for: HorizontalPoolLibrary.itemDidSaveNotification))
                    .receive(on: RunLoop.main)
            ) { notification in
                // A saved item is one of ours as likely as not; a changed
                // pool only when it is one this project draws on.
                let pools = HorizontalPoolBrowserView.browsedPools(for: .project(poolURL: projectPoolURL)).map(\.url)
                if notification.name == HorizontalPoolLibrary.itemDidSaveNotification
                    || HorizontalPoolLibrary.notification(notification, concerns: pools) {
                    store.reload(projectPoolURL: projectPoolURL)
                }
            }
    }

    private var actions: HorizontalPartReplaceActions {
        let store = store, replacement = replacement, replace = replace
        return HorizontalPartReplaceActions(
            content: { componentID, selection in
                guard let catalog = store.catalog else {
                    return HorizontalPartReplaceMenu.loading
                }
                return HorizontalPartReplaceMenu.content(
                    catalog: catalog, componentID: componentID, selection: selection, replacement: replacement)
            },
            replace: { partID, componentIDs in
                guard let part = store.catalog?.part(partID), let replacement = replacement(Set(componentIDs)),
                      // The part they all have, checked in the list, is no edit.
                      !replacement.operations(partID: part.uuid, entityID: part.item.partEntityID).isEmpty else {
                    return
                }
                replace(part.item, replacement)
            }
        )
    }
}

extension View {
    func partReplaceMenu(
        projectPoolURL: URL?,
        isEnabled: Bool,
        replacement: @escaping (Set<String>) -> HorizontalPartReplacement?,
        replace: @escaping (HorizontalPoolLibraryItem, HorizontalPartReplacement) -> Void
    ) -> some View {
        modifier(HorizontalPartReplaceMenuSource(
            projectPoolURL: projectPoolURL, isEnabled: isEnabled, replacement: replacement, replace: replace))
    }
}
