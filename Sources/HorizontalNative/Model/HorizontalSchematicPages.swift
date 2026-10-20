import Foundation

/// One page of the design as Horizon numbers and prints it: a sheet of some
/// block, drawn through the instance path that reaches it.
struct HorizontalSchematicPage: Identifiable {
    var block: HorizontalProjectBlock
    /// The sheet as its block's schematic holds it.
    var sheet: HorizontalSchematicSheet
    /// The instances, top down, that lead to the sheet; empty on the top
    /// block's own sheets.
    var path: [String]
    /// The page number, from 1.
    var number: Int

    var id: String { (path + [sheet.id]).joined(separator: "/") }
}

extension HorizontalProject {
    /// Horizon's `SheetMapping`, through `walk_sheets`: the top block's
    /// sheets in index order, each followed by the sheets of the blocks drawn
    /// on it, in their instances' refdes order, however deep. A block used
    /// three times gives its sheets three times; one used nowhere gives none.
    var schematicPages: [HorizontalSchematicPage] {
        guard let top = schematics.first(where: \.block.isTop) ?? schematics.first else {
            return []
        }
        var pages = [HorizontalSchematicPage]()
        func visit(_ entry: HorizontalProjectSchematic, path: [String]) {
            guard path.count < HorizontalBlockFlattener.maximumDepth else { return }
            for sheet in entry.schematic.sheets.sorted(by: { ($0.index, $0.id) < ($1.index, $1.id) }) {
                pages.append(HorizontalSchematicPage(block: entry.block, sheet: sheet, path: path, number: pages.count + 1))
                let symbols = sheet.blockSymbols.sorted { $0.refdes.localizedStandardCompare($1.refdes) == .orderedAscending }
                for symbol in symbols {
                    guard let child = schematics.first(where: { $0.block.uuid.caseInsensitiveCompare(symbol.blockID) == .orderedSame }) else {
                        continue
                    }
                    visit(child, path: path + [symbol.instanceID.lowercased()])
                }
            }
        }
        visit(top, path: [])
        return pages
    }

    /// A page's sheet as it prints: its components under the refdes its
    /// instance gives them, and its frame numbered among all the pages.
    func drawnSheet(for page: HorizontalSchematicPage, of total: Int) -> HorizontalSchematicSheet {
        var sheet = page.sheet
        if !page.path.isEmpty {
            sheet = sheet.showingRefdes(flattenedBlock?.instanceRefdes[page.path.joined(separator: "/")] ?? [:])
        }
        return sheet.numbered(page.number, of: total)
    }
}

extension HorizontalSchematicSheet {
    /// The sheet with its frame showing it as page `index` of `total`, as
    /// Horizon's title block numbers a hierarchy's sheets.
    func numbered(_ index: Int, of total: Int) -> HorizontalSchematicSheet {
        guard !frameNumberTemplates.isEmpty else {
            return self
        }
        var sheet = self
        for position in sheet.frameTexts.indices {
            guard let template = frameNumberTemplates[sheet.frameTexts[position].id] else { continue }
            sheet.frameTexts[position].text = HorizontalSchematic.numberedFrameText(template, index: index, total: total)
        }
        return sheet
    }
}
