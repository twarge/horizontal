import Foundation

/// A rigid motion of board objects, a shift, a turn and maybe a mirror, as a
/// `HorizontalPlacementTransform` gives one (mirror, then rotate, then shift),
/// applied as the board's geometry takes it: a mirror reverses arcs and puts
/// what it moves on the other side's layers, as flipping a package does.
/// Positions are exact at the cardinal angles, as `applying(to:)` gives them;
/// a caller writing a position to a file rounds it.
struct HorizontalBoardMotion {
    var transform: HorizontalPlacementTransform
    /// The board's inner copper layers, which a flip takes in reverse order.
    var innerLayerCount: Int

    init(_ transform: HorizontalPlacementTransform, innerLayerCount: Int) {
        self.transform = transform
        self.innerLayerCount = innerLayerCount
    }

    var mirrors: Bool {
        transform.mirrored
    }

    func point(_ point: HorizontalPoint) -> HorizontalPoint {
        transform.applying(to: point)
    }

    /// A layer on the side the motion leaves it: the other side's where it
    /// mirrors (Horizon's `flip_package_layer`), the outline staying put.
    func layer(_ layer: Int) -> Int {
        mirrors ? HorizontalBoardLayers.flippedPackageLayer(layer, nInnerLayers: innerLayerCount) : layer
    }

    func segment(_ segment: HorizontalSegment) -> HorizontalSegment {
        var segment = segment
        segment.from = point(segment.from)
        segment.to = point(segment.to)
        segment.center = segment.center.map(point)
        if mirrors {
            segment.reverse.toggle()
        }
        segment.layer = segment.layer.map(layer)
        return segment
    }

    func arc(_ arc: HorizontalArc) -> HorizontalArc {
        var arc = arc
        arc.from = point(arc.from)
        arc.to = point(arc.to)
        arc.center = point(arc.center)
        if mirrors {
            arc.reverse.toggle()
        }
        arc.layer = arc.layer.map(layer)
        return arc
    }

    /// A polygon and, on a pad, its label frame, which the loader composes
    /// with the placement as it does here (and the pour reads for spokes).
    func polygon(_ polygon: HorizontalPolygon) -> HorizontalPolygon {
        var result = polygon.transformed(point, flipsArcReverse: mirrors)
        result.padLabelFrame = polygon.padLabelFrame.map { frame in
            let composed = transform.accumulated(with: HorizontalPlacementTransform(
                shift: frame.center,
                angle: frame.angle,
                mirrored: frame.mirrored
            ))
            var moved = frame
            moved.center = composed.shift
            moved.angle = composed.angle
            moved.mirrored = composed.mirrored
            return moved
        }
        result.layer = polygon.layer.map(layer)
        // A pad's shape is named for the layer it is on, as the loader names
        // it (`…/layer/-100`), so a flipped pad is the one a reload draws.
        if let old = polygon.layer, let new = result.layer, old != new, polygon.id.hasSuffix("/layer/\(old)") {
            result.id = String(polygon.id.dropLast("\(old)".count)) + "\(new)"
        }
        return result
    }

    func hole(_ hole: HorizontalHole) -> HorizontalHole {
        var hole = hole
        hole.position = point(hole.position)
        hole.angle = transform.accumulated(with: HorizontalPlacementTransform(
            shift: .zero,
            angle: hole.angle,
            mirrored: false
        )).angle
        return hole
    }

    func keepout(_ keepout: HorizontalKeepout) -> HorizontalKeepout {
        var keepout = keepout
        keepout.polygon = polygon(keepout.polygon)
        return keepout
    }

    /// A board text, drawn as it was and carried by the motion, as the canvas
    /// mirrors and turns a text: a mirror keeps the angle it is drawn at and
    /// flips the side it reads from, a turn adds to it the way the text
    /// faces.
    func text(_ text: HorizontalText) -> HorizontalText {
        var text = text
        if mirrors {
            let drawnAngle = Self.drawnAngle(of: text)
            text.position = HorizontalPoint(x: -text.position.x, y: text.position.y)
            text.mirrored.toggle()
            text.angle = Self.storedAngle(drawing: drawnAngle, mirrored: text.mirrored)
            text.layer = text.layer.map(layer)
        }
        let turn = transform.angle
        let turned = HorizontalPlacementTransform(shift: transform.shift, angle: turn, mirrored: false)
        text.position = turned.applying(to: text.position)
        text.angle = Self.wrapped(text.angle + (text.mirrored ? -turn : turn))
        return text
    }

    /// A text a package draws from its pool package, at `old`, drawn where the
    /// loader draws it with the package at `new`: what the pool gives it is
    /// taken back out of the old frame and put into the new.
    static func packageText(
        _ text: HorizontalText,
        from old: HorizontalPlacementTransform,
        to new: HorizontalPlacementTransform,
        innerLayerCount: Int
    ) -> HorizontalText {
        let drawn = HorizontalPlacementTransform(shift: text.position, angle: text.angle, mirrored: text.mirrored)
        let local = old.unaccumulatedText(drawn)
        let placed = new.accumulatedText(with: local)
        var text = text
        text.position = placed.shift
        text.angle = placed.angle
        text.mirrored = placed.mirrored
        if old.mirrored != new.mirrored, let layer = text.layer {
            text.layer = HorizontalBoardLayers.flippedPackageLayer(layer, nInnerLayers: innerLayerCount)
        }
        return text
    }

