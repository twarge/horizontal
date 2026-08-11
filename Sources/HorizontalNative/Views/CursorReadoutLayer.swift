import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Carries the cursor's screen location from the (rarely-rendered) parent
/// InteractiveCanvasView body to the (frequently-rendered) cursor layer WITHOUT
/// re-rendering the parent. The parent holds this as `@State` (a reference it does
/// not observe), so writing `location` does not invalidate the ~500-line parent
/// body; only `CursorReadoutLayer`, which `@ObservedObject`s it, re-renders.
@MainActor
final class HorizontalCursorInput: ObservableObject {
    private var storedLocation: CGPoint?
    private var suppressedUntil = Date.distantPast

    /// Publishes only on an actual change, so repeated same-position pointer events
    /// (a stationary cursor that keeps firing) don't re-render the layer for nothing.
    /// Cursor *updates* are also dropped briefly after a pan/zoom (see
    /// `suppressForViewportGesture`); clearing (nil) always goes through.
    var location: CGPoint? {
        get { storedLocation }
        set {
            if newValue != nil, Date() < suppressedUntil { return }
            guard newValue != storedLocation else { return }
            objectWillChange.send()
            storedLocation = newValue
        }
    }

    /// Hide the cursor and ignore re-reports for a short window. Called on every
    /// pan/zoom event: the window keeps refreshing for the gesture's duration, so
    /// the snap crosshair stays hidden (matching the iOS pan/pinch suppression) and
    /// any just-computed snap result is disregarded — the crosshair simply clears.
    /// On macOS the cursor sampler + mouseMoved race to re-report the pointer
    /// mid-gesture; this time-boxed gate beats that race without a begin/end signal.
    func suppressForViewportGesture() {
        suppressedUntil = Date().addingTimeInterval(0.12)
        location = nil
    }
}

/// The snap-dependent cursor crosshair + coordinate readout, lifted out of
/// InteractiveCanvasView's body so a pointer move only re-renders this tiny view
/// (and redraws its own dedicated Metal overlay), never the big canvas body. It
/// shares the parent's transform inputs + viewport driver so it stays locked to
/// the board during pan/zoom. The snap math is identical to the parent's (its own
/// O(1) `HorizontalSnapIndexCache` over the stable snap targets).
struct CursorReadoutLayer: View {
    @ObservedObject var cursorInput: HorizontalCursorInput

    var bounds: HorizontalRect
    var effectiveViewport: CanvasViewport
    var effectiveZoom: CGFloat
    var effectivePan: CGSize
    var fitInsets: HorizontalCanvasInsets
    var minimumLineWidth: CGFloat
    var snapTargets: [HorizontalPoint]
    var grid: HorizontalGridSettings?
    var gridDivisor: Int
    var cursorSize: HorizontalCursorSize
    var drawsCursorInMetal: Bool
    var backgroundColor: Color
    var foregroundColor: Color
    var overlayBackgroundColor: Color
    var showsCoordinateReadout: Bool
    var showsHoverPopover: Bool
    var hoverStatusText: String?
    var viewportDriver: HorizontalCanvasViewportDriver?
    var usesViewportDriver: Bool

    @State private var snapIndexCache = HorizontalSnapIndexCache()

