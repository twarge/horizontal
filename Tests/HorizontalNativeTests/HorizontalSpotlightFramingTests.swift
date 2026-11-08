#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HorizontalProjectIO
@testable import HorizontalNative

/// Spotlight (L) beyond the canvases: where the setting to show it in every
/// view frames each view, how the Parts pane marks a selection and a
/// spotlight, and the workspace framing what L spotlit. Set
/// HORIZONTAL_SPOTLIGHT_RENDERS to a folder for a picture of the Parts pane's
/// marks.
@MainActor
final class HorizontalSpotlightFramingTests: XCTestCase {
    private let mm = 1_000_000.0

    // MARK: - Where each view is framed

    private func pad(_ id: String, at x: Double, _ y: Double, net: String? = nil) -> HorizontalPolygon {
        let half = 0.5 * mm
        return HorizontalPolygon(id: id, vertices: [
            .init(x: x - half, y: y - half), .init(x: x + half, y: y - half),
            .init(x: x + half, y: y + half), .init(x: x - half, y: y + half),
        ], layer: HorizontalBoardLayers.topCopper, netID: net)
    }

    /// R1 on top at (10, 10) mm, two pads 2 mm apart; R2 under the board at
    /// (30, 10), one pad; a track on N1 straight along y = 20 from x = 0 to 40; a via
    /// alone on N2 at (25, 0).
    private func board() -> HorizontalBoard {
        var board = HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/spotlight.hprj"), uuid: "b", name: "spotlight",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [HorizontalSegment(id: "t", from: .init(x: 0, y: 20 * mm), to: .init(x: 40 * mm, y: 20 * mm), width: 250_000, layer: 0, netID: "N1")],
            netTies: [], lines: [], arcs: [], connectionLines: [], airwires: [],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [HorizontalMarker(id: "v", position: .init(x: 25 * mm, y: 0), size: 600_000, layer: nil, netID: "n2")],
            viaHoles: [],
            packages: [
                HorizontalPlacement(id: "P1", position: .init(x: 10 * mm, y: 10 * mm), angle: 0, mirrored: false, label: "R1", componentID: "C-R1"),
                HorizontalPlacement(id: "p2", position: .init(x: 30 * mm, y: 10 * mm), angle: 0, mirrored: true, label: "R2", componentID: "c-r2"),
            ],
            packagePads: [pad("p1/a", at: 9 * mm, 10 * mm), pad("p1/b", at: 11 * mm, 10 * mm), pad("p2/a", at: 30 * mm, 10 * mm)],
            packageHoles: [], packagePolygons: [], packageLines: [], packageArcs: [], packageTexts: [],
            texts: [], boardPanels: [], physicalBounds: .empty, bounds: .empty
        )
        board.placeableObjects = []
        return board
    }

    private func assertRect(_ rect: HorizontalRect?, minX: Double, minY: Double, maxX: Double, maxY: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else {
            return XCTFail("no rectangle", file: file, line: line)
        }
        XCTAssertEqual(rect.minX / mm, minX, accuracy: 0.001, "minX", file: file, line: line)
        XCTAssertEqual(rect.minY / mm, minY, accuracy: 0.001, "minY", file: file, line: line)
        XCTAssertEqual(rect.maxX / mm, maxX, accuracy: 0.001, "maxX", file: file, line: line)
        XCTAssertEqual(rect.maxY / mm, maxY, accuracy: 0.001, "maxY", file: file, line: line)
    }

    func testTheBoardIsFramedOnTheSpotlitPartsPadsAndTheNetsCopper() {
        let board = board()
        // R1's pads span 8.5…11.5 × 9.5…10.5 mm, and the 3 mm margin.
        assertRect(HorizontalSpotlightFraming.boardRect(board, netIDs: [], componentIDs: ["c-r1"]),
                   minX: 5.5, minY: 6.5, maxX: 14.5, maxY: 13.5)
        // N1 is one straight track, so flat: framed along its length, about
        // its own line, not about its first point.
        assertRect(HorizontalSpotlightFraming.boardRect(board, netIDs: ["n1"], componentIDs: []),
                   minX: -3, minY: 17, maxX: 43, maxY: 23)
        // A net of a via alone still has somewhere to be.
        assertRect(HorizontalSpotlightFraming.boardRect(board, netIDs: ["N2"], componentIDs: []),
                   minX: 21, minY: -4, maxX: 29, maxY: 4)
        XCTAssertNil(HorizontalSpotlightFraming.boardRect(board, netIDs: ["n3"], componentIDs: ["c-r9"]), "nothing of it on the board")
    }

    func testASidedViewTurnsToTheSideEverySpotlitPartIsOn() {
        let board = board()
        XCTAssertEqual(HorizontalSpotlightFraming.boardSide(board, componentIDs: ["c-r1"]), .top)
        XCTAssertEqual(HorizontalSpotlightFraming.boardSide(board, componentIDs: ["C-R2"]), .bottom)
        XCTAssertNil(HorizontalSpotlightFraming.boardSide(board, componentIDs: ["c-r1", "c-r2"]), "one on each side: stay")
        XCTAssertNil(HorizontalSpotlightFraming.boardSide(board, componentIDs: []))
    }

    /// The starter project's top block, its one sheet as page 1 with R1 on
    /// it, and a page 2 with R2, R3 and a wire on N1.
    private func project() throws -> HorizontalProject {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var project = try HorizontalProject.load(from: root)
        var schematic = try XCTUnwrap(project.schematics.first)
        var first = try XCTUnwrap(schematic.schematic.sheets.first)
        var second = first
        second.id = "page-2"
        second.index = first.index + 1
        func symbol(_ component: String, at x: Double, _ y: Double) -> HorizontalPlacement {
            HorizontalPlacement(id: "s-\(component)", position: .init(x: x * mm, y: y * mm), angle: 0, mirrored: false, label: component, componentID: component)
        }
        first.symbols = [symbol("c-r1", at: 100, 50)]
        first.netLines = []
        second.symbols = [symbol("c-r2", at: 40, 40), symbol("c-r3", at: 80, 40)]
        second.netLines = [HorizontalSegment(id: "w", from: .init(x: 40 * mm, y: 60 * mm), to: .init(x: 120 * mm, y: 60 * mm), width: 0, layer: nil, netID: "n1")]
        schematic.schematic.sheets = [first, second]
        project.schematics[0] = schematic
        return project
    }

    func testTheSchematicTurnsToTheSheetThatDrawsTheMostOfIt() throws {
        let project = try project()
        let block = project.schematics[0].block.uuid
        let page1 = project.schematics[0].schematic.sheets[0].id

        let r1 = HorizontalSpotlightFraming.sheetTarget(project, netIDs: [], componentIDs: ["C-R1"], currentSheetID: "page-2")
        XCTAssertEqual(r1?.sheetID, page1)
        XCTAssertEqual(r1?.blockID, block)
        // 20 mm about the symbol, as zoom_to frames one, and the margin.
        assertRect(r1?.rect, minX: 87, minY: 37, maxX: 113, maxY: 63)

        XCTAssertEqual(HorizontalSpotlightFraming.sheetTarget(project, netIDs: [], componentIDs: ["c-r1", "c-r2", "c-r3"], currentSheetID: page1)?.sheetID,
                       "page-2", "two of the three are on page 2")
        // One each: the page showing keeps it.
        XCTAssertEqual(HorizontalSpotlightFraming.sheetTarget(project, netIDs: [], componentIDs: ["c-r1", "c-r2"], currentSheetID: "page-2")?.sheetID, "page-2")
        XCTAssertEqual(HorizontalSpotlightFraming.sheetTarget(project, netIDs: [], componentIDs: ["c-r1", "c-r2"], currentSheetID: page1)?.sheetID, page1)
        // A net alone: where its wire is.
        let net = HorizontalSpotlightFraming.sheetTarget(project, netIDs: ["N1"], componentIDs: [], currentSheetID: page1)
        XCTAssertEqual(net?.sheetID, "page-2")
        assertRect(net?.rect, minX: 37, minY: 57, maxX: 123, maxY: 63)
        XCTAssertNil(HorizontalSpotlightFraming.sheetTarget(project, netIDs: [], componentIDs: [], currentSheetID: page1))
        XCTAssertNil(HorizontalSpotlightFraming.sheetTarget(project, netIDs: ["n9"], componentIDs: ["c-r9"], currentSheetID: page1))
    }

    // MARK: - The Parts pane

    func testAPartsRowShowsTheSelectionAndTheSpotlight() {
        func mark(_ id: String, selected: Set<String> = [], spotlit: Set<String>? = nil, dims: Bool = true) -> HorizontalPartBrowserView.RowMark {
            HorizontalPartBrowserView.rowMark(partID: id, selected: selected, spotlit: spotlit, dimsOthers: dims)
        }
        XCTAssertEqual(mark("P-A"), .none)
        XCTAssertEqual(mark("P-A", selected: ["p-a"]), .selected, "ids match whatever their case")
        XCTAssertEqual(mark("P-A", spotlit: ["p-b"]), .dimmed, "Spotlight leaves it out")
        XCTAssertEqual(mark("P-B", spotlit: ["p-b"]), .none)
        XCTAssertEqual(mark("P-A", spotlit: ["p-b"], dims: false), .none, "As Is dims nothing")
        XCTAssertEqual(mark("P-A", selected: ["p-a"], spotlit: ["p-b"]), .selected, "the selection shows through a spotlight")
        XCTAssertEqual(mark("P-A", spotlit: []), .dimmed, "spotlit components fitted with nothing listed")
    }

    @MainActor private final class PartsState: ObservableObject {
        @Published var token = 0
        @Published var selected = Set<String>()
        @Published var spotlit: Set<String>?
    }

    private struct PartsHost: View {
        @ObservedObject var state: PartsState
        var parts: [HorizontalPoolPart]
        var body: some View {
            HorizontalPartBrowserView(parts: parts, library: HorizontalPartLibraryMonitor(),
                                      selectedComponentPartIDs: state.selected, spotlitPartIDs: state.spotlit,
                                      spotlightScrollToken: state.token)
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfColumns > 1 {
            return table
        }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    private func settle(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testTheSpotlightScrollsThePartsListToItsFirstPart() async throws {
        _ = NSApplication.shared
        let parts = (0..<80).map { index in
            HorizontalPoolPart(id: String(format: "p-%02d", index), mpn: String(format: "PART-%02d", index), manufacturer: "", partDescription: "",
                               packageName: "R0603", tags: [], value: "", displayValue: "", entityID: nil, refdesPrefix: "R", gates: [])
        }
        let state = PartsState()
        let defaults = UserDefaults(suiteName: "spotlight-parts-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: PartsHost(state: state, parts: parts).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { self.table(in: hosted)?.numberOfRows == 80 }
        XCTAssertTrue(mounted, "the list is up")
        let table = try XCTUnwrap(table(in: hosted))
        func shows(_ row: Int) -> Bool {
            table.rows(in: table.visibleRect).contains(row)
        }
        XCTAssertTrue(shows(0))
        XCTAssertFalse(shows(70), "precondition: the list scrolls")

        state.selected = ["p-02"]
        state.spotlit = ["p-70", "p-75"]
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(shows(70), "marking it scrolls nothing")
        write(hosted, name: "parts-marks")

        state.token += 1
        let scrolled = await settle { shows(70) }
        XCTAssertTrue(scrolled, "the first spotlit part comes into view")
        write(hosted, name: "parts-spotlight-scrolled")
        XCTAssertEqual(table.selectedRowIndexes, [], "the list's own selection is left alone")
    }

    private func write(_ view: NSView, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["HORIZONTAL_SPOTLIGHT_RENDERS"], !folder.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    // MARK: - The workspace

    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.board]
        @Published var request = 0
        @Published var highlightedNets = Set<String>()
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var spot: Spot
        var project: HorizontalProject
        @State var nets = Set<String>()
        @State var components = Set<String>()
        @State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $spot.document, visiblePanes: $spot.panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $spot.highlightedNets,
                                 selectedComponentIDs: $components, highlightedComponentIDs: $highlightedComponents,
                                 spotlightRequest: $spot.request)
        }
    }

    /// The starter board is 50 mm square with a GND via at (25, 0) mm. With
    /// the setting on, as it is until it is turned off, Spotlight on GND
    /// leaves the board where it is while the via is in view, and scrolls it
    /// to the via at the same zoom once it is out of view; off, the board
    /// stays where it was.
    func testWithTheSettingOnASpotlightScrollsTheBoardToItOnlyWhenItIsOutOfView() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let key = HorizontalSpotlightFraming.framesEveryViewKey
        let previous = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { @MainActor in
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-frame-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try HorizontalProject.load(from: root)
        let gnd = try XCTUnwrap(project.board?.vias.first?.netID, "the starter via is on GND")
        let spot = Spot(try HorizontalProjectArchive.snapshot(from: root))
        let defaults = UserDefaults(suiteName: "spotlight-frame-\(UUID().uuidString)")!
        let hosted = NSHostingView(rootView: Workspace(spot: spot, project: project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        func live() -> HorizontalLiveDocument? {
            HorizontalDispatchSession.shared.openEntries
                .first { $0.live != nil && $0.url.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() }?
                .live
        }
        func bounds() -> HorizontalRect? { live()?.visibleBounds(.board) }
        func showsVia(_ view: HorizontalRect) -> Bool {
            view.minX < 25 * mm && view.maxX > 25 * mm && view.minY < 0 && view.maxY > 0
        }
        let up = await settle(timeout: 10) { (bounds()?.width ?? 0) > 0 }
        XCTAssertTrue(up, "the board shows")
        let fitted = try XCTUnwrap(bounds())
        XCTAssertTrue(showsVia(fitted), "it starts fitted to the board, the via in view")

        UserDefaults.standard.set(true, forKey: key)
        spot.highlightedNets = [gnd]
        spot.request += 1
        try await Task.sleep(for: .milliseconds(300))
        let still = try XCTUnwrap(bounds())
        XCTAssertEqual(still.minX, fitted.minX, accuracy: 1, "in view, the board doesn't move")
        XCTAssertEqual(still.width, fitted.width, accuracy: 1, "nor zoom")

        // Zoomed in on the far corner, the via out of view.
        try XCTUnwrap(live()).frame(.board, HorizontalRect(center: HorizontalPoint(x: -20 * mm, y: -20 * mm), size: 8 * mm))
        let away = await settle { bounds().map { !showsVia($0) && $0.width < 20 * mm } ?? false }
        XCTAssertTrue(away, "zoomed in away from the via: \(String(describing: bounds()))")
        let zoomed = try XCTUnwrap(bounds())

        UserDefaults.standard.set(false, forKey: key)
        spot.request += 1
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try XCTUnwrap(bounds()).minX, zoomed.minX, accuracy: 1, "off, the board stays")

        // Never set is on.
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(HorizontalSpotlightFraming.framesEveryViewByDefault)
        spot.request += 1
        let scrolled = await settle { bounds().map(showsVia) ?? false }
        XCTAssertTrue(scrolled, "scrolled to the via: \(String(describing: bounds()))")
        let after = try XCTUnwrap(bounds())
        XCTAssertEqual(after.width, zoomed.width, accuracy: zoomed.width * 0.001, "at the zoom it was at")
        XCTAssertEqual(after.height, zoomed.height, accuracy: zoomed.height * 0.001)
        XCTAssertEqual(after.center.x, 25 * mm, accuracy: 0.6 * mm, "centred on the via")
    }
}
#endif
