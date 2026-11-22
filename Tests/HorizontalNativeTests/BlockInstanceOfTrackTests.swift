import XCTest
import HorizontalProjectIO
@testable import HorizontalNative
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// A track or a via is in the block instance whose pads its copper joins, so
/// Select Instance and Copy Layout to Other Instances are offered from it as
/// they are from one of the instance's parts. The board is
/// `BlockLayoutFixture`'s: each instance's R1, R2 and R3 in a row 5 mm apart,
/// pads at ±0.75 mm, I2 20 mm right of I1.
final class BlockInstanceOfTrackTests: XCTestCase {
    private var fixture: BlockLayoutFixture!
    private let mm = 1_000_000.0

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func junction(_ number: Int) -> String { "a0000000-0000-4000-8000-00000000000\(number)" }
    private func track(_ number: Int) -> String { "b0000000-0000-4000-8000-00000000000\(number)" }
    private func via(_ number: Int) -> String { "c0000000-0000-4000-8000-00000000000\(number)" }

    private func at(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * mm, y: y * mm)
    }

    /// I1's R1 joined to its R2 over a via, a stub off R1 that turns a corner,
    /// a track from I1's R3 to I2's R1, and a track and a via on no pad.
    private func addCopper() throws {
        let (i1, i2) = (fixture.instances[0], fixture.instances[1])
        try fixture.addCopper(
            junctions: [junction(1): at(2.5, 2), junction(2): at(-3, 0), junction(3): at(-3, 3),
                        junction(4): at(40, 30), junction(5): at(45, 30)],
            tracks: [
                track(1): (try fixture.padEnd(i1, "R1", 2), fixture.junctionEnd(junction(1)), 0),
                track(2): (fixture.junctionEnd(junction(1)), try fixture.padEnd(i1, "R2", 1), 0),
                track(3): (try fixture.padEnd(i1, "R1", 1), fixture.junctionEnd(junction(2)), 0),
                track(4): (fixture.junctionEnd(junction(2)), fixture.junctionEnd(junction(3)), 0),
                track(5): (try fixture.padEnd(i1, "R3", 2), try fixture.padEnd(i2, "R1", 1), 0),
                track(6): (fixture.junctionEnd(junction(4)), fixture.junctionEnd(junction(5)), 0),
            ],
            vias: [via(1): junction(1), via(2): junction(4)]
        )
    }

    func testATrackOrViaIsInTheInstanceWhosePadsItsCopperJoins() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try addCopper()
        let match = try fixture.match()
        for number in 1...3 {
            XCTAssertEqual(match.instance(ofTrack: track(number))?.name, "I1", "track \(number), on I1's pads")
        }
        XCTAssertEqual(match.instance(ofTrack: track(4))?.name, "I1", "the stub's far leg, which touches no pad itself")
        XCTAssertEqual(match.instance(ofTrack: track(2).uppercased())?.name, "I1", "an id in either case")
        XCTAssertEqual(match.instance(ofVia: via(1))?.name, "I1")
        XCTAssertNil(match.instance(ofTrack: track(5)), "a track two instances share is neither's")
        XCTAssertNil(match.instance(ofTrack: track(6)), "copper on no pad")
        XCTAssertNil(match.instance(ofVia: via(2)))
        XCTAssertNil(match.instance(ofTrack: "no such track"))
    }

    /// The instance's wiring to a part outside its block is still a track on
    /// the instance's pad, though not copper Copy Layout carries over.
    func testATrackOnToAPartOfNoBlockIsTheInstances() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        let i1 = fixture.instances[0]
        let connector = try XCTUnwrap(try fixture.apply([
            ["op": "ensure_component", "refdes": "J1", "part": fixture.partID],
        ]).first?["component"] as? String)
        try fixture.apply([["op": "place_component", "component": connector, "x_mm": 10, "y_mm": 10]])
        let package = try fixture.package(of: connector).id
        try fixture.addCopper(tracks: [
            track(1): (try fixture.padEnd(i1, "R3", 2), ["junc": NSNull(), "pad": "\(package)/\(fixture.padIDs[0])"], 0),
        ])
        let match = try fixture.match()
        XCTAssertEqual(match.instance(ofTrack: track(1))?.name, "I1")
        XCTAssertFalse(match.owned(fixture.path(0)).tracks.contains(track(1)), "it reaches a pad outside I1")
    }

    /// Channel uses Sub as S1: a track from S1's resistor to one of Channel's
    /// own is the Channel instance's, and one on S1's resistor alone is S1's.
    func testATrackBetweenABlockAndABlockInsideItIsTheOuterInstances() throws {
        fixture = try BlockLayoutFixture(instances: 2, nested: true)
        let i1 = fixture.instances[0]
        let inner = try fixture.package(of: fixture.nestedFlat(i1)).id
        func innerPad(_ number: Int) -> JSONDictionary {
            ["junc": NSNull(), "pad": "\(inner)/\(fixture.padIDs[number - 1])"]
        }
        try fixture.addCopper(
            junctions: [junction(1): at(-3, 5)],
            tracks: [
                track(1): (innerPad(2), try fixture.padEnd(i1, "R1", 2), 0),
                track(2): (innerPad(1), fixture.junctionEnd(junction(1)), 0),
            ]
        )
        let match = try fixture.match()
        XCTAssertEqual(match.instance(ofTrack: track(1))?.name, "I1")
        XCTAssertEqual(match.instance(ofTrack: track(2))?.name, "I1/S1")
    }

    /// What the inspector and the menus go by: the instances a selection is
    /// in, its tracks and vias counted with its parts.
    func testASelectionOfTracksNamesTheirInstance() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try addCopper()
        let match = try fixture.match()
        typealias Summary = HorizontalBlockInstanceSummary
        let leg = HorizontalSelectableRef(id: track(4), type: .track, layer: 0)
        let onVia = HorizontalSelectableRef(id: via(1), type: .via)
        let shared = HorizontalSelectableRef(id: track(5), type: .track, layer: 0)
        let other = HorizontalSelectableRef(id: try fixture.packageID(fixture.instances[1], "R2"), type: .boardPackage)

        let one = Summary.instances(of: [leg, onVia, shared], in: match)
        XCTAssertEqual(one.map(\.name), ["I1"])
        XCTAssertEqual(Summary.copperDetails(for: one, in: match).map { "\($0.label): \($0.value)" }, ["Block instance: I1 of Channel"])

        let two = Summary.instances(of: [other, leg], in: match)
        XCTAssertEqual(two.map(\.name), ["I1", "I2"])
        XCTAssertEqual(Summary.copperDetails(for: two, in: match).map { "\($0.label): \($0.value)" }, ["Block instances: I1, I2 of Channel"])

        XCTAssertTrue(Summary.instances(of: [shared, HorizontalSelectableRef(id: junction(1), type: .junction)], in: match).isEmpty)
        XCTAssertTrue(Summary.copperDetails(for: [], in: match).isEmpty)
    }

    /// The right-click on a track or via of an instance offers what the
    /// right-click on one of its parts does.
    func testTheRightClickOnATrackOfAnInstanceOffersCopyLayout() throws {
        fixture = try BlockLayoutFixture(instances: 2)
        try addCopper()
        let match = try fixture.match()
        func titles(_ ref: HorizontalSelectableRef, writable: Bool = true) -> [String] {
            HorizontalBlockInstanceSummary.menuEntries(for: ref, in: match, writable: writable).compactMap { entry in
                if case .command(let title, _) = entry { return title }
                return nil
            }
        }
        let offered = ["Select Instance", "Copy Layout to Other Instances"]
        XCTAssertEqual(titles(HorizontalSelectableRef(id: track(4), type: .track, layer: 0)), offered)
        XCTAssertEqual(titles(HorizontalSelectableRef(id: via(1), type: .via)), offered)
        XCTAssertEqual(titles(HorizontalSelectableRef(id: try fixture.packageID(fixture.instances[0], "R1"), type: .boardPackage)), offered)
        XCTAssertEqual(titles(HorizontalSelectableRef(id: track(1), type: .track, layer: 0), writable: false), ["Select Instance"],
                       "a locked board copies nothing")
        XCTAssertEqual(titles(HorizontalSelectableRef(id: track(5), type: .track, layer: 0)), [], "a track two instances share")
        XCTAssertEqual(titles(HorizontalSelectableRef(id: track(6), type: .track, layer: 0)), [], "copper on no pad")
    }
}

