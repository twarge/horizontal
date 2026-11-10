import Foundation

/// Pure geometry for two reciprocal tools:
///  • `tool_polygon_to_line_loop` — explode a polygon into junction-connected
///  lines/arcs (each edge inherits the originating vertex's line/arc type).
///  • `tool_line_loop_to_polygon` — collapse a closed loop of lines/arcs back
///  into a polygon (a DFS finds the cycle; arc connectors become arc vertices).
///
/// Horizontal stores board lines/arcs point-based (junctions are resolved by
/// position on save), and a polygon vertex describes the edge *leaving* it toward
/// the next vertex (matching `Polygon::Vertex`). Arc direction differs:
/// Horizon arcs carry no reverse flag (direction is the from→to order), while a
/// `HorizontalArc` has an explicit `reverse`. The shape-preserving bridge is
/// `vertexArcReverse = arc.reverse XOR (node == arc.to)`, which round-trips.
enum HorizontalPolygonLineLoop {
    static func pointKey(_ point: HorizontalPoint) -> String {
        "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
    }

    // MARK: - Polygon → Line loop

    struct LineLoopResult: Equatable {
        var lines: [HorizontalSegment]
        var arcs: [HorizontalArc]
        /// Endpoint and arc-center positions that need a junction so the lines/arcs
        /// resolve on save. The caller ensures a board junction at each.
        var junctionPoints: [HorizontalPoint]
    }

    /// Explodes `polygon` into a closed loop of width-0 lines/arcs on the polygon's
    /// layer (`tool_polygon_to_line_loop`). Returns nil for a degenerate
    /// polygon (< 3 vertices).
    static func lineLoop(from polygon: HorizontalPolygon, makeID: () -> String) -> LineLoopResult? {
        let verts = polygon.polygonVertices
        guard verts.count >= 3 else {
            return nil
        }
        var lines: [HorizontalSegment] = []
        var arcs: [HorizontalArc] = []
        var junctionPoints: [HorizontalPoint] = []
        for index in verts.indices {
            let vertex = verts[index]
            let next = verts[(index + 1) % verts.count]
            junctionPoints.append(vertex.position)
            if vertex.type == .arc {
                arcs.append(
                    HorizontalArc(
                        id: makeID(),
                        from: vertex.position,
                        to: next.position,
                        center: vertex.arcCenter,
                        width: 0,
                        layer: polygon.layer,
                        reverse: vertex.arcReverse
                    )
                )
                junctionPoints.append(vertex.arcCenter)
            } else {
                lines.append(
                    HorizontalSegment(
                        id: makeID(),
                        from: vertex.position,
                        to: next.position,
                        width: 0,
                        layer: polygon.layer
                    )
                )
            }
        }
        return LineLoopResult(lines: lines, arcs: arcs, junctionPoints: junctionPoints)
    }

    // MARK: - Line loop → Polygon

    struct PolygonResult {
        var polygon: HorizontalPolygon
        var consumedLineIDs: Set<String>
        var consumedArcIDs: Set<String>
        /// Position keys of the loop's junction nodes (so the caller can drop the
        /// now-orphaned junctions).
        var consumedJunctionKeys: Set<String>
    }

    private struct Connector {
        var id: String
        var isArc: Bool
        var fromKey: String
        var toKey: String
        var center: HorizontalPoint
        var reverse: Bool
        var layer: Int?
    }

