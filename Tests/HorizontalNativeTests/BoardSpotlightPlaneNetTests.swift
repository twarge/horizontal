import XCTest
@testable import HorizontalNative

/// Spotlight (L) on planes. A plane's net is the plane's, not its polygon's,
/// which has none of its own, as in Horizon: so a polygon a plane is poured
/// in is on the plane's net. Selecting it and pressing L spotlights that net
/// with the rest of the selection's, and a spotlight on a net lights its
/// planes, fill and polygon, and its polygons, and frames them; another
/// net's stay dimmed, and a polygon on no net and in no plane gives nothing.
final class BoardSpotlightPlaneNetTests: XCTestCase {
    private let mm = 1_000_000.0
    private let top = HorizontalBoardLayers.topCopper

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    private func square(_ id: String, from x0: Double, _ y0: Double, to x1: Double, _ y1: Double,
                        layer: Int? = nil, net: String? = nil) -> HorizontalPolygon {
        HorizontalPolygon(id: id, vertices: [p(x0, y0), p(x1, y0), p(x1, y1), p(x0, y1)], layer: layer ?? top, netID: net)
    }

    /// A plane on `net` poured in `polygon`, filled in the square given, or
    /// unpoured.
    private func plane(_ id: String, net: String?, in polygon: HorizontalPolygon,
                       fill: (x0: Double, y0: Double, x1: Double, y1: Double)? = nil) -> HorizontalPlane {
        let fragments = fill.map { [HorizontalPlaneFragment(paths: [[p($0.x0, $0.y0), p($0.x1, $0.y0), p($0.x1, $0.y1), p($0.x0, $0.y1)]], orphan: false)] } ?? []
        return HorizontalPlane(id: id, netID: net, polygonID: polygon.id, layer: polygon.layer, priority: 0,
                               fillStyle: "solid", minWidth: 0, keepOrphans: false, fragments: fragments,
                               fallbackPolygon: polygon)
    }

    /// As the board loads: a GND plane poured in its polygon (which, like
    /// every polygon a plane holds, is not among `polygons` and has no net),
    /// filled 12…38 × 12…28 mm inside its 10…40 × 10…30 mm outline; a VCC
    /// plane, unpoured, in a polygon of its own at 50…60 × 10…20 mm; a
    /// polygon of the board's own on GND, one on no net and in no plane, and
    /// the board outline; and a track on VCC.
    private func board() -> HorizontalBoard {
        let gndOutline = square("poly-gnd-plane", from: 10, 10, to: 40, 30)
        let vccOutline = square("poly-vcc-plane", from: 50, 10, to: 60, 20)
        var board = HorizontalGerberExportFixture.board(
            tracks: [HorizontalSegment(id: "t-vcc", from: p(0, 50), to: p(20, 50), width: 200_000, layer: top, netID: "vcc")],
            polygons: [
                square("poly-own-gnd", from: 70, 0, to: 75, 5, net: "GND"),
                square("poly-stray", from: 80, 0, to: 85, 5),
                square("outline", from: -5, -5, to: 100, 60, layer: HorizontalBoardLayers.outline, net: "gnd"),
            ],
            planes: [
                plane("plane-gnd", net: "gnd", in: gndOutline, fill: (12, 12, 38, 28)),
                plane("plane-vcc", net: "vcc", in: vccOutline),
            ]
        )
        let extent = HorizontalRect(points: [p(-5, -5), p(100, 60)])
        board.bounds = extent
        board.physicalBounds = extent
        return board
    }

    // MARK: - Which net

    func testAPolygonAPlaneIsPouredInIsOnThePlanesNet() {
        let board = board()
        let nets = BoardSpotlightNets(board)
        let outlines = Dictionary(uniqueKeysWithValues: board.outlinePolygons.map { ($0.id, $0) })
        XCTAssertNil(outlines["poly-gnd-plane"]?.netID, "the polygon has no net of its own")
        XCTAssertEqual(outlines["poly-gnd-plane"].flatMap(nets.netID(of:)), "gnd", "it is on its plane's")
        XCTAssertEqual(outlines["poly-vcc-plane"].flatMap(nets.netID(of:)), "vcc", "an unpoured plane's too")

        let own = Dictionary(uniqueKeysWithValues: board.polygons.map { ($0.id, $0) })
        XCTAssertEqual(own["poly-own-gnd"].flatMap(nets.netID(of:)), "GND", "a polygon with no plane keeps its own net")
        XCTAssertNil(own["poly-stray"].flatMap(nets.netID(of:)), "a polygon on no net and in no plane is on none")

        // A plane's net is the polygon's even when the polygon has one of
        // its own; a plane with no net leaves the polygon its own.
        let both = square("both", from: 0, 0, to: 1, 1, net: "vcc")
        XCTAssertEqual(BoardSpotlightNets(planes: [plane("p", net: "gnd", in: both)]).netID(of: both), "gnd")
        XCTAssertEqual(BoardSpotlightNets(planes: [plane("p", net: nil, in: both)]).netID(of: both), "vcc")
    }

