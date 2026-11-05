#if os(macOS)
import AppKit
import HorizontalProjectIO
import MetalKit
import SwiftUI
import XCTest
@testable import HorizontalNative

/// The rules window's Display warnings on canvas: on unless someone turns it
/// off, kept as the app's setting, and while off no canvas draws a warning
/// marker and the rules results button shows no count. A section closed in
/// the rules results sidebar leaves only its own findings unmarked, and the
/// marker is exclamationmark.triangle.fill in a black rim.
@MainActor
final class CanvasWarningsDisplayTests: XCTestCase {
    private let key = "appearance.displaysCanvasWarnings"

    func testWarningsAreDisplayedUntilTurnedOffAndTheChoiceIsKept() throws {
        let defaults = try freshDefaults()
        let settings = HorizontalAppearanceSettings(defaults: defaults)
        XCTAssertTrue(settings.shouldDisplayCanvasWarnings)
        XCTAssertNil(defaults.object(forKey: key))

        settings.canvasWarningsBinding().wrappedValue = false
        XCTAssertFalse(settings.shouldDisplayCanvasWarnings)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        XCTAssertFalse(HorizontalAppearanceSettings(defaults: defaults).shouldDisplayCanvasWarnings)

        settings.canvasWarningsBinding().wrappedValue = true
        XCTAssertTrue(HorizontalAppearanceSettings(defaults: defaults).shouldDisplayCanvasWarnings)
    }

    func testTheToolbarShowsNoCountWhileWarningsAreOff() {
        let finding = HorizontalBoardRuleFinding(kind: .trackWidth, level: .error, check: "too_narrow", title: "t", message: "e",
                                                 location: HorizontalPoint(x: 0, y: 0))
        let state = HorizontalBoardRulesResultState(ruleTitle: "Design Rules", messages: [], clearanceFindings: [],
                                                    boardFindings: [finding, finding], schematicFindings: [])
        XCTAssertEqual(state.toolbarBadgeCount(displayingWarnings: true), 2)
        XCTAssertEqual(state.toolbarBadgeCount(displayingWarnings: false), 0)
        XCTAssertEqual(state.badgeCount, 2, "the results sidebar still has them")
    }

    func testAClosedSectionLeavesOnlyItsOwnFindingsOffTheCanvas() {
        // Horizontal's own copper checks have no kind and list as "Copper".
        func finding(_ kind: HorizontalBoardRuleKind?, _ x: Double) -> HorizontalBoardRuleFinding {
            HorizontalBoardRuleFinding(kind: kind, level: .error, check: "c", title: "t", message: "m",
                                       location: HorizontalPoint(x: x, y: 0))
        }
        let schematic = HorizontalSchematicRuleFinding(check: .unconnectedPin, message: "Pin R1.2 is not connected", subject: "r1/2")
        let state = HorizontalBoardRulesResultState(ruleTitle: "Design Rules", messages: [], clearanceFindings: [],
                                                    boardFindings: [finding(.trackWidth, 1), finding(.holeSize, 2), finding(nil, 3)],
                                                    schematicFindings: [schematic])
        let trackWidth = HorizontalBoardRuleKind.trackWidth.rawValue
        // Copper first; before, a Copper finding sorted first made the
        // sections index the last of none, and the sidebar crashed.
        XCTAssertEqual(state.boardFindingSections.map(\.id), ["copper", trackWidth, HorizontalBoardRuleKind.holeSize.rawValue])
        XCTAssertEqual(state.boardFindingSections.map(\.findings.count), [1, 1, 1])

        func marked(_ collapsed: Set<String>) -> Set<Double> {
            Set(state.canvasBoardFindings(collapsedSections: collapsed).compactMap { $0.location?.x })
        }
        XCTAssertEqual(marked([]), [1, 2, 3])
        XCTAssertEqual(marked([trackWidth]), [2, 3], "only the track width finding goes")
        XCTAssertEqual(marked(["copper"]), [1, 2])
        XCTAssertEqual(marked([HorizontalBoardRulesResultState.schematicSectionID]), [1, 2, 3], "the schematic's section is its own")

        XCTAssertEqual(state.canvasSchematicFindings(collapsedSections: []).count, 1)
        XCTAssertEqual(state.canvasSchematicFindings(collapsedSections: [HorizontalBoardRulesResultState.schematicSectionID]).count, 0)
        XCTAssertEqual(state.canvasSchematicFindings(collapsedSections: [trackWidth]).count, 1)
        XCTAssertEqual(state.badgeCount, 4, "closing a section takes nothing off the badge")
    }

