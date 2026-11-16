import Foundation

/// Board objects mirrored across the vertical line through a point, as the
/// canvas's Mirror takes them and a package takes what it draws: an arc runs
/// the other way, a hole and a text face the other way. `innerLayers`, when
/// given, also puts the object on the other side's layer, on a board with
/// that many inner copper layers (`flippedPackageLayer`); left out, the
/// object stays on its layer.
enum BoardMirror {
    static func mirrored(
        _ segment: HorizontalSegment,
        around center: HorizontalPoint,
        flippingLayers innerLayers: Int? = nil
    ) -> HorizontalSegment {
        var segment = segment
        segment.from = HorizontalCanvasModeSupport.mirrored(segment.from, around: center)
        segment.to = HorizontalCanvasModeSupport.mirrored(segment.to, around: center)
        segment.center = segment.center.map { HorizontalCanvasModeSupport.mirrored($0, around: center) }
        segment.reverse.toggle()
        segment.layer = otherSide(segment.layer, innerLayers)
        return segment
    }

    static func mirrored(_ arc: HorizontalArc, around center: HorizontalPoint, flippingLayers innerLayers: Int? = nil) -> HorizontalArc {
        var arc = arc
        arc.from = HorizontalCanvasModeSupport.mirrored(arc.from, around: center)
        arc.to = HorizontalCanvasModeSupport.mirrored(arc.to, around: center)
        arc.center = HorizontalCanvasModeSupport.mirrored(arc.center, around: center)
        arc.reverse.toggle()
        arc.layer = otherSide(arc.layer, innerLayers)
        return arc
    }

    static func mirrored(
        _ polygon: HorizontalPolygon,
        around center: HorizontalPoint,
        flippingLayers innerLayers: Int? = nil
    ) -> HorizontalPolygon {
        var polygon = polygon.transformed({ HorizontalCanvasModeSupport.mirrored($0, around: center) }, flipsArcReverse: true)
        polygon.layer = otherSide(polygon.layer, innerLayers)
        return polygon
    }

    static func mirrored(_ hole: HorizontalHole, around center: HorizontalPoint) -> HorizontalHole {
        var hole = hole
        hole.position = HorizontalCanvasModeSupport.mirrored(hole.position, around: center)
        hole.angle = HorizontalCanvasModeSupport.wrappedAngle(32_768 - hole.angle)
        return hole
    }

    static func mirrored(_ text: HorizontalText, around center: HorizontalPoint, flippingLayers innerLayers: Int? = nil) -> HorizontalText {
        var text = text
        text.position = HorizontalCanvasModeSupport.mirrored(text.position, around: center)
        setMirrored(!text.mirrored, for: &text)
        text.layer = otherSide(text.layer, innerLayers)
        return text
    }

    static func mirrored(
        _ keepout: HorizontalKeepout,
        around center: HorizontalPoint,
        flippingLayers innerLayers: Int? = nil
    ) -> HorizontalKeepout {
        var keepout = keepout
        keepout.polygon = mirrored(keepout.polygon, around: center, flippingLayers: innerLayers)
        return keepout
    }

    /// The angle a text is drawn at: a mirrored one's is stored the other
    /// way round.
    static func displayAngle(for text: HorizontalText) -> Int {
        storedAngle(fromDisplayAngle: text.angle, mirrored: text.mirrored)
    }

    static func storedAngle(fromDisplayAngle angle: Int, mirrored: Bool) -> Int {
        mirrored ? HorizontalCanvasModeSupport.wrappedAngle(32_768 - angle) : HorizontalCanvasModeSupport.wrappedAngle(angle)
    }

    /// Mirrors `text` or not, keeping the angle it is drawn at.
    static func setMirrored(_ mirrored: Bool, for text: inout HorizontalText) {
        guard text.mirrored != mirrored else {
            return
        }
        let drawn = displayAngle(for: text)
        text.mirrored = mirrored
        text.angle = storedAngle(fromDisplayAngle: drawn, mirrored: mirrored)
    }

    private static func otherSide(_ layer: Int?, _ innerLayers: Int?) -> Int? {
        guard let layer, let innerLayers else {
            return layer
        }
        return HorizontalBoardLayers.flippedPackageLayer(layer, nInnerLayers: innerLayers)
    }
}