    /// Select All's thousands of refs are looked up by an index of the
    /// polygons, which gives a plane's polygon its plane's net as one at a
    /// time does.
    func testThePolygonIndexGivesAPlanesPolygonItsPlanesNet() {
        let nets = BoardSpotlightNets.polygonNetIDs(in: board())
        XCTAssertEqual(nets["poly-gnd-plane"], .some("gnd"))
        XCTAssertEqual(nets["poly-vcc-plane"], .some("vcc"))
        XCTAssertEqual(nets["poly-own-gnd"], .some("GND"))
        XCTAssertEqual(nets["poly-stray"], .some(nil), "picked, on no net")
        XCTAssertNil(nets["nothing"], "no such polygon")
    }

    // MARK: - What a spotlight lights

    func testASpotlitNetLightsItsPlanesAndPolygonsAndNoOtherNets() {
        let board = board()
        let nets = BoardSpotlightNets(board)
        let planes = Dictionary(uniqueKeysWithValues: board.planes.map { ($0.id, $0) })
        let polygons = Dictionary(uniqueKeysWithValues: (board.polygons + board.outlinePolygons).map { ($0.id, $0) })
        func lit(_ spotlit: Set<String>) -> Set<String> {
            Set(planes.values.filter { BoardSpotlightNets.lights($0, spotlighting: spotlit) }.map(\.id))
                .union(polygons.values.filter { nets.lights($0, spotlighting: spotlit) }.map(\.id))
        }
        XCTAssertEqual(lit(["gnd"]), ["plane-gnd", "poly-gnd-plane", "poly-own-gnd"],
                       "GND's plane, fill and polygon, and its own polygon; not VCC's, the stray polygon or the board outline")
        XCTAssertEqual(lit(["vcc"]), ["plane-vcc", "poly-vcc-plane"])
        XCTAssertEqual(lit(["gnd", "vcc"]), ["plane-gnd", "poly-gnd-plane", "poly-own-gnd", "plane-vcc", "poly-vcc-plane"])
        XCTAssertEqual(lit([]), [], "nothing spotlit lights nothing")
    }

    /// The highlight draws again what the spotlight lights. A plane's polygon
    /// is among the board's own while an edit has it there, and is drawn then
    /// with its plane, lit.
    func testTheHighlightDrawsANetsPlanesAndPolygons() {
        var board = board()
        _ = board.liftPlaneOutlines()
        let subset = BoardHighlightSubset.board(board, netIDs: ["gnd"], componentIDs: [])
        XCTAssertEqual(subset.planes.map(\.id), ["plane-gnd"])
        XCTAssertEqual(Set(subset.polygons.map(\.id)), ["poly-gnd-plane", "poly-own-gnd"],
                       "the plane's polygon with its own; not VCC's plane's, the stray or the board outline")
        XCTAssertEqual(subset.tracks.map(\.id), [])

        let vcc = BoardHighlightSubset.board(board, netIDs: ["vcc"], componentIDs: [])
        XCTAssertEqual(vcc.planes.map(\.id), ["plane-vcc"])
        XCTAssertEqual(vcc.polygons.map(\.id), ["poly-vcc-plane"])
        XCTAssertEqual(vcc.tracks.map(\.id), ["t-vcc"])
    }

    // MARK: - Framing

