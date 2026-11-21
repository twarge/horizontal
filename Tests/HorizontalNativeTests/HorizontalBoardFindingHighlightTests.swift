import HorizontalProjectIO
import XCTest
@testable import HorizontalNative

/// Board findings other than a clearance pair's say how far they run, as a
/// clearance finding does: copper joining two nets gives the outline of its
/// tracks and vias, a plane over another net's pad what of each pad the
/// fill covers, and a package in a height restriction where its outline and
/// the restriction overlap. The canvas strokes each in the same orange.
final class HorizontalBoardFindingHighlightTests: XCTestCase {
    private let top = HorizontalBoardLayers.topCopper
    private let bottom = HorizontalBoardLayers.bottomCopper
    /// How far inside another's copper a trimmed outline stops.
    private let tolerance = HorizontalArcChords.tolerance

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    private func mm(_ value: Double) -> Double { value * 1_000_000 }

    private func track(_ id: String, _ a: HorizontalPoint, _ b: HorizontalPoint, width: Double,
                       layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalSegment {
        HorizontalSegment(id: id, from: a, to: b, width: mm(width), layer: layer, netID: nil)
    }

    private func square(_ center: HorizontalPoint, _ size: Double) -> [HorizontalPoint] {
        let half = mm(size) / 2
        return [HorizontalPoint(x: center.x - half, y: center.y - half), HorizontalPoint(x: center.x + half, y: center.y - half),
                HorizontalPoint(x: center.x + half, y: center.y + half), HorizontalPoint(x: center.x - half, y: center.y + half)]
    }

    private func pad(_ name: String, at center: HorizontalPoint, net: String) -> HorizontalPolygon {
        HorizontalPolygon(id: "pkg/pad/\(name)/shape/s1", vertices: square(center, 1), layer: top, netID: net, metadata: ["Pad": name])
    }

    private let outline = HorizontalPolygon(
        id: "outline",
        vertices: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 40_000_000, y: 0),
                   HorizontalPoint(x: 40_000_000, y: 40_000_000), HorizontalPoint(x: 0, y: 40_000_000)],
        layer: HorizontalBoardLayers.outline
    )

    private func makeBoard(
        tracks: [HorizontalSegment] = [],
        polygons: [HorizontalPolygon] = [],
        pads: [HorizontalPolygon] = [],
        vias: [HorizontalMarker] = [],
        planes: [HorizontalPlane] = [],
        packages: [HorizontalPlacement] = [],
        packagePolygons: [HorizontalPolygon] = [],
        rules: JSONDictionary = [:]
    ) -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/highlights.hprj"), uuid: "b", name: "highlights",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [
                HorizontalBoardStackupLayer(layer: 0, copperThickness: 35_000, substrateThickness: 1_600_000),
                HorizontalBoardStackupLayer(layer: -100, copperThickness: 35_000, substrateThickness: 0),
            ],
            userLayers: [], junctions: [:], junctionNetIDs: [:],
            netDetails: ["net-a": HorizontalNetDetails(id: "net-a", name: "A"), "net-b": HorizontalNetDetails(id: "net-b", name: "B")],
            tracks: tracks, netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [outline] + polygons, planes: planes, keepouts: [], dimensions: [], decals: [], holes: [],
            vias: vias, viaHoles: [],
            packages: packages.isEmpty
                ? [HorizontalPlacement(id: "pkg", position: p(10, 10), angle: 0, mirrored: false, label: "U1", componentID: "comp-u1")]
                : packages,
            packagePads: pads, packageHoles: [],
            packagePolygons: packagePolygons, packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.takeRules(rules)
        return board
    }

    private func finding(_ board: HorizontalBoard, _ check: String) throws -> HorizontalBoardRuleFinding {
        let results = try XCTUnwrap(HorizontalBoardRulesCheck.run(board: board))
        return try XCTUnwrap(results.findings.first { $0.check == check }, results.findings.map(\.check).joined(separator: ", "))
    }

    /// The marker carries `finding`'s highlights, and the canvas strokes
    /// every segment of them as it does a clearance finding's.
    private func assertMarked(_ finding: HorizontalBoardRuleFinding, file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(HorizontalCanvasWarning.markers(boardFindings: [finding]).first, file: file, line: line)
        XCTAssertEqual(marker.highlights, finding.highlights, file: file, line: line)
        let lines = HorizontalCanvasWarningGeometry.lines(for: [marker])
        XCTAssertEqual(lines.count, finding.highlights.reduce(0) { $0 + $1.count - 1 }, file: file, line: line)
        XCTAssertEqual(Set(lines.map { "\($0.color)|\($0.width)|\($0.minimumWidth)" }).count, 1, "one orange", file: file, line: line)
    }

    /// A closed ring's corners, as the boolean gives them, in order of x
    /// then y; nil where the line doesn't end where it starts.
    private func corners(_ ring: [HorizontalPoint]) -> [HorizontalPoint]? {
        guard let first = ring.first, ring.last == first else { return nil }
        return ring.dropLast().sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    private func assertRings(_ rings: [[HorizontalPoint]], _ expected: [[HorizontalPoint]],
                             file: StaticString = #filePath, line: UInt = #line) {
        let found = rings.compactMap(corners)
        XCTAssertEqual(found.count, rings.count, "every ring is closed", file: file, line: line)
        let wanted = expected.map { $0.sorted { ($0.x, $0.y) < ($1.x, $1.y) } }
        XCTAssertEqual(found.count, wanted.count, "\(found)", file: file, line: line)
        for ring in wanted {
            let match = found.contains { candidate in
                candidate.count == ring.count && zip(candidate, ring).allSatisfy { abs($0.x - $1.x) <= 1 && abs($0.y - $1.y) <= 1 }
            }
            XCTAssertTrue(match, "no ring \(ring) among \(found)", file: file, line: line)
        }
    }

    // MARK: Copper joining two nets

    /// Copper joining two nets is outlined as far as it runs: a 0.2 mm track
    /// from A's pad into a 0.6 mm via, a 0.4 mm one on from it to B's pad,
    /// and a 0.2 mm one on the bottom from the via. Each track's sides run
    /// from its far end to where they go into the via, its round end there
    /// left out; the via's edge is drawn once, but where a track on either
    /// layer runs into it; and no line runs inside other copper on a layer
    /// it shares.
    func testCopperJoiningTwoNetsIsOutlinedAsFarAsItRuns() throws {
        let thin = track("thin", p(10, 10), p(12, 10), width: 0.2)
        let wide = track("wide", p(12, 10), p(14, 10), width: 0.4)
        let under = track("under", p(12, 10), p(12, 12), width: 0.2, layer: bottom)
        let via = HorizontalMarker(id: "v", position: p(12, 10), size: mm(0.6), holeSize: mm(0.3), layer: top,
                                   connectedLayers: [top, bottom], netID: nil)
        let board = makeBoard(tracks: [thin, wide, under], pads: [pad("1", at: p(10, 10), net: "net-a"), pad("2", at: p(14, 10), net: "net-b")],
                              vias: [via])
        let short = try finding(board, "short")
        XCTAssertEqual(Set(short.objectIDs), ["thin", "wide", "under", "v"])
        let points = short.highlights.flatMap { $0 }
        XCTAssertFalse(points.isEmpty)

        // How far along a side of a track of `half` width it is from the
        // via's centre to where the side goes into the via's copper.
        func into(_ half: Double) -> Double {
            ((mm(0.3) - tolerance) * (mm(0.3) - tolerance) - mm(half) * mm(half)).squareRoot()
        }
        func side(_ along: (HorizontalPoint) -> Double, where on: (HorizontalPoint) -> Bool) throws -> (Double, Double) {
            let found = points.filter(on).map(along)
            return (try XCTUnwrap(found.min()), try XCTUnwrap(found.max()))
        }
        // The thin track's sides, from A's pad to the via (and not the wide
        // one's round end, which passes their line at 14.17 mm).
        for y in [10.1, 9.9] {
            let (start, end) = try side(\.x) { abs($0.y - self.mm(y)) < 1 && $0.x < self.mm(13) }
            XCTAssertEqual(start, mm(10), accuracy: 1)
            XCTAssertEqual(end, mm(12) - into(0.1), accuracy: 100)
        }
        // The wide track's, from the via to B's pad, and its round end past it.
        for y in [10.2, 9.8] {
            let (start, end) = try side(\.x) { abs($0.y - self.mm(y)) < 1 }
            XCTAssertEqual(start, mm(12) + into(0.2), accuracy: 100)
            XCTAssertEqual(end, mm(14), accuracy: 1)
        }
        XCTAssertEqual(try XCTUnwrap(points.map(\.x).max()), mm(14.2), accuracy: 1)
        // The bottom track's, from the via up to its round end.
        for x in [11.9, 12.1] {
            let (start, end) = try side(\.y) { abs($0.x - self.mm(x)) < 1 }
            XCTAssertEqual(start, mm(10) + into(0.1), accuracy: 100)
            XCTAssertEqual(end, mm(12), accuracy: 1)
        }
        XCTAssertEqual(try XCTUnwrap(points.map(\.y).max()), mm(12.1), accuracy: 1)

        // Each piece of copper, and the layers it is on.
        let copper: [(a: HorizontalPoint, b: HorizontalPoint, radius: Double, layers: Set<Int>)] = [
            (thin.from, thin.to, mm(0.1), [top]), (wide.from, wide.to, mm(0.2), [top]),
            (under.from, under.to, mm(0.1), [bottom]), (via.position, via.position, mm(0.3), [top, bottom]),
        ]
        func distance(_ point: HorizontalPoint, _ piece: Int) -> Double {
            HorizontalRouteClearanceProbe.segmentDistance(point, point, copper[piece].a, copper[piece].b)
        }
        for point in points {
            // On the edge of some piece's copper, a chord's depth inside it at most…
            let edges = copper.indices.filter { distance(point, $0) > copper[$0].radius - tolerance - 1
                && distance(point, $0) < copper[$0].radius + 1 }
            XCTAssertFalse(edges.isEmpty, "\(point) is on no copper's edge")
            // …and no deeper inside another's on a layer they share.
            for piece in edges {
                for other in copper.indices where other != piece && !copper[other].layers.isDisjoint(with: copper[piece].layers) {
                    XCTAssertGreaterThan(distance(point, other), copper[other].radius - tolerance - 1,
                                         "\(point) on \(piece)'s edge is inside \(other)")
                }
            }
        }
        // The via's edge where no track runs into it, below it; and none of
        // it where the bottom track runs into it above, though no top one does.
        let rim = points.filter { abs(distance($0, 3) - mm(0.3)) <= tolerance + 1 }
        XCTAssertTrue(rim.contains { $0.y < mm(9.71) })
        XCTAssertFalse(rim.contains { $0.y > mm(10) && abs($0.x - mm(12)) < mm(0.1) - tolerance - 1 })
        // Once: no stretch of it twice, as it would be a layer at a time.
        let segments = short.highlights.flatMap { line in zip(line, line.dropFirst()) }
            .map { "\(Int(($0.0.x).rounded())),\(Int(($0.0.y).rounded()))-\(Int(($0.1.x).rounded())),\(Int(($0.1.y).rounded()))" }
        XCTAssertEqual(Set(segments).count, segments.count)

        try assertMarked(short)
    }

    // MARK: A plane over another net's pad

    /// A plane over another net's pads gives what of each it covers: all of
    /// one in its middle, the part of one over its edge inside it, and
    /// nothing of a pad on its own net or one outside it.
    func testAPlaneOverAPadGivesWhatOfEachPadItCovers() throws {
        let plane = HorizontalPlane(
            id: "gnd", netID: "net-a", polygonID: "gnd-polygon", layer: top, priority: 0, fillStyle: "solid",
            minWidth: 0, keepOrphans: false, fragments: [HorizontalPlaneFragment(paths: [square(p(30, 30), 6)], orphan: false)],
            fallbackPolygon: HorizontalPolygon(id: "gnd-polygon", vertices: square(p(30, 30), 6), layer: top))
        let board = makeBoard(
            pads: [pad("1", at: p(30, 30), net: "net-b"), pad("2", at: p(32.8, 30), net: "net-b"),
                   pad("3", at: p(36, 30), net: "net-b"), pad("4", at: p(28, 28), net: "net-a")],
            planes: [plane])
        let overPad = try finding(board, "plane_over_pad")
        assertRings(overPad.highlights, [
            square(p(30, 30), 1),
            [p(32.3, 29.5), p(33, 29.5), p(33, 30.5), p(32.3, 30.5)],
        ])
        try assertMarked(overPad)
    }

    // MARK: Height restrictions

    /// A package standing in a height restriction gives where its outline
    /// and the restriction overlap: a tall one half in it the half inside,
    /// and one with no model, all in it, its whole outline.
    func testAPackageInAHeightRestrictionGivesWhereItOverlapsIt() throws {
        func package(_ id: String, at center: HorizontalPoint, height: Double?) -> HorizontalPlacement {
            var placement = HorizontalPlacement(id: id, position: center, angle: 0, mirrored: false, label: id.uppercased(),
                                                componentID: "comp-\(id)")
            placement.model3D = height.map {
                HorizontalPackage3DModel(id: "m", filename: "m.step", fileURL: URL(fileURLWithPath: "/tmp/m.step"),
                                         x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 0, heightTop: mm($0), heightBottom: 0)
            }
            return placement
        }
        let packages = [package("u1", at: p(20, 10), height: 5), package("u2", at: p(14, 10), height: nil)]
        var board = makeBoard(
            polygons: [HorizontalPolygon(id: "hr-area", vertices: [p(5, 5), p(20, 5), p(20, 15), p(5, 15)],
                                         layer: HorizontalBoardLayers.topPackage)],
            packages: packages,
            packagePolygons: packages.map {
                HorizontalPolygon(id: "\($0.id)/polygon/o", vertices: square($0.position, 2), layer: HorizontalBoardLayers.topPackage)
            },
            rules: ["height_restrictions": ["enabled": true]])
        board.checkFacts.heightRestrictions = [HorizontalHeightRestriction(id: "hr", polygonID: "hr-area", height: mm(3))]

        let tall = try finding(board, "too_tall")
        XCTAssertEqual(tall.refdes, "U1")
        assertRings(tall.highlights, [[p(19, 9), p(20, 9), p(20, 11), p(19, 11)]])
        try assertMarked(tall)

        let noModel = try finding(board, "no_model")
        XCTAssertEqual(noModel.refdes, "U2")
        assertRings(noModel.highlights, [square(p(14, 10), 2)])
    }
}
