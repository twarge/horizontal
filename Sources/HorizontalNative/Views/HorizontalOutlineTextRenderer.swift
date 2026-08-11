import CoreGraphics
import Foundation
import SwiftUI

private final class HorizontalOutlineLRU<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private var nodes = [Key: Node]()
    private var head: Node?
    private var tail: Node?
    private let lock = NSLock()
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[key] else {
            return nil
        }
        moveToFront(node)
        return node.value
    }

    func setValue(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = nodes[key] {
            existing.value = value
            moveToFront(existing)
            return
        }
        let node = Node(key: key, value: value)
        nodes[key] = node
        addToFront(node)
        if nodes.count > limit {
            evictOldest()
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        nodes.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
    }

    private func addToFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private func moveToFront(_ node: Node) {
        guard node !== head else { return }
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if node === tail {
            tail = prev
        }
        addToFront(node)
    }

    private func evictOldest() {
        guard let evicted = tail else { return }
        nodes.removeValue(forKey: evicted.key)
        tail = evicted.prev
        tail?.next = nil
        if head === evicted {
            head = nil
        }
    }
}

enum HorizontalOutlineTextRenderer {
    private struct FontLineKey: Hashable {
        var text: String
        var font: HorizontalTextFont
    }

    private struct FontLine {
        var segments: [(CGPoint, CGPoint)]
        var xRight: Double
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        var width: Double {
            guard !segments.isEmpty else {
                return 0
            }

            return maxX - minX
        }

        var height: Double {
            guard !segments.isEmpty else {
                return 0
            }

            return maxY - minY
        }

        init(segments: [(CGPoint, CGPoint)], xRight: Double) {
            self.segments = segments
            self.xRight = xRight

            guard let first = segments.first else {
                self.minX = 0
                self.minY = 0
                self.maxX = 0
                self.maxY = 0
                return
            }

            var minX = min(Double(first.0.x), Double(first.1.x))
            var minY = min(Double(first.0.y), Double(first.1.y))
            var maxX = max(Double(first.0.x), Double(first.1.x))
            var maxY = max(Double(first.0.y), Double(first.1.y))

            for segment in segments.dropFirst() {
                minX = min(minX, Double(segment.0.x), Double(segment.1.x))
                minY = min(minY, Double(segment.0.y), Double(segment.1.y))
                maxX = max(maxX, Double(segment.0.x), Double(segment.1.x))
                maxY = max(maxY, Double(segment.0.y), Double(segment.1.y))
            }

            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    private static let outlineSegmentCacheLimit = 12_000
    private static let fontLineCacheLimit = 4_000
    nonisolated(unsafe) private static let outlineSegmentCache = HorizontalOutlineLRU<HorizontalText, [(HorizontalPoint, HorizontalPoint)]>(limit: outlineSegmentCacheLimit)
    nonisolated(unsafe) private static let fontLineCache = HorizontalOutlineLRU<FontLineKey, FontLine>(limit: fontLineCacheLimit)
    static let minimumDrawableScreenHeight: CGFloat = 2.75

    static func draw(
        _ text: HorizontalText,
        color: Color,
        context: GraphicsContext,
        transform: HorizontalCanvasTransform,
        minimumLineWidth: CGFloat = 0.75,
        minimumScreenHeight: CGFloat = minimumDrawableScreenHeight
    ) {
        guard shouldDraw(text, transform: transform, minimumScreenHeight: minimumScreenHeight) else {
            return
        }

        let path = path(for: text, transform: transform)
        guard !path.isEmpty else {
            return
        }

        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: transform.strokeWidth(text.width, minimum: minimumLineWidth),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    static func shouldDraw(
        _ text: HorizontalText,
        transform: HorizontalCanvasTransform,
        minimumScreenHeight: CGFloat = minimumDrawableScreenHeight
    ) -> Bool {
        guard transform.length(text.size) >= minimumScreenHeight else {
            return false
        }

        let visibleBounds = transform.visibleBounds.expanded(by: text.size * 2)
        return approximateBounds(for: text).intersects(visibleBounds)
    }

    static func textWidth(_ text: String, font: HorizontalTextFont, size: Double) -> Double {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return 0
        }

        let scale = size / 21
        return trimmedText
            .components(separatedBy: .newlines)
            .map { lineData(for: $0, font: font).width * scale }
            .max() ?? 0
    }

    static func textSize(_ text: String, font: HorizontalTextFont, size: Double) -> (width: Double, height: Double) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return (0, 0)
        }

        let lines = trimmedText.components(separatedBy: .newlines)
        let scale = size / 21
        let fontLines = lines.map { lineData(for: $0, font: font) }
        let width = fontLines.map { $0.width }.max() ?? 0
        let lineHeight = max(fontLines.map { $0.height }.max() ?? 0, 21)
        let height = lines.count <= 1
            ? lineHeight
            : lineHeight + Double(lines.count - 1) * 21 * 1.35

        return (width * scale, height * scale)
    }