    func testSpotlightFramesANetsPlanesAndPolygons() {
        let board = board()
        func assertRect(_ rect: HorizontalRect?, _ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double,
                        _ message: String, line: UInt = #line) {
            guard let rect else {
                return XCTFail("no rectangle: \(message)", line: line)
            }
            XCTAssertEqual(rect.minX / mm, minX, accuracy: 0.001, "minX: \(message)", line: line)
            XCTAssertEqual(rect.minY / mm, minY, accuracy: 0.001, "minY: \(message)", line: line)
            XCTAssertEqual(rect.maxX / mm, maxX, accuracy: 0.001, "maxX: \(message)", line: line)
            XCTAssertEqual(rect.maxY / mm, maxY, accuracy: 0.001, "maxY: \(message)", line: line)
        }
        assertRect(HorizontalSpotlightFraming.boardRect(board, netIDs: ["GND"], componentIDs: [], margin: 0),
                   12, 0, 75, 28, "GND's plane, where it is filled, and its own polygon at 70…75 × 0…5 mm")
        assertRect(HorizontalSpotlightFraming.boardRect(board, netIDs: ["vcc"], componentIDs: [], margin: 0),
                   0, 10, 60, 50, "VCC's track and its unpoured plane's outline")
        XCTAssertNil(HorizontalSpotlightFraming.boardRect(board, netIDs: ["n3"], componentIDs: []),
                     "a net with nothing on the board")
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// L on the board canvas, with a plane's polygon selected: the plane's net is
/// spotlit with every other selected object's.
@MainActor
final class BoardSpotlightPlanePolygonCanvasTests: XCTestCase {
    private let mm = 1_000_000.0

    @MainActor private final class State: ObservableObject {
        var actions: HorizontalCanvasCommandActions?
        var spotlit: Set<String>?
        var selected: Set<String>?
        var selectedTypes: [HorizontalObjectType] = []
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        let board: HorizontalBoard
        let settings: HorizontalSelectionToolSettings
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(),
                            selectionToolSettings: settings,
                            onSelectedNetChange: { state.selected = $0 },
                            onHighlightNetCommand: { state.spotlit = $0 },
                            onSelectionDetailsChange: { state.selectedTypes = $0.groups.map(\.type) },
                            onCanvasCommandActionsChange: { state.actions = $0 },
                            toolSettings: toolSettings)
        }
    }

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    /// A polygon about (cx, cy) with `sides` vertices.
    private func polygon(_ id: String, at cx: Double, _ cy: Double, radius: Double, sides: Int) -> HorizontalPolygon {
        let vertices = (0..<sides).map { index -> HorizontalPoint in
            let angle = Double(index) / Double(sides) * 2 * .pi
            return p(cx + radius * cos(angle), cy + radius * sin(angle))
        }
        return HorizontalPolygon(id: id, vertices: vertices, layer: HorizontalBoardLayers.topCopper)
    }

