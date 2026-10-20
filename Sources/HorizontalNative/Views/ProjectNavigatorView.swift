import SwiftUI
import HorizontalProjectIO

/// What the project navigator can select. The macOS workspace's sidebar and
/// the iPad's left-hand panel both list a project this way.
enum ProjectNavigatorSelection: Hashable {
    case package
    case projectFile
    case blocksFile
    case pool
    case block(String)
    /// A block's symbol, in Horizon's block symbol editor.
    case blockSymbol(String)
    case sheet(blockID: String, sheetID: String)
    case standaloneSheet(String)
    case board
    case diagnostics
}

struct ProjectNavigatorView: View {
    var project: HorizontalProject
    @Binding var selection: ProjectNavigatorSelection?
    @Binding var searchText: String
    /// The blocks whose sheets the host can show. The rest are still listed,
    /// dimmed, so the project reads whole. nil means every block.
    var availableBlockIDs: Set<String>? = nil
    /// Sheets drawing any of these nets are marked, so a highlighted net can
    /// be followed from page to page.
    var highlightedNetIDs: Set<String> = []
    /// The schematic canvas's highlight colour, so the mark matches it.
    var highlightColor = Color.accentColor
    var allowsSheetEditing = false
    /// Blocks can be added, renamed, removed and placed from here; the iPad,
    /// which shows the top block alone, leaves them be.
    var allowsBlockEditing = false
    /// (schematic URL, sheet ID, new name)
    var onRenameSheet: (URL, String, String) -> Void = { _, _, _ in }
    /// (schematic URL, sheet IDs in their new order)
    var onReorderSheets: (URL, [String]) -> Void = { _, _ in }
    /// (schematic URL, sheet ID, the frame or nil for none). A frame with a
    /// `source` is in a base pool, and the host caches it first.
    var onSetSheetFrame: (URL, String, HorizontalSheetFrameOption?) -> Void = { _, _, _ in }
    /// (schematic URL) → the new sheet's ID, or nil when it wasn't made.
    var onAddSheet: (URL) -> String? = { _ in nil }
    /// (schematic URL, sheet ID) → whether the sheet was deleted.
    var onRemoveSheet: (URL, String) -> Bool = { _, _ in false }
    /// Horizon's Add Block: (name) → the new block's ID, or nil.
    var onAddBlock: (String) -> String? = { _ in nil }
    /// (block ID, new name)
    var onRenameBlock: (String, String) -> Void = { _, _ in }
    /// (block ID) → whether the block was removed.
    var onRemoveBlock: (String) -> Bool = { _ in false }
    /// Places an instance of the block on the sheet showing; nil when no
    /// sheet shows.
    var onPlaceBlock: ((String) -> Void)? = nil
    /// The blocks the sheet showing can use: not its own, nor one that uses it.
    var placeableBlockIDs: Set<String> = []

    @State private var renameTarget: SheetRenameTarget?
    @State private var renameDraft = ""
    @State private var blockNameTarget: BlockNameTarget?
    @State private var blockNameDraft = ""
    /// The frames the project's base pools hold, for the Frame menu; read off
    /// the main thread, since it scans the pools.
    @State private var basePoolFrames: [HorizontalSheetFrameOption] = []
    @ObservedObject private var poolRegistry = HorizontalPoolRegistry.shared

    /// What the block name prompt names: a block to add, or one to rename.
    private enum BlockNameTarget: Identifiable {
        case new
        case rename(String)

        var id: String {
            switch self {
            case .new: "new"
            case .rename(let blockID): blockID
            }
        }
    }

    private struct SheetRenameTarget: Identifiable {
        var schematicURL: URL
        var sheetID: String
        var currentName: String
        var id: String { sheetID }
    }

    /// Net IDs are per block, so a sheet of another block never matches.
    private var sheetIDsWithHighlightedNet: Set<String> {
        guard !highlightedNetIDs.isEmpty else {
            return []
        }
        let netIDs = Set(highlightedNetIDs.map { $0.lowercased() })
        let sheets = project.schematics.isEmpty
            ? project.schematic?.sheets ?? []
            : project.schematics.flatMap(\.schematic.sheets)
        return Set(sheets.filter { $0.containsAnyNet(netIDs) }.map(\.id))
    }

