import Foundation
import XCTest
@testable import HorizontalNative

/// A part of a block's instance is two things: its package on the board,
/// named by its flat id, and its block's component on the block's sheet. A
/// part picked or spotlit on the board is that component in the schematic,
/// and a component picked or spotlit on the block's sheet is every
/// instance's package on the board.
final class HorizontalBlockComponentMappingTests: XCTestCase {
    private func lowercased(_ ids: Set<String>) -> Set<String> {
        Set(ids.map { $0.lowercased() })
    }

    func testABoardPartIsItsBlocksComponentInTheSchematic() throws {
        let fixture = try BlockLayoutFixture(instances: 2)
        let flattened = try XCTUnwrap(fixture.project.flattenedBlock)
        let r1 = try XCTUnwrap(fixture.components["R1"]).lowercased()
        let first = fixture.flat(fixture.instances[0], "R1").lowercased()
        let second = fixture.flat(fixture.instances[1], "R1").lowercased()

        XCTAssertEqual(lowercased(flattened.blockComponentIDs(for: [first])), [first, r1], "the first instance's R1 is the block's R1")
        XCTAssertEqual(lowercased(flattened.blockComponentIDs(for: [second])), [second, r1], "and so is the second's")
        XCTAssertEqual(lowercased(flattened.boardComponentIDs(for: [r1])), [r1, first, second], "the block's R1 is both packages")
        XCTAssertEqual(lowercased(flattened.boardComponentIDs(for: [first])), [first], "a package brings in no other instance")
    }

    func testAPartTopLevelOrUnknownIsItself() throws {
        let fixture = try BlockLayoutFixture(instances: 1)
        let flattened = try XCTUnwrap(fixture.project.flattenedBlock)
        XCTAssertEqual(flattened.blockComponentIDs(for: ["not-a-part"]), ["not-a-part"])
        XCTAssertEqual(flattened.boardComponentIDs(for: ["not-a-part"]), ["not-a-part"])
        XCTAssertEqual(flattened.blockComponentIDs(for: []), [])
    }

    /// Spotlight on a board part turns the schematic to the block's sheet,
    /// which drew nothing of it by its flat id; on the block's component it
    /// frames both instances' packages on the board.
    func testSpotlightFindsTheBlocksSheetAndBothPackages() throws {
        let fixture = try BlockLayoutFixture(instances: 2)
        let flattened = try XCTUnwrap(fixture.project.flattenedBlock)
        let r1 = try XCTUnwrap(fixture.components["R1"])
        let first = fixture.flat(fixture.instances[0], "R1")
        let block = try XCTUnwrap(flattened.componentBlocks[first.lowercased()])

        XCTAssertNil(HorizontalSpotlightFraming.sheetTarget(fixture.project, netIDs: [], componentIDs: [first], currentSheetID: nil),
                     "by its flat id no sheet draws it")
        let target = try XCTUnwrap(HorizontalSpotlightFraming.sheetTarget(
            fixture.project, netIDs: [], componentIDs: flattened.blockComponentIDs(for: [first]), currentSheetID: nil
        ))
        XCTAssertEqual(target.blockID?.lowercased(), block.lowercased(), "the block's sheet")

        let board = try fixture.board
        let packages = board.packages.filter { package in
            [first, fixture.flat(fixture.instances[1], "R1")].map { $0.lowercased() }.contains(package.componentID?.lowercased() ?? "")
        }
        XCTAssertEqual(packages.count, 2, "precondition: both instances' R1 are placed")
        XCTAssertNil(HorizontalSpotlightFraming.boardRect(board, netIDs: [], componentIDs: [r1]), "by the block's id no package is it")
        let rect = try XCTUnwrap(HorizontalSpotlightFraming.boardRect(
            board, netIDs: [], componentIDs: flattened.boardComponentIDs(for: [r1])
        ))
        for package in packages {
            XCTAssertTrue(rect.minX <= package.position.x && package.position.x <= rect.maxX
                          && rect.minY <= package.position.y && package.position.y <= rect.maxY,
                          "\(package.label) at \(package.position) in \(rect)")
        }
    }
}
