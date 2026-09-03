import SwiftUI
import UniformTypeIdentifiers

/// What a library browser is rooted at: a project's pool plus the base pools
/// it can draw from, or one pool on its own plus the pools it includes.
enum HorizontalPoolBrowserRoot: Hashable {
    case project(poolURL: URL?)
    case pool(URL)
}

/// Asks the browser to show one item: switch to its category, clear the
/// search and select it. A fresh `id` per request means asking for the same
/// item twice still re-selects it.
struct HorizontalPoolRevealRequest: Equatable {
    var id = UUID()
    var category: HorizontalPoolItemCategory
    var uuid: String

    init(category: HorizontalPoolItemCategory, uuid: String) {
        self.category = category
        self.uuid = uuid
    }

    init(item: HorizontalPoolLibraryItem) {
        self.init(category: item.category, uuid: item.uuid)
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

    @ObservedObject private var registry = HorizontalPoolRegistry.shared
    @EnvironmentObject private var appearanceSettings: HorizontalAppearanceSettings
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

    struct BrowsedPool: Identifiable, Hashable {
        var url: URL
        var name: String
        var isProjectPool: Bool

        var id: String { url.path }
    }

    /// The pools the browser (and the padstack pickers) can see, project pool
    /// first — the same resolution order HorizontalPoolPadstacks uses. A
    /// standalone pool browses itself plus the pools it includes.
    private var browsedPools: [BrowsedPool] {
        var result = [BrowsedPool]()
        var seen = Set<String>()

        func add(_ url: URL, name: String, isProjectPool: Bool) {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                return
            }
            result.append(BrowsedPool(url: standardized, name: name, isProjectPool: isProjectPool))
        }

        switch root {
        case .project(let projectPoolURL):
            if let projectPoolURL {
                add(projectPoolURL, name: "Project pool", isProjectPool: true)
            }
            let baseURLs = projectPoolURL.map { HorizontalPoolPadstacks.basePoolURLs(for: $0) }
                ?? HorizontalPoolRegistryStore.poolURLs()
            for url in baseURLs {
                add(url, name: HorizontalPoolRegistryStore.poolInfo(at: url).name, isProjectPool: false)
            }
        case .pool(let poolURL):
            add(poolURL, name: HorizontalPoolRegistryStore.poolInfo(at: poolURL).name, isProjectPool: false)
            for url in Self.includedPoolURLs(for: poolURL) {
                add(url, name: HorizontalPoolRegistryStore.poolInfo(at: url).name, isProjectPool: false)
            }
        }
        return result
    }

    /// The pools a standalone pool includes (`pools_included` uuids in its
    /// pool.json), found among the pools this app knows about: registered
    /// ones, `$HORIZON_POOL`, and any horizon-pool checkout nearby.
    static func includedPoolURLs(for poolURL: URL) -> [URL] {
        let json = (try? JSONHelper.loadDictionary(from: poolURL.appendingPathComponent("pool.json"))) ?? [:]
        let included = (json["pools_included"] as? [String] ?? []).map { $0.lowercased() }
        guard !included.isEmpty else {
            return []
        }
        var urlsByUUID = [String: URL]()
        for url in HorizontalPoolPadstacks.basePoolURLs(for: poolURL) {
            let uuid = HorizontalPoolRegistryStore.poolInfo(at: url).uuid.lowercased()
            if !uuid.isEmpty, urlsByUUID[uuid] == nil {
                urlsByUUID[uuid] = url
            }
        }
        return included.compactMap { urlsByUUID[$0] }
    }

    private var filteredItems: [HorizontalPoolLibraryItem] {
        let terms = searchText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        let inCategory = items.filter { $0.category == category }
        let filtered = terms.isEmpty
            ? inCategory
            : inCategory.filter { item in
                let haystack = [item.name, item.detail, item.tags, item.poolName, item.uuid]
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
            } else {
                splitContent
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .controlBackgroundColor))
        #else
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
        .task(id: scanKey) {
            await reloadItems()
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

    @ViewBuilder
    private var listContent: some View {
        if isLoading && items.isEmpty {
            ProgressView("Scanning Pools…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No \(category.title)" : "No Matches",
                systemImage: category.symbolName,
                description: Text(
                    searchText.isEmpty
                        ? "None of the browsed pools contain \(category.title.lowercased())."
                        : "No \(category.title.lowercased()) match “\(searchText)”."
                )
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
                        url: pool.url
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

    private func poolMenu(title: String, url: URL) -> some View {
        Menu(title) {
            Text(url.path)
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
                openInPool(item)
            }
        }
    }

    private func item(for selection: Set<HorizontalPoolLibraryItem.ID>) -> HorizontalPoolLibraryItem? {
        guard let id = selection.first else {
            return nil
        }
        return items.first { $0.id == id }
    }

    /// Horizon's pool browser context menu, minus what needs editors: open
    /// the item in each pool that carries it (a window per pool, scrolled to
    /// the item), reveal the file, copy its identity.
    @ViewBuilder
    private func itemContextMenu(_ item: HorizontalPoolLibraryItem) -> some View {
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

    /// Double-click or "Open in Pool": the item's pool in its own window,
    /// selected there. Inside that pool's own window there is nothing
    /// further to open (editing is not built).
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
        } else {
            addPoolFailurePath = url.lastPathComponent
        }
    }

    private func applyPendingReveal() {
        guard let request = pendingReveal else {
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
