import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The groundwork block layout sync stands on: a placement's inverse, a
/// package re-placed in memory as the loader would draw it at its new
/// placement, the copper fields a copied via and track keep in the file, and
/// the instances the flattener names.
final class HorizontalBoardMotionTests: XCTestCase {
    private static let angles = [0, 16_384, 32_768, 49_152, 8_192, 5_461, 60_000]

    func testAPlacementsInverseUndoesIt() {
        let points = [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 1_250_000, y: -730_000), HorizontalPoint(x: -4_000_000, y: 9_000_000)]
        for angle in Self.angles {
            for mirrored in [false, true] {
                let placement = HorizontalPlacementTransform(shift: HorizontalPoint(x: 12_300_000, y: -4_560_000), angle: angle, mirrored: mirrored)
                for composed in [placement.accumulated(with: placement.inverse), placement.inverse.accumulated(with: placement)] {
                    XCTAssertEqual(composed.angle, 0, "\(angle) \(mirrored)")
                    XCTAssertFalse(composed.mirrored)
                    XCTAssertEqual(composed.shift.x, 0, accuracy: 1e-6)
                    XCTAssertEqual(composed.shift.y, 0, accuracy: 1e-6)
                }
                for point in points {
                    let back = placement.inverse.applying(to: placement.applying(to: point))
                    XCTAssertEqual(back.x, point.x, accuracy: 1e-6)
                    XCTAssertEqual(back.y, point.y, accuracy: 1e-6)
                }
            }
        }
    }

    func testUnaccumulatedTextUndoesAccumulatedText() {
        for angle in Self.angles {
            for mirrored in [false, true] {
                let frame = HorizontalPlacementTransform(shift: HorizontalPoint(x: 3_000_000, y: 2_000_000), angle: angle, mirrored: mirrored)
                for childAngle in [0, 4_096, 30_000] {
                    for childMirrored in [false, true] {
                        let child = HorizontalPlacementTransform(shift: HorizontalPoint(x: 300_000, y: 1_000_000), angle: childAngle, mirrored: childMirrored)
                        let back = frame.unaccumulatedText(frame.accumulatedText(with: child))
                        XCTAssertEqual(back.angle, child.angle, "\(angle) \(mirrored) \(childAngle) \(childMirrored)")
                        XCTAssertEqual(back.mirrored, child.mirrored)
                        XCTAssertEqual(back.shift.x, child.shift.x, accuracy: 1e-6)
                        XCTAssertEqual(back.shift.y, child.shift.y, accuracy: 1e-6)
                    }
                }
            }
        }
    }

    /// A package put somewhere else in memory draws what the board, written
    /// with it there and loaded again, draws: its pads and label frames, pad
    /// centres, holes and its refdes, on the layers of the side it is on.
    func testAReplacedPackageDrawsWhereTheLoaderDrawsIt() throws {
        for innerLayers in [0, 2] {
            let fixture = try BlockLayoutFixture(instances: 1, innerLayers: innerLayers)
            defer { fixture.remove() }
            let component = fixture.flat(fixture.instances[0], "R1")
            let original = try fixture.board
            let saved = fixture.archive
            let packageID = try fixture.package(of: component).id
            let targets = [
                HorizontalPlacementTransform(shift: HorizontalPoint(x: 12_000_000, y: 7_000_000), angle: 0, mirrored: false),
                HorizontalPlacementTransform(shift: HorizontalPoint(x: 12_000_000, y: 7_000_000), angle: 16_384, mirrored: false),
                HorizontalPlacementTransform(shift: HorizontalPoint(x: -3_000_000, y: 2_000_000), angle: 8_192, mirrored: false),
                HorizontalPlacementTransform(shift: HorizontalPoint(x: 5_000_000, y: 5_000_000), angle: 5_461, mirrored: false),
                HorizontalPlacementTransform(shift: HorizontalPoint(x: 5_000_000, y: -5_000_000), angle: 0, mirrored: true),
                HorizontalPlacementTransform(shift: HorizontalPoint(x: 1_000_000, y: 9_000_000), angle: 16_384, mirrored: true),
            ]
            for target in targets {
                var moved = original
                let padMoves = moved.replacePackages([packageID: target])
                XCTAssertEqual(padMoves.count, 2, "both pads move")

                try fixture.install(saved)
                var json = try fixture.boardJSON()
                var packages = json.dictionaryMap("packages")
                var entry = try XCTUnwrap(packages[packageID])
                entry["placement"] = ["shift": [Int(target.shift.x), Int(target.shift.y)], "angle": target.angle, "mirror": target.mirrored]
                entry["flip"] = target.mirrored
                packages[packageID] = entry
                json["packages"] = packages
                try fixture.putBoard(json)
                let loaded = try fixture.board

                let label = "inner \(innerLayers), \(target)"
                let movedPackage = try XCTUnwrap(moved.packages.first { $0.id == packageID })
                XCTAssertEqual(movedPackage.position, target.shift, label)
                XCTAssertEqual(movedPackage.angle, target.angle, label)
                XCTAssertEqual(movedPackage.mirrored, target.mirrored, label)
                assertSame(Self.mine(moved.packagePadPositions, packageID), Self.mine(loaded.packagePadPositions, packageID), label)
                assertSamePolygons(moved.packagePads.filter { $0.id.hasPrefix(packageID) }, loaded.packagePads.filter { $0.id.hasPrefix(packageID) }, label)
                let movedTexts = moved.packageTexts.filter { $0.id.hasPrefix(packageID) }
                let loadedTexts = loaded.packageTexts.filter { $0.id.hasPrefix(packageID) }
                XCTAssertEqual(movedTexts.count, 1, label)
                for (mine, theirs) in zip(movedTexts.sorted { $0.id < $1.id }, loadedTexts.sorted { $0.id < $1.id }) {
                    XCTAssertEqual(mine.position.x, theirs.position.x, accuracy: 1, label)
                    XCTAssertEqual(mine.position.y, theirs.position.y, accuracy: 1, label)
                    XCTAssertEqual(mine.angle, theirs.angle, label)
                    XCTAssertEqual(mine.mirrored, theirs.mirrored, label)
                    XCTAssertEqual(mine.layer, theirs.layer, label)
                }
                // The other package stays where it was.
                let other = try XCTUnwrap(original.packages.first { $0.id != packageID })
                XCTAssertEqual(moved.packages.first { $0.id == other.id }?.position, other.position, label)
            }
        }
    }

    /// A via made in the app keeps the definition and the span it was made
    /// with, and its lock; a new track keeps its lock; and the loader reads
    /// both locks back.
    func testNewCopperKeepsItsDefinitionSpanAndLock() throws {
        let fixture = try BlockLayoutFixture(instances: 1, innerLayers: 2)
        defer { fixture.remove() }
        var board = try fixture.board
        let junction = "11111111-2222-4333-8444-555566667777"
        board.junctions[junction] = HorizontalPoint(x: 30_000_000, y: 30_000_000)
        let other = "21111111-2222-4333-8444-555566667777"
        board.junctions[other] = HorizontalPoint(x: 32_000_000, y: 30_000_000)
        board.vias.append(HorizontalMarker(
            id: "31111111-2222-4333-8444-555566667777",
            position: HorizontalPoint(x: 30_000_000, y: 30_000_000),
            size: 500_000, holeSize: 250_000, layer: nil,
            padstackID: HorizontalProjectArchive.defaultViaPadstack(poolDefaultVia: nil),
            definitionID: "41111111-2222-4333-8444-555566667777",
            span: HorizontalViaSpan(start: HorizontalBoardLayers.topCopper, end: -1),
            locked: true
        ))
        board.tracks.append(HorizontalSegment(
            id: "51111111-2222-4333-8444-555566667777",
            from: HorizontalPoint(x: 30_000_000, y: 30_000_000), to: HorizontalPoint(x: 32_000_000, y: 30_000_000),
            width: 200_000, layer: HorizontalBoardLayers.topCopper,
            fromJunctionID: junction, toJunctionID: other, locked: true
        ))
        try fixture.write(board)

        let json = try fixture.boardJSON()
        let via = try XCTUnwrap(json.dictionaryMap("vias")["31111111-2222-4333-8444-555566667777"])
        XCTAssertEqual(via.string("definition"), "41111111-2222-4333-8444-555566667777")
        XCTAssertEqual(via.string("source"), "definition")
        XCTAssertEqual(via.dictionary("span")?.int("start"), HorizontalBoardLayers.topCopper)
        XCTAssertEqual(via.dictionary("span")?.int("end"), -1)
        XCTAssertEqual(via.bool("locked"), true)
        let track = try XCTUnwrap(json.dictionaryMap("tracks")["51111111-2222-4333-8444-555566667777"])
        XCTAssertEqual(track.bool("locked"), true)

        let loaded = try fixture.board
        XCTAssertEqual(loaded.vias.first { $0.id == "31111111-2222-4333-8444-555566667777" }?.locked, true)
        XCTAssertEqual(loaded.tracks.first { $0.id == "51111111-2222-4333-8444-555566667777" }?.locked, true)
        XCTAssertEqual(loaded.vias.first { $0.id == "31111111-2222-4333-8444-555566667777" }?.connectedLayers.sorted(), [-1, 0])
    }

    /// The flattener names each instance and the block it is of, nested ones
    /// by their path.
    func testTheFlattenerNamesEveryInstanceAndItsBlock() {
        let top = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", channel = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let sub = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let first = "cccccccc-cccc-4ccc-8ccc-cccccccccccc", second = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let inner = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let topBlock: JSONDictionary = [
            "uuid": top, "nets": JSONDictionary(), "components": JSONDictionary(),
            "block_instances": [first: ["block": channel, "refdes": "I1", "connections": JSONDictionary()],
                                second: ["block": channel, "refdes": "I2", "connections": JSONDictionary()]]
        ]
        let channelBlock: JSONDictionary = [
            "uuid": channel, "nets": JSONDictionary(), "components": JSONDictionary(),
            "block_instances": [inner: ["block": sub, "refdes": "S1", "connections": JSONDictionary()]]
        ]
        let subBlock: JSONDictionary = ["uuid": sub, "nets": JSONDictionary(), "components": JSONDictionary()]
        let flat = HorizontalBlockFlattener.flatten(top: topBlock, blocks: [top: topBlock, channel: channelBlock, sub: subBlock])
        XCTAssertEqual(flat.instanceBlocks, [first: channel, second: channel, "\(first)/\(inner)": sub, "\(second)/\(inner)": sub])
        XCTAssertEqual(flat.instanceNames, [first: "I1", second: "I2", "\(first)/\(inner)": "I1/S1", "\(second)/\(inner)": "I2/S1"])
    }

    // MARK: - Helpers

    private static func mine(_ positions: [String: HorizontalPoint], _ packageID: String) -> [String: HorizontalPoint] {
        positions.filter { $0.key.lowercased().hasPrefix(packageID.lowercased() + "/") }
    }

    private func assertSame(_ lhs: [String: HorizontalPoint], _ rhs: [String: HorizontalPoint], _ label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(lhs.keys.map { $0.lowercased() }), Set(rhs.keys.map { $0.lowercased() }), label, file: file, line: line)
        for (key, point) in lhs {
            guard let other = rhs.first(where: { $0.key.lowercased() == key.lowercased() })?.value else { continue }
            XCTAssertEqual(point.x, other.x, accuracy: 1, "\(label) \(key)", file: file, line: line)
            XCTAssertEqual(point.y, other.y, accuracy: 1, "\(label) \(key)", file: file, line: line)
        }
    }

    private func assertSamePolygons(_ lhs: [HorizontalPolygon], _ rhs: [HorizontalPolygon], _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let left = lhs.sorted { $0.id < $1.id }, right = rhs.sorted { $0.id < $1.id }
        XCTAssertEqual(left.map(\.id), right.map(\.id), label, file: file, line: line)
        XCTAssertFalse(left.isEmpty, label, file: file, line: line)
        for (mine, theirs) in zip(left, right) {
            XCTAssertEqual(mine.layer, theirs.layer, "\(label) \(mine.id)", file: file, line: line)
            XCTAssertEqual(mine.vertices.count, theirs.vertices.count, label, file: file, line: line)
            for (a, b) in zip(mine.vertices, theirs.vertices) {
                XCTAssertEqual(a.x, b.x, accuracy: 1, "\(label) \(mine.id)", file: file, line: line)
                XCTAssertEqual(a.y, b.y, accuracy: 1, "\(label) \(mine.id)", file: file, line: line)
            }
            XCTAssertEqual(mine.padLabelFrame?.center.x ?? 0, theirs.padLabelFrame?.center.x ?? 0, accuracy: 1, label, file: file, line: line)
            XCTAssertEqual(mine.padLabelFrame?.center.y ?? 0, theirs.padLabelFrame?.center.y ?? 0, accuracy: 1, label, file: file, line: line)
            XCTAssertEqual(mine.padLabelFrame?.angle, theirs.padLabelFrame?.angle, label, file: file, line: line)
            XCTAssertEqual(mine.padLabelFrame?.mirrored, theirs.padLabelFrame?.mirrored, label, file: file, line: line)
        }
    }
}
