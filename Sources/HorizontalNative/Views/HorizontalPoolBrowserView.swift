import SwiftUI
import UniformTypeIdentifiers

/// What a library browser is rooted at: a project's pool plus the base pools
/// it can draw from, or one pool on its own plus the pools it includes.
enum HorizontalPoolBrowserRoot: Hashable {
    case project(poolURL: URL?)
    case pool(URL)
}

/// A term to look for in one category of the Pools pane: a part's MPN or
/// manufacturer among the parts, a package name among the packages.
struct HorizontalPoolSearch: Equatable {
    var category: HorizontalPoolItemCategory
    var term: String
}

/// Asks the browser to show one item — switch to its category, clear the
/// search and select it — or, with `search` set, to switch to the category
/// and filter it to the term. A fresh `id` per request means asking for the
/// same thing twice still applies it.
struct HorizontalPoolRevealRequest: Equatable {
    var id = UUID()
    var category: HorizontalPoolItemCategory
    var uuid: String
    var search: String? = nil

    init(category: HorizontalPoolItemCategory, uuid: String) {
        self.category = category
        self.uuid = uuid
    }

    init(item: HorizontalPoolLibraryItem) {
        self.init(category: item.category, uuid: item.uuid)
    }

    init(search: HorizontalPoolSearch) {
        category = search.category
        uuid = ""
        self.search = search.term
    }
}

/// The window's way of showing something in its Pools pane, for views that
/// sit far from it: the selection inspector's MPN, manufacturer and package
/// rows, the Parts pane's cells. Nil where there is no Pools pane.
private struct HorizontalPoolRevealActionKey: EnvironmentKey {
    static var defaultValue: ((HorizontalPoolRevealRequest) -> Void)? { nil }
}

extension EnvironmentValues {
    var horizonPoolRevealAction: ((HorizontalPoolRevealRequest) -> Void)? {
        get { self[HorizontalPoolRevealActionKey.self] }
        set { self[HorizontalPoolRevealActionKey.self] = newValue }
    }
}

/// What a project window's Pools pane can do with a part, as Horizon's part
/// browser has Place Part and Assign Part: place it on the schematic, or give
/// it to the components selected in the workspace.
struct HorizontalPoolPartActions {
    /// Starts placing a part; nil when nothing can be placed, and then
    /// `placeUnavailableReason` says why.
    var place: ((HorizontalPoolLibraryItem) -> Void)?
    var placeUnavailableReason: String?
    /// The components selected in the workspace, nil when there are none.
    var replacement: HorizontalPartReplacement?
    /// Gives the selected components a part as one undoable edit. The string
    /// is the part's package's name, for what Replace says when it can't
    /// change a package.
    var replace: ((HorizontalPoolLibraryItem, String, HorizontalPartReplacement) -> Void)?
    /// The attached pools a part of the project's pool can be copied into:
    /// none for a part an attached pool already has.
    var copyTargets: ((HorizontalPoolLibraryItem) -> [HorizontalPoolCopyTarget])? = nil
    /// Copies a part into a pool (a plan the host confirms first).
    var copyToPool: ((HorizontalPoolLibraryItem, URL) -> Void)? = nil
}

/// The library browser: Horizon's pool manager for this app. Browses every
/// pool a project can draw from — the project pool plus registered/discovered
/// base pools — across the pool item kinds (units, symbols, entities,
/// padstacks, packages, parts, frames, decals), with search, a preview of the
/// selected item below the list, and a Pools menu to register additional
/// pool directories (e.g. a horizon-pool checkout), rescan them or open one
/// in its own window. Parts can also be searched parametrically, by a table's
/// values, in a bar under the toolbar.
///
/// In a project window, Place puts the selected part on the schematic. With
/// components selected in the workspace the list shows only the parts that
/// fit them, and Place becomes Replace, as Horizon's part browser shows only
/// the entity's parts and makes Assign Part the suggested action.
struct HorizontalPoolBrowserView: View {
    var root: HorizontalPoolBrowserRoot
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var revealRequest: HorizontalPoolRevealRequest? = nil
    /// Set by a project window: Place and Replace for parts (the toolbar's
    /// button, double-click, Return, the context menu). Nil in a pool window.
    var partActions: HorizontalPoolPartActions? = nil

    @ObservedObject private var registry = HorizontalPoolRegistry.shared
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
    #if os(iOS)
    @State private var editingItem: HorizontalPoolLibraryItem?
    #endif
    @State private var category: HorizontalPoolItemCategory = .part
    @State private var searchText = ""
    @State private var items: [HorizontalPoolLibraryItem] = []
    @State private var index = HorizontalPoolLibraryIndex.empty
    @State private var isLoading = false
    @State private var selectedItemID: HorizontalPoolLibraryItem.ID?
    @State private var sortOrder = [KeyPathComparator(\HorizontalPoolLibraryItem.name)]
    @State private var isImportingPool = false
    @State private var addPoolFailurePath: String?
    @State private var scanGeneration = 0
    @State private var showsPreview = true
    @State private var pendingReveal: HorizontalPoolRevealRequest?
    @State private var creationError: String?
    @State private var pickerRequest: PoolItemPickerRequest?
    /// Pools > View: one browsed pool's own items (its `BrowsedPool.id`), or
    /// nil for all of them, one row per item.
    @State private var viewedPoolID: BrowsedPool.ID?
    /// The selection whose banner was closed: Horizon's entity info bar,
    /// whose close button goes back to showing every part and placing. A
    /// different selection brings Replace back.
    @State private var dismissedReplacementKey: String?
    /// The parametric bar: shown or behind the toolbar's disclosure triangle,
    /// kept across launches; the browsed pools' tables; the one chosen, nil for
    /// every part; its filters and the list's sort.
    @AppStorage("poolBrowser.showsParametricFilters") private var showsParametricFilters = false
    @State private var parametricTables: [HorizontalParametricTable] = []
    @State private var parametricTableName: String?
    @State private var parametricFilters = HorizontalParametricFilters()
    @State private var parametricSortOrder = [HorizontalParametricRowComparator(key: HorizontalParametricRowComparator.mpn)]
    @FocusState private var isListFocused: Bool
    /// `visibleItems` for the pool in view, kept from one scan or view
    /// change to the next rather than worked out on every pass of the body:
    /// with the arrows walking a list of thousands, each step is one.
    @State private var visibleRows: [HorizontalPoolLibraryItem] = []

    /// A "choose an item" step of a creation flow (a symbol's unit, a part's
    /// entity and package).
    struct PoolItemPickerRequest: Identifiable {
        var id = UUID()
        var title: String
        var category: HorizontalPoolItemCategory
        var onPick: (HorizontalPoolLibraryItem) -> Void
    }