    func testTheMarkerIsTheSymbolInABlackRimWithAWhiteMark() {
        let glyph = HorizontalCanvasWarningGeometry.glyph
        XCTAssertGreaterThan(glyph.count, 20)
        // What is drawn on top at a point: the last triangle over it.
        func top(_ point: CGPoint) -> HorizontalCanvasWarningGeometry.GlyphPart? {
            glyph.last { triangle in
                func side(_ p: CGPoint, _ q: CGPoint) -> Double { (q.x - p.x) * (point.y - p.y) - (q.y - p.y) * (point.x - p.x) }
                let s1 = side(triangle.a, triangle.b), s2 = side(triangle.b, triangle.c), s3 = side(triangle.c, triangle.a)
                return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
            }?.part
        }
        XCTAssertEqual(top(CGPoint(x: -4, y: 6)), .fill)
        XCTAssertEqual(top(CGPoint(x: 4, y: 6)), .fill)
        XCTAssertEqual(top(CGPoint(x: 0, y: -5.5)), .fill)
        XCTAssertEqual(top(CGPoint(x: 0, y: 2.85)), .fill, "between the bar and the dot")
        XCTAssertEqual(top(CGPoint(x: 0, y: -2)), .mark, "the bar")
        XCTAssertEqual(top(CGPoint(x: 0, y: 1.5)), .mark, "the bar")
        XCTAssertEqual(top(CGPoint(x: 0, y: 4.6)), .mark, "the dot")
        XCTAssertEqual(top(CGPoint(x: 0, y: 7.5)), .rim, "the rim along the bottom")
        XCTAssertEqual(top(CGPoint(x: 0, y: -7.4)), .rim, "the rim at the apex")
        XCTAssertEqual(top(CGPoint(x: -5.4, y: 0)), .rim, "the rim along a side")
        XCTAssertNil(top(CGPoint(x: 8.8, y: 7.9)), "the corner is rounded")
        XCTAssertNil(top(CGPoint(x: -8.8, y: 7.9)), "the corner is rounded")
        // Within the old marker's 18 by 16.
        for triangle in glyph {
            for p in [triangle.a, triangle.b, triangle.c] {
                XCTAssertTrue(abs(p.x) <= 9.001 && abs(p.y) <= 8.001, "\(p)")
            }
        }

        let error = HorizontalCanvasWarning(position: HorizontalPoint(x: 0, y: 0), messages: ["e"], errorMessages: ["e"])
        let warning = HorizontalCanvasWarning(position: HorizontalPoint(x: 1, y: 0), messages: ["w"], errorMessages: [])
        let drawn = HorizontalCanvasWarningGeometry.triangles(for: [error, warning])
        XCTAssertEqual(drawn.count, 2 * glyph.count)
        func colors(_ triangles: ArraySlice<HorizontalMetalScreenTrianglePrimitive>) -> [HorizontalCanvasWarningGeometry.GlyphPart: Set<HorizontalMetalRGBA>] {
            Dictionary(zip(glyph.map(\.part), triangles.map(\.color)).map { ($0, [$1]) }, uniquingKeysWith: { $0.union($1) })
        }
        let black = HorizontalMetalRGBA(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        XCTAssertEqual(colors(drawn.prefix(glyph.count)), [
            .rim: [black], .fill: [HorizontalMetalRGBA(red: 1, green: 0.23, blue: 0.19, alpha: 1)],
            .mark: [HorizontalMetalRGBA(red: 1, green: 1, blue: 1, alpha: 1)],
        ], "an error is red with a white mark")
        XCTAssertEqual(colors(drawn.suffix(glyph.count)), [
            .rim: [black], .fill: [HorizontalMetalRGBA(red: 1, green: 0.8, blue: 0.05, alpha: 1)], .mark: [black],
        ], "a warning is yellow with a black one")
    }

    func testTheBoardDrawsNoRuleMarkersWhileWarningsAreOff() async throws {
        let project = try templateProject()
        let board = try XCTUnwrap(project.board)
        let markers = [
            HorizontalCanvasWarning(position: HorizontalPoint(x: 10_000_000, y: 10_000_000), messages: ["e"], errorMessages: ["e"]),
            HorizontalCanvasWarning(position: HorizontalPoint(x: 20_000_000, y: 20_000_000), messages: ["w"], errorMessages: []),
        ]
        try await checkMarkers(count: markers.count) { BoardPane(board: board, markers: markers) }
    }

    func testTheSchematicDrawsNoMarkersWhileWarningsAreOff() async throws {
        let project = try templateProject()
        let sheet = try XCTUnwrap(project.schematic?.sheets.first)
        let marker = HorizontalCanvasWarning(position: HorizontalPoint(x: 0, y: 0), messages: ["Pin on no net"], errorMessages: ["Pin on no net"])
        try await checkMarkers(count: 1) { SchematicPane(sheet: sheet, markers: [marker]) }
    }

    // MARK: Mounting

    private struct BoardPane: View {
        var board: HorizontalBoard
        var markers: [HorizontalCanvasWarning]
        @State private var viewport = CanvasViewport()
        @State private var toolSettings = HorizontalBoardToolSettings()
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(),
                            toolSettings: toolSettings, ruleMarkers: markers)
        }
    }

    private struct SchematicPane: View {
        var sheet: HorizontalSchematicSheet
        var markers: [HorizontalCanvasWarning]
        @State private var viewport = CanvasViewport()
        var body: some View {
            SchematicCanvasView(sheet: sheet, allSheets: [sheet], viewport: $viewport, ruleMarkers: markers)
        }
    }

    /// Mounts `pane` and finds its warning markers, a glyph's triangles each,
    /// on the top overlay, then none once the setting is off, and back again.
    private func checkMarkers<Pane: View>(count: Int, _ pane: () -> Pane) async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        _ = NSApplication.shared
        let settings = HorizontalAppearanceSettings(defaults: try freshDefaults())
        let hosted = NSHostingView(rootView: pane().environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.close() }

        let triangles = count * HorizontalCanvasWarningGeometry.glyph.count
        let shown = await settle { self.markerTriangles(in: hosted) == triangles }
        XCTAssertTrue(shown, "the markers are drawn: \(markerTriangles(in: hosted)) triangles, not \(triangles)")

        settings.canvasWarningsBinding().wrappedValue = false
        let hidden = await settle { self.markerTriangles(in: hosted) == 0 }
        XCTAssertTrue(hidden, "no marker is drawn while warnings are off: \(markerTriangles(in: hosted)) triangles")

        settings.canvasWarningsBinding().wrappedValue = true
        let back = await settle { self.markerTriangles(in: hosted) == triangles }
        XCTAssertTrue(back, "the markers come back: \(markerTriangles(in: hosted)) triangles")
    }

    /// The top overlay's screen triangles, which with nothing selected are
    /// the warning markers alone; none when the layer draws nothing.
    private func markerTriangles(in view: NSView) -> Int {
        guard let renderer = CanvasFrameRecording.renderer(in: view) else { return -1 }
        return renderer.layer(labeled: "Metal top overlay")?.screenTrianglePrimitiveCount ?? 0
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func templateProject() throws -> HorizontalProject {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-warnings-\(UUID().uuidString).horizontal")
        try HorizontalProjectArchive.newProject().write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try HorizontalProject.load(from: root)
    }

    private func freshDefaults() throws -> UserDefaults {
        let name = "horizontal-canvas-warnings-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }
}
#endif