#if os(macOS)
/// On a mounted board canvas with a track on an instance's pads selected and
/// nothing else, Copy Block Layout to Other Instances is offered, the
/// inspector's track group says which instance and has the button, and the
/// copy lays the track out in the other instance as one undo step.
@MainActor
final class BlockInstanceOfTrackCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var board: HorizontalBoard
        @Published var command: HorizontalSelectionPropertyChangeCommand?
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
        var details = HorizontalSelectionDetailState.empty
        let instances: HorizontalBoardBlockInstances
        let settings: HorizontalSelectionToolSettings
        let undo = UndoManager()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard, instances: HorizontalBoardBlockInstances, settings: HorizontalSelectionToolSettings) {
            self.board = board
            self.instances = instances
            self.settings = settings
        }
    }

    private struct Pane: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: state.board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                selectionToolSettings: state.settings,
                onBoardChange: { state.committed.append($0); state.board = $0 },
                blockInstances: state.instances,
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.command,
                toolSettings: state.toolSettings)
        }
    }

    private var fixture: BlockLayoutFixture!
    private let mm = 1_000_000.0
    private let trackID = "b0000000-0000-4000-8000-000000000001"

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// The fixture's board with one track, from I1's R1 to `end`, on a
    /// mounted canvas whose Select All takes tracks alone, the track selected.
    private func mount(trackTo end: (BlockLayoutFixture) throws -> JSONDictionary) async throws -> (state: State, window: NSWindow) {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        fixture = try BlockLayoutFixture(instances: 2)
        try fixture.addCopper(tracks: [trackID: (try fixture.padEnd(fixture.instances[0], "R1", 2), try end(fixture), 0)])
        var settings = HorizontalSelectionToolSettings()
        settings.boardFilter.only(.tracks)
        let state = State(try fixture.board, instances: try XCTUnwrap(fixture.project.flattenedBlock).boardInstances, settings: settings)
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Pane(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.details.groups.map(\.type) == [.track] }
        XCTAssertTrue(selected, "the track alone: \(state.details.groups.map(\.title))")
        return (state, window)
    }

    /// The tracks between pad 2 of `from` and pad 1 of `to` in instance `index`.
    private func tracks(_ index: Int, _ from: String, _ to: String, in board: HorizontalBoard?) throws -> [HorizontalSegment] {
        let instance = fixture.instances[index]
        let a = try XCTUnwrap(board?.packages.first { $0.componentID?.lowercased() == fixture.flat(instance, from) }).position
        let b = try XCTUnwrap(board?.packages.first { $0.componentID?.lowercased() == fixture.flat(instance, to) }).position
        let ends = [HorizontalPoint(x: a.x + 0.75 * mm, y: a.y), HorizontalPoint(x: b.x - 0.75 * mm, y: b.y)]
        func near(_ p: HorizontalPoint, _ q: HorizontalPoint) -> Bool { abs(p.x - q.x) <= 2 && abs(p.y - q.y) <= 2 }
        return (board?.tracks ?? []).filter {
            (near($0.from, ends[0]) && near($0.to, ends[1])) || (near($0.from, ends[1]) && near($0.to, ends[0]))
        }
    }

    func testATrackOnAnInstancesPadsOffersCopyLayoutAndCopiesIt() async throws {
        let (state, window) = try await mount { try $0.padEnd($0.instances[0], "R2", 1) }
        defer { window.close() }
        let offered = await settle { state.actions?.canCopyBlockLayout == true }
        XCTAssertTrue(offered, "Copy Block Layout to Other Instances, from the track")
        XCTAssertEqual(state.actions?.canSelectBlockInstance, true)

        let group = try XCTUnwrap(state.details.groups.first { $0.type == .track })
        XCTAssertEqual(group.summary.last.map { "\($0.label): \($0.value)" }, "Block instance: I1 of Channel")
        XCTAssertEqual(group.actions.map(\.id), [HorizontalBlockInstanceSummary.selectActionID, HorizontalBlockInstanceSummary.copyLayoutActionID])

        XCTAssertEqual(try tracks(1, "R1", "R2", in: state.board).count, 0, "I2 has no track yet")
        state.actions?.dispatch(.copyBlockLayout)
        let copied = await settle { state.committed.count == 1 }
        XCTAssertTrue(copied)
        XCTAssertEqual(try tracks(1, "R1", "R2", in: state.committed.last).count, 1, "I2's R1 joined to its R2 as I1's is")
        XCTAssertEqual(try tracks(0, "R1", "R2", in: state.committed.last).count, 1, "I1's stays")

        state.undo.undo()
        let undone = await settle { state.committed.count == 2 }
        XCTAssertTrue(undone)
        XCTAssertEqual(state.committed.last?.tracks.count, 1, "one undo step takes the copy back")
    }

    /// The track group's own button copies from the tracks' instance.
    func testTheTrackGroupsButtonCopiesTheLayout() async throws {
        let (state, window) = try await mount { try $0.padEnd($0.instances[0], "R2", 1) }
        defer { window.close() }
        let group = try XCTUnwrap(state.details.groups.first { $0.type == .track })
        let item = try XCTUnwrap(group.items.first)
        state.command = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: item.ref, type: .track, propertyID: HorizontalBlockInstanceSummary.copyLayoutActionID,
            value: .bool(true), applyToAll: true))
        let copied = await settle { state.committed.count == 1 }
        XCTAssertTrue(copied)
        XCTAssertEqual(try tracks(1, "R1", "R2", in: state.committed.last).count, 1)
    }

    /// A track from one instance to another is in neither, so there is no
    /// one layout to copy.
    func testATrackTwoInstancesShareOffersNothing() async throws {
        let (state, window) = try await mount { try $0.padEnd($0.instances[1], "R1", 1) }
        defer { window.close() }
        let asked = await settle { state.actions?.canCopySelection == true }
        XCTAssertTrue(asked, "the track is selected")
        XCTAssertEqual(state.actions?.canCopyBlockLayout, false)
        XCTAssertEqual(state.actions?.canSelectBlockInstance, false)
        let group = try XCTUnwrap(state.details.groups.first { $0.type == .track })
        XCTAssertFalse(group.summary.contains { $0.label.hasPrefix("Block instance") })
        XCTAssertTrue(group.actions.isEmpty)
    }
}
#endif
