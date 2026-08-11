import Foundation

/// The oriented rectangle a pad label is laid out within.
struct PadLabelFrame {
    var center: HorizontalPoint
    var axis: HorizontalPoint
    var normal: HorizontalPoint
    var width: Double
    var height: Double
    var angle: Int
}

enum PadLabelMode {
    case full
    case upper
    case lower
}

/// Pure pad-label geometry + text fitting, extracted from `BoardCanvasView`.
/// No View/theme/selection state, so it's unit-testable.
///
/// The intrinsic-descriptor path (`frame(fromDescriptor:)`) is strongly
/// preferred: the polygon-edge scoring heuristic (`frame(forVertices:…)`) picks
/// essentially arbitrary angles for roundrect pads (dozens of corner chords each
/// clear the minimum-edge filter) and for circles (every chord is the same
/// length at a different angle), which is the "labels at odd angles" bug. The
/// descriptor carries the pad's true rotation/aspect, matching the reference implementation's
/// `canvas_gl.cpp::draw_bitmap_text_box`.
enum BoardPadLabelLayout {
    /// Vertical offset of the UPPER/LOWER text rows, as a fraction of the box
    /// height. Horizon: `text_pos.y = ±height / 4` (canvas_gl.cpp:945).
    static let rowOffsetFraction = 0.25

    /// Margin Horizon leaves around the fitted text: `sc = min(scale_x, scale_y) * .75`
    /// (canvas_gl.cpp:938).
    static let fitMargin = 0.75

    /// Build a frame from the intrinsic padstack descriptor — correct angle for
    /// any pad shape, including roundrect and circular.
    ///
    /// Specification, as requirements on the result rather than as steps:
    ///  • A label reads along the box's LONGER side.
    ///  • A near-square box has no meaningful long side, so its orientation is
    ///    settled to the shallowest equivalent — otherwise a square pad placed
    ///    at 80° would carry a steeply tilted label for no reason.
    ///  • Text is never drawn upside down.
    ///  • A mirrored pad is described in un-mirrored terms first, by inverting
    ///    its angle.
    ///
    /// Angles are the format's integer units (65536 == 360°). The
    /// upside-down rule is folded into the returned `axis`/`normal`: turning
    /// the frame a half turn negates `normal`, so callers keep placing the
    /// UPPER row at `center + normal * height/4` and still get the pad name on
    /// the visually-upper half of a flipped pad.
    ///
    /// Geometry is pinned by `PadLabelFrameGoldenData` over 128 angles × 5 box
    /// shapes.
    static func frame(fromDescriptor descriptor: PadLabelFrameDescriptor) -> PadLabelFrame? {
        guard descriptor.halfWidth > 0, descriptor.halfHeight > 0 else {
            return nil
        }

        var box = LabelBox(
            width: descriptor.halfWidth * 2,
            height: descriptor.halfHeight * 2,
            angle: HorizontalCanvasModeSupport.wrappedAngle(
                descriptor.mirrored ? -descriptor.angle : descriptor.angle
            )
        )
        box.layTextAlongLongSide()
        box.settleNearSquareOrientation()

        let angle = readableAngle(box.angle)
        let radians = Double(angle) / 65_536.0 * 2 * .pi
        let axis = HorizontalPoint(x: cos(radians), y: sin(radians))
        return PadLabelFrame(
            center: descriptor.center,
            axis: axis,
            normal: HorizontalPoint(x: -axis.y, y: axis.x),
            width: box.width,
            height: box.height,
            angle: angle
        )
    }

    /// The label's box mid-normalisation: a size, plus the orientation it is
    /// currently described in. A quarter turn that also swaps the sides leaves
    /// the box itself unchanged, which is what lets both rules below re-describe
    /// it freely.
    private struct LabelBox {
        var width: Double
        var height: Double
        var angle: Int

        private mutating func turnQuarter() {
            swap(&width, &height)
            angle = HorizontalCanvasModeSupport.wrappedAngle(angle + quarterTurnAngle)
        }

        /// A label reads along the longer side, so a taller-than-wide box is
        /// re-described as its own quarter turn.
        mutating func layTextAlongLongSide() {
            guard height > width else { return }
            turnQuarter()
        }