    private static let coordinateReadoutTrailingMargin: CGFloat = 16
    private static let coordinateReadoutBottomMargin: CGFloat = 14
    private static let coordinateReadoutHorizontalPadding: CGFloat = 9
    private static let coordinateReadoutHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            content(size: proxy.size)
        }
        .allowsHitTesting(false)
    }

    private func cursorScreenBatches(
        size: CGSize,
        transform: HorizontalCanvasTransform
    ) -> (lines: [HorizontalMetalScreenLinePrimitive], triangles: [HorizontalMetalScreenTrianglePrimitive]) {
        guard let cursorLocation = cursorInput.location else {
            return ([], [])
        }
        let box = metalCoordinateReadoutBatch(cursorLocation: cursorLocation, size: size, transform: transform)
        let crosshair = drawsCursorInMetal
            ? metalInteractiveScreenLines(cursorLocation: cursorLocation, size: size, transform: transform)
            : []
        return (crosshair + box.screenLines, box.screenTriangles)
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let cursorLocation = cursorInput.location
        let transform = HorizontalCanvasTransform(
            bounds: bounds,
            size: size,
            fitInsets: fitInsets,
            zoom: effectiveZoom,
            pan: effectivePan,
            minimumLineWidth: minimumLineWidth
        )
        // Batches are empty when there's no cursor; the backdrop stays mounted
        // regardless (below) so its Metal Renderer + pipeline states persist.
        let batches = cursorScreenBatches(size: size, transform: transform)
        let screenLines = batches.lines
        let screenTriangles = batches.triangles

        ZStack {
            #if canImport(MetalKit)
            // Always mounted (when supported): a long-lived Renderer that draws
            // nothing (empty batches, stable keys) while idle — versus remounting
            // per hover-start, which would rebuild ~11 pipeline states each time.
            if HorizontalMetalBackdropView.isSupported {
                HorizontalMetalBackdropView(
                    bounds: bounds,
                    viewport: effectiveViewport,
                    viewportDriver: usesViewportDriver ? viewportDriver : nil,
                    fitInsets: fitInsets,
                    grid: nil,
                    backgroundColor: .clear,
                    gridColor: .clear,
                    minimumLineWidth: minimumLineWidth,
                    screenTriangles: screenTriangles,
                    screenTriangleKey: screenTriangles.hashValue,
                    screenLines: screenLines,
                    screenLineKey: screenLines.hashValue,
                    loadProfileLabel: "Metal cursor",
                    marksLoadProfileFirstDraw: false
                )
                .allowsHitTesting(false)
            }
            #endif

            if let cursorLocation {
                if drawsCursorInSwiftUI {
                    Canvas { context, canvasSize in
                        var context = context
                        let cursorTransform = HorizontalCanvasTransform(
                            bounds: bounds,
                            size: canvasSize,
                            fitInsets: fitInsets,
                            zoom: effectiveZoom,
                            pan: effectivePan,
                            minimumLineWidth: minimumLineWidth
                        )
                        drawCursor(
                            context: &context,
                            size: canvasSize,
                            transform: cursorTransform,
                            cursorLocation: cursorLocation
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                #if canImport(MetalKit)
                // Drawn last so the readout label sits crisp OVER its translucent
                // box (the pre-refactor order layered the box on top, dimming it).
                if HorizontalMetalBackdropView.isSupported,
                   let coordinateLabel = coordinateReadoutTextOverlay(cursorLocation: cursorLocation, size: size, transform: transform) {
                    Text(coordinateLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, Self.coordinateReadoutTrailingMargin + Self.coordinateReadoutHorizontalPadding)
                        .padding(.bottom, Self.coordinateReadoutBottomMargin)
                        .allowsHitTesting(false)
                }
                #endif
            }
        }
    }

    private var drawsCursorInSwiftUI: Bool {
        #if canImport(MetalKit)
        !drawsCursorInMetal || !HorizontalMetalBackdropView.isSupported
        #else
        true
        #endif
    }

    // MARK: - Cursor crosshair (Metal + SwiftUI fallback), moved verbatim from
    // InteractiveCanvasView and parameterized on `cursorLocation`.

    private func metalInteractiveScreenLines(
        cursorLocation: CGPoint,
        size: CGSize,
        transform: HorizontalCanvasTransform
    ) -> [HorizontalMetalScreenLinePrimitive] {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported else {
            return []
        }

        let snapped = snappedCursor(at: cursorLocation, transform: transform)
        let point = transform.point(snapped.point)
        guard point.x.isFinite, point.y.isFinite else {
            return []
        }

        let segments: [(CGPoint, CGPoint)]
        switch cursorSize {
        case .small:
            let halfLength: CGFloat = 10
            segments = [
                (CGPoint(x: point.x - halfLength, y: point.y), CGPoint(x: point.x + halfLength, y: point.y)),
                (CGPoint(x: point.x, y: point.y - halfLength), CGPoint(x: point.x, y: point.y + halfLength))
            ]
        case .fullScreen:
            segments = [
                (CGPoint(x: 0, y: point.y), CGPoint(x: size.width, y: point.y)),
                (CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: size.height))
            ]
        }

        let innerColor = snapped.isTarget
            ? HorizontalMetalRGBA(red: 1, green: 0, blue: 0, alpha: 1)
            : HorizontalMetalRGBA(red: 0, green: 1, blue: 0, alpha: 1)
        let outerColor = HorizontalMetalRGBA(backgroundColor.opacity(0.95))
        return segments.flatMap { segment in
            [
                HorizontalMetalScreenLinePrimitive(from: segment.0, to: segment.1, color: outerColor, width: 4),
                HorizontalMetalScreenLinePrimitive(from: segment.0, to: segment.1, color: innerColor, width: 1)
            ]
        }
        #else
        return []
        #endif
    }

    private func drawCursor(
        context: inout GraphicsContext,
        size: CGSize,
        transform: HorizontalCanvasTransform,
        cursorLocation: CGPoint
    ) {
        let snapped = snappedCursor(at: cursorLocation, transform: transform)
        let point = transform.point(snapped.point)
        guard point.x.isFinite, point.y.isFinite else {
            return
        }

        let segments: [(CGPoint, CGPoint)]
        switch cursorSize {
        case .small:
            let halfLength: CGFloat = 10
            segments = [
                (CGPoint(x: point.x - halfLength, y: point.y), CGPoint(x: point.x + halfLength, y: point.y)),
                (CGPoint(x: point.x, y: point.y - halfLength), CGPoint(x: point.x, y: point.y + halfLength))
            ]
        case .fullScreen:
            segments = [
                (CGPoint(x: 0, y: point.y), CGPoint(x: size.width, y: point.y)),
                (CGPoint(x: point.x, y: 0), CGPoint(x: point.x, y: size.height))
            ]
        }

        var path = Path()
        for segment in segments {
            path.move(to: segment.0)
            path.addLine(to: segment.1)
        }

        context.stroke(
            path,
            with: .color(backgroundColor.opacity(0.95)),
            style: StrokeStyle(lineWidth: 4, lineCap: .square)
        )
        context.stroke(
            path,
            with: .color(snapped.isTarget ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 1, blue: 0)),
            style: StrokeStyle(lineWidth: 1, lineCap: .square)
        )
    }

    // MARK: - Coordinate readout

    private func coordinateReadoutTextOverlay(
        cursorLocation: CGPoint,
        size: CGSize,
        transform: HorizontalCanvasTransform
    ) -> String? {
        guard showsCoordinateReadout else {
            return nil
        }
        let worldPoint = snappedCursor(at: cursorLocation, transform: transform).point
        return coordinateReadoutLabel(for: worldPoint, maxWidth: max(size.width - 32, 160))
    }

    private func metalCoordinateReadoutBatch(
        cursorLocation: CGPoint,
        size: CGSize,
        transform: HorizontalCanvasTransform
    ) -> HorizontalMetalInteractiveOverlayBatch {
        #if canImport(MetalKit)
        guard HorizontalMetalBackdropView.isSupported, showsCoordinateReadout else {
            return .empty
        }

        let worldPoint = snappedCursor(at: cursorLocation, transform: transform).point
        let maxWidth = max(size.width - 32, 160)
        let label = coordinateReadoutLabel(for: worldPoint, maxWidth: maxWidth)
        let labelWidth = readoutTextWidth(label)
        let backgroundWidth = min(labelWidth + Self.coordinateReadoutHorizontalPadding * 2, maxWidth)
        let backgroundMaxX = size.width - Self.coordinateReadoutTrailingMargin
        let backgroundMaxY = size.height - Self.coordinateReadoutBottomMargin
        let rect = CGRect(
            x: backgroundMaxX - backgroundWidth,
            y: backgroundMaxY - Self.coordinateReadoutHeight + 4,
            width: backgroundWidth,
            height: Self.coordinateReadoutHeight
        )
        guard rect.width > 0, rect.height > 0 else {
            return .empty
        }

        var batch = HorizontalMetalInteractiveOverlayBatch()
        let points = roundedRectPoints(rect: rect, radius: 5, segmentsPerCorner: 5)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let fillColor = HorizontalMetalRGBA(overlayBackgroundColor)
        for pair in zip(points, Array(points.dropFirst()) + [points[0]]) {
            batch.screenLines.append(
                HorizontalMetalScreenLinePrimitive(
                    from: pair.0,
                    to: pair.1,
                    color: HorizontalMetalRGBA(foregroundColor.opacity(0.25)),
                    width: 0.7
                )
            )
        }
        for pair in zip(points, Array(points.dropFirst()) + [points[0]]) {
            batch.screenTriangles.append(
                HorizontalMetalScreenTrianglePrimitive(a: center, b: pair.0, c: pair.1, color: fillColor)
            )
        }
        return batch
        #else
        return .empty
        #endif
    }

    private func roundedRectPoints(rect: CGRect, radius: CGFloat, segmentsPerCorner: Int) -> [CGPoint] {
        let radius = min(radius, min(rect.width, rect.height) * 0.5)
        let segments = max(segmentsPerCorner, 2)
        let corners: [(CGPoint, Double, Double)] = [
            (CGPoint(x: rect.maxX - radius, y: rect.minY + radius), -Double.pi / 2, 0),
            (CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), 0, Double.pi / 2),
            (CGPoint(x: rect.minX + radius, y: rect.maxY - radius), Double.pi / 2, Double.pi),
            (CGPoint(x: rect.minX + radius, y: rect.minY + radius), Double.pi, Double.pi * 1.5)
        ]
        return corners.flatMap { center, start, end in
            (0...segments).map { index in
                let t = Double(index) / Double(segments)
                let angle = start + (end - start) * t
                return CGPoint(
                    x: center.x + CGFloat(cos(angle)) * radius,
                    y: center.y + CGFloat(sin(angle)) * radius
                )
            }
        }
    }

    private func coordinateReadoutLabel(for worldPoint: HorizontalPoint, maxWidth: CGFloat) -> String {
        let coordinates = "X: \(coordinateLabel(worldPoint.x))   Y: \(coordinateLabel(worldPoint.y))"
        guard !showsHoverPopover,
              let hoverStatusText = hoverStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hoverStatusText.isEmpty else {
            return coordinates
        }

        let availableWidth = max(maxWidth - 22, 80)
        let separator = "   "
        let fullLabel = hoverStatusText + separator + coordinates
        guard readoutTextWidth(fullLabel) > availableWidth else {
            return fullLabel
        }

        let coordinatesWidth = readoutTextWidth(separator + coordinates)
        let hoverWidth = max(availableWidth - coordinatesWidth, 24)
        let truncatedHover = truncatedStatus(hoverStatusText, maxWidth: hoverWidth)
        return truncatedHover + separator + coordinates
    }

    private func truncatedStatus(_ status: String, maxWidth: CGFloat) -> String {
        guard readoutTextWidth(status) > maxWidth else {
            return status
        }

        var text = status
        while text.count > 1 {
            text.removeLast()
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            if readoutTextWidth(candidate) <= maxWidth {
                return candidate
            }
        }
        return "..."
    }

    private func readoutTextWidth(_ text: String) -> CGFloat {
        #if canImport(AppKit)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return (text as NSString).size(withAttributes: [.font: font]).width
        #else
        return CGFloat(text.count) * 6.5
        #endif
    }

    private func coordinateLabel(_ value: Double) -> String {
        let millimeters = value / 1_000_000
        return "\(millimeters.formatted(.number.precision(.fractionLength(2)))) mm"
    }

    // MARK: - Snapping (own O(1) index over the stable snap targets)

    private func snappedCursor(at location: CGPoint, transform: HorizontalCanvasTransform) -> HorizontalSnappedCursor {
        let worldPoint = transform.worldPoint(location)
        let gridPoint = grid.map {
            snapToGrid(worldPoint, grid: $0, divisor: gridDivisor)
        } ?? worldPoint

        let index = snapIndexCache.index(for: snapTargets)

        if let exactTarget = index.exactMatch(gridPoint) {
            return HorizontalSnappedCursor(point: exactTarget, isTarget: true)
        }

        if let nearestTarget = nearestSnapTarget(index: index, to: location, transform: transform) {
            return HorizontalSnappedCursor(point: nearestTarget, isTarget: true)
        }

        return HorizontalSnappedCursor(point: gridPoint, isTarget: false)
    }

    private func nearestSnapTarget(index: HorizontalSnapIndex, to location: CGPoint, transform: HorizontalCanvasTransform) -> HorizontalPoint? {
        let snapRadius: CGFloat = 30
        let world = transform.worldPoint(location)
        let edge = transform.worldPoint(CGPoint(x: location.x + snapRadius, y: location.y))
        let worldRadius = hypot(edge.x - world.x, edge.y - world.y)
        return index.nearest(to: world, within: worldRadius)
    }

    private func snapToGrid(_ point: HorizontalPoint, grid: HorizontalGridSettings, divisor: Int) -> HorizontalPoint {
        let safeDivisor = max(divisor, 1)
        let originX = Int64(grid.origin.x)
        let originY = Int64(grid.origin.y)
        let spacingX = max(Int64(grid.spacing.x) / Int64(safeDivisor), 1)
        let spacingY = max(Int64(grid.spacing.y) / Int64(safeDivisor), 1)
        let x = roundMultiple(Int64(point.x) - originX, spacingX) + originX
        let y = roundMultiple(Int64(point.y) - originY, spacingY) + originY
        return HorizontalPoint(x: Double(x), y: Double(y))
    }

    private func roundMultiple(_ value: Int64, _ multiple: Int64) -> Int64 {
        let sign: Int64
        if value > 0 {
            sign = 1
        } else if value < 0 {
            sign = -1
        } else {
            sign = 0
        }
        return ((value + sign * multiple / 2) / multiple) * multiple
    }
}
