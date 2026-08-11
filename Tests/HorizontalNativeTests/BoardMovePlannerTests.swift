import XCTest
@testable import HorizontalNative

/// Tests the move-planning logic extracted from BoardCanvasView into the
/// stateless `BoardMovePlanner`. The dependency-minimal signature lets us verify
/// the drag connectivity index with plain geometry — no View, no full board.
final class BoardMovePlannerTests: XCTestCase {
    private func key(_ x: Double, _ y: Double) -> String {
        HorizontalCanvasModeSupport.pointKey(HorizontalPoint(x: x, y: y))
    }

    func testTrackEndpointsAreIndexedByPointWithDirection() {
        let track = HorizontalSegment(id: "t1", from: HorizontalPoint(x: 0, y: 0),
                                   to: HorizontalPoint(x: 1000, y: 0), width: 100, layer: 0, netID: "net1")
        let index = BoardMovePlanner.connectivityIndex(
            tracks: [track], netTies: [], junctions: [:], junctionNetIDs: [:],
            vias: [], packagePads: [], packageHoles: [], includesPackages: false)

        let ref = HorizontalSelectableRef(id: "t1", type: .track, layer: 0)
        XCTAssertEqual(index.segmentsByRef[ref], track)

        let fromEndpoints = index.segmentEndpointsByPoint[key(0, 0)] ?? []
        XCTAssertEqual(fromEndpoints.count, 1)
        XCTAssertEqual(fromEndpoints.first?.ref, ref)
        XCTAssertEqual(fromEndpoints.first?.movesFrom, true)
        XCTAssertEqual(fromEndpoints.first?.netID, "net1")

        let toEndpoints = index.segmentEndpointsByPoint[key(1000, 0)] ?? []
        XCTAssertEqual(toEndpoints.first?.movesFrom, false)
    }

    func testNetTiesUseNetTieType() {
        let tie = HorizontalSegment(id: "nt1", from: HorizontalPoint(x: 5, y: 5),
                                 to: HorizontalPoint(x: 10, y: 5), width: 50, layer: 0, netID: "n")
        let index = BoardMovePlanner.connectivityIndex(
            tracks: [], netTies: [tie], junctions: [:], junctionNetIDs: [:],
            vias: [], packagePads: [], packageHoles: [], includesPackages: false)
        let endpoints = index.segmentEndpointsByPoint[key(5, 5)] ?? []
        XCTAssertEqual(endpoints.first?.ref.type, .boardNetTie)
    }

    func testJunctionsAndViasIndexedByPoint() {
        let index = BoardMovePlanner.connectivityIndex(
            tracks: [], netTies: [],
            junctions: ["j1": HorizontalPoint(x: 200, y: 300)],
            junctionNetIDs: ["j1": "netA"],
            vias: [HorizontalMarker(id: "v1", position: HorizontalPoint(x: 400, y: 500), size: 200, layer: 0, netID: "netB")],
            packagePads: [], packageHoles: [], includesPackages: false)

        let junctionOwners = index.junctionOwnersByPoint[key(200, 300)] ?? []
        XCTAssertEqual(junctionOwners.first?.ref, HorizontalSelectableRef(id: "j1", type: .junction))
        XCTAssertEqual(junctionOwners.first?.netID, "netA")

        let viaOwners = index.viaOwnersByPoint[key(400, 500)] ?? []
        XCTAssertEqual(viaOwners.first?.ref, HorizontalSelectableRef(id: "v1", type: .via))
        XCTAssertEqual(viaOwners.first?.netID, "netB")
    }

    func testPackageAnchorsOnlyWhenIncludesPackages() {
        let hole = HorizontalHole(id: "pkg1/hole/h1", position: HorizontalPoint(x: 700, y: 800),
                               diameter: 300, plated: true, netID: "netC")

        let without = BoardMovePlanner.connectivityIndex(
            tracks: [], netTies: [], junctions: [:], junctionNetIDs: [:],
            vias: [], packagePads: [], packageHoles: [hole], includesPackages: false)
        XCTAssertTrue(without.packageAnchorsByID.isEmpty)

        let with = BoardMovePlanner.connectivityIndex(
            tracks: [], netTies: [], junctions: [:], junctionNetIDs: [:],
            vias: [], packagePads: [], packageHoles: [hole], includesPackages: true)
        let anchors = with.packageAnchorsByID["pkg1"] ?? []
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors.first?.point.x, 700)
        XCTAssertEqual(anchors.first?.netID, "netC")