    /// Collapses the loop reachable from `startKey` (a junction/line/arc endpoint
    /// position key) into a polygon (`tool_line_loop_to_polygon`).
    /// Mirrors Horizon: deletes every connector incident to a loop node and every
    /// loop junction. Returns nil when no cycle is found.
    static func polygon(
        startKey: String,
        lines: [HorizontalSegment],
        arcs: [HorizontalArc],
        makeID: () -> String
    ) -> PolygonResult? {
        var connectors: [Connector] = []
        var pointForKey: [String: HorizontalPoint] = [:]
        for line in lines {
            let fromKey = pointKey(line.from)
            let toKey = pointKey(line.to)
            pointForKey[fromKey] = line.from
            pointForKey[toKey] = line.to
            connectors.append(Connector(id: line.id, isArc: false, fromKey: fromKey, toKey: toKey, center: .zero, reverse: false, layer: line.layer))
        }
        for arc in arcs {
            let fromKey = pointKey(arc.from)
            let toKey = pointKey(arc.to)
            pointForKey[fromKey] = arc.from
            pointForKey[toKey] = arc.to
            connectors.append(Connector(id: arc.id, isArc: true, fromKey: fromKey, toKey: toKey, center: arc.center, reverse: arc.reverse, layer: arc.layer))
        }

        var graph: [String: [Int]] = [:]
        for (index, connector) in connectors.enumerated() {
            graph[connector.fromKey, default: []].append(index)
            if connector.toKey != connector.fromKey {
                graph[connector.toKey, default: []].append(index)
            }
        }

        guard let path = findLoop(from: startKey, graph: graph, connectors: connectors),
              path.count >= 3 else {
            return nil
        }

        var vertices: [HorizontalPolygonVertex] = []
        var consumedLineIDs = Set<String>()
        var consumedArcIDs = Set<String>()
        var consumedJunctionKeys = Set<String>()
        var consumedConnectorIndices = Set<Int>()

        for step in path {
            let nodeKey = step.node
            let connector = connectors[step.connector]
            let position = pointForKey[nodeKey] ?? .zero
            consumedJunctionKeys.insert(nodeKey)
            if connector.isArc {
                // Shape-preserving reverse: arc.reverse XOR (node is the arc's `to`).
                let reverse = connector.reverse != (nodeKey == connector.toKey)
                vertices.append(HorizontalPolygonVertex(type: .arc, position: position, arcCenter: connector.center, arcReverse: reverse))
            } else {
                vertices.append(HorizontalPolygonVertex(type: .line, position: position))
            }
            // Horizon deletes every connector incident to a loop node (tails too).
            for incident in graph[nodeKey] ?? [] {
                consumedConnectorIndices.insert(incident)
            }
        }
        for index in consumedConnectorIndices {
            let connector = connectors[index]
            if connector.isArc {
                consumedArcIDs.insert(connector.id)
            } else {
                consumedLineIDs.insert(connector.id)
            }
        }

        let layer = connectors[path[0].connector].layer
        let polygon = HorizontalPolygon(id: makeID(), polygonVertices: vertices, layer: layer)
        return PolygonResult(
            polygon: polygon,
            consumedLineIDs: consumedLineIDs,
            consumedArcIDs: consumedArcIDs,
            consumedJunctionKeys: consumedJunctionKeys
        )
    }

    private struct PathStep {
        var node: String
        var connector: Int
    }

    /// Finds a closed loop among the connectors, returned as an ordered list of
    /// (junction, connector leaving that junction).
    ///
    /// Specification, independent of any particular implementation:
    ///  • Walk from `start` along connectors incident to the current junction.
    ///  • Never immediately retrace the connector just arrived on; a connector
    ///    joining a junction to itself is not traversable.
    ///  • Reaching a junction already on the current walk closes a loop: the
    ///    result is the walk from that junction onward, plus the connector that
    ///    returned to it.
    ///  • If the walk exhausts every branch without closing, there is no loop.
    ///
    /// Depth-first with an explicit stack so the walk is undone on backtrack;
    /// termination follows from the path growing over a finite junction set.
    private static func findLoop(
        from start: String,
        graph: [String: [Int]],
        connectors: [Connector]
    ) -> [PathStep]? {
        struct Frame {
            let node: String
            let arrivedVia: Int?
            var remaining: ArraySlice<Int>
        }

        guard let incident = graph[start] else {
            return nil
        }

        var path = [PathStep]()
        var stack = [Frame(node: start, arrivedVia: nil, remaining: incident[...])]

        while let popped = stack.popLast() {
            var frame = popped
            guard let index = frame.remaining.popFirst() else {
                // Branch exhausted — undo the step that descended into it.
                if !path.isEmpty {
                    path.removeLast()
                }
                continue
            }
            stack.append(frame)

            // Don't turn straight back along the connector we arrived on.
            if index == frame.arrivedVia {
                continue
            }

            let connector = connectors[index]
            let node = frame.node
            let next: String
            if connector.fromKey == node {
                next = connector.toKey
            } else if connector.toKey == node {
                next = connector.fromKey
            } else {
                continue // not incident to this junction
            }

            if let closes = path.firstIndex(where: { $0.node == next }) {
                return Array(path[closes...]) + [PathStep(node: node, connector: index)]
            }

            guard let onward = graph[next] else {
                continue // dead end: nothing leaves the far junction
            }
            path.append(PathStep(node: node, connector: index))
            stack.append(Frame(node: next, arrivedVia: index, remaining: onward[...]))
        }
        return nil
    }
}
