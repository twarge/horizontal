import SwiftUI
import HorizontalProjectIO
#if os(macOS)
import AppKit
#endif

private enum HorizontalPartSearchScope: String, CaseIterable, Identifiable {
    case all
    case mpn
    case value
    case manufacturer
    case description
    case tags

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .mpn: "MPN"
        case .value: "Value"
        case .manufacturer: "Manufacturer"
        case .description: "Description"
        case .tags: "Tags"
        }
    }
}

/// Which parts the Parts pane lists, by where they stand against their pools.
private enum HorizontalPartLibraryFilter: String, CaseIterable, Identifiable {
    case all
    case outOfDate
    case notInAttachedPool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Parts"
        case .outOfDate: "Out of Date"
        case .notInAttachedPool: "Not in an Attached Pool"
        }
    }
}

struct HorizontalPartBrowserView: View {
    var parts: [HorizontalPoolPart]
    var poolURL: URL?
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var isReadOnly = false
    var onPlacePart: (HorizontalPoolPart) -> Void = { _ in }
    /// The document's review of its parts against their pools.
    @ObservedObject var library: HorizontalPartLibraryMonitor
    /// The parts components use, which are listed even when they are only a
    /// base other parts derive from.
    var usedPartIDs: Set<String> = []
    /// The parts some component is fitted with, so a part only Do Not
    /// Populate components use can be hidden; nil hides none for it.
    var populatedPartIDs: Set<String>? = nil
    /// Attached pools a part no attached pool has can be copied into.
    var copyTargets: [HorizontalPoolCopyTarget] = []
    /// Copies a part into a pool (a plan the host confirms first).
    var onCopyToPool: ((HorizontalPoolPart.ID, URL) -> Void)? = nil
    /// Opens the document's Update Project Parts sheet.
    var onReviewUpdates: () -> Void = {}
    /// Opens the project pool cleanup, where the document offers one.
    var onCleanUp: (() -> Void)? = nil
    /// What DigiKey stocks of each part, for the DigiKey Stock column.
    @ObservedObject var digiKey: HorizontalDigiKeyStockMonitor = .shared

