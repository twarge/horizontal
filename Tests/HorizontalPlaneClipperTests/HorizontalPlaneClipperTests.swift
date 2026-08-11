import XCTest
import HorizontalPlaneClipper

/// Drives the C plane-fill ABI with deterministic geometry to validate the
/// ported pour engine (HorizontalClipperBuildPlaneFillEx) independently of the
/// full board model. All coordinates are in nanometers (1mm = 1_000_000).
final class HorizontalPlaneClipperTests: XCTestCase {
    private let mm = 1_000_000.0

    // MARK: - Helpers

    private func square(centerX: Double, centerY: Double, half: Double) -> [HorizontalClipperPoint] {
        [
            HorizontalClipperPoint(x: centerX - half, y: centerY - half),
            HorizontalClipperPoint(x: centerX + half, y: centerY - half),
            HorizontalClipperPoint(x: centerX + half, y: centerY + half),
            HorizontalClipperPoint(x: centerX - half, y: centerY + half),
        ]
    }

    /// A scratch allocator that builds the C structs by hand, mirroring the
    /// production PlaneFillArena, so the test avoids overlapping-access pitfalls
    /// of nested withUnsafeMutableBufferPointer.
    private final class Arena {
        private var pointBuffers: [UnsafeMutablePointer<HorizontalClipperPoint>] = []

        func path(_ pts: [HorizontalClipperPoint]) -> HorizontalClipperPath {
            guard !pts.isEmpty else { return HorizontalClipperPath(points: nil, count: 0) }
            let buf = UnsafeMutablePointer<HorizontalClipperPoint>.allocate(capacity: pts.count)
            for (i, p) in pts.enumerated() { buf[i] = p }
            pointBuffers.append(buf)
            return HorizontalClipperPath(points: buf, count: Int32(pts.count))
        }

        func free() {
            for b in pointBuffers { b.deallocate() }
            pointBuffers.removeAll()
        }
    }

    /// Calls BuildPlaneFillEx with the supplied geometry, returns the fragment
    /// paths as plain Swift arrays, and frees the C allocation.
    private func pour(
        subject: [HorizontalClipperPoint],
        minWidth: Double,
        joinType: Int32 = 0,
        cutouts: [(path: [HorizontalClipperPoint], outset: Double, joinType: Int32, arc: Double)] = [],
        boardOutline: [[HorizontalClipperPoint]] = [],
        boardOutlineContract: Double = 0,
        thermalPads: [(path: [HorizontalClipperPoint], gap: Double, spoke: Double, nSpokes: Int32, connect: Int32)] = [],
        fillStyle: Int32 = 0,
        hatchBorderWidth: Double = 500_000,
        hatchLineWidth: Double = 200_000,
        hatchLineSpacing: Double = 500_000
    ) -> [[[HorizontalClipperPoint]]] {
        let arena = Arena()
        defer { arena.free() }

        var subjectArr = [arena.path(subject)]
        var cutoutArr = cutouts.map {
            HorizontalClipperCutout(path: arena.path($0.path), outset: $0.outset, joinType: $0.joinType, arcTolerance: $0.arc)
        }
        var outlineArr = boardOutline.map { arena.path($0) }
        var thermalArr = thermalPads.map { pad in
            HorizontalClipperThermalPad(
                path: arena.path(pad.path),
                placementX: 0, placementY: 0, placementAngle: 0, placementMirror: 0,
                connectStyle: pad.connect, gapWidth: pad.gap, spokeWidth: pad.spoke,
                nSpokes: pad.nSpokes, spokeAngle: 0)
        }

        let subjectCount = subjectArr.count
        let cutoutCount = cutoutArr.count
        let outlineCount = outlineArr.count
        let thermalCount = thermalArr.count
        let hasOutline = boardOutline.isEmpty ? Int32(0) : Int32(1)

        let raw: HorizontalClipperFragmentList = subjectArr.withUnsafeBufferPointer { subjectBuf in
            cutoutArr.withUnsafeBufferPointer { cutoutBuf in
                outlineArr.withUnsafeBufferPointer { outlineBuf in
                    thermalArr.withUnsafeBufferPointer { thermalBuf in
                        var params = HorizontalClipperPlaneFillParams()
                        params.subjects = subjectBuf.baseAddress
                        params.subjectCount = Int32(subjectCount)
                        params.minWidth = minWidth
                        params.joinType = joinType
                        params.cutouts = cutoutBuf.baseAddress
                        params.cutoutCount = Int32(cutoutCount)
                        params.boardOutline = outlineBuf.baseAddress
                        params.boardOutlineCount = Int32(outlineCount)
                        params.hasBoardOutline = hasOutline
                        params.boardOutlineContract = boardOutlineContract
                        params.thermalPads = thermalBuf.baseAddress
                        params.thermalPadCount = Int32(thermalCount)
                        params.fillStyle = fillStyle
                        params.hatchBorderWidth = hatchBorderWidth
                        params.hatchLineWidth = hatchLineWidth
                        params.hatchLineSpacing = hatchLineSpacing
                        return withUnsafePointer(to: &params) { HorizontalClipperBuildPlaneFillEx($0) }
                    }
                }
            }
        }
        defer { HorizontalClipperFreeFragments(raw) }
        _ = (subjectCount, cutoutCount, outlineCount, thermalCount)
        return Self.extract(raw)
    }

