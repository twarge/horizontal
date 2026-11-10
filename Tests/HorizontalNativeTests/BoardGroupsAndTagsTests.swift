import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// The board rail's Groups and Tags: Set group and Set tag on the selected
/// parts, Rename and Clear a group or tag, the members Highlight shows, and
/// Copy placement from one group to another whose parts share its tags.
/// Each is one batch of set_group_tag (or copy_group_layout), one undo step.
final class BoardGroupsAndTagsTests: XCTestCase {
    private var fixture: SchematicProjectEditFixture!
    private var ids: [String: String] = [:]

    /// Two copies of a two-resistor circuit on the board: R1 and R2, R3 and
    /// R4, laid out differently.
    override func setUpWithError() throws {
        fixture = try SchematicProjectEditFixture(testCase: self)
        try fixture.apply([
            ["op": "ensure_component", "refdes": "R1", "part": fixture.part],
            ["op": "ensure_component", "refdes": "R2", "part": fixture.part],
            ["op": "ensure_component", "refdes": "R3", "part": fixture.part],
            ["op": "ensure_component", "refdes": "R4", "part": fixture.part],
            ["op": "place_component", "component": "R1", "x_mm": 10, "y_mm": 10],
            ["op": "place_component", "component": "R2", "x_mm": 15, "y_mm": 10],
            ["op": "place_component", "component": "R3", "x_mm": 50, "y_mm": 30],
            ["op": "place_component", "component": "R4", "x_mm": 70, "y_mm": 40],
        ])
        for (id, component) in try fixture.blockJSON().dictionaryMap("components") {
            ids[component.string("refdes") ?? ""] = id.lowercased()
        }
    }

    private var groupTags: HorizontalGroupTags {
        get throws { HorizontalGroupTags(block: try fixture.blockJSON()) }
    }

    private func set(_ refdes: [String]) -> Set<String> { Set(refdes.compactMap { ids[$0] }) }

    private func position(_ refdes: String) throws -> HorizontalPoint {
        try XCTUnwrap(fixture.project.board?.packages.first { $0.componentID?.lowercased() == ids[refdes] }).position
    }

    private func groupAndTag() throws {
        let edits: [[JSONDictionary]] = [
            try groupTags.settingGroup("A", of: set(["R1", "R2"])),
            try groupTags.settingGroup("B", of: set(["R3", "R4"])),
        ]
        for ops in edits { try fixture.apply(ops) }
        try fixture.apply(try groupTags.settingTag("T1", of: set(["R1", "R3"])))
        try fixture.apply(try groupTags.settingTag("T2", of: set(["R2", "R4"])))
    }

    func testSettingAGroupThenATagKeepsBothAndTheListsShowTheirMembers() throws {
        let ops = try groupTags.settingGroup(" A ", of: set(["R1", "R2"]))
        XCTAssertEqual(ops.count, 2, "one set_group_tag a part, in one batch")
        try groupAndTag()
        let groups = try groupTags.groups
        XCTAssertEqual(groups.map(\.name), ["A", "B"])
        XCTAssertEqual(groups.first?.refdesList, "R1, R2")
        XCTAssertEqual(groups.first?.memberIDs, set(["R1", "R2"]), "what Highlight shows")
        XCTAssertEqual(try groupTags.tags.map(\.name), ["T1", "T2"])
        XCTAssertEqual(try groupTags.tags.first?.refdesList, "R1, R3")
        XCTAssertEqual(try groupTags.settingGroup("A", of: set(["R1"])).count, 0, "already in it")
    }

    func testRenamingAGroupKeepsItsMembersAndTheirTagsAndClearingItLeavesTheTags() throws {
        try groupAndTag()
        let a = try XCTUnwrap(try groupTags.groups.first { $0.name == "A" })
        try fixture.apply(try groupTags.renamingGroup(a.id, to: "Left"))
        XCTAssertEqual(try groupTags.groups.map(\.name), ["B", "Left"])
        XCTAssertEqual(try groupTags.groups.first { $0.name == "Left" }?.memberIDs, set(["R1", "R2"]))
        XCTAssertEqual(try groupTags.tags.first { $0.name == "T1" }?.memberIDs, set(["R1", "R3"]), "tags kept")

        let b = try XCTUnwrap(try groupTags.groups.first { $0.name == "B" })
        try fixture.apply(try groupTags.clearingGroup(b.id))
        XCTAssertEqual(try groupTags.groups.map(\.name), ["Left"])
        XCTAssertEqual(try groupTags.tags.map(\.memberIDs), [set(["R1", "R3"]), set(["R2", "R4"])])

        let t2 = try XCTUnwrap(try groupTags.tags.first { $0.name == "T2" })
        try fixture.apply(try groupTags.renamingTag(t2.id, to: "Pull-up"))
        XCTAssertEqual(try groupTags.tags.map(\.name), ["Pull-up", "T1"])
        // Renamed, the tag is the one of that name, as set_group_tag names it.
        let pullUp = try XCTUnwrap(try groupTags.tags.first { $0.name == "Pull-up" })
        XCTAssertEqual(pullUp.memberIDs, set(["R2", "R4"]))
        try fixture.apply(try groupTags.clearingTag(pullUp.id))
        XCTAssertEqual(try groupTags.tags.map(\.name), ["T1"])
    }

    func testCopyLayoutPlacesTheTargetGroupAsTheSourceIsAboutTheirFirstSharedTag() throws {
        try groupAndTag()
        let a = try XCTUnwrap(try groupTags.groups.first { $0.name == "A" })
        let b = try XCTUnwrap(try groupTags.groups.first { $0.name == "B" })
        XCTAssertEqual(try groupTags.copyTargets(for: a.id).map(\.id), [b.id])

        let anchor = try position("R3")
        try fixture.apply([try groupTags.copyingLayout(from: a.id, to: b.id, includeRouting: false)])
        XCTAssertEqual(try position("R3"), anchor, "the anchor stays where it was")
        let r1 = try position("R1"), r2 = try position("R2"), r3 = try position("R3"), r4 = try position("R4")
        XCTAssertEqual(r4.x - r3.x, r2.x - r1.x, accuracy: 1)
        XCTAssertEqual(r4.y - r3.y, r2.y - r1.y, accuracy: 1)
    }
}