        /// With no meaningful long side, any of the four quarter turns would do,
        /// so settle on the shallowest. Bounded at four turns because that is a
        /// full revolution — a guard against a non-terminating loop, not a case
        /// that should arise.
        mutating func settleNearSquareOrientation() {
            guard width > 0, height / width > nearSquareRatio else { return }
            var turns = 0
            while angle >= quarterTurnAngle, turns < 4 {
                turnQuarter()
                turns += 1
            }
        }
    }

    /// Text oriented between a quarter and three-quarter turn reads upside down;
    /// draw it a half turn around instead.
    private static func readableAngle(_ angle: Int) -> Int {
        guard angle > quarterTurnAngle, angle <= 3 * quarterTurnAngle else {
            return angle
        }
        return HorizontalCanvasModeSupport.wrappedAngle(angle + halfTurnAngle)
    }

    /// Largest text size (in pad units) that fits `text` within `frame` for the
    /// given layout mode.
    static func fittedTextSize(_ text: String, frame: PadLabelFrame, mode: PadLabelMode) -> Double {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, frame.width > 0, frame.height > 0 else {
            return 0
        }

        let nominalSize = 1_000_000.0
        let metrics = HorizontalOutlineTextRenderer.textSize(text, font: .simplex, size: nominalSize)
        guard metrics.width > 0, metrics.height > 0 else {
            return 0
        }

        let widthScale = metrics.width / frame.width
        var heightScale = metrics.height / frame.height
        if mode != .full {
            heightScale *= 2
        }

        // Horizon scales the fitted text by `.75` (canvas_gl.cpp:938), i.e. it
        // divides the exactly-fitting size by 1/0.75.
        let scaleFactor = max(widthScale, heightScale) / fitMargin
        guard scaleFactor.isFinite, scaleFactor > 0 else {
            return 0
        }
        return nominalSize / scaleFactor
    }

    /// Fallback frame derived from the rendered pad polygon by scoring candidate
    /// axes (the pad's edges). Used only when no intrinsic descriptor is present.
    static func frame(forVertices vertices: [HorizontalPoint], padText: String? = nil, netText: String? = nil) -> PadLabelFrame? {
        guard vertices.count >= 2 else {
            return nil
        }

        let axisAlignedBounds = HorizontalRect(points: vertices)
        guard !axisAlignedBounds.isEmpty else {
            return nil
        }

        let maxExtent = max(axisAlignedBounds.width, axisAlignedBounds.height)
        let minExtent = min(axisAlignedBounds.width, axisAlignedBounds.height)
        let aspect = maxExtent > 0 ? minExtent / maxExtent : 0
        if vertices.count > 8,
           aspect > 0.86,
           var horizontalFrame = frame(forVertices: vertices, axis: HorizontalPoint(x: 1, y: 0)) {
            normalize(&horizontalFrame)
            return horizontalFrame
        }

        let minimumEdgeLength = max(maxExtent * 0.02, 1)
        var candidates = [HorizontalPoint(x: 1, y: 0)]
        var candidateKeys: Set<String> = ["1000:0"]

        func addCandidate(_ candidate: HorizontalPoint) {
            let axis = canonicalAxis(candidate)
            let key = "\(Int((axis.x * 1000).rounded())):\(Int((axis.y * 1000).rounded()))"
            guard candidateKeys.insert(key).inserted else {
                return
            }
            candidates.append(axis)
        }

        for index in vertices.indices {
            let nextIndex = index == vertices.index(before: vertices.endIndex)
                ? vertices.startIndex
                : vertices.index(after: index)
            let edge = vertices[nextIndex] - vertices[index]
            guard edge.length >= minimumEdgeLength else {
                continue
            }
            addCandidate(edge.normalized)
        }

        let isTextAware = padText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        var bestFrame: PadLabelFrame?
        var bestScore = -Double.infinity
        var bestArea = Double.infinity
        for candidate in candidates {
            guard var frame = frame(forVertices: vertices, axis: candidate) else {
                continue
            }
            normalize(&frame)
            let area = frame.width * frame.height
            let score = isTextAware
                ? frameScore(frame, padText: padText ?? "", netText: netText)
                : -area
            let isBetter = isTextAware
                ? score > bestScore * 1.000001
                : area < bestArea * 0.999999
            if isBetter {
                bestScore = score
                bestArea = area
                bestFrame = frame
            }
        }

        if !isTextAware, var horizontalFrame = frame(forVertices: vertices, axis: HorizontalPoint(x: 1, y: 0)) {
            normalize(&horizontalFrame)
            let horizontalArea = horizontalFrame.width * horizontalFrame.height
            let horizontalAspect = min(horizontalFrame.width, horizontalFrame.height) / max(horizontalFrame.width, horizontalFrame.height)
            if horizontalArea.isFinite,
               horizontalAspect > 0.86,
               bestArea >= horizontalArea * 0.94 {
                bestFrame = horizontalFrame
            }
        }

        return bestFrame
    }

