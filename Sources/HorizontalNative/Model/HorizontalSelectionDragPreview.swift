import CoreGraphics

/// An area-selection drag in progress, anchored to the document rather than
/// to the screen.
///
/// The input layer reports a drag as screen points. Each is converted to a
/// world point once, with the viewport as it was when the pointer was there,
/// so panning or zooming mid-drag leaves the region already drawn where it
/// was drawn. `current` stays a screen point: it is the pointer, which a pan
/// does not move.
struct HorizontalSelectionDragPreview {
    var tool: HorizontalSelectionTool
    private(set) var start: HorizontalPoint
    private(set) var current: CGPoint
    private(set) var points: [HorizontalPoint]

    init(
        tool: HorizontalSelectionTool,
        start: CGPoint,
        current: CGPoint,
        points: [CGPoint],
        toWorld: (CGPoint) -> HorizontalPoint
    ) {
        self.tool = tool
        self.start = toWorld(start)
        self.current = current
        self.points = points.map(toWorld)
    }

    /// Takes the drag's screen points so far, which only ever grow, and
    /// anchors those not yet seen. Returns false, changing nothing, when
    /// `points` is shorter than what is already anchored: a different drag.
    mutating func extend(
        current: CGPoint,
        points screenPoints: [CGPoint],
        toWorld: (CGPoint) -> HorizontalPoint
    ) -> Bool {
        guard screenPoints.count >= points.count else {
            return false
        }
        self.current = current
        points.append(contentsOf: screenPoints[points.count...].map(toWorld))
        return true
    }
}