    private static func drawnAngle(of text: HorizontalText) -> Int {
        text.mirrored ? wrapped(32_768 - text.angle) : wrapped(text.angle)
    }

    private static func storedAngle(drawing angle: Int, mirrored: Bool) -> Int {
        mirrored ? wrapped(32_768 - angle) : wrapped(angle)
    }

    private static func wrapped(_ angle: Int) -> Int {
        let wrapped = angle % 65_536
        return wrapped < 0 ? wrapped + 65_536 : wrapped
    }
}

/// Where one pad's centre was and is, when a package moves.
struct HorizontalPadMove: Hashable {
    var from: HorizontalPoint
    var to: HorizontalPoint
}

extension HorizontalBoard {
    /// The placement a package is drawn with.
    static func placementTransform(of package: HorizontalPlacement) -> HorizontalPlacementTransform {
        HorizontalPlacementTransform(shift: package.position, angle: package.angle, mirrored: package.mirrored)
    }

    /// Packages put at new placements, each as one rigid motion from where it
    /// is (the new placement after the old one undone): what each draws, its
    /// pads with their label frames, holes, polygons, lines, arcs, texts and
    /// keepouts, and its pad centres go where the new placement puts them, on
    /// the other side's layers where it changes side. The copper on its pads
    /// stays where it is, for the caller to follow. Keyed by package id, any
    /// case; one pass over the board for them all. Returns each pad centre
    /// that moved, by pad path (`<package>/<pad>`, lowercased).
    @discardableResult
    mutating func replacePackages(_ placements: [String: HorizontalPlacementTransform]) -> [String: HorizontalPadMove] {
        let wanted = placements.reduce(into: [String: HorizontalPlacementTransform]()) {
            $0[$1.key.lowercased()] = $1.value
        }
        guard !wanted.isEmpty else {
            return [:]
        }
        let innerLayers = max(copperLayerCount - 2, 0)
        var motions = [String: HorizontalBoardMotion]()
        var frames = [String: (old: HorizontalPlacementTransform, new: HorizontalPlacementTransform)]()
        for index in packages.indices {
            let id = packages[index].id.lowercased()
            guard let placement = wanted[id] else {
                continue
            }
            let old = Self.placementTransform(of: packages[index])
            packages[index].position = placement.shift
            packages[index].angle = placement.angle
            packages[index].mirrored = placement.mirrored
            let motion = placement.accumulated(with: old.inverse)
            guard !motion.isIdentity else {
                continue
            }
            motions[id] = HorizontalBoardMotion(motion, innerLayerCount: innerLayers)
            frames[id] = (old, placement)
        }
        guard !motions.isEmpty else {
            return [:]
        }

        func motion(for geometryID: String) -> HorizontalBoardMotion? {
            BoardMovePlanner.packageID(forGeometryID: geometryID).flatMap { motions[$0] }
        }
        for index in packagePads.indices {
            if let motion = motion(for: packagePads[index].id) {
                packagePads[index] = motion.polygon(packagePads[index])
            }
        }
        for index in packageHoles.indices {
            if let motion = motion(for: packageHoles[index].id) {
                packageHoles[index] = motion.hole(packageHoles[index])
            }
        }
        for index in packagePolygons.indices {
            if let motion = motion(for: packagePolygons[index].id) {
                packagePolygons[index] = motion.polygon(packagePolygons[index])
            }
        }
        for index in packageLines.indices {
            if let motion = motion(for: packageLines[index].id) {
                packageLines[index] = motion.segment(packageLines[index])
            }
        }
        for index in packageArcs.indices {
            if let motion = motion(for: packageArcs[index].id) {
                packageArcs[index] = motion.arc(packageArcs[index])
            }
        }
        for index in packageTexts.indices {
            guard let id = BoardMovePlanner.packageID(forGeometryID: packageTexts[index].id),
                  let motion = motions[id], let frame = frames[id] else {
                continue
            }
            packageTexts[index] = packageTexts[index].fromSmash
                ? motion.text(packageTexts[index])
                : HorizontalBoardMotion.packageText(packageTexts[index], from: frame.old, to: frame.new, innerLayerCount: innerLayers)
        }
        for index in keepouts.indices {
            if let motion = motion(for: keepouts[index].id) {
                keepouts[index] = motion.keepout(keepouts[index])
            }
        }

        // Pad centres are keyed `<package>/<pad>`.
        var moved = [String: HorizontalPadMove]()
        for (path, position) in packagePadPositions {
            guard let slash = path.firstIndex(of: "/"),
                  let motion = motions[path[..<slash].lowercased()] else {
                continue
            }
            let to = motion.point(position)
            packagePadPositions[path] = to
            moved[path.lowercased()] = HorizontalPadMove(from: position, to: to)
        }
        return moved
    }
}
