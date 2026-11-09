#if os(macOS)
import AppKit
import HorizontalProjectIO
import SwiftUI
import XCTest
@testable import HorizontalNative

/// A board polygon's plane or keepout in the sidebar, as Horizon's polygon
/// has them: Define Plane… and Define Keepout… under a plain polygon's
/// details; a plane's settings in its outline's Plane section, ending in
/// Delete Plane Definition; a keepout's options, ending in Delete Keepout
/// Definition, in its polygon's Keepout section: a keepout's polygon stays a
/// polygon to pick, move and reshape. Define Keepout… makes the keepout at
/// once, and the writer the document saves with puts a keepout new to the
/// file in it.
@MainActor
final class BoardPlaneKeepoutSidebarTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        @Published var change: HorizontalSelectionPropertyChangeCommand?
        var source: HorizontalBoard
        var committed: [HorizontalBoard] = []
        var planeEdits: [(board: HorizontalBoard, actionName: String)] = []
        var actions: HorizontalCanvasCommandActions?
        var details: HorizontalSelectionDetailState = .empty
        var sidebarShown = 0
        let undo: UndoManager = {
            let undo = UndoManager()
            undo.groupsByEvent = false
            return undo
        }()
        let toolSettings = HorizontalBoardToolSettings()
        init(_ board: HorizontalBoard) { source = board }
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        init(state: State) {
            self.state = state
            _board = SwiftUI.State(initialValue: state.source)
        }
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), undoManager: state.undo,
                onBoardChange: { state.committed.append($0); board = $0 },
                onPlaneEdit: { state.planeEdits.append(($0, $1)); board = $0 },
                onSelectionDetailsChange: { state.details = $0 },
                onCanvasCommandActionsChange: { state.actions = $0 },
                selectionPropertyChangeCommand: state.change,
                onShowSelectionDetails: { state.sidebarShown += 1 },
                toolSettings: state.toolSettings)
        }
    }

    private let mm = 1_000_000.0
    private var project: HorizontalProject!
    private var archive: HorizontalProjectArchive!

    private func square(_ cx: Double, _ cy: Double, half: Double) -> [HorizontalPoint] {
        [
            HorizontalPoint(x: cx - half, y: cy - half), HorizontalPoint(x: cx + half, y: cy - half),
            HorizontalPoint(x: cx + half, y: cy + half), HorizontalPoint(x: cx - half, y: cy + half),
        ]
    }

    /// The template project's board with a top-copper polygon and one on the
    /// top silkscreen, written to its file, and a GND net; with `plane`, the
    /// copper one a GND plane.
    private func fixture(plane: Bool = false) throws -> HorizontalBoard {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("horizontal-plane-keepout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Untitled.horizontal")
        try HorizontalProjectArchive.newProject(blankBoard: true).write(to: url)
        project = try HorizontalProject.load(from: url)
        archive = try HorizontalProjectArchive.completeProject(from: url)

        var board = try XCTUnwrap(project.board)
        board.netDetails["gnd"] = HorizontalNetDetails(id: "gnd", name: "GND")
        let pour = HorizontalPolygon(id: "pour", vertices: square(10 * mm, 10 * mm, half: 10 * mm), layer: HorizontalBoardLayers.topCopper)
        let silk = HorizontalPolygon(id: "silk", vertices: square(40 * mm, 10 * mm, half: 5 * mm), layer: HorizontalBoardLayers.topSilkscreen)
        if plane {
            board.planes.append(HorizontalPlane(polygon: pour, draft: HorizontalPlaneEditorDraft(netID: "gnd")))
            board.polygons.append(silk)
        } else {
            board.polygons += [pour, silk]
        }
        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        return board
    }

    private func written(_ key: String) throws -> [String: [String: Any]] {
        let data = try XCTUnwrap(archive.regularFileData(relativePath: "board.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var map = [String: [String: Any]]()
        for (id, value) in json[key] as? [String: Any] ?? [:] {
            map[id.lowercased()] = value as? [String: Any] ?? [:]
        }
        return map
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func mount(_ state: State) async throws -> NSWindow {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        // Every edit in one undo group, as an event would open one.
        state.undo.beginUndoGrouping()
        addTeardownBlock { @MainActor in state.undo.endUndoGrouping() }
        return window
    }

    /// Everything selected, and the sidebar item of `polygonID`'s first edge.
    private func edgeItem(_ state: State, _ polygonID: String) async -> HorizontalSelectionDetailItem? {
        state.actions?.dispatch(.selectAll)
        _ = await settle { state.details.groups.contains { $0.type == .polygonEdge } }
        return item(state, .polygonEdge, polygonID)
    }

    private func item(_ state: State, _ type: HorizontalObjectType, _ id: String) -> HorizontalSelectionDetailItem? {
        state.details.groups.first { $0.type == type }?.items.first { $0.ref.id.lowercased() == id.lowercased() }
    }

    private func send(_ state: State, _ ref: HorizontalSelectableRef, _ propertyID: String, _ value: HorizontalSelectionPropertyValue) {
        state.change = HorizontalSelectionPropertyChangeCommand(change: HorizontalSelectionPropertyChange(
            ref: ref, type: ref.type, propertyID: propertyID, value: value, applyToAll: false))
    }

    private func edge(_ id: String, layer: Int = HorizontalBoardLayers.topCopper) -> HorizontalSelectableRef {
        HorizontalSelectableRef(id: id, type: .polygonEdge, vertex: 0, layer: layer)
    }

    // MARK: - A polygon

    func testAPolygonOffersDefinePlaneAndDefineKeepoutBelowItsDetails() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        let pour = await edgeItem(state, "pour")
        let actions = pour?.properties.filter { $0.editor == .action }
        XCTAssertEqual(actions?.map(\.id), ["definePlane", "defineKeepout"])
        XCTAssertEqual(actions?.map(\.label), ["Define Plane…", "Define Keepout…"])
        XCTAssertEqual(pour?.properties.suffix(2).map(\.id), ["definePlane", "defineKeepout"], "below its details")
        XCTAssertEqual(pour?.properties.first { $0.id == "usage" }?.value, .readOnly("Polygon"))
        XCTAssertEqual(item(state, .polygonEdge, "silk")?.properties.filter { $0.editor == .action }.map(\.id), ["defineKeepout"],
                       "a plane is poured on copper only")
    }

    // MARK: - A keepout

    /// The pour polygon's item, once the sidebar shows it so.
    private func pourItem(_ state: State, usage: String) async -> HorizontalSelectionDetailItem? {
        _ = await settle {
            self.item(state, .polygonEdge, "pour")?.properties.first { $0.id == "usage" }?.value == .readOnly(usage)
        }
        return item(state, .polygonEdge, "pour")
    }

    func testDefineKeepoutMakesTheKeepoutAtOnceAndTheFileHasIt() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        send(state, edge("pour"), "defineKeepout", .bool(true))
        let defined = await settle { state.committed.last?.keepouts.count == 1 }
        XCTAssertTrue(defined)
        let board = try XCTUnwrap(state.committed.last)
        let keepout = try XCTUnwrap(board.keepouts.first)
        XCTAssertEqual(keepout.polygonID, "pour")
        XCTAssertEqual(keepout.polygon.layer, HorizontalBoardLayers.topCopper)
        XCTAssertFalse(keepout.allCopperLayers, "on its polygon's copper layer")
        XCTAssertFalse(keepout.exposedCopperOnly)
        XCTAssertEqual(keepout.copperPatchTypes, ["track", "pad", "pad_th", "via", "plane", "hole_pth"])
        XCTAssertFalse(board.polygons.contains { $0.id == "pour" }, "the keepout holds its polygon, as the board loads one")
        XCTAssertTrue(state.planeEdits.isEmpty, "a board edit as any other")
        XCTAssertEqual(state.sidebarShown, 1, "the sidebar opens on it")

        // The polygon stays selected, a polygon with a Keepout section.
        let shown = await pourItem(state, usage: "Keepout")
        let pour = try XCTUnwrap(shown, "\(state.details.groups.map(\.type))")
        XCTAssertFalse(pour.properties.contains { $0.id == "definePlane" || $0.id == "defineKeepout" }, "a keepout already")
        let section = pour.properties.filter { $0.section == "Keepout" }
        XCTAssertEqual(section.map(\.id), [
            "keepout.keepoutClass", "keepout.allCopperLayers", "keepout.exposedCopperOnly",
            "keepout.patch.track", "keepout.patch.pad", "keepout.patch.pad_th", "keepout.patch.via", "keepout.patch.plane",
            "keepout.patch.text", "keepout.patch.net_tie", "keepout.patch.hole_pth", "keepout.patch.hole_npth",
            "deleteKeepoutDefinition",
        ])
        XCTAssertEqual(section.filter { $0.id.hasPrefix("keepout.patch.") && $0.value == .bool(true) }.count, 6)
        XCTAssertEqual(section.last?.editor, .action, "Delete Keepout Definition at the bottom")
        XCTAssertEqual(pour.properties.last?.id, "deleteKeepoutDefinition")
        XCTAssertTrue(pour.openSections.contains("Keepout"))

        try HorizontalProjectJSONApplicator.apply(board: board, in: project, to: &archive)
        let entry = try XCTUnwrap(try written("keepouts")[keepout.id], "a keepout new to the file is written")
        XCTAssertEqual(entry["polygon"] as? String, "pour")
        XCTAssertEqual(entry["keepout_class"] as? String, "")
        XCTAssertEqual(entry["all_cu_layers"] as? Bool, false)
        XCTAssertEqual(entry["exposed_cu_only"] as? Bool, false)
        XCTAssertEqual(entry["patch_types_cu"] as? [String], keepout.copperPatchTypes)
        XCTAssertNotNil(try written("polygons")["pour"], "with its polygon")

        // Its options, in the polygon's Keepout section.
        send(state, edge("pour"), "keepout.patch.via", .bool(false))
        let noVias = await settle { state.committed.last?.keepouts.first?.copperPatchTypes.contains("via") == false }
        XCTAssertTrue(noVias)
        send(state, edge("pour"), "keepout.patch.text", .bool(true))
        let text = await settle { state.committed.last?.keepouts.first?.copperPatchTypes.contains("text") == true }
        XCTAssertTrue(text)
        XCTAssertEqual(state.committed.last?.keepouts.first?.copperPatchTypes,
                       ["track", "pad", "pad_th", "plane", "text", "hole_pth"], "in the order the sidebar lists them")
        send(state, edge("pour"), "keepout.allCopperLayers", .bool(true))
        let all = await settle { state.committed.last?.keepouts.first?.allCopperLayers == true }
        XCTAssertTrue(all)
        send(state, edge("pour"), "keepout.keepoutClass", .text("antenna"))
        let named = await settle { state.committed.last?.keepouts.first?.keepoutClass == "antenna" }
        XCTAssertTrue(named)
        // And its polygon's, as any polygon's.
        send(state, edge("pour"), "layer", .layer(HorizontalBoardLayers.bottomCopper))
        let moved = await settle { state.committed.last?.keepouts.first?.polygon.layer == HorizontalBoardLayers.bottomCopper }
        XCTAssertTrue(moved, "the keepout's polygon takes the layer")
        let edited = try XCTUnwrap(state.committed.last)
        XCTAssertFalse(edited.polygons.contains { $0.id == "pour" })
        try HorizontalProjectJSONApplicator.apply(board: edited, in: project, to: &archive)
        let rewritten = try XCTUnwrap(try written("keepouts")[keepout.id])
        XCTAssertEqual(rewritten["all_cu_layers"] as? Bool, true)
        XCTAssertEqual(rewritten["keepout_class"] as? String, "antenna")
        XCTAssertEqual(rewritten["patch_types_cu"] as? [String], ["track", "pad", "pad_th", "plane", "text", "hole_pth"])
        XCTAssertEqual(try written("polygons")["pour"]?["layer"] as? Int, HorizontalBoardLayers.bottomCopper)

        // Delete Keepout Definition leaves the polygon a polygon, selected.
        let count = state.committed.count
        send(state, edge("pour"), "deleteKeepoutDefinition", .bool(true))
        let deleted = await settle { state.committed.count > count && state.committed.last?.keepouts.isEmpty == true }
        XCTAssertTrue(deleted)
        let after = try XCTUnwrap(state.committed.last)
        XCTAssertTrue(after.polygons.contains { $0.id == "pour" }, "the polygon is the board's again")
        let polygon = await pourItem(state, usage: "Polygon")
        XCTAssertEqual(polygon?.properties.filter { $0.editor == .action }.map(\.id), ["definePlane", "defineKeepout"],
                       "and selected, to define again")
        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertNil(try written("keepouts")[keepout.id], "the keepout is gone from the file")
        XCTAssertNotNil(try written("polygons")["pour"], "and its polygon is not")
    }

    func testDefineKeepoutOnAPolygonOffCopperKeepsOutAllCopper() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        // Define Plane… sent for it anyway selects it and pours no plane off
        // copper; then the context menu's Define Keepout…, on that selection.
        send(state, edge("silk", layer: HorizontalBoardLayers.topSilkscreen), "definePlane", .bool(true))
        let selected = await settle { self.item(state, .polygonEdge, "silk") != nil && state.details.groups.count == 1 }
        XCTAssertTrue(selected)
        XCTAssertTrue(state.planeEdits.isEmpty, "no plane off copper")
        state.actions?.dispatch(.defineKeepout)
        let defined = await settle { state.committed.last?.keepouts.count == 1 }
        XCTAssertTrue(defined, "Define Keepout… on the selected polygon")
        let keepout = try XCTUnwrap(state.committed.last?.keepouts.first)
        XCTAssertEqual(keepout.polygonID, "silk")
        XCTAssertTrue(keepout.allCopperLayers, "a keepout on no copper keeps out all of it")
    }

    /// A keepout's polygon is picked and moved as any polygon, and the file
    /// has it where it went; its polygon deleted, the keepout goes with it.
    func testAKeepoutsPolygonMovesAndDeletesAsAPolygon() async throws {
        let state = State(try fixture())
        let window = try await mount(state)
        defer { window.close() }

        send(state, edge("pour"), "defineKeepout", .bool(true))
        let defined = await settle { state.committed.last?.keepouts.count == 1 }
        XCTAssertTrue(defined)
        let keepout = try XCTUnwrap(state.committed.last?.keepouts.first)
        state.actions?.dispatch(.selectAll)
        let picked = await settle { self.item(state, .polygonEdge, "pour") != nil && self.item(state, .polygonVertex, "pour") != nil }
        XCTAssertTrue(picked, "its polygon's edges and vertices: \(state.details.groups.map(\.type))")
        XCTAssertFalse(state.details.groups.contains { $0.type == .keepout }, "not a keepout picked whole")

        let count = state.committed.count
        state.actions?.dispatch(.deleteSelection)
        let deleted = await settle { state.committed.count > count }
        XCTAssertTrue(deleted)
        let after = try XCTUnwrap(state.committed.last)
        XCTAssertTrue(after.keepouts.isEmpty, "the keepout goes with its polygon")
        XCTAssertTrue(after.removedKeepoutIDs.contains(keepout.id))
        try HorizontalProjectJSONApplicator.apply(board: after, in: project, to: &archive)
        XCTAssertNil(try written("keepouts")[keepout.id])
        XCTAssertNil(try written("polygons")["pour"])
    }

    // MARK: - A plane

    func testAPlanesPolygonHasItsPlaneSectionEndingInDeletePlaneDefinition() async throws {
        let board = try fixture(plane: true)
        let state = State(board)
        let window = try await mount(state)
        defer { window.close() }

        let item = await edgeItem(state, "pour")
        let pour = try XCTUnwrap(item)
        XCTAssertEqual(pour.properties.first { $0.id == "usage" }?.value, .readOnly("Plane"))
        XCTAssertFalse(pour.properties.contains { $0.id == "definePlane" || $0.id == "defineKeepout" }, "a plane already")
        let section = pour.properties.filter { $0.section == "Plane" }
        XCTAssertTrue(section.allSatisfy { $0.id.hasPrefix("plane.") || $0.id == "deletePlaneDefinition" })
        for id in ["plane.net", "plane.priority", "plane.fromRules", "plane.minWidth", "plane.style", "plane.keepOrphans",
                   "plane.textStyle", "plane.connectStyle", "plane.fill"] {
            XCTAssertTrue(section.contains { $0.id == id }, id)
        }
        XCTAssertEqual(section.first { $0.id == "plane.net" }?.value, .choice("gnd"))
        XCTAssertEqual(section.last?.id, "deletePlaneDefinition", "at the bottom")
        XCTAssertEqual(section.last?.editor, .action)
        XCTAssertEqual(pour.properties.last?.id, "deletePlaneDefinition")
        XCTAssertTrue(pour.openSections.contains("Plane"))

        // A thermal's and a hatch's settings show once the plane has them.
        let thermal = board.planes.first?.settings.thermalSettings.connectStyle == .thermal
        send(state, edge("pour"), "plane.connectStyle", .choice(thermal ? "solid" : "thermal"))
        let connected = await settle {
            (state.committed.last?.planes.first?.settings.thermalSettings.connectStyle == .thermal) != thermal
        }
        XCTAssertTrue(connected)
        XCTAssertEqual(state.committed.last?.planes.first?.fromRules, false, "its own settings now")
        if thermal {
            send(state, edge("pour"), "plane.connectStyle", .choice("thermal"))
            _ = await settle { state.committed.last?.planes.first?.settings.thermalSettings.connectStyle == .thermal }
        }
        let spokes = await settle { self.item(state, .polygonEdge, "pour")?.properties.contains { $0.id == "plane.spokes" } == true }
        XCTAssertTrue(spokes, "the thermal's settings")
        send(state, edge("pour"), "plane.spokes", .choice("2"))
        let two = await settle { state.committed.last?.planes.first?.settings.thermalSettings.nSpokes == 2 }
        XCTAssertTrue(two)
        send(state, edge("pour"), "plane.thermalGap", .length(300_000))
        let gap = await settle { state.committed.last?.planes.first?.settings.thermalSettings.thermalGapWidth == 300_000 }
        XCTAssertTrue(gap)
        send(state, edge("pour"), "plane.fill", .choice("hatch"))
        let hatch = await settle { self.item(state, .polygonEdge, "pour")?.properties.contains { $0.id == "plane.hatchSpacing" } == true }
        XCTAssertTrue(hatch, "the hatch's settings")
        send(state, edge("pour"), "plane.hatchSpacing", .length(1_000_000))
        let spacing = await settle { state.committed.last?.planes.first?.settings.hatchLineSpacing == 1_000_000 }
        XCTAssertTrue(spacing)
        send(state, edge("pour"), "plane.style", .choice("miter"))
        let sharp = await settle { state.committed.last?.planes.first?.settings.style == .miter }
        XCTAssertTrue(sharp)
        XCTAssertEqual(state.planeEdits.count, 0, "settings are property edits, not plane definitions")
    }
}
#endif