    var body: some View {
        let sheetIDsWithHighlightedNet = sheetIDsWithHighlightedNet
        List(selection: $selection) {
            if !project.schematics.isEmpty {
                Section {
                    ForEach(project.schematics.filter(schematicMatchesSearch)) { schematic in
                        let blockMatches = blockMatchesSearch(schematic.block, schematicFilename: schematic.schematicFilename)
                        let sheets = sheetsForSearch(in: schematic, blockMatches: blockMatches)

                        if blockMatches || !isSearching {
                            NavigatorRow(
                                icon: schematic.block.isTop ? "target" : "square.stack.3d.up",
                                title: navigatorTitle(for: schematic.block),
                                detail: blockDetail(for: schematic)
                            )
                            .tag(ProjectNavigatorSelection.block(schematic.block.uuid))
                            .disabled(!isAvailable(schematic.block))
                            .contextMenu {
                                if allowsSheetEditing, isAvailable(schematic.block) {
                                    blockContextMenu(for: schematic)
                                }
                            }
                        }

                        if allowsBlockEditing, !schematic.block.isTop, schematic.block.symbolFilename?.isEmpty == false,
                           blockMatches || !isSearching {
                            NavigatorRow(icon: "square.on.square.dashed", title: "Symbol")
                                .padding(.leading, 18)
                                .tag(ProjectNavigatorSelection.blockSymbol(schematic.block.uuid))
                                .disabled(!isAvailable(schematic.block))
                                .contextMenu {
                                    if allowsSheetEditing, isAvailable(schematic.block) {
                                        blockContextMenu(for: schematic)
                                    }
                                }
                        }

                        ForEach(sheets) { sheet in
                            if matchesSearch("sheet", sheet.name, navigatorTitle(for: schematic.block)) || blockMatches || !isSearching {
                                NavigatorRow(
                                    icon: "rectangle.grid.1x2",
                                    title: sheet.name,
                                    marksHighlightedNet: sheetIDsWithHighlightedNet.contains(sheet.id),
                                    highlightColor: highlightColor
                                )
                                .padding(.leading, 18)
                                .tag(ProjectNavigatorSelection.sheet(blockID: schematic.block.uuid, sheetID: sheet.id))
                                .disabled(!isAvailable(schematic.block))
                                .contextMenu {
                                    sheetContextMenu(for: sheet, in: schematic.schematic.sheets, schematicURL: schematic.schematic.url) {
                                        .sheet(blockID: schematic.block.uuid, sheetID: $0)
                                    }
                                }
                            }
                        }
                        .onMove(perform: sheetMoveHandler(orderedIDs: schematic.schematic.sheets.map(\.id), schematicURL: schematic.schematic.url))
                    }
                } header: {
                    HStack {
                        Text("Blocks")
                        Spacer()
                        if allowsSheetEditing, allowsBlockEditing {
                            Button {
                                beginNamingBlock(.new)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                            .help("New Block")
                            .accessibilityLabel("New Block")
                        }
                    }
                }
            }

            if let schematic = project.schematic, project.schematics.isEmpty {
                Section("Schematic") {
                    if matchesSearch("schematic", schematic.url.lastPathComponent) {
                        NavigatorRow(
                            icon: "doc.text.magnifyingglass",
                            title: schematic.url.lastPathComponent,
                            detail: "Schematic"
                        )
                        .contextMenu {
                            if allowsSheetEditing {
                                newSheetButton(schematicURL: schematic.url) { .standaloneSheet($0) }
                            }
                        }
                    }
                    ForEach(schematic.sheets.filter { matchesSearch("sheet", $0.name) }) { sheet in
                        NavigatorRow(
                            icon: "rectangle.grid.1x2",
                            title: sheet.name,
                            marksHighlightedNet: sheetIDsWithHighlightedNet.contains(sheet.id),
                            highlightColor: highlightColor
                        )
                        .tag(ProjectNavigatorSelection.standaloneSheet(sheet.id))
                        .contextMenu {
                            sheetContextMenu(for: sheet, in: schematic.sheets, schematicURL: schematic.url) { .standaloneSheet($0) }
                        }
                    }
                    .onMove(perform: sheetMoveHandler(orderedIDs: schematic.sheets.map(\.id), schematicURL: schematic.url))
                }
            }

            if let board = project.board {
                Section("Board") {
                    if matchesSearch("board", board.url.lastPathComponent, board.name) {
                        NavigatorRow(icon: "cpu", title: board.url.lastPathComponent, detail: board.name)
                            .tag(ProjectNavigatorSelection.board)
                    }
                }
            }

            if let selectedSummary {
                Section("Selection") {
                    NavigatorSelectionSummaryView(summary: selectedSummary)
                }
            }

            if !project.diagnostics.isEmpty {
                Section("Diagnostics") {
                    NavigatorRow(icon: "exclamationmark.triangle", title: "Diagnostics", detail: "\(project.diagnostics.count) messages")
                        .tag(ProjectNavigatorSelection.diagnostics)
                    ForEach(project.diagnostics) { diagnostic in
                        Label(diagnostic.message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .alert("Rename Sheet", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameDraft)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert(blockNameTitle, isPresented: blockNameAlertPresented) {
            TextField("Name", text: $blockNameDraft)
            Button(blockNameTarget.map { if case .new = $0 { "Add" } else { "Rename" } } ?? "OK") { commitBlockName() }
            Button("Cancel", role: .cancel) { blockNameTarget = nil }
        } message: {
            if case .new? = blockNameTarget {
                Text("A block is a schematic of its own that other sheets use through its symbol, as many times as they like.")
            }
        }
        .task(id: allowsSheetEditing ? [projectPoolURL.path] + poolRegistry.pools.map(\.url.path) : []) {
            guard allowsSheetEditing else {
                basePoolFrames = []
                return
            }
            let poolURL = projectPoolURL
            basePoolFrames = await Task.detached(priority: .utility) {
                HorizontalSchematic.basePoolFrames(poolURL: poolURL)
            }.value
        }
    }

    private var projectPoolURL: URL {
        project.baseURL.appendingPathComponent(project.poolDirectory ?? HorizontalProjectArchive.projectPoolDirectoryName, isDirectory: true)
    }

    /// `select` turns a sheet ID into the selection that shows it, so a new
    /// sheet can be shown and a deleted one's neighbour selected.
    @ViewBuilder
    private func sheetContextMenu(
        for sheet: HorizontalSchematicSheet,
        in sheets: [HorizontalSchematicSheet],
        schematicURL: URL,
        selecting select: @escaping (String) -> ProjectNavigatorSelection
    ) -> some View {
        if allowsSheetEditing {
            Button("Rename…") {
                renameDraft = sheet.name
                renameTarget = SheetRenameTarget(
                    schematicURL: schematicURL,
                    sheetID: sheet.id,
                    currentName: sheet.name
                )
            }
            frameMenu(for: sheet, schematicURL: schematicURL)
            Divider()
            newSheetButton(schematicURL: schematicURL, selecting: select)
            deleteSheetButton(for: sheet, in: sheets, schematicURL: schematicURL, selecting: select)
        }
    }

    /// The blocks some sheet draws an instance of: those can't be removed.
    private var usedBlockIDs: Set<String> {
        Set(project.schematics.flatMap { $0.schematic.sheets.flatMap { $0.blockSymbols.map(\.blockID) } })
    }

    private func blockDetail(for schematic: HorizontalProjectSchematic) -> String {
        guard !schematic.block.isTop else {
            return schematic.schematicFilename
        }
        let count = project.schematics.reduce(0) { total, other in
            total + other.schematic.sheets.reduce(0) { $0 + $1.blockSymbols.filter { $0.blockID == schematic.block.uuid.lowercased() }.count }
        }
        return count == 1 ? "1 instance" : "\(count) instances"
    }

    /// Horizon's sheets-and-blocks menu for a block: place one, edit its
    /// symbol, name it, give it a sheet, or remove it while nothing uses it.
    @ViewBuilder
    private func blockContextMenu(for schematic: HorizontalProjectSchematic) -> some View {
        let block = schematic.block
        if allowsBlockEditing, !block.isTop {
            Button("Place Block") {
                onPlaceBlock?(block.uuid)
            }
            .disabled(onPlaceBlock == nil || !placeableBlockIDs.contains(block.uuid.lowercased()))
            Button("Edit Symbol") {
                selection = .blockSymbol(block.uuid)
            }
            .disabled(block.symbolFilename?.isEmpty != false)
            Button("Rename Block…") {
                beginNamingBlock(.rename(block.uuid))
            }
            Divider()
        }
        newSheetButton(schematicURL: schematic.schematic.url) {
            .sheet(blockID: block.uuid, sheetID: $0)
        }
        if allowsBlockEditing {
            Button("New Block…") {
                beginNamingBlock(.new)
            }
        }
        if allowsBlockEditing, !block.isTop {
            Divider()
            Button("Delete Block", role: .destructive) {
                let wasShowing: Bool
                switch selection {
                case .block(let id), .blockSymbol(let id), .sheet(let id, _):
                    wasShowing = id == block.uuid
                default:
                    wasShowing = false
                }
                if onRemoveBlock(block.uuid), wasShowing {
                    selection = project.blocks.first(where: \.isTop).map { .block($0.uuid) }
                }
            }
            .disabled(usedBlockIDs.contains(block.uuid.lowercased()))
        }
    }

    private func beginNamingBlock(_ target: BlockNameTarget) {
        switch target {
        case .new:
            blockNameDraft = "Channel"
        case .rename(let blockID):
            blockNameDraft = project.blocks.first { $0.uuid == blockID }?.displayName ?? ""
        }
        blockNameTarget = target
    }

    private var blockNameTitle: String {
        if case .rename? = blockNameTarget { return "Rename Block" }
        return "New Block"
    }

    private var blockNameAlertPresented: Binding<Bool> {
        Binding {
            blockNameTarget != nil
        } set: { presented in
            if !presented {
                blockNameTarget = nil
            }
        }
    }

    private func commitBlockName() {
        guard let target = blockNameTarget else {
            return
        }
        blockNameTarget = nil
        let name = blockNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        switch target {
        case .new:
            // Horizon selects the block it made; its symbol is what to draw first.
            if let blockID = onAddBlock(name) {
                selection = .blockSymbol(blockID)
            }
        case .rename(let blockID):
            if name != project.blocks.first(where: { $0.uuid == blockID })?.displayName {
                onRenameBlock(blockID, name)
            }
        }
    }

    /// Horizon's Add Sheet: a page after the last, which is then shown.
    private func newSheetButton(schematicURL: URL, selecting select: @escaping (String) -> ProjectNavigatorSelection) -> some View {
        Button("New Sheet") {
            if let sheetID = onAddSheet(schematicURL) {
                selection = select(sheetID)
            }
        }
    }

    /// Horizon's Delete Sheet, for a page with no symbols on it, and never
    /// the last. A deleted sheet that was showing hands the selection to the
    /// page before it, or the one after.
    private func deleteSheetButton(
        for sheet: HorizontalSchematicSheet,
        in sheets: [HorizontalSchematicSheet],
        schematicURL: URL,
        selecting select: @escaping (String) -> ProjectNavigatorSelection
    ) -> some View {
        let isEmpty = sheet.symbols.isEmpty && sheet.blockSymbolLines.isEmpty && sheet.blockSymbolPorts.isEmpty
        return Button("Delete Sheet", role: .destructive) {
            let wasSelected = selection == select(sheet.id)
            let position = sheets.firstIndex { $0.id == sheet.id } ?? 0
            let remaining = sheets.filter { $0.id != sheet.id }
            guard onRemoveSheet(schematicURL, sheet.id), wasSelected, !remaining.isEmpty else {
                return
            }
            selection = select(remaining[min(max(position - 1, 0), remaining.count - 1)].id)
        }
        .disabled(sheets.count < 2 || !isEmpty)
    }

    /// The project pool's frames: every block's sheets draw from the one pool.
    private var availableFrames: [HorizontalSheetFrameOption] {
        project.schematics.first?.schematic.availableFrames ?? project.schematic?.availableFrames ?? []
    }

    private static let noFrameTag = ""

    /// Horizon's sheet frame choice, which browses the whole pool: None and
    /// the project pool's frames, then, by pool, the frames the pools it
    /// draws from hold and it hasn't cached yet. Choosing one of those caches
    /// it into the project pool.
    private func frameMenu(for sheet: HorizontalSchematicSheet, schematicURL: URL) -> some View {
        let frames = availableFrames
        let current = sheet.frameID ?? Self.noFrameTag
        let cached = Set(frames.map(\.id))
        var poolNames = [String]()
        var framesByPool = [String: [HorizontalSheetFrameOption]]()
        for frame in basePoolFrames where !cached.contains(frame.id) {
            let pool = frame.source?.poolName ?? ""
            if framesByPool[pool] == nil { poolNames.append(pool) }
            framesByPool[pool, default: []].append(frame)
        }
        return Menu("Frame") {
            Picker("Frame", selection: Binding(
                get: { current },
                set: { chosen in
                    guard chosen != current else { return }
                    onSetSheetFrame(schematicURL, sheet.id, chosen == Self.noFrameTag
                        ? nil
                        : frames.first { $0.id == chosen } ?? HorizontalSheetFrameOption(id: chosen, name: ""))
                }
            )) {
                Text("None").tag(Self.noFrameTag)
                ForEach(frames) { frame in
                    Text(frame.name.isEmpty ? frame.id : frame.name).tag(frame.id)
                }
                // A frame the project pool lacks draws nothing, but it is
                // still what the sheet names.
                if let missing = sheet.frameID, !frames.contains(where: { $0.id == missing }) {
                    Text("\(sheet.frameName ?? String(missing.prefix(8))) (not in the project pool)").tag(missing)
                }
            }
            .pickerStyle(.inline)
            ForEach(poolNames, id: \.self) { pool in
                Section(pool.isEmpty ? "Pool" : pool) {
                    ForEach((framesByPool[pool] ?? []).sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }) { frame in
                        Button(frame.name.isEmpty ? frame.id : frame.name) {
                            onSetSheetFrame(schematicURL, sheet.id, frame)
                        }
                    }
                }
            }
        }
    }

    /// Drag-reordering for a sheets ForEach. `nil` (disabling the drag) while a
    /// search filters the rows — the visible indices wouldn't map onto the real
    /// sheet order — or when the project is read-only.
    private func sheetMoveHandler(orderedIDs: [String], schematicURL: URL) -> ((IndexSet, Int) -> Void)? {
        guard allowsSheetEditing, !isSearching, orderedIDs.count > 1 else {
            return nil
        }
        return { source, destination in
            var reordered = orderedIDs
            reordered.move(fromOffsets: source, toOffset: destination)
            guard reordered != orderedIDs else {
                return
            }
            onReorderSheets(schematicURL, reordered)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding {
            renameTarget != nil
        } set: { presented in
            if !presented {
                renameTarget = nil
            }
        }
    }

    private func commitRename() {
        guard let target = renameTarget else {
            return
        }
        renameTarget = nil
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.currentName else {
            return
        }
        onRenameSheet(target.schematicURL, target.sheetID, name)
    }

    private var isSearching: Bool {
        !searchTokens.isEmpty
    }

    private var searchTokens: [String] {
        searchText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { String($0).lowercased() }
    }

    private func matchesSearch(_ values: String...) -> Bool {
        let tokens = searchTokens
        guard !tokens.isEmpty else {
            return true
        }

        let haystack = values
            .joined(separator: " ")
            .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func blockMatchesSearch(_ block: HorizontalProjectBlock, schematicFilename: String) -> Bool {
        matchesSearch(
            "block schematic sheet",
            navigatorTitle(for: block),
            block.displayName,
            block.uuid,
            block.blockFilename ?? "",
            schematicFilename,
            block.symbolFilename ?? ""
        )
    }

    private func isAvailable(_ block: HorizontalProjectBlock) -> Bool {
        availableBlockIDs?.contains(block.uuid) ?? true
    }

    private func navigatorTitle(for block: HorizontalProjectBlock) -> String {
        block.isTop ? "Schematic" : block.displayName
    }

    private func schematicMatchesSearch(_ schematic: HorizontalProjectSchematic) -> Bool {
        blockMatchesSearch(schematic.block, schematicFilename: schematic.schematicFilename)
            || schematic.schematic.sheets.contains {
                matchesSearch("sheet", $0.name)
            }
    }

    private func sheetsForSearch(in schematic: HorizontalProjectSchematic, blockMatches: Bool) -> [HorizontalSchematicSheet] {
        if !isSearching || blockMatches {
            return schematic.schematic.sheets
        }

        return schematic.schematic.sheets.filter {
            matchesSearch("sheet", $0.name)
        }
    }

    private var selectedSummary: NavigatorSelectionSummary? {
        guard let selection else {
            return nil
        }

        switch selection {
        case .package:
            return NavigatorSelectionSummary(
                id: "package",
                title: project.url.lastPathComponent,
                subtitle: "Document Package",
                url: project.url,
                rows: [
                    detail("Project", project.projectFileURL.lastPathComponent),
                    detail("Blocks", project.blocks.count.formatted()),
                    detail("Sheets", totalSheetCount.formatted()),
                    detail("Diagnostics", project.diagnostics.count.formatted())
                ]
            )
        case .projectFile:
            return NavigatorSelectionSummary(
                id: "project-file",
                title: project.projectFileURL.lastPathComponent,
                subtitle: ".hprj Project File",
                url: project.projectFileURL,
                rows: [
                    detail("UUID", project.uuid),
                    detail("Title", project.displayTitle),
                    detail("Base", project.baseURL.lastPathComponent)
                ]
            )
        case .blocksFile:
            return NavigatorSelectionSummary(
                id: "blocks-file",
                title: project.blocksFilename,
                subtitle: "Block Graph",
                url: project.baseURL.appendingPathComponent(project.blocksFilename),
                rows: [
                    detail("Blocks", project.blocks.count.formatted()),
                    detail("Top Block", project.blocks.first(where: \.isTop)?.displayName ?? "Unavailable")
                ]
            )
        case .pool:
            guard let poolDirectory = project.poolDirectory else {
                return nil
            }
            return NavigatorSelectionSummary(
                id: "pool",
                title: poolDirectory,
                subtitle: "Project Pool",
                url: project.baseURL.appendingPathComponent(poolDirectory),
                rows: [
                    detail("Location", project.baseURL.appendingPathComponent(poolDirectory).path)
                ]
            )
        case .block(let blockID):
            guard let schematic = project.schematics.first(where: { $0.block.uuid == blockID }) else {
                return nil
            }
            return NavigatorSelectionSummary(
                id: "block-\(blockID)",
                title: schematic.block.displayName,
                subtitle: schematic.block.isTop ? "Top Block" : "Block",
                url: schematic.block.blockFilename.map { project.baseURL.appendingPathComponent($0) },
                rows: [
                    detail("UUID", schematic.block.uuid),
                    detail("Schematic", schematic.schematicFilename)
                ]
            )
        case .sheet, .standaloneSheet, .blockSymbol:
            return nil
        case .board:
            return nil
        case .diagnostics:
            return NavigatorSelectionSummary(
                id: "diagnostics",
                title: "Diagnostics",
                subtitle: "\(project.diagnostics.count.formatted()) messages",
                url: nil,
                rows: project.diagnostics.prefix(5).enumerated().map { index, diagnostic in
                    detail("Message \(index + 1)", diagnostic.message)
                }
            )
        }
    }

    private var totalSheetCount: Int {
        if project.schematics.isEmpty {
            return project.schematic?.sheets.count ?? 0
        }
        return project.schematics.reduce(0) { $0 + $1.schematic.sheets.count }
    }

    private func detail(_ title: String, _ value: String) -> NavigatorSelectionDetail {
        NavigatorSelectionDetail(title: title, value: value)
    }
}

struct NavigatorSelectionSummary: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var url: URL?
    var rows: [NavigatorSelectionDetail]
}

struct NavigatorSelectionDetail: Identifiable {
    var title: String
    var value: String

    var id: String { "\(title):\(value)" }
}

struct NavigatorSelectionSummaryView: View {
    var summary: NavigatorSelectionSummary
    var usesSystemValueText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(summary.rows) { row in
                NavigatorValueRow(title: row.title, value: row.value, usesSystemValueText: usesSystemValueText)
            }

            // An iPad document's files live inside its package, which Files
            // shows only as the document itself: there is nothing to reveal.
            #if os(macOS)
            if let url = summary.url {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")

                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Open")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy Path")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            #endif
        }
        .padding(.vertical, 4)
    }
}

struct NavigatorRow: View {
    var icon: String
    var title: String
    var detail: String?
    /// A sheet that draws the highlighted net.
    var marksHighlightedNet = false
    var highlightColor = Color.accentColor

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(marksHighlightedNet ? .semibold : nil)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if marksHighlightedNet {
                    Spacer(minLength: 0)
                    Circle()
                        .fill(highlightColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(marksHighlightedNet ? AnyShapeStyle(highlightColor) : AnyShapeStyle(.secondary))
        }
        .help(marksHighlightedNet ? "Contains the highlighted net" : "")
        .accessibilityValue(marksHighlightedNet ? "Contains the highlighted net" : "")
    }
}

struct NavigatorValueRow: View {
    var title: String
    var value: String
    var usesSystemValueText = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(usesSystemValueText ? .body.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(usesSystemValueText ? .primary : .secondary)
        }
    }
}