    @State private var searchScope: HorizontalPartSearchScope = .all
    @State private var searchText = ""
    @State private var selectedPartID: HorizontalPoolPart.ID?
    @State private var sortOrder = [KeyPathComparator(\HorizontalPoolPart.mpn)]
    @Environment(\.horizonPoolRevealAction) private var poolRevealAction
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    /// For the pool windows Open in … opens.
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    #endif
    @State private var pendingRevealTask: Task<Void, Never>?
    /// A fresh value asks the list to bring the selected part into view
    /// (`HorizontalTableScrollRequest`); a new selection does on its own.
    @State private var scrollToken = 0
    @State private var selectionChangedAt = Date.distantPast
    @State private var libraryFilter = HorizontalPartLibraryFilter.all
    /// Leaves out what isn't bought for the board: parts flagged exclude
    /// from BOM (test pads, mounting holes) and parts only Do Not Populate
    /// components use.
    @AppStorage("Horizontal.partBrowser.hidesExcludedFromBOM") private var hidesExcludedFromBOM = true
    @AppStorage("Horizontal.partBrowser.hidesDoNotPopulate") private var hidesDoNotPopulate = true
    @SceneStorage("Horizontal.partBrowser.columnCustomization")
    private var columnCustomization = TableColumnCustomization<HorizontalPoolPart>()
    /// Where in this pane the keyboard is, if anywhere: Return places only
    /// from here. A window-wide Return placed this pane's part from wherever
    /// else the keyboard was, such as the Pools pane's list, which has its
    /// own Return.
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case search
        case table
    }

    /// The project's parts, less those in its pool only as the base another
    /// derives from: caching a derived part brings its base along, but the
    /// design didn't choose it, unless a component uses it.
    private var listedParts: [HorizontalPoolPart] {
        Self.listedParts(parts, used: usedPartIDs)
    }

    static func listedParts(_ parts: [HorizontalPoolPart], used: Set<String>) -> [HorizontalPoolPart] {
        let bases = Set(parts.compactMap(\.baseID))
        return parts.filter { !bases.contains($0.id.lowercased()) || used.contains($0.id.lowercased()) }
    }

    /// The listed parts the exclusion toggles leave: what a search and the
    /// DigiKey lookups see.
    private var shownParts: [HorizontalPoolPart] {
        listedParts.filter { !isHidden($0) }
    }

    private var hiddenCount: Int {
        listedParts.count { isHidden($0) }
    }

    private func isHidden(_ part: HorizontalPoolPart) -> Bool {
        Self.isHidden(part, used: usedPartIDs, populated: hidesDoNotPopulate ? populatedPartIDs : nil,
                      hidesExcludedFromBOM: hidesExcludedFromBOM)
    }

    /// Whether a part is left out: flagged exclude from BOM, when those are
    /// hidden, or used by components none of which is fitted. A part no
    /// component uses is never Do Not Populate.
    static func isHidden(_ part: HorizontalPoolPart, used: Set<String>, populated: Set<String>?, hidesExcludedFromBOM: Bool) -> Bool {
        if hidesExcludedFromBOM, part.excludeFromBOM {
            return true
        }
        let id = part.id.lowercased()
        if let populated, used.contains(id), !populated.contains(id) {
            return true
        }
        return false
    }

    private var filteredParts: [HorizontalPoolPart] {
        let parts = shownParts
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let filtered = terms.isEmpty
            ? parts
            : parts.filter { part in
                terms.allSatisfy { term in
                    searchableText(for: part).contains(term)
                }
            }
        return filtered.filter(matchesLibraryFilter).sorted(using: sortOrder)
    }

    private func libraryRow(for part: HorizontalPoolPart) -> HorizontalPartLibraryReview? {
        library.review?.parts.first { $0.id.caseInsensitiveCompare(part.id) == .orderedSame }
    }

    private func matchesLibraryFilter(_ part: HorizontalPoolPart) -> Bool {
        switch libraryFilter {
        case .all: true
        case .outOfDate: libraryRow(for: part).map { !$0.changes.isEmpty } ?? false
        case .notInAttachedPool: libraryRow(for: part)?.isInNoAttachedPool ?? false
        }
    }

    private var selectedPart: HorizontalPoolPart? {
        guard let selectedPartID else {
            return nil
        }
        return parts.first { $0.id == selectedPartID }
    }

    private var canPlaceSelectedPart: Bool {
        !isReadOnly && selectedPart?.gates.first?.symbolID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
                .padding(.top, safeAreaInsets.top)
            Divider()
            if parts.isEmpty {
                unavailableView
            } else {
                partTable
            }
        }
        // The pane split runs under the navigator sidebar so canvases can
        // show through it; a table cannot, so keep the content clear of it.
        .padding(.leading, safeAreaInsets.leading)
        .padding(.trailing, safeAreaInsets.trailing)
        .onChange(of: selectedPartID) { _, _ in
            selectionChangedAt = Date()
            pendingRevealTask?.cancel()
            pendingRevealTask = nil
        }
        // A re-sort, or the selection coming back into a filtered list,
        // keeps the selected part where it can be seen.
        .onChange(of: sortOrder) { _, _ in
            scrollToken += 1
        }
        .onChange(of: libraryFilter) { _, _ in
            scrollToken += 1
        }
        // Asks DigiKey about parts it has no fresh answer for whenever the
        // parts or the credentials change, unless the column is hidden.
        .task(id: digiKeyLookupSignature) {
            guard showsDigiKeyStock else { return }
            digiKey.lookUp(shownParts)
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    /// One row; the commands under the search; then, for a pane narrower
    /// than those (the pane split goes down to 280 points), the pickers as
    /// menus behind icons and the commands as icons, so the toolbar always
    /// fits. A wider row in a narrow pane was centred over the pane's edges,
    /// painting the pane's background over its neighbour, left of the table.
    private var browserToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                searchControls(compact: false)
                partCommands(compact: false).fixedSize()
            }
            VStack(spacing: 8) {
                searchControls(compact: false)
                HStack { Spacer(); partCommands(compact: false) }
            }
            VStack(spacing: 8) {
                searchControls(compact: true)
                HStack { Spacer(); partCommands(compact: true) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var scopePicker: some View {
        Picker("Search Field", selection: $searchScope) {
            ForEach(HorizontalPartSearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
    }

    private var libraryFilterPicker: some View {
        Picker("Show", selection: $libraryFilter) {
            ForEach(HorizontalPartLibraryFilter.allCases) { filter in
                Text(filter.title).tag(filter)
            }
        }
    }

    private func searchControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact {
                Menu {
                    scopePicker
                        .pickerStyle(.inline)
                } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Search \(searchScope == .all ? "every field" : searchScope.title)")
            } else {
                scopePicker
                    .labelsHidden()
                    .frame(width: 150)
            }

            TextField("Search Parts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: compact ? 60 : 100)
                .leavesFieldOnEscape()
                .focused($focus, equals: .search)

            if !compact {
                libraryFilterPicker
                    .labelsHidden()
                    .fixedSize()
                    .help("List the parts out of date with their pools, or the ones no attached pool has")
            }

            exclusionMenu(compact: compact)
        }
    }

    /// Compact, the Show picker rides in here too.
    private func exclusionMenu(compact: Bool) -> some View {
        Menu {
            if compact {
                libraryFilterPicker
                    .pickerStyle(.inline)
                Divider()
            }
            Toggle("Hide Parts Excluded from BOM", isOn: $hidesExcludedFromBOM)
            Toggle("Hide Do Not Populate Parts", isOn: $hidesDoNotPopulate)
            Divider()
            Text(hiddenCount == 1 ? "1 part hidden" : "\(hiddenCount) parts hidden")
        } label: {
            Image(systemName: hidesExcludedFromBOM || hidesDoNotPopulate || (compact && libraryFilter != .all)
                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help((compact ? "Showing \(libraryFilter.title). " : "")
              + "Hide test pads, mounting holes and other parts excluded from the BOM, and parts only Do Not Populate components use")
    }

    private func partCommands(compact: Bool) -> some View {
        let updates = library.review?.parts.filter { !$0.changes.isEmpty }.count ?? 0
        return HStack(spacing: 8) {
            Button(action: onReviewUpdates) {
                Label(compact ? "\(updates)" : "Updates (\(updates))", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(library.review == nil)
            .help("Review project parts against their source libraries (\(updates == 1 ? "1 update" : "\(updates) updates"))")

            if let onCleanUp {
                Button(action: onCleanUp) {
                    commandLabel("Clean Up…", systemImage: "trash", compact: compact)
                }
                .disabled(isReadOnly)
                .help("Remove project pool items nothing in the design uses")
            }

            Button { library.recheck() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(library.isChecking)
            .help("Check source libraries again")

            Button {
                placeSelectedPart()
            } label: {
                commandLabel("Place", systemImage: "plus.square.on.square", compact: compact)
            }
            .keyboardShortcut(focus == nil ? nil : KeyboardShortcut(.return, modifiers: []))
            .disabled(!canPlaceSelectedPart)
            .help("Place the selected part in the schematic")
        }
    }

    @ViewBuilder
    private func commandLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    /// The sum of the columns' minimum widths (plus row insets): the least
    /// width at which every column is still legible.
    private static let minimumTableWidth: CGFloat = 1240

    private static let digiKeyStockColumnID = "digikeyStock"

    private var showsDigiKeyStock: Bool {
        columnCustomization[visibility: Self.digiKeyStockColumnID] != .hidden
    }

    private var digiKeyLookupSignature: String {
        guard digiKey.isConfigured, showsDigiKeyStock else { return "" }
        let keys = shownParts.map { HorizontalDigiKeyQuery(part: $0).key }.sorted()
        return "\(digiKey.credentialsRevision)\u{1E}" + keys.joined(separator: "\u{1E}")
    }

    private var partTable: some View {
        // Table has no horizontal scrolling of its own — when the pane is
        // narrower than the columns it just clips them — so it rides in a
        // horizontal ScrollView pinned to no less than the columns' minimum
        // width. Vertical scrolling stays the table's own.
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                sortableTable
                    .frame(
                        width: max(proxy.size.width, Self.minimumTableWidth),
                        height: proxy.size.height
                    )
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
        }
    }

    /// The selected part's row, for the list's scroll anchor.
    private func scrollRequest(in rows: [HorizontalPoolPart]) -> HorizontalTableScrollRequest? {
        guard let selectedPartID, let row = rows.firstIndex(where: { $0.id == selectedPartID }) else {
            return nil
        }
        return HorizontalTableScrollRequest(rowID: selectedPartID, row: row, rowCount: rows.count, centers: false, token: scrollToken)
    }

    private var sortableTable: some View {
        let rows = filteredParts
        return Table(
            rows,
            selection: $selectedPartID,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("MPN", value: \.mpn) { part in
                poolLinkText(part.mpn, part: part, category: .part)
            }
            .width(min: 130, ideal: 180)
            .customizationID("mpn")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Library Status") { part in
                if let row = libraryRow(for: part) {
                    Label(row.statusTitle, systemImage: row.status.symbol)
                        .foregroundStyle(row.status == .current || row.status == .projectOnly ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .help(row.message.isEmpty ? row.sourcePool.map { "From \($0)" } ?? row.statusTitle : row.message)
                } else {
                    Text(library.isChecking ? "Checking" : "Unavailable").foregroundStyle(.secondary)
                }
            }
            .width(min: 175, ideal: 185)
            .customizationID("libraryStatus")

            // The pool a part is kept up to date from; none where no attached
            // pool has it.
            TableColumn("Source Pool") { part in
                if let row = libraryRow(for: part) {
                    Text(row.sourcePool ?? (row.status == .projectOnly ? "This project" : "None attached"))
                        .foregroundStyle(row.sourcePool != nil ? Color.primary : row.status == .projectOnly ? Color.secondary : Color.orange)
                        .lineLimit(1)
                } else {
                    Text("")
                }
            }
            .width(min: 110, ideal: 140)
            .customizationID("sourcePool")

            TableColumn("Value", value: \.value) { part in
                tableText(part.value, part: part)
            }
            .width(min: 90, ideal: 120)
            .customizationID("value")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Manufacturer", value: \.manufacturer) { part in
                poolLinkText(part.manufacturer, part: part, category: .part)
            }
            .width(min: 120, ideal: 150)
            .customizationID("manufacturer")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Description", value: \.partDescription) { part in
                tableText(part.partDescription, part: part)
            }
            .width(min: 220, ideal: 360)
            .customizationID("description")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Package", value: \.packageName) { part in
                poolLinkText(part.packageName, part: part, category: .package)
            }
            .width(min: 110, ideal: 140)
            .customizationID("package")
            .disabledCustomizationBehavior(.visibility)

            // DigiKey's stock of the part's MPN. Not sortable: like the
            // library columns, it comes from outside the part.
            TableColumn("DigiKey Stock") { part in
                digiKeyStockCell(part)
            }
            .width(min: 100, ideal: 110)
            .customizationID(Self.digiKeyStockColumnID)

            TableColumn("Tags", value: \.tagList) { part in
                tableText(part.tagList, part: part)
            }
            .width(min: 140, ideal: 220)
            .customizationID("tags")
            .disabledCustomizationBehavior(.visibility)
        }
        // Alternating row backgrounds are a macOS-only Table modifier.
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .textSelection(.enabled)
        .tableScrollRequest(scrollRequest(in: rows))
        .contextMenu(forSelectionType: HorizontalPoolPart.ID.self) { ids in
            if let id = ids.first, let part = parts.first(where: { $0.id == id }) {
                partContextMenu(part)
            }
        }
        .focused($focus, equals: .table)
    }

    /// Place, and for a part no attached pool has, a copy into one of them;
    /// then the part in a pool: this window's Pools pane, and, as the Pools
    /// pane's own Open in … entries do, a window on the project pool or on
    /// the pool the part was cached from, scrolled to it there.
    @ViewBuilder
    private func partContextMenu(_ part: HorizontalPoolPart) -> some View {
        if !isReadOnly, part.gates.first?.symbolID != nil {
            Button("Place in Schematic") { place(part) }
        }
        if let onCopyToPool, !isReadOnly, !copyTargets.isEmpty, libraryRow(for: part)?.isInNoAttachedPool == true {
            Menu("Copy to Pool") {
                ForEach(copyTargets) { target in
                    Button(target.name) { onCopyToPool(part.id, target.url) }
                }
            }
        }
        #if os(macOS)
        let pools = Self.poolsToOpen(part, projectPoolURL: poolURL, review: libraryRow(for: part))
        #else
        // No pool windows on iPadOS: the Pools pane is where a pool opens.
        let pools = [HorizontalPoolCopyTarget]()
        #endif
        if poolRevealAction != nil || !pools.isEmpty {
            Divider()
        }
        if let poolRevealAction {
            Button("Show in Pools Pane") {
                poolRevealAction(HorizontalPoolRevealRequest(category: .part, uuid: part.id))
            }
        }
        #if os(macOS)
        ForEach(pools) { pool in
            Button("Open in \(pool.name)") {
                HorizontalPoolWindowManager.shared.open(
                    poolURL: pool.url,
                    reveal: HorizontalPoolRevealRequest(category: .part, uuid: part.id),
                    appearanceSettings: appearanceSettings
                )
            }
        }
        #endif
        let stock = digiKey.state(for: part)
        if stock != .noMPN, stock != .notSetUp {
            Divider()
            if let url = stock.productURL {
                Link("Open on DigiKey", destination: url)
            }
            Button("Check DigiKey Stock Again") { digiKey.lookUp([part], force: true) }
        }
    }

    /// The pools a part can be opened in, each in a window of its own: the
    /// project's pool, which every listed part is in (named as the Pools pane
    /// names it), then the pools the library review found it came from. A
    /// pool that can't be read now (the sandbox wants a folder grant) is left
    /// out, as is the project pool once more under another name.
    static func poolsToOpen(
        _ part: HorizontalPoolPart,
        projectPoolURL: URL?,
        review: HorizontalPartLibraryReview?
    ) -> [HorizontalPoolCopyTarget] {
        var pools = [HorizontalPoolCopyTarget]()
        var seen = Set<String>()
        func add(_ url: URL, name: String) {
            let canonical = HorizontalPoolLibrary.canonicalURL(url)
            guard HorizontalPoolLibrary.accessError(for: canonical) == nil, seen.insert(canonical.path).inserted else {
                return
            }
            pools.append(HorizontalPoolCopyTarget(url: canonical, name: name))
        }
        if let projectPoolURL {
            add(projectPoolURL, name: "Project pool")
        }
        for url in review?.sourcePoolURLs ?? [] {
            add(url, name: HorizontalPoolRegistryStore.poolInfo(at: url).name)
        }
        return pools
    }

    /// The part's stock at DigiKey, in the packaging Settings chooses: a
    /// count, right-aligned, orange when none is left or the part is winding
    /// down, and a link to the part's DigiKey page; its tooltip names the
    /// DigiKey part numbers behind it.
    @ViewBuilder
    private func digiKeyStockCell(_ part: HorizontalPoolPart) -> some View {
        let state = digiKey.state(for: part)
        let text = Text(state.title)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: state.isNumeric ? .trailing : .leading)
            .contentShape(Rectangle())
        if let url = state.productURL {
            Button { openURL(url) } label: {
                text.foregroundStyle(state.isWarning ? Color.orange : Color.accentColor)
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .pointerStyle(.link)
            #endif
            .help(state.help(for: part))
        } else {
            text
                .foregroundStyle(state.isWarning ? Color.orange : state.isNumeric ? Color.primary : Color.secondary)
                .onTapGesture(count: 2) {
                    place(part)
                }
                .help(state.help(for: part))
        }
    }

    private var unavailableView: some View {
        // Greedy frame so the toolbar stays pinned to the top — without it the
        // enclosing VStack hugs its content and floats to the pane's center.
        ContentUnavailableView(
            "No Parts",
            systemImage: "list.bullet.rectangle",
            description: Text(poolURL.map { "No cached parts were found in \($0.path)." } ?? "This project does not declare a pool directory.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tableText(_ value: String, part: HorizontalPoolPart) -> some View {
        Text(value.isEmpty ? "-" : value)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                place(part)
            }
    }

    /// MPN, manufacturer and package: on the selected row they are links into
    /// the Pools pane. A click on one waits out the double-click interval so
    /// that a double-click — including one whose first click selected the
    /// row — still places the part.
    @ViewBuilder
    private func poolLinkText(_ value: String, part: HorizontalPoolPart, category: HorizontalPoolItemCategory) -> some View {
        if selectedPartID == part.id, !value.isEmpty, let poolRevealAction {
            Button {
                clickPoolLink(value, part: part, category: category, reveal: poolRevealAction)
            } label: {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show “\(value)” in the Pools pane (double-click places the part)")
        } else {
            tableText(value, part: part)
        }
    }

    private func clickPoolLink(
        _ value: String,
        part: HorizontalPoolPart,
        category: HorizontalPoolItemCategory,
        reveal: @escaping (HorizontalPoolRevealRequest) -> Void
    ) {
        let interval = Self.doubleClickInterval
        let isSecondClick = pendingRevealTask != nil || Date().timeIntervalSince(selectionChangedAt) < interval
        pendingRevealTask?.cancel()
        pendingRevealTask = nil
        if isSecondClick {
            place(part)
            return
        }
        pendingRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else {
                return
            }
            pendingRevealTask = nil
            reveal(HorizontalPoolRevealRequest(search: HorizontalPoolSearch(category: category, term: value)))
        }
    }

    private static var doubleClickInterval: TimeInterval {
        #if os(macOS)
        NSEvent.doubleClickInterval
        #else
        0.3
        #endif
    }

    private func placeSelectedPart() {
        guard let selectedPart else {
            return
        }
        place(selectedPart)
    }

    private func place(_ part: HorizontalPoolPart) {
        guard !isReadOnly,
              part.gates.first?.symbolID != nil else {
            return
        }
        onPlacePart(part)
    }

    private func searchableText(for part: HorizontalPoolPart) -> String {
        switch searchScope {
        case .all:
            return [
                part.mpn,
                part.value,
                part.manufacturer,
                part.partDescription,
                part.packageName,
                part.tagList
            ].joined(separator: "\n").lowercased()
        case .mpn:
            return part.mpn.lowercased()
        case .value:
            return part.value.lowercased()
        case .manufacturer:
            return part.manufacturer.lowercased()
        case .description:
            return part.partDescription.lowercased()
        case .tags:
            return part.tagList.lowercased()
        }
    }
}