    // MARK: - Private

    /// Above this height/width ratio a box has no meaningful long side.
    private static let nearSquareRatio = 0.9
    private static let quarterTurnAngle = 16_384
    private static let halfTurnAngle = 32_768

    private static func frameScore(_ frame: PadLabelFrame, padText: String, netText: String?) -> Double {
        if let netText {
            return min(
                fittedTextSize(padText, frame: frame, mode: .upper),
                fittedTextSize(netText, frame: frame, mode: .lower)
            )
        }
        return fittedTextSize(padText, frame: frame, mode: .full)
    }

    /// Same two normalisation steps as `frame(fromDescriptor:)`, for the
    /// vertices fallback. `canonicalAxis` forces the axis into the right
    /// half-plane, which is *exactly* readability flip: negating the
    /// axis rotates the frame 180° and negates `normal` (==
    /// `text_pos *= -1` in the reference), so no separate flip step is needed here.
    private static func normalize(_ frame: inout PadLabelFrame) {
        if frame.height > frame.width {
            swap(&frame.width, &frame.height)
            frame.axis = canonicalAxis(frame.normal)
            frame.normal = HorizontalPoint(x: -frame.axis.y, y: frame.axis.x)
            frame.angle = angle(from: .zero, to: frame.axis)
        }

        if frame.width > 0, frame.height / frame.width > 0.9 {
            var rotations = 0
            while HorizontalCanvasModeSupport.wrappedAngle(frame.angle) >= 16_384 && rotations < 4 {
                swap(&frame.width, &frame.height)
                frame.axis = HorizontalPoint(x: -frame.axis.y, y: frame.axis.x)
                frame.normal = HorizontalPoint(x: -frame.axis.y, y: frame.axis.x)
                frame.angle = HorizontalCanvasModeSupport.wrappedAngle(frame.angle + 16_384)
                rotations += 1
            }
        }
    }

    private static func frame(forVertices vertices: [HorizontalPoint], axis: HorizontalPoint) -> PadLabelFrame? {
        let axis = canonicalAxis(axis)
        let normal = HorizontalPoint(x: -axis.y, y: axis.x)
        guard axis.length > 0, normal.length > 0 else {
            return nil
        }

        var minU = Double.infinity
        var maxU = -Double.infinity
        var minV = Double.infinity
        var maxV = -Double.infinity
        for vertex in vertices {
            let u = padDot(vertex, axis)
            let v = padDot(vertex, normal)
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
        }

        guard minU.isFinite, maxU.isFinite, minV.isFinite, maxV.isFinite else {
            return nil
        }

        return PadLabelFrame(
            center: axis * ((minU + maxU) / 2) + normal * ((minV + maxV) / 2),
            axis: axis,
            normal: normal,
            width: maxU - minU,
            height: maxV - minV,
            angle: angle(from: .zero, to: axis)
        )
    }

    private static func canonicalAxis(_ axis: HorizontalPoint) -> HorizontalPoint {
        var axis = axis.normalized
        if axis.x < 0 || (abs(axis.x) < 0.000001 && axis.y < 0) {
            axis = axis * -1
        }
        return axis
    }

    private static func padDot(_ lhs: HorizontalPoint, _ rhs: HorizontalPoint) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y
    }

    private static func angle(from: HorizontalPoint, to: HorizontalPoint) -> Int {
        let radians = atan2(to.y - from.y, to.x - from.x)
        return Int((radians / (2 * .pi) * 65_536).rounded())
    }
}