    private static func extract(_ raw: HorizontalClipperFragmentList) -> [[[HorizontalClipperPoint]]] {
        guard let frags = raw.fragments, raw.count > 0 else { return [] }
        return (0..<Int(raw.count)).map { fi -> [[HorizontalClipperPoint]] in
            let frag = frags[fi]
            guard let paths = frag.paths, frag.count > 0 else { return [] }
            return (0..<Int(frag.count)).map { pi -> [HorizontalClipperPoint] in
                let path = paths[pi]
                guard let pts = path.points, path.count > 0 else { return [] }
                return (0..<Int(path.count)).map { pts[$0] }
            }
        }
    }

    private func area(_ ring: [HorizontalClipperPoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in ring.indices {
            let j = (i + 1) % ring.count
            sum += ring[i].x * ring[j].y - ring[j].x * ring[i].y
        }
        return abs(sum) / 2
    }

    private func bbox(_ frags: [[[HorizontalClipperPoint]]]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var pts = frags.flatMap { $0.flatMap { $0 } }
        guard !pts.isEmpty else { return nil }
        let first = pts.removeFirst()
        var lo = first, hi = first
        for p in pts {
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        return (lo.x, lo.y, hi.x, hi.y)
    }

    // MARK: - Tests

    func testEmptyPlaneStillFills() {
        // A bare 50mm square with min_width should pour as one solid fragment.
        let frags = pour(subject: square(centerX: 0, centerY: 0, half: 25 * mm), minWidth: 200_000)
        XCTAssertEqual(frags.count, 1, "bare plane should be one fragment")
        XCTAssertEqual(frags.first?.count, 1, "no cutouts -> single outer ring, no holes")
        // Area is roughly (50mm - min_width)^2; shrink then re-expand nets ~original.
        let outerArea = area(frags.first?.first ?? [])
        XCTAssertGreaterThan(outerArea, 40 * mm * 40 * mm, "fill should cover most of the square")
    }

    func testForeignCutoutPunchesHole() {
        // A foreign pad in the middle should punch a hole (fragment with 2 rings).
        let cutout = square(centerX: 0, centerY: 0, half: 2 * mm)
        let frags = pour(
            subject: square(centerX: 0, centerY: 0, half: 25 * mm),
            minWidth: 200_000,
            cutouts: [(cutout, 350_000 + 100_000, 0, 2_000)])
        XCTAssertEqual(frags.count, 1)
        XCTAssertEqual(frags.first?.count, 2, "outer ring + one hole around the cutout")
        // Hole should be larger than the bare 2mm pad due to clearance + min_width.
        let holeArea = area(frags.first?.last ?? [])
        XCTAssertGreaterThan(holeArea, area(cutout), "hole is expanded by clearance")
    }

    func testBoardOutlineContractsFill() {
        // Outline smaller than the plane should clip the fill inside it.
        let outline = square(centerX: 0, centerY: 0, half: 10 * mm)
        let frags = pour(
            subject: square(centerX: 0, centerY: 0, half: 25 * mm),
            minWidth: 200_000,
            boardOutline: [outline],
            boardOutlineContract: 125_000 + 100_000)
        XCTAssertGreaterThanOrEqual(frags.count, 1)
        guard let bb = bbox(frags) else { return XCTFail("no geometry") }
        // Fill must sit strictly inside the 10mm outline (contracted).
        XCTAssertLessThan(bb.maxX, 10 * mm, "fill clipped inside contracted outline")
        XCTAssertGreaterThan(bb.minX, -10 * mm)
    }

    func testThermalPadProducesAntipadAndSpokes() {
        // Same-net thermal pad: antipad cut + spokes connecting back.
        let pad = square(centerX: 0, centerY: 0, half: 1 * mm)
        let frags = pour(
            subject: square(centerX: 0, centerY: 0, half: 25 * mm),
            minWidth: 200_000,
            thermalPads: [(pad, 300_000, 400_000, 4, 1)])
        XCTAssertGreaterThanOrEqual(frags.count, 1)
        // The antipad gap should create a hole ring around the pad (spokes bridge it,
        // but with 4 spokes the antipad remains a ring with the pad island inside).
        let totalRings = frags.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalRings, 1, "thermal relief should introduce extra rings (antipad)")
    }

    func testHatchIsSparserThanSolid() {
        // A hatch fill covers much less copper than a solid fill of the same
        // outline (thin bars + a perimeter border, mostly empty between).
        let outline = square(centerX: 0, centerY: 0, half: 25 * mm)
        let solid = pour(subject: outline, minWidth: 200_000, fillStyle: 0)
        let hatch = pour(
            subject: outline,
            minWidth: 200_000,
            fillStyle: 1,
            hatchBorderWidth: 500_000,
            hatchLineWidth: 200_000,
            hatchLineSpacing: 2_000_000)

        func coveredArea(_ frags: [[[HorizontalClipperPoint]]]) -> Double {
            frags.reduce(0.0) { total, frag in
                guard let outer = frag.first else { return total }
                let holes = frag.dropFirst().reduce(0.0) { $0 + area($1) }
                return total + area(outer) - holes
            }
        }

        let solidArea = coveredArea(solid)
        let hatchArea = coveredArea(hatch)
        XCTAssertGreaterThan(solidArea, 0)
        XCTAssertGreaterThan(hatchArea, 0, "hatch should still cover some copper")
        XCTAssertLessThan(hatchArea, solidArea * 0.6, "hatch should be substantially sparser than solid")
        // The hatch fragment(s) should carry many interior holes (the grid gaps).
        let totalRings = hatch.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(totalRings, 5, "hatch grid should create many interior holes")
    }

    // MARK: - Offset polygon (parameter-program expand-polygon)

    private func offsetPolygon(_ pts: [HorizontalClipperPoint], delta: Double, joinType: Int32 = 2) -> [HorizontalClipperPoint] {
        let result = pts.withUnsafeBufferPointer {
            HorizontalClipperOffsetPolygon($0.baseAddress, Int32($0.count), delta, joinType)
        }
        defer { HorizontalClipperFreePath(result) }
        guard let p = result.points, result.count > 0 else { return [] }
        return (0..<Int(result.count)).map { p[$0] }
    }

    func testOffsetPolygonExpands() {
        let sq = square(centerX: 0, centerY: 0, half: 5 * mm) // 10mm square, area 100mm^2
        let expanded = offsetPolygon(sq, delta: 1 * mm)
        XCTAssertGreaterThanOrEqual(expanded.count, 4)
        // Miter-expanding a 10mm square by 1mm -> 12mm square, area 144mm^2.
        XCTAssertEqual(area(expanded), 144 * mm * mm, accuracy: 2 * mm * mm)
    }

    func testOffsetPolygonContracts() {
        let sq = square(centerX: 0, centerY: 0, half: 5 * mm)
        let contracted = offsetPolygon(sq, delta: -1 * mm)
        XCTAssertGreaterThanOrEqual(contracted.count, 4)
        XCTAssertEqual(area(contracted), 64 * mm * mm, accuracy: 2 * mm * mm) // 8mm square
    }

    func testOffsetPolygonCollapseReturnsEmpty() {
        // Contracting a 2mm square by 5mm collapses it -> no result.
        let sq = square(centerX: 0, centerY: 0, half: 1 * mm)
        XCTAssertTrue(offsetPolygon(sq, delta: -5 * mm).isEmpty)
    }

    func testDegenerateSubjectReturnsEmpty() {
        let frags = pour(subject: [HorizontalClipperPoint(x: 0, y: 0), HorizontalClipperPoint(x: 1, y: 1)], minWidth: 0)
        XCTAssertTrue(frags.isEmpty, "fewer than 3 points -> no fill")
    }
}
