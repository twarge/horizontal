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

/// The library browser: Horizon's pool manager for this app. Browses every
/// pool a project can draw from — the project pool plus registered/discovered
/// base pools — across the pool item kinds (units, symbols, entities,
/// padstacks, packages, parts, frames, decals), with search, a preview of the
/// selected item below the list, and a Pools menu to register additional
/// pool directories (e.g. a horizon-pool checkout) or open one in its own
/// window.
struct HorizontalPoolBrowserView: View {
    var root: HorizontalPoolBrowserRoot
    var safeAreaInsets: EdgeInsets = EdgeInsets()
    var revealRequest: HorizontalPoolRevealRequest? = nil
    /// Set by a project window: "Place in Schematic" for parts (double-click,
    /// the Place button, Return, the context menu). Nil in a pool window.
    var onPlacePart: ((HorizontalPoolLibraryItem) -> Void)? = nil

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
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                return
            }
            result.append(
                BrowsedPool(
                    url: standardized,
                    name: name ?? HorizontalPoolRegistryStore.poolInfo(at: standardized).name,
                    isProjectPool: isProjectPool,
                    accessError: HorizontalPoolLibrary.accessError(for: standardized)
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

    private var filteredItems: [HorizontalPoolLibraryItem] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let inCategory = items.filter { $0.category == category }
        let filtered = terms.isEmpty
            ? inCategory
            : inCategory.filter { item in
                let haystack = [item.name, item.detail, item.manufacturer, item.tags, item.poolName, item.uuid]
                    .joined(separator: "\n")
                    .lowercased()
                return terms.allSatisfy(haystack.contains)
            }
        return filtered.sorted(using: sortOrder)
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
            listContent
                .frame(minHeight: 120)
            if showsPreview {
                previewPane
                    .frame(minHeight: 120)
            }
        }
        #else
        GeometryReader { proxy in
            VStack(spacing: 0) {
                listContent
                    .frame(height: showsPreview ? proxy.size.height * 0.55 : proxy.size.height)
                if showsPreview {
                    Divider()
                    previewPane
                }
            }
        }
        #endif
    }

    private var previewPane: some View {
        HorizontalPoolItemPreviewView(item: selectedItem, index: index)
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
            ? "None of the browsed pools contain \(category.title.lowercased())."
            : "No \(category.title.lowercased()) match “\(searchText)”."
        let unreadable = unreadablePools
        if !unreadable.isEmpty {
            let names = unreadable.map { "“\($0.url.lastPathComponent)”" }.joined(separator: ", ")
            text += "\n\nHorizontal isn’t allowed to read \(names). Use Pools > Grant Access… to browse \(unreadable.count == 1 ? "it" : "them")."
        }
        return text
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading && items.isEmpty {
            ProgressView("Scanning Pools…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No \(category.title)" : "No Matches",
                systemImage: category.symbolName,
                description: Text(emptyListDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            itemTable
        }
    }

    // MARK: - Toolbar

    private var browserToolbar: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $category) {
                ForEach(HorizontalPoolItemCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbolName)
                        .tag(category)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("Search \(category.title)", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            poolsMenu

            newItemMenu

            if onPlacePart != nil {
                Button {
                    if let item = selectedItem, canPlace(item) {
                        onPlacePart?(item)
                    }
                } label: {
                    Label("Place", systemImage: "plus.square.on.square")
                }
                .disabled(selectedItem.map { !canPlace($0) } ?? true)
                .help("Place the selected part in the schematic (also double-click or Return in the list)")
            }

            Toggle(isOn: $showsPreview) {
                Label("Preview", systemImage: "rectangle.bottomhalf.inset.filled")
            }
            .toggleStyle(.button)
            .help("Show the selected item below the list")

            Button {
                HorizontalPoolLibrary.invalidateCache()
                scanGeneration += 1
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Rescan the browsed pools")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var poolsMenu: some View {
        Menu {
            Section("Browsing") {
                ForEach(browsedPools) { pool in
                    poolMenu(
                        title: "\(pool.name)\(pool.isProjectPool ? " (project)" : "")",
                        url: pool.url,
                        accessError: pool.accessError
                    )
                }
            }
            let unbrowsedRegisteredPools = registry.pools.filter { registered in
                !browsedPools.contains { $0.id == registered.id }
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
                isImportingPool = true
            } label: {
                Label("Add Pool…", systemImage: "plus")
            }
        } label: {
            Label("Pools", systemImage: "books.vertical")
        }
        .help("The pools being browsed; register more to make their padstacks and parts available")
    }

    /// Horizon's per-kind "Create" buttons, as one menu. With several
    /// writable pools browsed, each gets a submenu.
    private var newItemMenu: some View {
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
            Label("New", systemImage: "plus")
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
            if let registered = registry.pools.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
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

    private var itemTable: some View {
        Table(filteredItems, selection: $selectedItemID, sortOrder: $sortOrder) {
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

            TableColumn("Pool", value: \.poolName) { item in
                tableText(item.poolName)
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
                if canPlace(item) {
                    onPlacePart?(item)
                } else {
                    editItem(item)
                }
            }
        }
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
        if canPlace(item) {
            Button("Place in Schematic") {
                onPlacePart?(item)
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
                    pendingReveal = HorizontalPoolRevealRequest(item: entry.item)
                    applyPendingReveal()
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

    // MARK: - Placing and related items

    private func canPlace(_ item: HorizontalPoolLibraryItem) -> Bool {
        onPlacePart != nil && item.category == .part && !appearanceSettings.isReadOnlyOperationEnabled
    }

    /// The items this one refers to, for the context menu's "Show …" entries:
    /// a part's entity, package and base part; an entity's units; a symbol's
    /// unit; a package's padstacks.
    private func relatedItems(for item: HorizontalPoolLibraryItem) -> [(title: String, item: HorizontalPoolLibraryItem)] {
        guard let json = try? JSONHelper.loadDictionary(from: item.url) else {
            return []
        }
        var entries = [(title: String, item: HorizontalPoolLibraryItem)]()
        var seen = Set<String>()
        func add(_ category: HorizontalPoolItemCategory, _ uuid: String?, label: String) {
            guard let uuid, let related = index.item(category, uuid: uuid.lowercased()), seen.insert(related.id).inserted else {
                return
            }
            entries.append((title: "\(label) “\(related.name)”", item: related))
        }
        switch item.category {
        case .part:
            add(.entity, json.string("entity"), label: "Entity")
            add(.package, json.string("package"), label: "Package")
            add(.part, json.string("base"), label: "Base Part")
        case .entity:
            for (_, gate) in json.dictionaryMap("gates").sorted(by: { $0.key < $1.key }) {
                add(.unit, gate.string("unit"), label: "Unit")
            }
        case .symbol:
            add(.unit, json.string("unit"), label: "Unit")
        case .package:
            for (_, pad) in json.dictionaryMap("pads").sorted(by: { $0.key < $1.key }) {
                add(.padstack, pad.string("padstack"), label: "Padstack")
            }
        default:
            break
        }
        return Array(entries.prefix(10))
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

    private func applyPendingReveal() {
        guard let request = pendingReveal else {
            return
        }
        if let search = request.search {
            category = request.category
            searchText = search
            selectedItemID = filteredItems.first?.id
            pendingReveal = nil
            return
        }
        let uuid = request.uuid.lowercased()
        guard let item = items.first(where: { $0.category == request.category && $0.uuid == uuid }) else {
            return
        }
        category = request.category
        searchText = ""
        selectedItemID = item.id
        pendingReveal = nil
    }

    private func reloadItems() async {
        isLoading = true
        defer { isLoading = false }
        let pools = browsedPools
        let loaded = await Task.detached(priority: .userInitiated) {
            pools.flatMap { pool in
                HorizontalPoolLibrary.items(inPool: pool.url, poolName: pool.name)
            }
        }.value
        guard !Task.isCancelled else {
            return
        }
        items = loaded
        index = HorizontalPoolLibraryIndex(items: loaded)
        applyPendingReveal()
        // A reveal the scan could not satisfy is stale; don't keep trying.
        pendingReveal = nil
    }
}
