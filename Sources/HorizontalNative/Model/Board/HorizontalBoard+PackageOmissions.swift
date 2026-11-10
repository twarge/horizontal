import Foundation

/// Horizon's omit_silkscreen and omit_outline on placed packages, as its
/// `Canvas::render(Package)` and `Board::get_outline` apply them: a package
/// omitting its silkscreen draws none of its own lines, arcs, polygons or
/// texts on a silkscreen layer, and one omitting its outline none of its own
/// polygons on the outline layer. The texts smashed out of a package are the
/// board's, and stay.
struct HorizontalPackageOmissions {
    private var silkscreen = Set<String>()
    private var outline = Set<String>()

    init(packages: [HorizontalPlacement]) {
        for package in packages {
            if package.omitSilkscreen { silkscreen.insert(package.id.lowercased()) }
            if package.omitOutline { outline.insert(package.id.lowercased()) }
        }
    }

    var isEmpty: Bool { silkscreen.isEmpty && outline.isEmpty }

    /// Whether the package geometry `geometryID` on `layer` goes undrawn;
    /// `polygon` says it is one of the package's polygons, the only thing
    /// omit_outline takes.
    func omits(_ geometryID: String, layer: Int?, polygon: Bool = false) -> Bool {
        guard !isEmpty, let layer, let package = BoardMovePlanner.packageID(forGeometryID: geometryID)?.lowercased() else {
            return false
        }
        return (HorizontalBoardLayers.isSilkscreen(layer) && silkscreen.contains(package))
            || (polygon && HorizontalBoardLayers.isOutline(layer) && outline.contains(package))
    }
}

extension HorizontalBoard {
    /// The board without the package artwork its packages' Omit Silkscreen
    /// and Omit Outline leave out. The loader keeps all of it, so the board
    /// canvas, which gates it as it draws, can turn the flags on and off
    /// live; the 3D view and the exports, which draw the board as it is
    /// made, read this.
    func omittingPackageArtwork() -> HorizontalBoard {
        let omissions = HorizontalPackageOmissions(packages: packages)
        guard !omissions.isEmpty else { return self }
        var board = self
        board.packagePolygons.removeAll { omissions.omits($0.id, layer: $0.layer, polygon: true) }
        board.packageLines.removeAll { omissions.omits($0.id, layer: $0.layer) }
        board.packageArcs.removeAll { omissions.omits($0.id, layer: $0.layer) }
        board.packageTexts.removeAll { !$0.fromSmash && omissions.omits($0.id, layer: $0.layer) }
        return board
    }
}