    static func outlineSegments(for text: HorizontalText) -> [(HorizontalPoint, HorizontalPoint)] {
        if let cached = outlineSegmentCache.value(for: text) {
            return cached
        }

        let segments = buildOutlineSegments(for: text)
        outlineSegmentCache.setValue(segments, for: text)
        return segments
    }

    private static func buildOutlineSegments(for text: HorizontalText) -> [(HorizontalPoint, HorizontalPoint)] {
        let trimmedText = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return []
        }

        let lines = trimmedText.components(separatedBy: .newlines)
        let lineCount = max(lines.count - 1, 0)
        let wrappedAngle = wrap(text.angle)
        let backwards = wrappedAngle > 16_384 && wrappedAngle <= 49_152 && !text.allowUpsideDown
        let scale = text.size / 21
        let lineSkip = (text.size * 1.35 + text.width) * (text.mirrored ? -1 : 1)
        let yShift = yShift(for: text.origin)
        var outlineSegments = [(HorizontalPoint, HorizontalPoint)]()

        for (lineIndex, line) in lines.enumerated() {
            let fontLine = lineData(for: line, font: text.font)
            let lineOffsetIndex = (backwards != text.mirrored) ? lineCount - lineIndex : lineIndex
            let lineOrigin = linePosition(
                for: text,
                lineSkip: lineSkip,
                lineOffsetIndex: lineOffsetIndex,
                angle: wrappedAngle
            )
            let drawAngle = backwards ? wrappedAngle - 32_768 : wrappedAngle
            var xShift = backwards ? -fontLine.xRight : 0
            if text.centered {
                xShift += backwards ? fontLine.xRight / 2 : -fontLine.xRight / 2
            }

            for segment in fontLine.segments {
                let start = localPoint(segment.0, xShift: xShift, yShift: yShift, scale: scale)
                let end = localPoint(segment.1, xShift: xShift, yShift: yShift, scale: scale)
                outlineSegments.append((
                    apply(start, origin: lineOrigin, angle: drawAngle),
                    apply(end, origin: lineOrigin, angle: drawAngle)
                ))
            }
        }

