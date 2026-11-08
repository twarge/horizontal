import Foundation

/// Where Spotlight (L) frames what it spotlights in each view, when the
/// setting asks it to: the board and the 3D view on the components' pads and
/// the nets' pads, tracks, airwires and vias, much as `zoom_to` frames them; the
/// schematic on the sheet that draws the most of it, the one showing when it
/// draws as much as any other. Ids are compared lowercased.
enum HorizontalSpotlightFraming {
    /// The setting: Spotlight scrolls and zooms every view showing to what
    /// it spotlights. Off by default.
    static let framesEveryViewKey = "Horizontal.spotlight.framesEveryView"

    /// Room around what is framed, as `zoom_to` leaves by default.
    static let margin = 3_000_000.0

    /// What the spotlit components' packages and nets' copper cover on the
    /// board, with a margin; nil when none of it is on the board.
    static func boardRect(_ board: HorizontalBoard, netIDs: Set<String>, componentIDs: Set<String>) -> HorizontalRect? {
        let nets = Set(netIDs.map { $0.lowercased() })
        let components = Set(componentIDs.map { $0.lowercased() })
        func onNet(_ netID: String?) -> Bool {
            netID.map { nets.contains($0.lowercased()) } ?? false
        }
        let packages = board.packages.filter { $0.componentID.map { components.contains($0.lowercased()) } ?? false }
        let prefixes = packages.map { $0.id.lowercased() + "/" }
        var points = [HorizontalPoint]()
        for pad in board.packagePads {
            let id = pad.id.lowercased()
            if onNet(pad.netID) || prefixes.contains(where: id.hasPrefix) {
                points.append(contentsOf: pad.vertices)
            }
        }
        // A package without pads is framed about its origin.
        for package in packages where !board.packagePads.contains(where: { $0.id.lowercased().hasPrefix(package.id.lowercased() + "/") }) {
            points.append(package.position)
        }
        for segment in board.tracks + board.airwires where onNet(segment.netID) {
            points.append(segment.from)
            points.append(segment.to)
        }
        // Vias too, which zoom_to leaves out: a net of vias and planes alone
        // still has somewhere to be.
        for via in board.vias where onNet(via.netID) {
            points.append(via.position)
        }
        return framed(points, smallest: 2_000_000)
    }

    /// The side of the board every spotlit package is on, when they share
    /// one: a sided view turns over to it, as `zoom_to` turns it.
    static func boardSide(_ board: HorizontalBoard, componentIDs: Set<String>) -> HorizontalBoardSide? {
        let components = Set(componentIDs.map { $0.lowercased() })
        let sides = Set(board.packages.compactMap { package -> Bool? in
            package.componentID.map { components.contains($0.lowercased()) } == true ? package.mirrored : nil
        })
        guard sides.count == 1, let mirrored = sides.first else {
            return nil
        }
        return mirrored ? .bottom : .top
    }

    struct SheetTarget: Equatable {
        /// The block whose sheet it is; nil for a schematic that stands alone.
        var blockID: String?
        var sheetID: String
        var rect: HorizontalRect
    }

    /// The sheet that draws the most of what is spotlit — its components'
    /// symbols, and its nets' wires and the pins on them — and the rectangle
    /// about it there. The sheet showing wins a tie, so a spotlight that is
    /// on it doesn't turn the page.
    static func sheetTarget(_ project: HorizontalProject, netIDs: Set<String>, componentIDs: Set<String>,
                            currentSheetID: String?) -> SheetTarget? {
        let nets = Set(netIDs.map { $0.lowercased() })
        let components = Set(componentIDs.map { $0.lowercased() })
        guard !nets.isEmpty || !components.isEmpty else {
            return nil
        }
        func onNet(_ netID: String?) -> Bool {
            netID.map { nets.contains($0.lowercased()) } ?? false
        }
        var pages: [(blockID: String?, sheet: HorizontalSchematicSheet)] = project.schematics.flatMap { schematic in
            schematic.schematic.sheets.map { (Optional(schematic.block.uuid), $0) }
        }
        if pages.isEmpty, let schematic = project.schematic {
            pages = schematic.sheets.map { (nil, $0) }
        }
        var best: (count: Int, target: SheetTarget)?
        for page in pages.sorted(by: { $0.sheet.index < $1.sheet.index }) {
            var points = [HorizontalPoint]()
            var symbols = 0
            for symbol in page.sheet.symbols where symbol.componentID.map({ components.contains($0.lowercased()) }) == true {
                // A symbol is framed 20 mm about where it stands, as zoom_to
                // frames one.
                points.append(HorizontalPoint(x: symbol.position.x - 10_000_000, y: symbol.position.y - 10_000_000))
                points.append(HorizontalPoint(x: symbol.position.x + 10_000_000, y: symbol.position.y + 10_000_000))
                symbols += 1
            }
            var wires = 0
            for segment in page.sheet.netLines + page.sheet.symbolPins where onNet(segment.netID) {
                points.append(segment.from)
                points.append(segment.to)
                wires += 1
            }
            guard let rect = framed(points, smallest: 20_000_000) else {
                continue
            }
            // A symbol counts for more than a stretch of wire: the parts are
            // what L was pressed on, more often than not.
            let count = symbols * 1_000 + wires
            let isCurrent = page.sheet.id.caseInsensitiveCompare(currentSheetID ?? "") == .orderedSame
            if best == nil || count > best!.count || (count == best!.count && isCurrent) {
                best = (count, SheetTarget(blockID: page.blockID, sheetID: page.sheet.id, rect: rect))
            }
        }
        return best?.target
    }

    /// The points' bounds with the margin, at least `smallest` across.
    static func framed(_ points: [HorizontalPoint], smallest: Double) -> HorizontalRect? {
        guard !points.isEmpty else {
            return nil
        }
        // Not HorizontalRect.isEmpty, which a straight run of track, one
        // flat side, would count as empty.
        let bounds = HorizontalRect(points: points)
        var low = HorizontalPoint(x: bounds.minX, y: bounds.minY)
        var high = HorizontalPoint(x: bounds.maxX, y: bounds.maxY)
        if high.x - low.x < smallest, high.y - low.y < smallest {
            let center = HorizontalPoint(x: (low.x + high.x) / 2, y: (low.y + high.y) / 2)
            low = HorizontalPoint(x: center.x - smallest / 2, y: center.y - smallest / 2)
            high = HorizontalPoint(x: center.x + smallest / 2, y: center.y + smallest / 2)
        }
        return HorizontalRect(points: [
            HorizontalPoint(x: low.x - margin, y: low.y - margin),
            HorizontalPoint(x: high.x + margin, y: high.y + margin),
        ])
    }
}