        let owners = with.packageOwnersByPoint[key(700, 800)] ?? []
        XCTAssertEqual(owners.first?.ref, HorizontalSelectableRef(id: "pkg1", type: .boardPackage))
    }

    // MARK: - residentMovePlan

    private func plan(
        refs: [HorizontalSelectableRef],
        tracks: [HorizontalSegment] = [],
        netTies: [HorizontalSegment] = [],
        junctions: [String: HorizontalPoint] = [:],
        junctionNetIDs: [String: String] = [:],
        vias: [HorizontalMarker] = [],
        packageHoles: [HorizontalHole] = []
    ) -> BoardResidentMovePlan {
        BoardMovePlanner.residentMovePlan(
            for: refs, tracks: tracks, netTies: netTies,
            junctions: junctions, junctionNetIDs: junctionNetIDs,
            vias: vias, packagePads: [], packageHoles: packageHoles)
    }

    func testUnconnectedTrackMovesBothEndpoints() {
        let track = HorizontalSegment(id: "t1", from: HorizontalPoint(x: 0, y: 0),
                                   to: HorizontalPoint(x: 1000, y: 0), width: 100, layer: 0, netID: "n")
        let ref = HorizontalSelectableRef(id: "t1", type: .track, layer: 0)
        let result = plan(refs: [ref], tracks: [track])
        let move = result.segmentMoves[ref]
        XCTAssertNotNil(move)
        XCTAssertEqual(move?.movesFrom, true)
        XCTAssertEqual(move?.movesTo, true)
        XCTAssertTrue(result.translatedRefs.isEmpty)
    }

    func testConnectedTrackDragsNeighborAtJunction() {
        // t1 and t2 share a junction at (0,0); selecting only t1 should also move
        // t2's endpoint at that junction (connection propagation).
        let t1 = HorizontalSegment(id: "t1", from: HorizontalPoint(x: 0, y: 0),
                                to: HorizontalPoint(x: 1000, y: 0), width: 100, layer: 0, netID: "n")
        let t2 = HorizontalSegment(id: "t2", from: HorizontalPoint(x: 0, y: 0),
                                to: HorizontalPoint(x: 0, y: 1000), width: 100, layer: 0, netID: "n")
        let ref1 = HorizontalSelectableRef(id: "t1", type: .track, layer: 0)
        let ref2 = HorizontalSelectableRef(id: "t2", type: .track, layer: 0)
        let result = plan(
            refs: [ref1], tracks: [t1, t2],
            junctions: ["j1": HorizontalPoint(x: 0, y: 0)], junctionNetIDs: ["j1": "n"])

        XCTAssertEqual(result.segmentMoves[ref1]?.movesFrom, true)
        XCTAssertEqual(result.segmentMoves[ref1]?.movesTo, true)
        // t2 is dragged along at the shared junction.
        XCTAssertEqual(result.segmentMoves[ref2]?.movesFrom, true)
        XCTAssertNotEqual(result.segmentMoves[ref2]?.movesTo, true)
    }

    func testPackageDragMovesConnectedTrack() {
        let hole = HorizontalHole(id: "pkg1/hole/h1", position: HorizontalPoint(x: 500, y: 500),
                               diameter: 300, plated: true, netID: "n")
        let track = HorizontalSegment(id: "t1", from: HorizontalPoint(x: 500, y: 500),
                                   to: HorizontalPoint(x: 1500, y: 500), width: 100, layer: 0, netID: "n")
        let packageRef = HorizontalSelectableRef(id: "pkg1", type: .boardPackage)
        let result = plan(refs: [packageRef], tracks: [track], packageHoles: [hole])

        XCTAssertTrue(result.translatedRefs.contains(HorizontalSelectableRef(id: "pkg1", type: .boardPackage)))
        // The track endpoint anchored on the package pad/hole is pulled along.
        let trackRef = HorizontalSelectableRef(id: "t1", type: .track, layer: 0)
        XCTAssertEqual(result.segmentMoves[trackRef]?.movesFrom, true)
    }

    func testSimpleObjectIsTranslated() {
        let ref = HorizontalSelectableRef(id: "l1", type: .boardLine, layer: 0)
        let result = plan(refs: [ref])
        XCTAssertTrue(result.translatedRefs.contains(HorizontalSelectableRef(id: "l1", type: .boardLine, layer: 0)))
        XCTAssertTrue(result.segmentMoves.isEmpty)
    }

    func testUnsupportedRefIsRecorded() {
        let ref = HorizontalSelectableRef(id: "s1", type: .schematicSymbol)
        let result = plan(refs: [ref])
        XCTAssertTrue(result.unsupportedRefs.contains(ref))
        XCTAssertTrue(result.translatedRefs.isEmpty)
    }

    // MARK: - expandedSelection / movableEndpointOwnerRefs

    func testExpandedSelectionIncludesConnectedJunction() {
        let track = HorizontalSegment(id: "t1", from: HorizontalPoint(x: 0, y: 0),
                                   to: HorizontalPoint(x: 1000, y: 0), width: 100, layer: 0, netID: "n")
        let trackRef = HorizontalSelectableRef(id: "t1", type: .track, layer: 0)
        let expanded = BoardMovePlanner.expandedSelection(
            [trackRef], tracks: [track], netTies: [],
            junctions: ["j1": HorizontalPoint(x: 0, y: 0)], junctionNetIDs: ["j1": "n"], vias: [])
        XCTAssertTrue(expanded.contains(trackRef))
        XCTAssertTrue(expanded.contains(HorizontalSelectableRef(id: "j1", type: .junction)))
    }

    func testExpandedSelectionPassesThroughNonTrack() {
        let ref = HorizontalSelectableRef(id: "x", type: .via)
        let expanded = BoardMovePlanner.expandedSelection(
            [ref], tracks: [], netTies: [], junctions: [:], junctionNetIDs: [:], vias: [])
        XCTAssertEqual(expanded, [ref])
    }

    func testMovableEndpointOwnersFindsPackageAnchorOnlyWhenEnabled() {
        let pkg = HorizontalPlacement(id: "pkg1", position: HorizontalPoint(x: 500, y: 500),
                                   angle: 0, mirrored: false, label: "U1")
        let hole = HorizontalHole(id: "pkg1/hole/h1", position: HorizontalPoint(x: 500, y: 500),
                               diameter: 300, plated: true, netID: "n")
        let point = HorizontalPoint(x: 500, y: 500)

        let enabled = BoardMovePlanner.movableEndpointOwnerRefs(
            at: point, netID: "n", junctions: [:], junctionNetIDs: [:], vias: [],
            packages: [pkg], packagePads: [], packageHoles: [hole], includesPackages: true)
        XCTAssertTrue(enabled.contains(HorizontalSelectableRef(id: "pkg1", type: .boardPackage)))

        let disabled = BoardMovePlanner.movableEndpointOwnerRefs(
            at: point, netID: "n", junctions: [:], junctionNetIDs: [:], vias: [],
            packages: [pkg], packagePads: [], packageHoles: [hole], includesPackages: false)
        XCTAssertTrue(disabled.isEmpty)
    }

    func testMovableEndpointOwnersMatchesJunctionAndVia() {
        let owners = BoardMovePlanner.movableEndpointOwnerRefs(
            at: HorizontalPoint(x: 10, y: 20), netID: "n",
            junctions: ["j1": HorizontalPoint(x: 10, y: 20)], junctionNetIDs: ["j1": "n"],
            vias: [HorizontalMarker(id: "v1", position: HorizontalPoint(x: 10, y: 20), size: 200, layer: 0, netID: "n")],
            packages: [], packagePads: [], packageHoles: [], includesPackages: false)
        XCTAssertTrue(owners.contains(HorizontalSelectableRef(id: "j1", type: .junction)))
        XCTAssertTrue(owners.contains(HorizontalSelectableRef(id: "v1", type: .via)))
    }

    func testPackageIDParsing() {
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "pkg-abc/pad/pad-1"), "pkg-abc")
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "pkg-abc/hole/h-2"), "pkg-abc")
        // No recognized separator -> nil.
        XCTAssertNil(BoardMovePlanner.packageID(forGeometryID: "loose-id"))
        // Separator at the start (no prefix) -> nil.
        XCTAssertNil(BoardMovePlanner.packageID(forGeometryID: "pad/x"))
    }

    /// Edge cases that pin the allocation-free UTF-8 fast path to the original
    /// `lowercased().split("/")...joined()` semantics.
    func testPackageIDParsingEdgeCases() {
        // Result is lowercased; a segment that merely contains a separator as a
        // substring (e.g. "pad-1") is not itself the separator.
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "PKG-ABC/PAD/x"), "pkg-abc")
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "pad-1/pad/x"), "pad-1")
        // Multi-segment prefix is joined with "/".
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "a/b/pad/x"), "a/b")
        // Separator as the last segment (no trailing object id).
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "pkg/pad"), "pkg")
        // Empty segments (collapsed/leading/trailing slashes) are omitted, matching `split`.
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "a//pad/x"), "a")
        XCTAssertNil(BoardMovePlanner.packageID(forGeometryID: "/pad/x"))
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "pkg/pad/"), "pkg")
        // Empty input -> nil.
        XCTAssertNil(BoardMovePlanner.packageID(forGeometryID: ""))
        // Non-ASCII defers to the Unicode-correct path (and still folds case).
        XCTAssertEqual(BoardMovePlanner.packageID(forGeometryID: "PÉKG/pad/x"), "pékg")
    }
}
