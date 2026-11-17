#if os(macOS)
import AppKit
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// Spotlight on a net draws the net again over the dimmed board, and with it
/// the net's connection lines: its airwires and the connection lines drawn on
/// it. Another net's stay dimmed under it.
@MainActor
final class BoardSpotlightConnectionLinesTests: XCTestCase {
    private let mm = 1_000_000.0

    @MainActor private final class State: ObservableObject {
        @Published var spotlitNets = Set<String>()
        @Published var options = BoardDisplayOptions()
        let toolSettings = HorizontalBoardToolSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        var board: HorizontalBoard
        @SwiftUI.State private var viewport = CanvasViewport()
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: state.options,
                            highlightedNetIDs: state.spotlitNets, toolSettings: state.toolSettings)
        }
    }

    private func p(_ x: Double, _ y: Double) -> HorizontalPoint { HorizontalPoint(x: x * mm, y: y * mm) }

    private func segment(_ id: String, y: Double, net: String, width: Double = 0, layer: Int? = nil) -> HorizontalSegment {
        HorizontalSegment(id: id, from: p(5, y), to: p(25, y), width: width, layer: layer, netID: net)
    }

    /// A 30 mm board with, on each of GND and VCC, a track, an airwire and a
    /// drawn connection line, each at a height of its own.
    private func board() -> HorizontalBoard {
        let extent = HorizontalRect(points: [p(0, 0), p(30, 30)])
        return HorizontalBoard(
            url: URL(fileURLWithPath: "/tmp/spotlight-connection-lines.hprj"), uuid: "b", name: "t",
            grid: .boardDefault,
            colors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil),
            stackupLayers: [], userLayers: [], junctions: [:], junctionNetIDs: [:], netDetails: [:],
            tracks: [
                segment("t-gnd", y: 4, net: "gnd", width: 200_000, layer: 0),
                segment("t-vcc", y: 6, net: "vcc", width: 200_000, layer: 0)
            ],
            netTies: [], lines: [], arcs: [],
            connectionLines: [segment("c-gnd", y: 10, net: "gnd"), segment("c-vcc", y: 12, net: "vcc")],
            airwires: [segment("a-gnd", y: 16, net: "gnd"), segment("a-vcc", y: 18, net: "vcc")],
            polygons: [], planes: [], keepouts: [], dimensions: [], decals: [], holes: [],
            vias: [], viaHoles: [], packages: [], packagePads: [], packageHoles: [], packagePolygons: [],
            packageLines: [], packageArcs: [], packageTexts: [], texts: [],
            boardPanels: [], physicalBounds: extent, bounds: extent
        )
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func metalViews(in view: NSView) -> [MTKView] {
        (view as? MTKView).map { [$0] } ?? view.subviews.flatMap { metalViews(in: $0) }
    }

    /// The heights, in mm, of the lines the spotlight draws over the dim.
    private func spotlitLineHeights(in hosted: NSView) -> Set<Int> {
        let renderer = metalViews(in: hosted).first?.delegate as? HorizontalMetalBackdropView.Renderer
        let lines = renderer?.layer(labeled: "Metal top overlay")?.residentLineEndpoints(compositeGroup: 0) ?? []
        return Set(lines.filter { $0.from.y == $0.to.y }.map { Int(($0.from.y / Float(mm)).rounded()) })
    }

    private func host(_ state: State) -> (NSView, NSWindow) {
        let hosted = NSHostingView(rootView: Canvas(state: state, board: board())
            .environmentObject(HorizontalAppearanceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        return (hosted, window)
    }

    func testASpotlitNetsAirwiresAndConnectionLinesAreDrawnOverTheDim() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State()
        let (hosted, window) = host(state)
        defer { window.close() }

        let up = await settle { !self.metalViews(in: hosted).isEmpty }
        XCTAssertTrue(up, "the board shows")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spotlitLineHeights(in: hosted), [], "nothing is spotlit yet")

        state.spotlitNets = ["gnd"]
        let lit = await settle { self.spotlitLineHeights(in: hosted).contains(16) }
        XCTAssertTrue(lit, "the net's airwire is drawn again over the dim")
        let heights = spotlitLineHeights(in: hosted)
        XCTAssertTrue(heights.contains(10), "and the connection line drawn on it")
        XCTAssertFalse(heights.contains(18), "another net's airwire stays dimmed")
        XCTAssertFalse(heights.contains(12), "and its connection line")
    }

    /// The airwire filter leaves a net's airwires off the board. Spotlit, the
    /// net is drawn whole, its airwires too, and they go again with the
    /// spotlight. The Connections switch still rules: off, a spotlight draws
    /// no connection lines.
    func testASpotlitNetsAirwiresAreDrawnThoughTheAirwireFilterHidesThem() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let state = State()
        state.options.hiddenAirwireNetIDs = ["gnd", "vcc"]
        let (hosted, window) = host(state)
        defer { window.close() }
        let up = await settle { !self.metalViews(in: hosted).isEmpty }
        XCTAssertTrue(up, "the board shows")

        state.spotlitNets = ["gnd"]
        let lit = await settle { self.spotlitLineHeights(in: hosted).contains(16) }
        XCTAssertTrue(lit, "the spotlit net's airwire is drawn, filtered or not")
        XCTAssertFalse(spotlitLineHeights(in: hosted).contains(18), "a filtered net that isn't spotlit stays hidden")

        state.options.connectionLines = false
        let off = await settle { self.spotlitLineHeights(in: hosted).isDisjoint(with: [10, 16]) }
        XCTAssertTrue(off, "with Connections off the spotlight draws none")

        state.options.connectionLines = true
        state.spotlitNets = []
        let gone = await settle { self.spotlitLineHeights(in: hosted).isEmpty }
        XCTAssertTrue(gone, "and they go with the spotlight")
    }

    func testTheSpotlightTakesItsNetsOutOfTheAirwireFilter() {
        var options = BoardDisplayOptions()
        options.hiddenAirwireNetIDs = ["gnd", "vcc"]
        XCTAssertEqual(options.hiddenAirwireNetIDs(spotlighting: ["gnd"]), ["vcc"])
        XCTAssertTrue(options.showsAirwires(ofNet: "GND", spotlighting: ["gnd"]), "ids are matched lowercased")
        XCTAssertFalse(options.showsAirwires(ofNet: "VCC", spotlighting: ["gnd"]))
        XCTAssertFalse(options.showsAirwires(ofNet: "gnd", spotlighting: []), "with nothing spotlit the filter is as it was")
        XCTAssertFalse(options.showsAirwires(ofNet: "gnd"))
    }
}
#endif