    /// What the New menu offers, in Horizon's pool manager order.
    enum NewItemKind: String, CaseIterable, Identifiable {
        case unit, entity, symbol, part, package, padstack, frame, decal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .unit: "Unit"
            case .entity: "Entity"
            case .symbol: "Symbol…"
            case .part: "Part…"
            case .package: "Package"
            case .padstack: "Padstack"
            case .frame: "Frame"
            case .decal: "Decal"
            }
        }

        var category: HorizontalPoolItemCategory {
            switch self {
            case .unit: .unit
            case .entity: .entity
            case .symbol: .symbol
            case .part: .part
            case .package: .package
            case .padstack: .padstack
            case .frame: .frame
            case .decal: .decal
            }
        }
    }

    struct BrowsedPool: Identifiable, Hashable {
        var url: URL
        var name: String
        var isProjectPool: Bool
        /// Why the pool can't be read right now (sandbox), or nil.
        var accessError: String?

        var id: String { url.path }
        var isReadable: Bool { accessError == nil }
    }

    /// The pools the browser (and the padstack pickers) can see, project pool
    /// first — the same resolution order HorizontalPoolPadstacks uses. A
    /// standalone pool browses itself plus the pools it includes.
    private var browsedPools: [BrowsedPool] {
        var result = [BrowsedPool]()
        var seen = Set<String>()

        func add(_ url: URL, name: String?, isProjectPool: Bool) {
            let canonical = HorizontalPoolLibrary.canonicalURL(url)
            guard seen.insert(canonical.path).inserted else {
                return
            }
            result.append(
                BrowsedPool(
                    url: canonical,
                    name: name ?? HorizontalPoolRegistryStore.poolInfo(at: canonical).name,
                    isProjectPool: isProjectPool,
                    accessError: HorizontalPoolLibrary.accessError(for: canonical)
                )
            )
        }

        // Registered pools restore their security scopes on first use; make
        // sure that has happened before any pool is probed for readability.
        let registeredURLs = HorizontalPoolRegistryStore.poolURLs()

        switch root {
        case .project(let projectPoolURL):
            if let projectPoolURL {
                add(projectPoolURL, name: "Project pool", isProjectPool: true)
            }
            let baseURLs = projectPoolURL.map { HorizontalPoolPadstacks.basePoolURLs(for: $0) } ?? registeredURLs
            for url in baseURLs {
                add(url, name: nil, isProjectPool: false)
            }
        case .pool(let poolURL):
            add(poolURL, name: nil, isProjectPool: false)
            for url in Self.includedPoolURLs(for: poolURL) {
                add(url, name: nil, isProjectPool: false)
            }
        }
        return result
    }

    private var unreadablePools: [BrowsedPool] {
        browsedPools.filter { !$0.isReadable }
    }

    /// A standalone pool window whose own pool can't be read has nothing to
    /// show but the way to fix that.
    private var unreadableRootPool: BrowsedPool? {
        guard case .pool = root, let pool = browsedPools.first, !pool.isReadable else {
            return nil
        }
        return pool
    }

    static func includedPoolURLs(for poolURL: URL) -> [URL] {
        HorizontalPoolLibrary.includedPoolURLs(for: poolURL)
    }

    /// The pool Pools > View narrows the list to, or nil for all of them.
    private var viewedPool: BrowsedPool? {
        viewedPoolID.flatMap { id in browsedPools.first { $0.id == id } }
    }

    /// What the list shows before the search: with every pool in view, one
    /// row per item, the first pool's copy (the project pool comes first, and
    /// its copy is what the project uses, as Horizon's pool database keeps
    /// one row per uuid with the project pool's overriding); with one pool in
    /// view, that pool's own items, cached copies and all. Either way a row
    /// names every pool holding the item, its own first, so a part cached in
    /// the project pool still says where it came from.
    static func visibleItems(_ items: [HorizontalPoolLibraryItem], viewing poolURL: URL?) -> [HorizontalPoolLibraryItem] {
        let holders = HorizontalPoolLibrary.holders(items)
        if let poolURL {
            let path = poolURL.standardizedFileURL.path
            return items
                .filter { $0.poolURL.standardizedFileURL.path == path }
                .map { HorizontalPoolLibrary.naming($0, holders: holders) }
        }
        var seen = Set<String>()
        return items
            .filter { seen.insert($0.itemKey).inserted }
            .map { HorizontalPoolLibrary.naming($0, holders: holders) }
    }

    /// The search: every word is somewhere in the row, the pool column
    /// included, so "twinleaf tps62172" finds a part Twinleaf Pool holds even
    /// where the row shows the project pool's copy.
    static func matches(_ terms: [String], _ item: HorizontalPoolLibraryItem) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = [item.name, item.detail, item.manufacturer, item.tags, item.poolsLabel, item.uuid]
            .joined(separator: "\n")
            .lowercased()
        return terms.allSatisfy(haystack.contains)
    }

    /// What the list shows of `items`, before sorting: the kind, the
    /// search, and, while components are being replaced, only the parts that
    /// fit them.
    static func listed(
        _ items: [HorizontalPoolLibraryItem],
        category: HorizontalPoolItemCategory,
        search: String,
        replacement: HorizontalPartReplacement?
    ) -> [HorizontalPoolLibraryItem] {
        let terms = search
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let replacement = category == .part ? replacement : nil
        return items.filter { item in
            item.category == category && Self.matches(terms, item) && (replacement?.isCompatible(item) ?? true)
        }
    }

    private var listedItems: [HorizontalPoolLibraryItem] {
        Self.listed(visibleRows, category: category, search: searchText, replacement: activeReplacement)
    }

    private func updateVisibleRows() {
        visibleRows = Self.visibleItems(items, viewing: viewedPool?.url)
    }

    private var filteredItems: [HorizontalPoolLibraryItem] {
        listedItems.sorted(using: sortOrder)
    }

    /// The selection Replace acts on: the window's, unless its banner was
    /// closed for it.
    private var activeReplacement: HorizontalPartReplacement? {
        guard let replacement = partActions?.replacement, replacement.key != dismissedReplacementKey else {
            return nil
        }
        return replacement
    }

    /// The parametric table the list shows, while parts are listed.
    private var parametricTable: HorizontalParametricTable? {
        guard category == .part, let parametricTableName else {
            return nil
        }
        return parametricTables.first { $0.name == parametricTableName }
    }

    /// The table's parts among those listed, before its filters.
    private func parametricRows(in table: HorizontalParametricTable) -> [HorizontalParametricRow] {
        HorizontalPoolParametricSearch.rows(listedItems, table: table) { packageID in
            packageID.isEmpty ? "" : index.name(.package, uuid: packageID) ?? ""
        }
    }

    private var selectedItem: HorizontalPoolLibraryItem? {
        guard let selectedItemID else {
            return nil
        }
        return items.first { $0.id == selectedItemID }
    }

    /// Changes to any of these require a rescan: the pool set (registration,
    /// project) or an explicit refresh.
    private var scanKey: String {
        browsedPools.map(\.id).joined(separator: "|") + "|\(scanGeneration)"
    }

    var body: some View {
        VStack(spacing: 0) {
            browserToolbar
                .padding(.top, safeAreaInsets.top)
            Divider()
            if category == .part && showsParametricFilters {
                parametricBar
                Divider()
            }
            replacementBanner
            if browsedPools.isEmpty {
                noPoolsView
            } else if let pool = unreadableRootPool {
                needsAccessView(pool)
            } else {
                splitContent
            }
        }
        // Same as the Parts pane: as the leftmost pane this would otherwise
        // run under the navigator sidebar.
        .padding(.leading, safeAreaInsets.leading)
        .padding(.trailing, safeAreaInsets.trailing)
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
        .task(id: scanKey) {
            await reloadItems()
        }
        // An item saved from its editor shows its new name and metadata here.
        .onReceive(
            NotificationCenter.default.publisher(for: HorizontalPoolLibrary.itemDidSaveNotification)
                .receive(on: RunLoop.main)
        ) { _ in
            scanGeneration += 1
        }
        .onAppear {
            if let revealRequest {
                pendingReveal = revealRequest
                applyPendingReveal()
            }
        }
        .onChange(of: revealRequest) { _, request in
            pendingReveal = request
            applyPendingReveal()
        }
        .onAppear(perform: adoptReplacement)
        .onChange(of: viewedPoolID) { _, _ in
            updateVisibleRows()
        }
        .onChange(of: partActions?.replacement?.key) { _, key in
            // Closing the banner holds for that selection only: once the
            // selection changes, coming back to it brings Replace back.
            if key != dismissedReplacementKey {
                dismissedReplacementKey = nil
            }
            adoptReplacement()
        }
        .onChange(of: parametricTableName) { _, _ in
            parametricFilters.reset()
            parametricSortOrder = [HorizontalParametricRowComparator(key: HorizontalParametricRowComparator.mpn)]
        }
        #if os(iOS)
        .fullScreenCover(item: $editingItem) { item in
            HorizontalPoolItemEditorCover(item: item) {
                editingItem = nil
            }
            .environmentObject(appearanceSettings)
        }
        #endif
        .fileImporter(isPresented: $isImportingPool, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else {
                return
            }
            addPool(at: url)
        }
        .alert(
            "Not a Horizon Pool",
            isPresented: Binding(
                get: { addPoolFailurePath != nil },
                set: { if !$0 { addPoolFailurePath = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("“\(addPoolFailurePath ?? "")” has no pool.json, so it can’t be added as a pool.")
        }
        .alert(
            "Could Not Create Item",
            isPresented: Binding(
                get: { creationError != nil },
                set: { if !$0 { creationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(creationError ?? "")
        }
        .sheet(item: $pickerRequest) { request in
            HorizontalPoolItemPickerSheet(
                title: request.title,
                category: request.category,
                index: index,
                onPick: { item in
                    pickerRequest = nil
                    request.onPick(item)
                },
                onCancel: { pickerRequest = nil }
            )
        }
    }

    // MARK: - Layout

    /// The list above, the selected item's preview below. macOS gets a real
    /// split with a draggable divider; iPadOS a fixed proportion.
    @ViewBuilder
    private var splitContent: some View {
        #if os(macOS)
        VSplitView {
            listArea
                .frame(minHeight: 120)
            if showsPreview {
                previewPane
                    .frame(minHeight: 120)
            }
        }
        #else
        GeometryReader { proxy in
            VStack(spacing: 0) {
                listArea
                    .frame(height: showsPreview ? proxy.size.height * 0.55 : proxy.size.height)
                if showsPreview {
                    Divider()
                    previewPane
                }
            }
        }
        #endif
    }

    /// A part's links (its entity, units, symbols, package…) reveal the item
    /// here, as the context menu's "Show …" entries do.
    private var previewPane: some View {
        HorizontalPoolItemPreviewView(item: selectedItem, index: index) { request in
            reveal(request)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Greedy frames keep the toolbar pinned to the top: without them the
    // VStack hugs its content and floats to the pane's center.
    private var noPoolsView: some View {
        ContentUnavailableView(
            "No Pools",
            systemImage: "books.vertical",
            description: Text("This project has no pool. Use Pools > Add Pool… to register one, e.g. a horizon-pool checkout.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The sandbox lets the app see that a pool exists without letting it
    /// read the folder; the fix is a folder grant, kept as a registered pool
    /// so it survives relaunches.
    private func needsAccessView(_ pool: BrowsedPool) -> some View {
        ContentUnavailableView {
            Label("Needs Access to “\(pool.url.lastPathComponent)”", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(
                "Horizontal found this pool at \(pool.url.path) but isn’t allowed to read it.\n\(pool.accessError ?? "")\n\nGrant access to browse it; the pool is registered so the grant persists."
            )
        } actions: {
            Button("Grant Access…") {
                grantAccess(to: pool.url)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyListDescription: String {
        var text = searchText.isEmpty
            ? viewedPool.map { "\($0.name) contains no \(category.title.lowercased())." }
                ?? "None of the browsed pools contain \(category.title.lowercased())."
            : "No \(category.title.lowercased()) match “\(searchText)”\(viewedPool.map { " in \($0.name)" } ?? "")."
        if category == .part, let replacement = activeReplacement {
            text = replacement.problem
                ?? (searchText.isEmpty
                    ? "No part for \(entityName(of: replacement)), the entity of \(replacement.refdesList), is in \(viewedPool?.name ?? "the browsed pools")."
                    : "No part for \(entityName(of: replacement)) matches “\(searchText)”\(viewedPool.map { " in \($0.name)" } ?? "").")
        }
        let unreadable = unreadablePools
        if !unreadable.isEmpty {
            let names = unreadable.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
            text += "\n\nHorizontal isn’t allowed to read \(names). Use Pools > Grant Access… to browse \(unreadable.count == 1 ? "it" : "them")."
        }
        return text
    }

    /// The list. While parts are listed, a chosen table shows its parts,
    /// narrowed by its filters, with a column for each of its values.
    @ViewBuilder
    private var listArea: some View {
        if category == .part, let table = parametricTable {
            parametricListContent(table, rows: HorizontalPoolParametricSearch.filter(parametricRows(in: table), by: parametricFilters.applied))
        } else {
            listContent
        }
    }

    /// The parametric bar under the toolbar (130): the table, Search and
    /// Reset with the filters applied, and a box of values for each column.
    private var parametricBar: some View {
        let table = parametricTable
        let columns = table.map(HorizontalPoolParametricSearch.filterColumns(of:)) ?? []
        let rows = table.map { HorizontalPoolParametricSearch.filter(parametricRows(in: $0), by: parametricFilters.applied) }
        return HorizontalPoolParametricFilterView(
            tables: parametricTables,
            tableName: $parametricTableName,
            columns: columns,
            valuesRemaining: rows.map { HorizontalPoolParametricSearch.valuesRemaining($0, columns: columns) } ?? [:],
            filters: $parametricFilters
        )
    }

    @ViewBuilder
    private func parametricListContent(_ table: HorizontalParametricTable, rows: [HorizontalParametricRow]) -> some View {
        if isLoading && items.isEmpty {
            ProgressView("Scanning Pools…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No \(table.displayName)",
                systemImage: category.symbolName,
                description: Text(parametricEmptyDescription(table))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            parametricItemTable(table, rows: rows.sorted(using: parametricSortOrder))
        }
    }

    private func parametricEmptyDescription(_ table: HorizontalParametricTable) -> String {
        let name = table.displayName.lowercased()
        if !parametricFilters.applied.isEmpty {
            return "No \(name) pass the parametric filters. Take one off, or Reset."
        }
        let replacement = activeReplacement
        if let problem = replacement?.problem {
            return problem
        }
        return "No \(name)\(replacement.map { " for \(entityName(of: $0))" } ?? "")"
            + "\(searchText.isEmpty ? "" : " match “\(searchText)”")"
            + " in \(viewedPool?.name ?? "the browsed pools"). The list shows only the parts in the \(table.displayName) table; "
            + "choose All Parts in the parametric section for every part."
    }

    @ViewBuilder
    private var listContent: some View {
        let rows = filteredItems
        if isLoading && items.isEmpty {
            ProgressView("Scanning Pools…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No \(category.title)" : "No Matches",
                systemImage: category.symbolName,
                description: Text(emptyListDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            itemTable(rows)
        }
    }

    // MARK: - Toolbar

    /// Labels give way to icons when the pane is too narrow for them, and
    /// then the search to a row of its own, so the toolbar always fits the
    /// pane (which the split lets go down to 280 points); the menus keep
    /// their triangles, and each control's help names it.
    private var browserToolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(compact: false)
            toolbarRow(compact: true)
            VStack(spacing: 8) {
                // Tighter, to fit the narrowest pane.
                HStack(spacing: 4) {
                    leadingToolbarControls(compact: true)
                    Spacer(minLength: 0)
                    trailingToolbarControls(compact: true)
                }
                searchField(minWidth: 60)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            leadingToolbarControls(compact: compact)
            searchField(minWidth: compact ? 80 : 160)
            trailingToolbarControls(compact: compact)
        }
    }

    @ViewBuilder
    private func leadingToolbarControls(compact: Bool) -> some View {
        if category == .part {
            parametricDisclosure
        }

        kindPicker(compact: compact)
    }

    private func searchField(minWidth: CGFloat) -> some View {
        TextField("Search \(category.title)", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: minWidth)
            .leavesFieldOnEscape()
            // Down from the search goes into the list, as in a Finder or
            // Spotlight search, so the arrows can carry on through it.
            .onKeyPress(.downArrow) {
                focusList()
                return .handled
            }
    }

    @ViewBuilder
    private func trailingToolbarControls(compact: Bool) -> some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        }

        poolsMenu(compact: compact)

        newItemMenu(compact: compact)

        Toggle(isOn: $showsPreview) {
            toolbarLabel("Preview", systemImage: "rectangle.bottomhalf.inset.filled", compact: compact)
        }
        .toggleStyle(.button)
        .help("Show the selected item below the list")

        if partActions != nil {
            partButton(compact: compact)
        }
    }

    /// The parametric bar's triangle, at the toolbar's left while parts are
    /// listed (130), with a filter mark while the bar is closed and a table
    /// still narrows the list.
    private var parametricDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsParametricFilters.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: showsParametricFilters ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
                if !showsParametricFilters, parametricTable != nil {
                    Image(systemName: parametricFilters.applied.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(parametricDisclosureHelp)
    }

    private var parametricDisclosureHelp: String {
        if showsParametricFilters {
            return "Hide the parametric filters"
        }
        if let table = parametricTable {
            return "Show the parametric filters (showing \(table.displayName) only\(parametricFilters.applied.isEmpty ? "" : ", filtered"))"
        }
        return "Show the parametric filters"
    }

    /// Place, or Replace while components are selected: the pane's primary
    /// action in a project window, there whether or not it can act now, its
    /// help saying why not when it can't.
    @ViewBuilder
    private func partButton(compact: Bool) -> some View {
        let item = selectedListedItem
        if let replacement = activeReplacement {
            let refusal = replaceRefusal(for: item, replacement)
            Button {
                if let item { replace(item, replacement) }
            } label: {
                toolbarLabel("Replace", systemImage: "arrow.triangle.2.circlepath", compact: compact)
            }
            .buttonStyle(.borderedProminent)
            .disabled(refusal != nil)
            .help(refusal ?? "Give \(replacement.refdesList) the selected part, keeping their connections (also double-click or Return in the list)")
        } else {
            let reason = placeUnavailableReason(for: item)
            Button {
                if let item { place(item) }
            } label: {
                toolbarLabel("Place", systemImage: "plus.square.on.square", compact: compact)
            }
            .buttonStyle(.borderedProminent)
            .disabled(reason != nil)
            .help(reason ?? "Place the selected part in the schematic (also double-click or Return in the list)")
        }
    }

    /// What Replace and Place say the selected item is: only an item the list
    /// shows, so a selection the search or the replacement filter hides is
    /// never what they act on.
    private var selectedListedItem: HorizontalPoolLibraryItem? {
        guard let selectedItemID, let item = visibleRows.first(where: { $0.id == selectedItemID }),
              !Self.listed([item], category: category, search: searchText, replacement: activeReplacement).isEmpty else {
            return nil
        }
        if let table = parametricTable {
            return parametricTableShows(item, table) ? item : nil
        }
        return item
    }

    /// The item kind: a pop-up with its name, or, compact, a menu showing only
    /// the kind's icon.
    @ViewBuilder
    private func kindPicker(compact: Bool) -> some View {
        let picker = Picker("Kind", selection: $category) {
            ForEach(HorizontalPoolItemCategory.allCases) { category in
                Label(category.title, systemImage: category.symbolName)
                    .tag(category)
            }
        }
        if compact {
            Menu {
                picker
                    .pickerStyle(.inline)
                    .labelsHidden()
            } label: {
                toolbarLabel(category.title, systemImage: category.symbolName, compact: true)
            }
            .fixedSize()
            .help(category.title)
        } else {
            picker
                .labelsHidden()
                .frame(width: 130)
        }
    }

    /// A toolbar control's label, its icon alone when compact. The style is
    /// set on the label rather than the row so a menu's own items keep their
    /// titles.
    @ViewBuilder
    private func toolbarLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private func poolsMenu(compact: Bool) -> some View {
        Menu {
            Picker("View", selection: $viewedPoolID) {
                Text("All Pools").tag(BrowsedPool.ID?.none)
                Divider()
                ForEach(browsedPools.filter(\.isReadable)) { pool in
                    Text(pool.isProjectPool ? "\(pool.name) (project)" : pool.name)
                        .tag(Optional(pool.id))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Section("Browsing") {
                ForEach(browsedPools) { pool in
                    poolMenu(
                        title: "\(pool.name)\(pool.isProjectPool ? " (project)" : "")",
                        url: pool.url,
                        accessError: pool.accessError
                    )
                }
            }
            // A registered pool keeps the path it was added by; the browsed
            // pools are canonical (`HorizontalPoolLibrary.canonicalURL`).
            let unbrowsedRegisteredPools = registry.pools.filter { registered in
                let path = HorizontalPoolLibrary.canonicalURL(registered.url).path
                return !browsedPools.contains { $0.id == path }
            }
            if !unbrowsedRegisteredPools.isEmpty {
                Section("Registered Pools") {
                    ForEach(unbrowsedRegisteredPools) { pool in
                        poolMenu(title: pool.name, url: pool.url)
                    }
                }
            }
            Divider()
            Button {
                rescanPools()
            } label: {
                Label("Rescan Pools", systemImage: "arrow.clockwise")
            }
            Button {
                isImportingPool = true
            } label: {
                Label("Add Pool…", systemImage: "plus")
            }
        } label: {
            toolbarLabel(viewedPool?.name ?? "Pools", systemImage: "books.vertical", compact: compact)
        }
        .help(viewedPool.map { "Showing \($0.name) only. Pools > View > All Pools shows every pool." }
            ?? "The pools being browsed; register more to make their padstacks and parts available")
    }

    /// Horizon's per-kind "Create" buttons, as one menu. With several
    /// writable pools browsed, each gets a submenu.
    private func newItemMenu(compact: Bool) -> some View {
        let pools = browsedPools.filter(\.isReadable)
        return Menu {
            if pools.count == 1, let pool = pools.first {
                newItemButtons(in: pool)
            } else {
                ForEach(pools) { pool in
                    Menu(pool.isProjectPool ? "\(pool.name) (project)" : pool.name) {
                        newItemButtons(in: pool)
                    }
                }
            }
        } label: {
            toolbarLabel("New", systemImage: "plus", compact: compact)
        }
        .disabled(pools.isEmpty || appearanceSettings.isReadOnlyOperationEnabled)
        .help("Create a new pool item")
    }

    @ViewBuilder
    private func newItemButtons(in pool: BrowsedPool) -> some View {
        ForEach(NewItemKind.allCases) { kind in
            Button(kind.title) {
                createItem(kind, in: pool)
            }
        }
    }

    private func poolMenu(title: String, url: URL, accessError: String? = nil) -> some View {
        Menu {
            Text(url.path)
            if let accessError {
                Text("Not readable: \(accessError)")
                Button("Grant Access…") {
                    grantAccess(to: url)
                }
            }
            #if os(macOS)
            if root != .pool(url) {
                Button("Open in Separate Window") {
                    openPoolWindow(url, reveal: nil)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            #endif
            if let registered = registry.pools.first(where: {
                HorizontalPoolLibrary.canonicalURL($0.url).path == HorizontalPoolLibrary.canonicalURL(url).path
            }) {
                Button("Remove", role: .destructive) {
                    registry.removePool(registered)
                    HorizontalPoolLibrary.invalidateCache()
                    scanGeneration += 1
                }
            }
        } label: {
            if accessError != nil {
                Label(title, systemImage: "lock")
            } else {
                Text(title)
            }
        }
    }

    // MARK: - Table

    private func itemTable(_ rows: [HorizontalPoolLibraryItem]) -> some View {
        Table(rows, selection: $selectedItemID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                tableText(item.name)
            }
            .width(min: 160, ideal: 240)

            TableColumn(category.detailTitle, value: \.detail) { item in
                tableText(item.detail)
            }
            .width(min: 120, ideal: 180)

            TableColumn("Tags", value: \.tags) { item in
                tableText(item.tags)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Pool", value: \.poolsLabel) { item in
                tableText(item.poolsLabel)
                    .help(item.pools.count > 1
                          ? "This row is \(item.poolName)'s copy. Also in \(item.pools.dropFirst().joined(separator: ", "))."
                          : "")
            }
            .width(min: 110, ideal: 160)
        }
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .textSelection(.enabled)
        .contextMenu(forSelectionType: HorizontalPoolLibraryItem.ID.self) { selection in
            if let item = item(for: selection) {
                itemContextMenu(item)
            }
        } primaryAction: { selection in
            if let item = item(for: selection) {
                activate(item)
            }
        }
        .focused($isListFocused)
    }

    /// A table's parts with its values, Horizon's parametric list: MPN,
    /// manufacturer and package, then a column per value, each sorting by
    /// number or naturally as its column does.
    private func parametricItemTable(_ table: HorizontalParametricTable, rows: [HorizontalParametricRow]) -> some View {
        Table(rows, selection: $selectedItemID, sortOrder: $parametricSortOrder) {
            TableColumn("MPN", sortUsing: HorizontalParametricRowComparator(key: HorizontalParametricRowComparator.mpn)) { row in
                tableText(row.item.name)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Manufacturer", sortUsing: HorizontalParametricRowComparator(key: HorizontalParametricFilterColumn.manufacturerName)) { row in
                tableText(row.item.manufacturer)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Package", sortUsing: HorizontalParametricRowComparator(key: HorizontalParametricFilterColumn.packageName)) { row in
                tableText(row.packageName)
            }
            .width(min: 90, ideal: 120)

            TableColumnForEach(table.columns) { column in
                TableColumn(column.displayName,
                            sortUsing: HorizontalParametricRowComparator(key: column.name, isQuantity: column.kind == .quantity)) { row in
                    HorizontalParametricValueText(column: HorizontalParametricFilterColumn(column), value: row.values[column.name] ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 70, ideal: 100)
            }

            TableColumn("Pool", sortUsing: HorizontalParametricRowComparator(key: HorizontalParametricRowComparator.pool)) { row in
                tableText(row.item.poolsLabel)
            }
            .width(min: 90, ideal: 140)
        }
        .id(table.name)
        #if os(macOS)
        .alternatingRowBackgrounds(.enabled)
        #endif
        .contextMenu(forSelectionType: HorizontalPoolLibraryItem.ID.self) { selection in
            if let item = item(for: selection) {
                itemContextMenu(item)
            }
        } primaryAction: { selection in
            if let item = item(for: selection) {
                activate(item)
            }
        }
        .focused($isListFocused)
    }

    private func item(for selection: Set<HorizontalPoolLibraryItem.ID>) -> HorizontalPoolLibraryItem? {
        guard let id = selection.first else {
            return nil
        }
        return items.first { $0.id == id }
    }

    /// Horizon's pool browser context menu: edit the item in its own
    /// document window, open it in each pool that carries it (a window per
    /// pool, scrolled to the item), reveal the file, copy its identity.
    @ViewBuilder
    private func itemContextMenu(_ item: HorizontalPoolLibraryItem) -> some View {
        if let replacement = activeReplacement, replaceRefusal(for: item, replacement) == nil {
            Button("Replace \(replacement.refdesList)") {
                replace(item, replacement)
            }
        }
        if canPlace(item) {
            Button("Place in Schematic") {
                place(item)
            }
        }
        Button("Edit…") {
            editItem(item)
        }
        let related = relatedItems(for: item)
        if !related.isEmpty {
            Divider()
            ForEach(related, id: \.item.id) { entry in
                Button("Show \(entry.title)") {
                    reveal(HorizontalPoolRevealRequest(item: entry.item))
                }
            }
        }
        if !appearanceSettings.isReadOnlyOperationEnabled {
            Button("Duplicate…") {
                duplicateItem(item)
            }
            switch item.category {
            case .unit:
                Button("New Symbol for Unit…") {
                    createSymbol(forUnit: item)
                }
                Button("New Entity for Unit…") {
                    createEntity(forUnit: item)
                }
            case .part:
                Button("New Part Based on This…") {
                    createPart(basedOn: item)
                }
                if let copyToPool = partActions?.copyToPool, let targets = partActions?.copyTargets?(item), !targets.isEmpty {
                    Menu("Copy to Pool") {
                        ForEach(targets) { target in
                            Button(target.name) { copyToPool(item, target.url) }
                        }
                    }
                }
            case .package:
                Button("New Padstack for Package…") {
                    createPackageLocalPadstack(for: item)
                }
            default:
                EmptyView()
            }
        }
        Divider()
        #if os(macOS)
        ForEach(openTargets(for: item)) { target in
            Button("Open in \(target.poolName)") {
                openPoolWindow(target.poolURL, reveal: HorizontalPoolRevealRequest(item: target))
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        #endif
        Button("Copy UUID") {
            copyToPasteboard(item.uuid)
        }
        Button("Copy Path") {
            copyToPasteboard(item.url.path)
        }
    }

    private func tableText(_ value: String) -> some View {
        Text(value.isEmpty ? "-" : value)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// Where an item can be opened: its own pool first, then every other
    /// browsed pool carrying the same item — a project pool's cache copy also
    /// lives in the registered pool it came from, and that source is where
    /// one would edit it. A pool this browser is already rooted at is left
    /// out (nothing further to open there).
    private func openTargets(for item: HorizontalPoolLibraryItem) -> [HorizontalPoolLibraryItem] {
        let poolOrder = browsedPools.map(\.id)
        func rank(_ copy: HorizontalPoolLibraryItem) -> Int {
            copy.id == item.id ? -1 : (poolOrder.firstIndex(of: copy.poolURL.path) ?? poolOrder.count)
        }
        return items
            .filter { $0.category == item.category && $0.uuid == item.uuid && root != .pool($0.poolURL) }
            .sorted { rank($0) < rank($1) }
    }

    /// Double-click or "Edit…": the item opens as its own document, the way
    /// Horizon's pool manager spawns an editor per file. On macOS that goes
    /// through the document controller (the browser may be hosted outside
    /// any SwiftUI scene, in a pool window); iPadOS uses the scene's
    /// document opener.
    private func editItem(_ item: HorizontalPoolLibraryItem) {
        #if os(macOS)
        NSDocumentController.shared.openDocument(withContentsOf: item.url, display: true) { _, _, error in
            if let error {
                NSAlert(error: error).runModal()
            }
        }
        #else
        editingItem = item
        #endif
    }

    // MARK: - Placing, replacing and related items

    /// Double-click or Return on a row: Replace while components are
    /// selected, as Horizon's part browser assigns rather than places while
    /// it shows an entity's parts, else Place, else the item's editor.
    private func activate(_ item: HorizontalPoolLibraryItem) {
        if let replacement = activeReplacement, item.category == .part {
            if replaceRefusal(for: item, replacement) == nil {
                replace(item, replacement)
            } else {
                #if os(macOS)
                NSSound.beep()
                #endif
            }
        } else if canPlace(item) {
            place(item)
        } else {
            editItem(item)
        }
    }

    private func canPlace(_ item: HorizontalPoolLibraryItem) -> Bool {
        placeUnavailableReason(for: item) == nil
    }

    /// Why Place can't place `item`, or nil when it can: what the Place
    /// button's help says while it is disabled.
    static func placeUnavailableReason(for item: HorizontalPoolLibraryItem?, actions: HorizontalPoolPartActions?,
                                       isReadOnly: Bool) -> String? {
        guard let actions, actions.place != nil else {
            return actions?.placeUnavailableReason ?? "Parts are placed from a project window."
        }
        if isReadOnly {
            return "Read-only operation is enabled in Horizontal."
        }
        guard let item else {
            return "Select a part to place it in the schematic."
        }
        guard item.category == .part else {
            return "Only parts are placed. Choose Parts in the kind menu."
        }
        return nil
    }

    /// Why Replace can't give the selected components `item`, or nil.
    static func replaceRefusal(for item: HorizontalPoolLibraryItem?, _ replacement: HorizontalPartReplacement,
                               actions: HorizontalPoolPartActions?, isReadOnly: Bool) -> String? {
        if let problem = replacement.problem {
            return problem
        }
        guard actions?.replace != nil else {
            return "Parts can't be replaced in this window."
        }
        if isReadOnly {
            return "Read-only operation is enabled in Horizontal."
        }
        guard let item else {
            return "Select a part to give to \(replacement.refdesList)."
        }
        return replacement.refusal(for: item)
    }

    private func placeUnavailableReason(for item: HorizontalPoolLibraryItem?) -> String? {
        Self.placeUnavailableReason(for: item, actions: partActions, isReadOnly: appearanceSettings.isReadOnlyOperationEnabled)
    }

    private func replaceRefusal(for item: HorizontalPoolLibraryItem?, _ replacement: HorizontalPartReplacement) -> String? {
        Self.replaceRefusal(for: item, replacement, actions: partActions, isReadOnly: appearanceSettings.isReadOnlyOperationEnabled)
    }

    private func place(_ item: HorizontalPoolLibraryItem) {
        guard canPlace(item) else {
            return
        }
        partActions?.place?(item)
    }

    private func replace(_ item: HorizontalPoolLibraryItem, _ replacement: HorizontalPartReplacement) {
        guard replaceRefusal(for: item, replacement) == nil else {
            return
        }
        partActions?.replace?(item, item.packageID.isEmpty ? "" : index.name(.package, uuid: item.packageID) ?? "", replacement)
    }

    /// The entity a replacement's components are on, by name.
    private func entityName(of replacement: HorizontalPartReplacement) -> String {
        guard let entityID = replacement.entityID else {
            return "their entities"
        }
        return "“\(index.name(.entity, uuid: entityID) ?? String(entityID.prefix(8)))”"
    }

    /// Horizon's entity info bar: what the list is showing while components
    /// are selected, and a button that goes back to every part and Place.
    @ViewBuilder
    private var replacementBanner: some View {
        if category == .part, let replacement = activeReplacement {
            HStack(spacing: 8) {
                Image(systemName: replacement.problem == nil ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                    .foregroundStyle(replacement.problem == nil ? Color.accentColor : Color.orange)
                Text(replacement.problem
                     ?? "Only showing parts for entity \(entityName(of: replacement)), to replace \(replacement.refdesList).")
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    dismissedReplacementKey = replacement.key
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show every part, and place rather than replace")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))
            Divider()
        }
    }

    /// A new selection of components: show the parts that fit them, with the
    /// one they have now selected, as Horizon's part chooser opens on the
    /// component's part, and, with the parametric section open, the table
    /// that part is in.
    private func adoptReplacement() {
        adoptReplacement(switchingKind: true)
    }

    /// `switchingKind` false: only what the scan can add, once the pools are
    /// read, leaving the kind as the user has it.
    private func adoptReplacement(switchingKind: Bool) {
        guard let replacement = activeReplacement else {
            return
        }
        if switchingKind {
            category = .part
        }
        let currentParts = Set(replacement.targets.compactMap(\.partID))
        if let selectedItem, !replacement.isCompatible(selectedItem) {
            selectedItemID = nil
        }
        if currentParts.count == 1, let current = currentParts.first,
           let row = visibleRows.first(where: { $0.category == .part && $0.uuid == current }) {
            selectedItemID = row.id
        }
        if showsParametricFilters {
            let tables = Set(currentParts.compactMap { index.item(.part, uuid: $0)?.parametric["table"] })
            if tables.count == 1, let table = tables.first, parametricTables.contains(where: { $0.name == table }) {
                parametricTableName = table
            }
        }
    }

    /// Down in the search field: the list takes the keyboard, its first row
    /// selected when nothing is.
    private func focusList() {
        isListFocused = true
        if selectedListedItem == nil {
            if let table = parametricTable {
                selectedItemID = HorizontalPoolParametricSearch.filter(parametricRows(in: table), by: parametricFilters.applied)
                    .sorted(using: parametricSortOrder).first?.id
            } else {
                selectedItemID = filteredItems.first?.id
            }
        }
    }

    /// Pools > Rescan Pools: every pool read again from disk.
    private func rescanPools() {
        HorizontalPoolLibrary.invalidateCache()
        scanGeneration += 1
    }

    /// The items this one leads to that the browsed pools have, for the
    /// context menu's "Show …" entries — what a part's preview links to
    /// (`HorizontalPoolPreviewBuilder.references`): a part's base part,
    /// entity, units, symbols, package and padstacks; an entity's units and
    /// symbols; a symbol's unit; a package's padstacks.
    private func relatedItems(for item: HorizontalPoolLibraryItem) -> [(title: String, item: HorizontalPoolLibraryItem)] {
        guard let json = try? JSONHelper.loadDictionary(from: item.url) else {
            return []
        }
        var seen = Set<String>()
        let entries = HorizontalPoolPreviewBuilder.links(for: item, json: json, index: index).compactMap { reference in
            index.item(reference.category, uuid: reference.uuid).flatMap { related in
                seen.insert(related.id).inserted ? (title: "\(reference.role.menuTitle) “\(related.name)”", item: related) : nil
            }
        }
        return Array(entries.prefix(12))
    }

    // MARK: - Creating and duplicating

    private func pool(for item: HorizontalPoolLibraryItem) -> BrowsedPool {
        browsedPools.first { $0.url.standardizedFileURL.path == item.poolURL.standardizedFileURL.path }
            ?? BrowsedPool(url: item.poolURL, name: item.poolName, isProjectPool: false, accessError: nil)
    }

    private func loadModel(of item: HorizontalPoolLibraryItem) -> HorizontalPoolItemModel? {
        do {
            return try HorizontalPoolItemModel.load(category: item.category, json: JSONHelper.loadDictionary(from: item.url))
        } catch {
            creationError = "“\(item.name)” could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    private func createItem(_ kind: NewItemKind, in pool: BrowsedPool) {
        switch kind {
        case .unit:
            saveNewItem(.unit(HorizontalPoolItemFactory.newUnit()), in: pool)
        case .entity:
            saveNewItem(.entity(HorizontalPoolItemFactory.newEntity()), in: pool)
        case .symbol:
            pickerRequest = PoolItemPickerRequest(title: "Unit for the New Symbol", category: .unit) { unitItem in
                createSymbol(forUnit: unitItem, in: pool)
            }
        case .part:
            pickerRequest = PoolItemPickerRequest(title: "Entity for the New Part", category: .entity) { entityItem in
                // The picker sheet has to go away before the next one can show.
                DispatchQueue.main.async {
                    pickerRequest = PoolItemPickerRequest(title: "Package for the New Part", category: .package) { packageItem in
                        createPart(entity: entityItem, package: packageItem, in: pool)
                    }
                }
            }
        case .package:
            saveNewItem(.package(HorizontalPoolItemFactory.newPackage()), in: pool)
        case .padstack:
            saveNewItem(.padstack(HorizontalPoolItemFactory.newPadstack()), in: pool)
        case .frame:
            saveNewItem(.frame(HorizontalPoolItemFactory.newFrame()), in: pool)
        case .decal:
            saveNewItem(.decal(HorizontalPoolItemFactory.newDecal()), in: pool)
        }
    }

    /// `handle_create_symbol_for_unit`: named after the unit, suggested at
    /// the unit's path mirrored under `symbols/`.
    private func createSymbol(forUnit unitItem: HorizontalPoolLibraryItem, in pool: BrowsedPool? = nil) {
        guard case .unit(let unit)? = loadModel(of: unitItem) else {
            return
        }
        let pool = pool ?? self.pool(for: unitItem)
        let symbol = HorizontalPoolItemFactory.newSymbol(for: unit)
        let mirrored = unitItem.poolURL.standardizedFileURL.path == pool.url.standardizedFileURL.path ? unitItem.url : nil
        saveNewItem(.symbol(symbol), in: pool, suggested: HorizontalPoolItemFactory.suggestedURL(for: .symbol(symbol), in: pool.url, mirroring: mirrored))
    }

    private func createEntity(forUnit unitItem: HorizontalPoolLibraryItem) {
        guard case .unit(let unit)? = loadModel(of: unitItem) else {
            return
        }
        saveNewItem(.entity(HorizontalPoolItemFactory.newEntity(for: unit)), in: pool(for: unitItem))
    }

    private func createPart(entity entityItem: HorizontalPoolLibraryItem, package packageItem: HorizontalPoolLibraryItem, in pool: BrowsedPool) {
        guard case .entity(let entity)? = loadModel(of: entityItem) else {
            return
        }
        saveNewItem(.part(HorizontalPoolItemFactory.newPart(entity: entity, packageID: packageItem.uuid)), in: pool)
    }

    private func createPart(basedOn baseItem: HorizontalPoolLibraryItem) {
        guard case .part(let base)? = loadModel(of: baseItem) else {
            return
        }
        let part = HorizontalPoolItemFactory.newPart(basedOn: base)
        saveNewItem(.part(part), in: pool(for: baseItem), suggested: HorizontalPoolItemFactory.suggestedDuplicateURL(of: baseItem.url))
    }

    /// `handle_create_padstack_for_package`: a padstack that lives in the
    /// package's own `padstacks/` folder.
    private func createPackageLocalPadstack(for packageItem: HorizontalPoolLibraryItem) {
        let padstack = HorizontalPoolItemFactory.newPadstack()
        let directory = packageItem.url.deletingLastPathComponent().appendingPathComponent("padstacks", isDirectory: true)
        let suggested = directory.appendingPathComponent(HorizontalPoolItemFactory.slug(padstack.name, fallback: "padstack") + ".json")
        saveNewItem(.padstack(padstack), in: pool(for: packageItem), suggested: suggested)
    }

    /// `handle_duplicate_*`: the same item under a fresh uuid, " (Copy)"
    /// appended, saved next to the original; a package's directory is copied
    /// whole with its local padstacks re-identified.
    private func duplicateItem(_ item: HorizontalPoolLibraryItem) {
        guard let model = loadModel(of: item) else {
            return
        }
        let pool = pool(for: item)
        let copy = HorizontalPoolItemFactory.duplicate(model)
        let suggested = HorizontalPoolItemFactory.suggestedDuplicateURL(of: item.url)
        if case .package = copy {
            chooseDestination(suggested: suggested, category: .package, in: pool) { url in
                do {
                    let newDirectory = url.deletingLastPathComponent()
                    let written = try HorizontalPoolItemFactory.duplicatePackage(from: item.url, to: newDirectory, name: copy.name)
                    let package = try HorizontalPoolItemModel.load(category: .package, json: JSONHelper.loadDictionary(from: written))
                    finishCreation(package, at: written, data: try Data(contentsOf: written), in: pool)
                } catch {
                    creationError = error.localizedDescription
                }
            }
            return
        }
        saveNewItem(copy, in: pool, suggested: suggested)
    }

    /// Asks where the item goes (a save panel on macOS; the suggested spot on
    /// iPadOS), checks the pool layout rules, writes, rescans and opens it.
    private func saveNewItem(_ model: HorizontalPoolItemModel, in pool: BrowsedPool, suggested: URL? = nil) {
        let suggestedURL = suggested ?? HorizontalPoolItemFactory.suggestedURL(for: model, in: pool.url)
        chooseDestination(suggested: suggestedURL, category: model.category, in: pool) { url in
            do {
                let data = try HorizontalPoolItemFactory.write(model, to: url, replacingExisting: true)
                finishCreation(model, at: url, data: data, in: pool)
            } catch {
                creationError = error.localizedDescription
            }
        }
    }

    private func chooseDestination(
        suggested: URL,
        category: HorizontalPoolItemCategory,
        in pool: BrowsedPool,
        completion: @escaping (URL) -> Void
    ) {
        let isPackage = category == .package
        #if os(macOS)
        // Packages are chosen by directory: the panel names the folder and
        // package.json goes inside it.
        let target = isPackage ? suggested.deletingLastPathComponent() : suggested
        let directory = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.directoryURL = directory
        panel.nameFieldStringValue = target.lastPathComponent
        panel.canCreateDirectories = true
        panel.title = "New \(category.singularTitle)"
        panel.prompt = "Create"
        panel.message = isPackage
            ? "Choose a folder name for the package inside “\(pool.name)”; package.json is created inside it."
            : "Choose where the \(category.singularTitle.lowercased()) is saved inside “\(pool.name)”."
        if !isPackage {
            panel.allowedContentTypes = [.json]
        }
        panel.begin { response in
            guard response == .OK, let chosen = panel.url else {
                return
            }
            let url = isPackage ? chosen.appendingPathComponent("package.json") : chosen
            if let problem = HorizontalPoolItemFactory.locationProblem(for: url, category: category, in: pool.url) {
                creationError = problem
                return
            }
            completion(url)
        }
        #else
        let url = HorizontalPoolItemFactory.availableURL(for: suggested)
        if let problem = HorizontalPoolItemFactory.locationProblem(for: url, category: category, in: pool.url) {
            creationError = problem
            return
        }
        completion(url)
        #endif
    }

    /// The file is on disk: tell open projects (a project pool lives inside
    /// the project package, whose in-memory archive must learn the new
    /// file), rescan the pools and open the editor on it.
    private func finishCreation(_ model: HorizontalPoolItemModel, at url: URL, data: Data, in pool: BrowsedPool) {
        HorizontalPoolLibrary.invalidateCache()
        HorizontalPoolPadstacks.invalidateCaches()
        let payload = HorizontalPoolLibrary.ItemDidSavePayload(
            url: url,
            category: model.category,
            uuid: model.uuid,
            data: data
        )
        NotificationCenter.default.post(
            name: HorizontalPoolLibrary.itemDidSaveNotification,
            object: nil,
            userInfo: [HorizontalPoolLibrary.itemDidSavePayloadKey: payload]
        )
        scanGeneration += 1
        category = model.category
        let item = HorizontalPoolItemFactory.libraryItem(for: model, at: url, poolURL: pool.url, poolName: pool.name)
        selectedItemID = item.id
        editItem(item)
    }

    /// "Open in Pool": the item's pool in its own window, selected there.
    private func openInPool(_ item: HorizontalPoolLibraryItem) {
        guard root != .pool(item.poolURL) else {
            return
        }
        openPoolWindow(item.poolURL, reveal: HorizontalPoolRevealRequest(item: item))
    }

    private func openPoolWindow(_ poolURL: URL, reveal: HorizontalPoolRevealRequest?) {
        #if os(macOS)
        HorizontalPoolWindowManager.shared.open(
            poolURL: poolURL,
            reveal: reveal,
            appearanceSettings: appearanceSettings
        )
        #endif
    }

    private func copyToPasteboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func addPool(at url: URL) {
        // The importer's grant only lives while the scope is active; keep it
        // open so the registry can mint its persistent bookmark, then let the
        // registry's own restored scope carry future sessions.
        _ = url.startAccessingSecurityScopedResource()
        if registry.addPool(at: url) {
            HorizontalPoolLibrary.invalidateCache()
            scanGeneration += 1
            #if os(macOS)
            HorizontalPoolWindowManager.shared.refreshTitle(for: url)
            #endif
        } else {
            addPoolFailurePath = url.lastPathComponent
        }
    }

    /// Asks macOS for the folder grant a discovered-but-unreadable pool needs,
    /// then registers it so the grant is kept. On iPadOS the folder picker
    /// (Add Pool…) is the same flow.
    private func grantAccess(to poolURL: URL) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = poolURL
        panel.message = "Grant Horizontal access to the pool folder “\(poolURL.lastPathComponent)” to browse it."
        panel.prompt = "Grant Access"
        panel.begin { response in
            guard response == .OK, let chosen = panel.url else {
                return
            }
            addPool(at: chosen)
        }
        #else
        isImportingPool = true
        #endif
    }

    /// Shows a request's item, or the first match of its search, here:
    /// what a reveal from elsewhere in the window, a preview link and a
    /// "Show …" entry all come through.
    private func reveal(_ request: HorizontalPoolRevealRequest) {
        pendingReveal = request
        applyPendingReveal()
    }

    /// Applies the pending reveal once the scan has its item, then scrolls
    /// the list to it, centred, however far down it is.
    private func applyPendingReveal() {
        guard let request = pendingReveal else {
            return
        }
        if let search = request.search {
            category = request.category
            searchText = search
            viewedPoolID = nil
            updateVisibleRows()
            selectedItemID = filteredItems.first?.id
            if let selectedItem {
                makeListed(selectedItem)
            }
            pendingReveal = nil
            return
        }
        let uuid = request.uuid.lowercased()
        guard var item = items.first(where: { $0.category == request.category && $0.uuid == uuid }) else {
            return
        }
        if let viewed = viewedPool,
           let own = Self.visibleItems(items, viewing: viewed.url).first(where: { $0.category == request.category && $0.uuid == uuid }) {
            item = own
        } else {
            viewedPoolID = nil
            updateVisibleRows()
        }
        category = request.category
        searchText = ""
        selectedItemID = item.id
        makeListed(item)
        pendingReveal = nil
    }

    /// What a reveal does for a part the list would otherwise hide: one
    /// that doesn't fit the components being replaced closes the banner, as
    /// its close button does, and one the parametric table leaves out goes
    /// back to every part. The item a reveal asked for is always on screen.
    private func makeListed(_ item: HorizontalPoolLibraryItem) {
        guard item.category == .part else {
            return
        }
        if let replacement = activeReplacement, !replacement.isCompatible(item) {
            dismissedReplacementKey = replacement.key
        }
        if let table = parametricTable, !parametricTableShows(item, table) {
            parametricTableName = nil
        }
    }

    /// Whether the parametric list shows `item` with its filters as they are.
    private func parametricTableShows(_ item: HorizontalPoolLibraryItem, _ table: HorizontalParametricTable) -> Bool {
        let row = HorizontalPoolParametricSearch.rows([item], table: table) { packageID in
            packageID.isEmpty ? "" : index.name(.package, uuid: packageID) ?? ""
        }
        return !HorizontalPoolParametricSearch.filter(row, by: parametricFilters.applied).isEmpty
    }

    private func reloadItems() async {
        isLoading = true
        defer { isLoading = false }
        let pools = browsedPools
        let (loaded, tables) = await Task.detached(priority: .userInitiated) {
            (
                HorizontalPoolLibrary.resolvingInheritance(pools.flatMap { pool in
                    HorizontalPoolLibrary.items(inPool: pool.url, poolName: pool.name)
                }),
                // The project pool's tables (or a pool's own) win over the
                // pools it draws from, as `PoolParametric` reads them.
                HorizontalPoolParametricTables.load(poolURLs: pools.filter(\.isReadable).map(\.url).reversed())
            )
        }.value
        guard !Task.isCancelled else {
            return
        }
        items = loaded
        index = HorizontalPoolLibraryIndex(items: loaded)
        parametricTables = tables
        if let parametricTableName, !parametricTables.contains(where: { $0.name == parametricTableName }) {
            self.parametricTableName = nil
        }
        if let viewedPoolID, !pools.contains(where: { $0.id == viewedPoolID }) {
            self.viewedPoolID = nil
        }
        updateVisibleRows()
        if selectedItemID == nil {
            adoptReplacement(switchingKind: false)
        }
        applyPendingReveal()
        // A reveal the scan could not satisfy is stale; don't keep trying.
        pendingReveal = nil
    }
}
