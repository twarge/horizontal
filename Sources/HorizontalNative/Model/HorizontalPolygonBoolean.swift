import Foundation
#if canImport(HorizontalPlaneClipper)
import HorizontalPlaneClipper
#endif

/// Boolean operations on closed paths, in Clipper's integer nanometres:
/// what the board checks compare areas with where Horizon's do (exposed
/// copper, overlapping plane outlines, a net tie's overlap with its nets).
/// A result is fragments, each an outer contour followed by its holes.
enum HorizontalPolygonBoolean {
    enum Operation: Int32 {
        case intersection = 0
        case union = 1
        case difference = 2
        case xor = 3
    }

    enum Fill: Int32 {
        case evenOdd = 0
        case nonZero = 1
    }

    /// `operation` on `subjects` and `clips`, each filled by its own rule.
    static func apply(
        _ operation: Operation,
        _ subjects: [[HorizontalPoint]],
        _ clips: [[HorizontalPoint]],
        subjectFill: Fill = .nonZero,
        clipFill: Fill = .nonZero
    ) -> [[[HorizontalPoint]]] {
        #if canImport(HorizontalPlaneClipper)
        let subjectStorage = BooleanPathStorage(subjects)
        let clipStorage = BooleanPathStorage(clips)
        let raw = HorizontalClipperBoolean(
            subjectStorage.pointer, Int32(subjectStorage.count),
            clipStorage.pointer, Int32(clipStorage.count),
            operation.rawValue, subjectFill.rawValue, clipFill.rawValue
        )
        return fragments(taking: raw)
        #else
        return []
        #endif
    }

    /// `subjects` less `clips`, each filled non-zero, shrunk by `inset` and
    /// made strictly simple: where copper narrows to nothing, so that a hole
    /// would touch its outline or another hole, shrinking opens it, and no
    /// fragment's paths touch, as a solid's face needs.
    static func simpleDifference(
        _ subjects: [[HorizontalPoint]],
        _ clips: [[HorizontalPoint]],
        inset: Double
    ) -> [[[HorizontalPoint]]] {
        #if canImport(HorizontalPlaneClipper)
        let subjectStorage = BooleanPathStorage(subjects)
        let clipStorage = BooleanPathStorage(clips)
        let raw = HorizontalClipperSimpleDifference(
            subjectStorage.pointer, Int32(subjectStorage.count),
            clipStorage.pointer, Int32(clipStorage.count),
            inset
        )
        return fragments(taking: raw)
        #else
        return []
        #endif
    }

    #if canImport(HorizontalPlaneClipper)
    /// The fragments a Clipper call returned, which it frees.
    private static func fragments(taking raw: HorizontalClipperFragmentList) -> [[[HorizontalPoint]]] {
        defer {
            HorizontalClipperFreeFragments(raw)
        }
        guard let fragmentPointer = raw.fragments, raw.count > 0 else {
            return []
        }
        var fragments = [[[HorizontalPoint]]]()
        for fragmentIndex in 0..<Int(raw.count) {
            let fragment = fragmentPointer[fragmentIndex]
            guard let pathPointer = fragment.paths, fragment.count > 0 else {
                continue
            }
            var paths = [[HorizontalPoint]]()
            for pathIndex in 0..<Int(fragment.count) {
                let path = pathPointer[pathIndex]
                guard let points = path.points, path.count >= 3 else {
                    continue
                }
                paths.append((0..<Int(path.count)).map { HorizontalPoint(x: points[$0].x, y: points[$0].y) })
            }
            if !paths.isEmpty {
                fragments.append(paths)
            }
        }
        return fragments
    }
    #endif

    static func intersection(_ subjects: [[HorizontalPoint]], _ clips: [[HorizontalPoint]]) -> [[[HorizontalPoint]]] {
        apply(.intersection, subjects, clips)
    }

    /// `subjects` less `clips`.
    static func difference(_ subjects: [[HorizontalPoint]], _ clips: [[HorizontalPoint]]) -> [[[HorizontalPoint]]] {
        apply(.difference, subjects, clips)
    }

    /// A path's area, positive whichever way round it runs.
    static func area(_ path: [HorizontalPoint]) -> Double {
        abs(signedArea(path))
    }

    /// A fragment's area: its outer contour's less its holes'.
    static func area(fragment: [[HorizontalPoint]]) -> Double {
        guard let outer = fragment.first else { return 0 }
        return max(0, area(outer) - fragment.dropFirst().reduce(0) { $0 + area($1) })
    }

    static func signedArea(_ path: [HorizontalPoint]) -> Double {
        guard path.count >= 3 else { return 0 }
        var sum = 0.0
        for index in path.indices {
            let a = path[index], b = path[(index + 1) % path.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// The mean of a fragment's outer contour's points, where Horizon puts a
    /// finding about the area.
    static func centroid(of fragment: [[HorizontalPoint]]) -> HorizontalPoint {
        guard let outer = fragment.first, !outer.isEmpty else { return .zero }
        let sum = outer.reduce(HorizontalPoint.zero) { $0 + $1 }
        return HorizontalPoint(x: sum.x / Double(outer.count), y: sum.y / Double(outer.count))
    }
}

#if canImport(HorizontalPlaneClipper)
/// Paths laid out for the C ABI for as long as the storage lives.
private final class BooleanPathStorage {
    private let pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>]
    private let pathBuffer: UnsafeMutablePointer<HorizontalClipperPath>?
    let count: Int

    var pointer: UnsafePointer<HorizontalClipperPath>? {
        UnsafePointer(pathBuffer)
    }

    init(_ paths: [[HorizontalPoint]]) {
        let valid = paths.filter { $0.count >= 3 }
        count = valid.count
        pathBuffer = count > 0 ? UnsafeMutablePointer<HorizontalClipperPath>.allocate(capacity: count) : nil
        var buffers = [UnsafeMutablePointer<HorizontalClipperPoint>]()
        buffers.reserveCapacity(count)
        for (pathIndex, path) in valid.enumerated() {
            let buffer = UnsafeMutablePointer<HorizontalClipperPoint>.allocate(capacity: path.count)
            for (pointIndex, point) in path.enumerated() {
                buffer[pointIndex] = HorizontalClipperPoint(x: point.x, y: point.y)
            }
            buffers.append(buffer)
            pathBuffer?[pathIndex] = HorizontalClipperPath(points: buffer, count: Int32(path.count))
        }
        pointBuffers = buffers
    }

    deinit {
        for buffer in pointBuffers {
            buffer.deallocate()
        }
        pathBuffer?.deallocate()
    }
}
#endif
