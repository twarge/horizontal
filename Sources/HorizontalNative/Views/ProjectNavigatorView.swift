import SwiftUI

/// What the project navigator can select. The macOS workspace's sidebar and
/// the iPad's left-hand panel both list a project this way.
enum ProjectNavigatorSelection: Hashable {
    case package
    case projectFile
    case blocksFile
    case pool
    case block(String)
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
    /// (schematic URL, sheet ID, new name)
    var onRenameSheet: (URL, String, String) -> Void = { _, _, _ in }
    /// (schematic URL, sheet IDs in their new order)
    var onReorderSheets: (URL, [String]) -> Void = { _, _ in }

    @State private var renameTarget: SheetRenameTarget?
    @State private var renameDraft = ""

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
                Section("Blocks") {
                    ForEach(project.schematics.filter(schematicMatchesSearch)) { schematic in
                        let blockMatches = blockMatchesSearch(schematic.block, schematicFilename: schematic.schematicFilename)
                        let sheets = sheetsForSearch(in: schematic, blockMatches: blockMatches)

                        if blockMatches || !isSearching {
                            NavigatorRow(
                                icon: schematic.block.isTop ? "target" : "square.stack.3d.up",
                                title: navigatorTitle(for: schematic.block),
                                detail: schematic.schematicFilename
                            )
                            .tag(ProjectNavigatorSelection.block(schematic.block.uuid))
                            .disabled(!isAvailable(schematic.block))
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
                                    sheetContextMenu(for: sheet, schematicURL: schematic.schematic.url)
                                }
                            }
                        }
                        .onMove(perform: sheetMoveHandler(orderedIDs: schematic.schematic.sheets.map(\.id), schematicURL: schematic.schematic.url))
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
                            sheetContextMenu(for: sheet, schematicURL: schematic.url)
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
    }

    @ViewBuilder
    private func sheetContextMenu(for sheet: HorizontalSchematicSheet, schematicURL: URL) -> some View {
        if allowsSheetEditing {
            Button("Rename…") {
                renameDraft = sheet.name
                renameTarget = SheetRenameTarget(
                    schematicURL: schematicURL,
                    sheetID: sheet.id,
                    currentName: sheet.name
                )
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
        case .sheet, .standaloneSheet:
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