        return outlineSegments
    }

    private static func approximateBounds(for text: HorizontalText) -> HorizontalRect {
        let trimmedText = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return HorizontalRect(center: text.position, size: max(text.size, text.width))
        }

        let lines = trimmedText.components(separatedBy: .newlines)
        let lineCount = max(lines.count - 1, 0)
        let wrappedAngle = wrap(text.angle)
        let backwards = wrappedAngle > 16_384 && wrappedAngle <= 49_152 && !text.allowUpsideDown
        let scale = text.size / 21
        let lineSkip = (text.size * 1.35 + text.width) * (text.mirrored ? -1 : 1)
        let yShift = yShift(for: text.origin)
        let drawAngle = backwards ? wrappedAngle - 32_768 : wrappedAngle
        var points = [text.position]

        for (lineIndex, line) in lines.enumerated() {
            let fontLine = lineData(for: line, font: text.font)
            let lineOffsetIndex = (backwards != text.mirrored) ? lineCount - lineIndex : lineIndex
            let lineOrigin = linePosition(
                for: text,
                lineSkip: lineSkip,
                lineOffsetIndex: lineOffsetIndex,
                angle: wrappedAngle
            )
            var xShift = backwards ? -fontLine.xRight : 0
            if text.centered {
                xShift += backwards ? fontLine.xRight / 2 : -fontLine.xRight / 2
            }

            let minX = min(fontLine.minX, 0)
            let maxX = max(fontLine.maxX, fontLine.xRight)
            let minY = fontLine.segments.isEmpty ? -10 : fontLine.minY
            let maxY = fontLine.segments.isEmpty ? 10 : fontLine.maxY
            let corners = [
                CGPoint(x: minX, y: minY),
                CGPoint(x: minX, y: maxY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX, y: maxY),
            ]

            points.append(contentsOf: corners.map { point in
                let local = localPoint(point, xShift: xShift, yShift: yShift, scale: scale)
                return apply(local, origin: lineOrigin, angle: drawAngle)
            })
        }

        let padding = max(text.size / 4, text.width / 2)
        return HorizontalRect(points: points).expanded(by: padding)
    }

    private static func path(for text: HorizontalText, transform: HorizontalCanvasTransform) -> Path {
        var path = Path()
        for segment in outlineSegments(for: text) {
            path.move(to: transform.point(segment.0))
            path.addLine(to: transform.point(segment.1))
        }
        return path
    }

    private static func lineData(for text: String, font: HorizontalTextFont) -> FontLine {
        let key = FontLineKey(text: text, font: font)
        if let cached = fontLineCache.value(for: key) {
            return cached
        }

        var segments = [(CGPoint, CGPoint)]()
        var xCursor = 0
        var overbarStart: Int?

        for scalar in text.unicodeScalars {
            if scalar.value == 126 {
                if let start = overbarStart {
                    if start != xCursor {
                        segments.append((
                            CGPoint(x: Double(start), y: 24),
                            CGPoint(x: Double(xCursor), y: 24)
                        ))
                    }
                    overbarStart = nil
                } else {
                    overbarStart = xCursor
                }
                continue
            }

            guard let glyph = glyph(for: scalar, font: font) else {
                continue
            }

            let glyphScalars = Array(glyph.unicodeScalars)
            guard glyphScalars.count >= 2 else {
                continue
            }

            let left = Int(glyphScalars[0].value) - 82
            let right = Int(glyphScalars[1].value) - 82
            let xShift = -left
            var previous: CGPoint?
            var index = 2

            while index < glyphScalars.count {
                if glyphScalars[index].value == 32 {
                    previous = nil
                    index += 1
                    continue
                }

                guard index + 1 < glyphScalars.count else {
                    break
                }

                let x = Int(glyphScalars[index].value) - 82
                let y = -(Int(glyphScalars[index + 1].value) - 82) + 9
                let point = CGPoint(x: xCursor + x + xShift, y: y)
                if let previous {
                    segments.append((previous, point))
                }
                previous = point
                index += 2
            }

            xCursor += right - left
        }

        if let overbarStart {
            segments.append((
                CGPoint(x: Double(overbarStart), y: 24),
                CGPoint(x: Double(xCursor), y: 24)
            ))
        }

        let fontLine = FontLine(segments: segments, xRight: Double(xCursor))
        fontLineCache.setValue(fontLine, for: key)
        return fontLine
    }

    private static func glyph(for scalar: Unicode.Scalar, font: HorizontalTextFont) -> String? {
        if let glyphID = glyphID(for: scalar, font: font),
           let glyph = HorizontalOutlineFont.glyphs[glyphID],
           !glyph.isEmpty {
            return glyph
        }

        guard scalar.value >= 32, scalar.value < 127 else {
            return nil
        }

        let index = Int(scalar.value) - 32
        let fallbackID = HorizontalOutlineFont.plainGlyphIDs[index]
        return HorizontalOutlineFont.glyphs[fallbackID]
    }

    private static func glyphID(for scalar: Unicode.Scalar, font: HorizontalTextFont) -> Int? {
        if scalar.value >= 32, scalar.value < 127 {
            let glyphIDs = font == .small || font == .smallItalic
                ? HorizontalOutlineFont.plainGlyphIDs
                : HorizontalOutlineFont.simplexGlyphIDs
            return glyphIDs[Int(scalar.value) - 32]
        }

        switch scalar.value {
        case 0x03bc, 0x00b5:
            return 638
        case 0x00b7:
            return 729
        case 0x2126, 0x03a9:
            return 550
        case 0x03d1:
            return 634
        case 0x00d7:
            return 727
        case 0x00b0:
            return 718
        case 0x00b1:
            return 2_233
        case 0x00a0:
            return glyphID(for: " ", font: font)
        default:
            return 870
        }
    }

    private static func localPoint(
        _ point: CGPoint,
        xShift: Double,
        yShift: Double,
        scale: Double
    ) -> HorizontalPoint {
        HorizontalPoint(
            x: (Double(point.x) + xShift) * scale,
            y: (Double(point.y) + yShift) * scale
        )
    }

    private static func linePosition(
        for text: HorizontalText,
        lineSkip: Double,
        lineOffsetIndex: Int,
        angle: Int
    ) -> HorizontalPoint {
        let offset = rotate(
            HorizontalPoint(x: 0, y: -lineSkip * Double(lineOffsetIndex)),
            angle: angle
        )
        return HorizontalPoint(x: text.position.x + offset.x, y: text.position.y + offset.y)
    }

    private static func apply(
        _ point: HorizontalPoint,
        origin: HorizontalPoint,
        angle: Int
    ) -> HorizontalPoint {
        let rotated = rotate(point, angle: angle)
        return HorizontalPoint(x: origin.x + rotated.x, y: origin.y + rotated.y)
    }

    private static func rotate(_ point: HorizontalPoint, angle: Int) -> HorizontalPoint {
        switch wrap(angle) {
        case 0:
            return point
        case 16_384:
            return HorizontalPoint(x: -point.y, y: point.x)
        case 32_768:
            return HorizontalPoint(x: -point.x, y: -point.y)
        case 49_152:
            return HorizontalPoint(x: point.y, y: -point.x)
        default:
            let radians = Double(angle) / 65_536 * Double.pi * 2
            return HorizontalPoint(
                x: point.x * cos(radians) - point.y * sin(radians),
                y: point.x * sin(radians) + point.y * cos(radians)
            )
        }
    }

    private static func yShift(for origin: HorizontalTextOrigin) -> Double {
        switch origin {
        case .baseline:
            return 0
        case .center:
            return -10
        case .bottom:
            return -21
        }
    }

    private static func wrap(_ angle: Int) -> Int {
        let wrapped = angle % 65_536
        return wrapped < 0 ? wrapped + 65_536 : wrapped
    }
}
