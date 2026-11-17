import Foundation

/// Where a board text draws: the box its strokes fill, as the canvas and the
/// silkscreen check draw them, and which way it runs from its position.
enum HorizontalBoardTextExtents {
    struct Extent {
        /// The strokes' box, their width included.
        var box: HorizontalRect
        var corners: [HorizontalPoint] {
            [HorizontalPoint(x: box.minX, y: box.minY), HorizontalPoint(x: box.maxX, y: box.minY),
             HorizontalPoint(x: box.maxX, y: box.maxY), HorizontalPoint(x: box.minX, y: box.maxY)]
        }
        /// "right", "left", "up" or "down" from the text's position, as the
        /// board is seen from the top; "centered" for a text centred on it,
        /// and for one that draws nothing.
        var runs: String
    }

    /// A text the board draws, and the package it belongs to.
    struct Drawn {
        var text: HorizontalText
        /// The board package, lowercased; nil for a text of the board's own.
        var packageID: String?
        /// The text's id in the board's or the pool package's `texts`.
        var textID: String
    }

    static func extent(of text: HorizontalText) -> Extent {
        let segments = HorizontalOutlineTextRenderer.outlineSegments(for: text)
        guard !segments.isEmpty else {
            return Extent(box: HorizontalRect(points: [text.position]), runs: "centered")
        }
        let points = segments.flatMap { [$0.0, $0.1] }
        let strokes = HorizontalRect(points: points)
        let box = HorizontalRouteClearanceProbe.bounds(points, growth: max(text.width, 0) / 2)
        let dx: Double = strokes.center.x - text.position.x
        let dy: Double = strokes.center.y - text.position.y
        let runs: String
        // A text that starts at its position has its middle half its length
        // away along the way it runs; one centred on it has it there.
        if text.centered || max(abs(dx), abs(dy)) < max(strokes.width, strokes.height) / 4 {
            runs = "centered"
        } else if abs(dx) >= abs(dy) {
            runs = dx > 0 ? "right" : "left"
        } else {
            runs = dy > 0 ? "up" : "down"
        }
        return Extent(box: box, runs: runs)
    }

    /// Every text the board draws: its own, the ones smashed out of packages,
    /// and each package's own that neither a smash nor Omit Silkscreen hides.
    static func drawnTexts(of board: HorizontalBoard) -> [Drawn] {
        var drawn = board.texts.map { Drawn(text: $0, packageID: nil, textID: $0.id) }
        let omissions = HorizontalPackageOmissions(packages: board.packages)
        for text in board.packageTexts {
            guard text.fromSmash || !omissions.omits(text.id, layer: text.layer) else { continue }
            let parts = text.id.split(separator: "/").map(String.init)
            drawn.append(Drawn(text: text, packageID: parts.first?.lowercased(), textID: parts.last ?? text.id))
        }
        return drawn
    }
}