    /// A GND plane poured in its polygon, which has `sides` sides, a polygon
    /// on no net and in no plane, and a track on VCC; the plane's polygon
    /// held by the plane, as the board loads it.
    private func board(sides: Int, track: Bool = true) -> HorizontalBoard {
        let outline = polygon("poly-gnd-plane", at: 20, 20, radius: 10, sides: sides)
        let fill = HorizontalPlaneFragment(paths: [polygon("fill", at: 20, 20, radius: 9, sides: sides).vertices], orphan: false)
        let gnd = HorizontalPlane(id: "plane-gnd", netID: "gnd", polygonID: outline.id, layer: outline.layer, priority: 0,
                                  fillStyle: "solid", minWidth: 0, keepOrphans: false, fragments: [fill],
                                  fallbackPolygon: outline)
        var board = HorizontalGerberExportFixture.board(
            tracks: track ? [HorizontalSegment(id: "t-vcc", from: p(0, 40), to: p(30, 40), width: 200_000,
                                               layer: HorizontalBoardLayers.topCopper, netID: "vcc")] : [],
            polygons: [polygon("poly-stray", at: 45, 20, radius: 3, sides: 4)],
            planes: [gnd]
        )
        let extent = HorizontalRect(points: [p(0, 0), p(50, 45)])
        board.bounds = extent
        board.physicalBounds = extent
        return board
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    /// What L spotlights with every polygon and track selected (Select All
    /// through a filter that lets only those through), and what the
    /// selection told the window it is on.
    private func spotlitBySelectingPolygonsAndTracks(on board: HorizontalBoard) async throws -> (spotlit: Set<String>?, selected: Set<String>?) {
        var settings = HorizontalSelectionToolSettings()
        settings.boardFilter.only(.polygons)
        settings.boardFilter.set(.tracks, admitted: true)
        return try await spotlitBySelecting(on: board, settings: settings)
    }

    /// What L spotlights with everything the settings' filter lets through
    /// selected by Select All.
    private func spotlitBySelecting(on board: HorizontalBoard, settings: HorizontalSelectionToolSettings) async throws -> (spotlit: Set<String>?, selected: Set<String>?) {
        let state = State()
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state, board: board, settings: settings)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)
        state.actions?.dispatch(.selectAll)
        let selected = await settle { state.actions?.canCopySelection == true }
        XCTAssertTrue(selected, "Select All selected something")
        state.actions?.dispatch(.highlightNet)
        _ = await settle { state.spotlit != nil }
        return (state.spotlit, state.selected)
    }

    func testLOnAPlanesPolygonSpotlightsThePlanesNetWithTheRestOfTheSelections() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        // A square, a few refs looked up one by one; and a polygon of many
        // sides, more refs than that, looked up by an index.
        for sides in [4, 48] {
            let result = try await spotlitBySelectingPolygonsAndTracks(on: board(sides: sides))
            XCTAssertEqual(result.spotlit, ["gnd", "vcc"],
                           "\(sides) sides: the plane's net and the track's; the stray polygon adds none")
            XCTAssertEqual(result.selected, ["gnd", "vcc"], "\(sides) sides: the selection is on both")
        }
    }

    /// Select Net (⇧L) leaves a plane's outline out though Spotlight takes it
    /// to be on the plane's net: Select Net, and a Delete after it, take a
    /// net's copper and leave its planes.
    func testSelectNetLeavesAPlanesOutlineOut() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = board(sides: 4)
        board.tracks.append(HorizontalSegment(id: "t-gnd", from: p(0, 2), to: p(30, 2), width: 200_000,
                                              layer: HorizontalBoardLayers.topCopper, netID: "gnd"))
        var settings = HorizontalSelectionToolSettings()
        settings.boardFilter.only(.polygons)
        settings.boardFilter.set(.tracks, admitted: true)
        let state = State()
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state, board: board, settings: settings)
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }
        let polygonParts: Set<HorizontalObjectType> = [.polygonEdge, .polygonVertex, .polygonArcCenter]
        let mounted = await settle { state.actions != nil }
        XCTAssertTrue(mounted)

        state.actions?.dispatch(.selectAll)
        let selectedAll = await settle { state.selectedTypes.contains(where: polygonParts.contains) }
        XCTAssertTrue(selectedAll, "Select All takes the plane's outline")

        state.actions?.dispatch(.selectNet)
        let selectedNet = await settle {
            state.selectedTypes.contains(.track) && !state.selectedTypes.contains(where: polygonParts.contains)
        }
        XCTAssertTrue(selectedNet, "Select Net keeps the tracks and leaves the plane's outline: \(state.selectedTypes)")
    }

    func testLOnAPolygonOnNoNetAndInNoPlaneSpotlightsNoNet() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var board = board(sides: 4, track: false)
        board.planes = []
        let result = try await spotlitBySelectingPolygonsAndTracks(on: board)
        XCTAssertEqual(result.spotlit, [], "a polygon with no plane and no net gives Spotlight nothing")
    }

    /// On a real board (HORIZONTAL_REAL_BOARD_FOLDER, a project folder): every
    /// polygon selected, L spotlights every plane's net, and the spotlight
    /// draws every one of those planes and frames each of them.
    func testOnARealBoardLOnThePlanesPolygonsSpotlightsAndFramesThePlanes() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HORIZONTAL_REAL_BOARD_FOLDER"] ?? "/nonexistent")
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("board.json").path) else {
            throw XCTSkip("set HORIZONTAL_REAL_BOARD_FOLDER to a real board's project folder to run")
        }
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        var diagnostics = [HorizontalDiagnostic]()
        let board = try HorizontalBoard.load(
            from: base.appendingPathComponent("board.json"),
            blockURL: base.appendingPathComponent("top_block.json"),
            planesURL: base.appendingPathComponent("planes.json"),
            poolURL: base.appendingPathComponent("pool"),
            diagnostics: &diagnostics
        )
        let planes = board.planes.filter { $0.netID != nil && $0.fallbackPolygon != nil }
        guard !planes.isEmpty else { throw XCTSkip("the board has no planes") }
        let planeNets = Set(planes.compactMap { $0.netID?.lowercased() })

        var settings = HorizontalSelectionToolSettings()
        settings.boardFilter.only(.polygons)
        let result = try await spotlitBySelecting(on: board, settings: settings)
        XCTAssertEqual(result.spotlit.map { $0.intersection(planeNets) }, planeNets, "every plane's net")
        // The board's own polygons are on no net.
        XCTAssertEqual(result.spotlit, planeNets, "and no other")

        let subset = BoardHighlightSubset.board(board, netIDs: planeNets, componentIDs: [])
        XCTAssertEqual(Set(subset.planes.map(\.id)), Set(planes.map(\.id)), "every plane drawn lit")
        for plane in planes {
            let net = try XCTUnwrap(plane.netID)
            let rect = try XCTUnwrap(HorizontalSpotlightFraming.boardRect(board, netIDs: [net], componentIDs: [], margin: 0))
            let fill = HorizontalRect(points: plane.points)
            XCTAssertTrue(rect.minX <= fill.minX && rect.minY <= fill.minY && rect.maxX >= fill.maxX && rect.maxY >= fill.maxY,
                          "plane \(plane.id) is framed")
        }
    }
}
#endif
