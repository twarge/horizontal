import Foundation
#if canImport(HorizontalPlaneClipper)
import HorizontalPlaneClipper
#endif

struct HorizontalPadOutlineFragment: Hashable {
    var id: String
    var layer: Int?
    var netID: String?
    var metadata: [String: String]
    var paths: [[HorizontalPoint]]
}

private struct HorizontalPadOutlineKey: Hashable {
    var rootID: String
    var layer: Int?
    var netID: String?
}

private struct HorizontalPadOutlineGroup {
    var rootID: String
    var layer: Int?
    var netID: String?
    var metadata: [String: String]
    var paths: [[HorizontalPoint]]
}

func horizonPadOutlineFragments(_ pads: [HorizontalPolygon]) -> [HorizontalPadOutlineFragment] {
    var groups = [HorizontalPadOutlineKey: HorizontalPadOutlineGroup]()
    var order = [HorizontalPadOutlineKey]()

    for pad in pads {
        let path = pad.hasArcEdges
            ? pad.renderVertices(arcPrecision: 32)
            : pad.polygonVertices.map(\.position)
        guard path.count >= 3 else {
            continue
        }
        let rootID = horizonPadRootID(for: pad.id)
        let key = HorizontalPadOutlineKey(
            rootID: rootID.lowercased(),
            layer: pad.layer,
            netID: pad.netID?.lowercased()
        )
        if var group = groups[key] {
            group.paths.append(path)
            for (metadataKey, metadataValue) in pad.metadata where group.metadata[metadataKey] == nil {
                group.metadata[metadataKey] = metadataValue
            }
            groups[key] = group
        } else {
            order.append(key)
            groups[key] = HorizontalPadOutlineGroup(
                rootID: rootID,
                layer: pad.layer,
                netID: pad.netID,
                metadata: pad.metadata,
                paths: [path]
            )
        }
    }

    var fragments = [HorizontalPadOutlineFragment]()
    for key in order {
        guard let group = groups[key] else {
            continue
        }
        let validPaths = group.paths.filter { $0.count >= 3 }
        let paths: [[[HorizontalPoint]]]
        if validPaths.count <= 1 {
            paths = validPaths.map { [$0] }
        } else {
            let mergedPaths = horizonUnionedClosedPaths(validPaths)
            paths = mergedPaths.isEmpty ? validPaths.map { [$0] } : mergedPaths
        }
        for (index, fragmentPaths) in paths.enumerated() where !fragmentPaths.isEmpty {
            fragments.append(
                HorizontalPadOutlineFragment(
                    id: "\(group.rootID)/outline/\(index)",
                    layer: group.layer,
                    netID: group.netID,
                    metadata: group.metadata,
                    paths: fragmentPaths
                )
            )
        }
    }
    return fragments
}

private func horizonPadRootID(for id: String) -> String {
    if let marker = id.range(of: "/pad/") {
        let padIDStart = marker.upperBound
        guard let nextSlash = id[padIDStart...].firstIndex(of: "/") else {
            return id
        }
        return String(id[..<nextSlash])
    }

    if id.hasPrefix("pad/") {
        let padIDStart = id.index(id.startIndex, offsetBy: 4)
        guard let nextSlash = id[padIDStart...].firstIndex(of: "/") else {
            return id
        }
        return String(id[..<nextSlash])
    }

    return id
}

private func horizonUnionedClosedPaths(_ paths: [[HorizontalPoint]]) -> [[[HorizontalPoint]]] {
    #if canImport(HorizontalPlaneClipper)
    let storage = HorizontalClipperPathListStorage(paths)
    guard storage.count > 0 else {
        return []
    }

    let rawFragments = HorizontalClipperBuildPlaneFill(
        storage.pointer,
        Int32(storage.count),
        nil,
        0,
        0,
        0,
        0
    )
    defer {
        HorizontalClipperFreeFragments(rawFragments)
    }

    guard let fragmentPointer = rawFragments.fragments,
          rawFragments.count > 0 else {
        return []
    }

    var fragments = [[[HorizontalPoint]]]()
    for fragmentIndex in 0..<Int(rawFragments.count) {
        let fragment = fragmentPointer[fragmentIndex]
        guard let pathPointer = fragment.paths,
              fragment.count > 0 else {
            continue
        }

        var fragmentPaths = [[HorizontalPoint]]()
        for pathIndex in 0..<Int(fragment.count) {
            let path = pathPointer[pathIndex]
            guard let pointPointer = path.points,
                  path.count >= 3 else {
                continue
            }

            var points = [HorizontalPoint]()
            points.reserveCapacity(Int(path.count))
            for pointIndex in 0..<Int(path.count) {
                let point = pointPointer[pointIndex]
                points.append(HorizontalPoint(x: point.x, y: point.y))
            }
            if points.count >= 3 {
                fragmentPaths.append(points)
            }
        }

        if !fragmentPaths.isEmpty {
            fragments.append(fragmentPaths)
        }
    }
    return fragments
    #else
    return paths.filter { $0.count >= 3 }.map { [$0] }
    #endif
}

#if canImport(HorizontalPlaneClipper)
private final class HorizontalClipperPathListStorage {
    private let pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>]
    private let pathBuffer: UnsafeMutablePointer<HorizontalClipperPath>?
    let count: Int

    var pointer: UnsafePointer<HorizontalClipperPath>? {
        UnsafePointer(pathBuffer)
    }

    init(_ paths: [[HorizontalPoint]]) {
        var buffers = [UnsafeMutablePointer<HorizontalClipperPoint>]()
        let validPaths = paths.filter { $0.count >= 3 }
        count = validPaths.count
        pathBuffer = count > 0 ? UnsafeMutablePointer<HorizontalClipperPath>.allocate(capacity: count) : nil

        for (pathIndex, path) in validPaths.enumerated() {
            let pointBuffer = UnsafeMutablePointer<HorizontalClipperPoint>.allocate(capacity: path.count)
            for (pointIndex, point) in path.enumerated() {
                pointBuffer[pointIndex] = HorizontalClipperPoint(x: point.x, y: point.y)
            }
            buffers.append(pointBuffer)
            pathBuffer?[pathIndex] = HorizontalClipperPath(points: pointBuffer, count: Int32(path.count))
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
