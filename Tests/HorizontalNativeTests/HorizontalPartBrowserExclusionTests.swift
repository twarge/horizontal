import Foundation
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The Parts pane leaves out what isn't bought for the board: parts flagged
/// exclude from BOM, and parts only Do Not Populate components use.
final class HorizontalPartBrowserExclusionTests: XCTestCase {
    func testAPartOnlyDoNotPopulateComponentsUseIsNotPopulated() throws {
        let block: JSONDictionary = [
            "type": "block",
            "uuid": "block-1",
            "components": [
                "c1": ["part": "PART-A", "refdes": "R1"],
                "c2": ["part": "part-b", "refdes": "R2", "nopopulate": true],
                "c3": ["part": "part-c", "refdes": "R3", "nopopulate": true],
                "c4": ["part": "part-c", "refdes": "R4", "nopopulate": false]
            ]
        ]
        var archive = HorizontalProjectArchive(root: .directory([:]))
        try archive.replaceRegularFileData(relativePath: "blocks/block.json", with: JSONSerialization.data(withJSONObject: block))

        XCTAssertEqual(HorizontalPoolCacheUpdater.populatedPartIDs(in: archive), ["part-a", "part-c"],
                       "a part one fitted component uses is populated, whatever its others are")
        XCTAssertEqual(Set(HorizontalPoolCacheUpdater.references(in: archive).keys), ["part-a", "part-b", "part-c"])
    }

    func testTheTogglesHideTestPadsAndDoNotPopulateParts() {
        let resistor = part("resistor")
        var testPad = part("test-pad")
        testPad.excludeFromBOM = true
        let fittedNowhere = part("dnp")
        let unused = part("unused")
        let used: Set<String> = ["resistor", "test-pad", "dnp"]
        let populated: Set<String> = ["resistor", "test-pad"]

        func hidden(populated: Set<String>?, excluded: Bool) -> [String] {
            [resistor, testPad, fittedNowhere, unused]
                .filter { HorizontalPartBrowserView.isHidden($0, used: used, populated: populated, hidesExcludedFromBOM: excluded) }
                .map(\.id)
        }
        XCTAssertEqual(hidden(populated: populated, excluded: true), ["test-pad", "dnp"],
                       "a part no component uses isn't Do Not Populate")
        XCTAssertEqual(hidden(populated: populated, excluded: false), ["dnp"])
        XCTAssertEqual(hidden(populated: nil, excluded: true), ["test-pad"], "nil hides nothing for Do Not Populate")
        XCTAssertEqual(hidden(populated: nil, excluded: false), [])
    }

    private func part(_ id: String) -> HorizontalPoolPart {
        HorizontalPoolPart(id: id, mpn: id.uppercased(), manufacturer: "", partDescription: "", packageName: "", tags: [],
                           value: "", displayValue: id, entityID: nil, refdesPrefix: "R", gates: [])
    }
}
