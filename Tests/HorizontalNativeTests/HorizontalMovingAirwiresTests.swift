import XCTest
@testable import HorizontalNative

/// The live rats' nest a move draws must be the one regenerating the airwires
/// of the moved board gives. Trees can differ where two links tie, so they are
/// compared by link count and total length.
final class HorizontalMovingAirwiresTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper

    private func square(around center: HorizontalPoint, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: center.x - half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y - half),
            HorizontalPoint(x: center.x + half, y: center.y + half),
            HorizontalPoint(x: center.x - half, y: center.y + half),
        ]
    }

    private func addPad(_ package: String, _ pad: String, at center: HorizontalPoint, net: String, to board: inout HorizontalBoard) {
        board.packagePads.append(HorizontalPolygon(
            id: "\(package)/pad/\(pad)/shape/s",
            polygonVertices: square(around: center, half: 0.4 * mm).map { HorizontalPolygonVertex(position: $0) },
            layer: top,
            netID: net
        ))
        board.packagePadPositions["\(package)/\(pad)"] = center
    }

    /// `board` with `packageIDs` and the listed track ends moved by `offset`.
    private func moved(
        _ board: HorizontalBoard,
        packageIDs: Set<String>,
        segmentEnds: [String: (from: Bool, to: Bool)],
        by offset: HorizontalPoint
    ) -> HorizontalBoard {
        var board = board
        for (path, position) in board.packagePadPositions {
            let packageID = String(path.split(separator: "/").first ?? "").lowercased()
            if packageIDs.contains(packageID) {
                board.packagePadPositions[path] = position + offset
            }
        }
        for index in board.tracks.indices {
            guard let ends = segmentEnds[board.tracks[index].id.lowercased()] else {
                continue
            }
            if ends.from {
                board.tracks[index].from = board.tracks[index].from + offset
            }
            if ends.to {
                board.tracks[index].to = board.tracks[index].to + offset
            }
        }
        board.regenerateAirwires()
        return board
    }

    private func assertSameRatsNest(
        live: [HorizontalSegment],
        regenerated: [HorizontalSegment],
        nets: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func length(_ segment: HorizontalSegment) -> Double {
            hypot(segment.to.x - segment.from.x, segment.to.y - segment.from.y)
        }
        let expected = regenerated.filter { $0.netID.map { nets.contains($0.lowercased()) } ?? false }
        XCTAssertEqual(live.count, expected.count, "airwire count", file: file, line: line)
        let liveLength = live.reduce(0) { $0 + length($1) }
        let expectedLength = expected.reduce(0) { $0 + length($1) }
        XCTAssertEqual(liveLength, expectedLength, accuracy: max(1, expectedLength * 1e-9), "total length", file: file, line: line)
    }

    func testFollowsAMovingPackageAcrossAFill() {
        var board = HorizontalGerberExportFixture.board()
        addPad("s1", "p1", at: HorizontalPoint(x: 0, y: 0), net: "n", to: &board)
        addPad("s2", "p1", at: HorizontalPoint(x: 10 * mm, y: 0), net: "n", to: &board)
        addPad("s3", "p1", at: HorizontalPoint(x: 10 * mm, y: 10 * mm), net: "n", to: &board)
        addPad("s4", "p1", at: HorizontalPoint(x: 20 * mm, y: 20 * mm), net: "n2", to: &board)
        addPad("m", "p1", at: HorizontalPoint(x: 5 * mm, y: 5 * mm), net: "n", to: &board)
        addPad("m", "p2", at: HorizontalPoint(x: 6 * mm, y: 5 * mm), net: "n2", to: &board)
        // A fill joins s1 and s2, and catches the moving pad when it comes close.
        board.planes = [HorizontalPlane(
            id: "plane", netID: "n", polygonID: "poly", layer: top,
            priority: 0, fillStyle: "solid", minWidth: 200_000, keepOrphans: false,
            fragments: [HorizontalPlaneFragment(paths: [square(around: HorizontalPoint(x: 5 * mm, y: 0), half: 6 * mm)], orphan: false)]
        )]
        board.regenerateAirwires()

        let live = board.movingAirwires(packageIDs: ["m"], viaIDs: [], junctionIDs: [], segmentEnds: [:])
        XCTAssertEqual(live.netIDs, ["n", "n2"])
        for offset in [
            HorizontalPoint(x: 0, y: 0),
            HorizontalPoint(x: 3 * mm, y: -2 * mm),
            HorizontalPoint(x: -6 * mm, y: 1 * mm),
            HorizontalPoint(x: 12 * mm, y: 12 * mm),
            HorizontalPoint(x: 5 * mm, y: -5 * mm),
        ] {
            assertSameRatsNest(
                live: live.airwires(offset: offset),
                regenerated: moved(board, packageIDs: ["m"], segmentEnds: [:], by: offset).airwires,
                nets: live.netIDs
            )
        }
    }

    func testATrackThatFollowsKeepsItsPadJoined() {
        var board = HorizontalGerberExportFixture.board()
        addPad("s1", "p1", at: HorizontalPoint(x: 0, y: 0), net: "n", to: &board)
        addPad("s2", "p1", at: HorizontalPoint(x: 0, y: 10 * mm), net: "n", to: &board)
        addPad("m", "p1", at: HorizontalPoint(x: 10 * mm, y: 0), net: "n", to: &board)
        board.tracks = [HorizontalSegment(
            id: "t1", from: HorizontalPoint(x: 0, y: 0), to: HorizontalPoint(x: 10 * mm, y: 0),
            width: 0.2 * mm, layer: top, netID: "n"
        )]
        board.regenerateAirwires()

        let ends: [String: (from: Bool, to: Bool)] = ["t1": (false, true)]
        let live = board.movingAirwires(packageIDs: ["m"], viaIDs: [], junctionIDs: [], segmentEnds: ends)
        for offset in [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 4 * mm, y: 7 * mm), HorizontalPoint(x: -10 * mm, y: 9 * mm)] {
            let airwires = live.airwires(offset: offset)
            XCTAssertEqual(airwires.count, 1, "s1 and m stay one piece; only s2 needs joining")
            assertSameRatsNest(
                live: airwires,
                regenerated: moved(board, packageIDs: ["m"], segmentEnds: ends, by: offset).airwires,
                nets: ["n"]
            )
        }
    }

    /// On a real board: packages moved with their tracks following, against a
    /// regeneration of each moved board.
    func testMatchesRegenerationOnARealBoard() throws {
        let base = URL(fileURLWithPath: "/Users/kornack/Repositories/coriander/Coriander Horizon")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("Coriander board not available")
        }
        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )

        func key(_ point: HorizontalPoint) -> String {
            "\(Int64(point.x.rounded())):\(Int64(point.y.rounded()))"
        }
        let packageIDs = board.packages.map { $0.id.lowercased() }.sorted().prefix(12)
        var compared = 0
        var liveAirwireCount = 0
        for packageID in packageIDs {
            let padKeys = Set(board.packagePadPositions.filter { $0.key.lowercased().hasPrefix(packageID + "/") }.values.map(key))
            guard !padKeys.isEmpty else {
                continue
            }
            var ends = [String: (from: Bool, to: Bool)]()
            for track in board.tracks {
                let from = padKeys.contains(key(track.from))
                let to = padKeys.contains(key(track.to))
                if from || to {
                    ends[track.id.lowercased()] = (from, to)
                }
            }
            let live = board.movingAirwires(packageIDs: [packageID], viaIDs: [], junctionIDs: [], segmentEnds: ends)
            for offset in [HorizontalPoint(x: 1.5 * mm, y: 0), HorizontalPoint(x: -4 * mm, y: 3 * mm)] {
                liveAirwireCount += live.airwires(offset: offset).count
                assertSameRatsNest(
                    live: live.airwires(offset: offset),
                    regenerated: moved(board, packageIDs: [packageID], segmentEnds: ends, by: offset).airwires,
                    nets: live.netIDs
                )
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 0)
        XCTAssertGreaterThan(liveAirwireCount, 0, "the moves leave airwires to compare")
    }
}
