import Foundation

/// Which net a board's planes and polygons are on for Spotlight (L), and
/// whether a spotlight lights them: one answer for the nets a selection
/// gives Spotlight, the canvas's drawing of what is spotlit, and the framing
/// of it in the other views.
///
/// In Horizon the net is the plane's, not its polygon's: a plane holds a
/// polygon, which has no net of its own (the board loader gives it none). So
/// a polygon a plane is poured in is on its plane's net, as the selection HUD
/// names it ("Plane GND"): selecting it and pressing L spotlights the plane's
/// net with the rest of the selection's, and a spotlight on that net lights
/// the plane, its fill and its polygon both. A polygon with no plane is on
/// its own net when it has one, and on none when it hasn't. The board outline
/// is no copper of any net, and no spotlight lights it. Nets and ids are
/// compared lowercased.
struct BoardSpotlightNets {
    /// Each plane's net by its polygon's id, lowercased. A plane with no net
    /// leaves its polygon to its own.
    private let planeNetIDsByPolygonID: [String: String]

    init(planes: [HorizontalPlane]) {
        var nets = [String: String](minimumCapacity: planes.count)
        for plane in planes {
            guard let netID = plane.netID else {
                continue
            }
            let polygonID = plane.polygonID.lowercased()
            if nets[polygonID] == nil {
                nets[polygonID] = netID
            }
        }
        planeNetIDsByPolygonID = nets
    }

    init(_ board: HorizontalBoard) {
        self.init(planes: board.planes)
    }

    // MARK: - Which net

    /// The net the polygon is on: its plane's when a plane is poured in it,
    /// else its own, if any.
    func netID(of polygon: HorizontalPolygon) -> String? {
        planeNetIDsByPolygonID[polygon.id.lowercased()] ?? polygon.netID
    }

    /// The net of each polygon a click can pick on the board, by its id
    /// lowercased: the board's own and the outlines its planes and keepouts
    /// hold (`HorizontalBoard.outlinePolygons`), the board's own first where
    /// an id is both, as a pick finds them. For a selection of thousands, one
    /// look-up each.
    static func polygonNetIDs(in board: HorizontalBoard) -> [String: String?] {
        let nets = BoardSpotlightNets(board)
        var result = [String: String?](minimumCapacity: board.polygons.count + board.planes.count)
        for polygon in board.polygons + board.outlinePolygons where result[polygon.id.lowercased()] == nil {
            result[polygon.id.lowercased()] = .some(nets.netID(of: polygon))
        }
        return result
    }

    // MARK: - Whether a spotlight lights it

    /// Whether a spotlight on `netIDs`, lowercased, lights the polygon: its
    /// plane's net or its own is one of them, and it isn't the board outline.
    func lights(_ polygon: HorizontalPolygon, spotlighting netIDs: Set<String>) -> Bool {
        guard !(polygon.layer.map(HorizontalBoardLayers.isOutline) ?? false) else {
            return false
        }
        return Self.isSpotlit(netID(of: polygon), spotlighting: netIDs)
    }

    /// Whether a spotlight on `netIDs`, lowercased, lights the plane, its
    /// fill and its polygon.
    static func lights(_ plane: HorizontalPlane, spotlighting netIDs: Set<String>) -> Bool {
        isSpotlit(plane.netID, spotlighting: netIDs)
    }

    /// Whether `netID` is one of `netIDs`, which are lowercased.
    static func isSpotlit(_ netID: String?, spotlighting netIDs: Set<String>) -> Bool {
        guard let netID, !netIDs.isEmpty else {
            return false
        }
        return netIDs.contains(netID.lowercased())
    }

    /// Where the planes and polygons a spotlight on `netIDs`, lowercased,
    /// lights lie on the board: each lit plane's fills, or its outline while
    /// it has none (what it draws, `HorizontalPlane.renderFragments`), and
    /// each lit polygon of the board's own.
    func spotlitPoints(in board: HorizontalBoard, spotlighting netIDs: Set<String>) -> [HorizontalPoint] {
        guard !netIDs.isEmpty else {
            return []
        }
        var points = [HorizontalPoint]()
        for plane in board.planes where Self.lights(plane, spotlighting: netIDs) {
            points.append(contentsOf: plane.points)
        }
        for polygon in board.polygons where lights(polygon, spotlighting: netIDs) {
            points.append(contentsOf: polygon.vertices)
        }
        return points
    }
}
