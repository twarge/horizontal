#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import simd
import HorizontalProjectIO
@testable import HorizontalNative

/// Spotlight in a view it didn't start in moves that view only when what is
/// spotlit is out of it, and then scrolls without zooming; a part being placed
/// from the unplaced column is the workspace's selection, which the other
/// views mark.
@MainActor
final class HorizontalSpotlightRevealTests: XCTestCase {
    private let mm = 1_000_000.0

    /// A 100 mm square sheet drawn on an 800 by 600 canvas, zoomed in 4
    /// times on its middle.
    private func zoomedIn() -> HorizontalCanvasTransform {
        HorizontalCanvasTransform(
            bounds: HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 100 * mm, y: 100 * mm)]),
            size: CGSize(width: 800, height: 600), zoom: 4
        )
    }

    private func applied(_ viewport: CanvasViewport, to transform: HorizontalCanvasTransform) -> HorizontalCanvasTransform {
        var moved = transform
        moved.zoom = viewport.zoom
        moved.pan = viewport.pan
        return moved
    }

    func testAViewThatShowsTheRectIsLeftAlone() {
        let transform = zoomedIn()
        let visible = transform.visibleBounds
        let inside = HorizontalRect(center: visible.center, size: visible.height / 4)
        XCTAssertNil(CanvasViewport.revealing(inside, in: transform, identity: "sheet"))
    }

    func testOneThatDoesntScrollsToItAtTheSameZoom() throws {
        let transform = zoomedIn()
        let before = transform.visibleBounds
        let corner = HorizontalRect(center: HorizontalPoint(x: 5 * mm, y: 95 * mm), size: 2 * mm)
        XCTAssertFalse(before.intersects(corner), "precondition: out of view")

        let viewport = try XCTUnwrap(CanvasViewport.revealing(corner, in: transform, identity: "sheet"))
        XCTAssertEqual(viewport.zoom, transform.zoom, accuracy: 0.0001, "no zoom")
        let after = applied(viewport, to: transform).visibleBounds
        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertEqual(after.center.x, corner.center.x, accuracy: 1, "centred on it")
        XCTAssertEqual(after.center.y, corner.center.y, accuracy: 1)
        XCTAssertEqual(viewport.reference?.identity, "sheet")

        let partly = HorizontalRect(center: HorizontalPoint(x: before.maxX, y: before.center.y), size: 4 * mm)
        XCTAssertNotNil(CanvasViewport.revealing(partly, in: transform), "half out of view is out of view")
    }

    /// A page turned to keeps the scale the last page was drawn at, though
    /// its own bounds, and so what a zoom of 1 means, differ.
    func testAScaleGivenIsKeptOnAnotherPage() throws {
        let scale = zoomedIn().length(1)
        let otherPage = HorizontalCanvasTransform(
            bounds: HorizontalRect(points: [HorizontalPoint(x: 0, y: 0), HorizontalPoint(x: 300 * mm, y: 200 * mm)]),
            size: CGSize(width: 800, height: 600)
        )
        let target = HorizontalRect(center: HorizontalPoint(x: 150 * mm, y: 100 * mm), size: 2 * mm)
        let viewport = try XCTUnwrap(CanvasViewport.revealing(target, in: otherPage, scale: scale, identity: "page 2"),
                                     "applied even where the target shows")
        XCTAssertEqual(applied(viewport, to: otherPage).length(1), scale, accuracy: scale * 0.0001)
    }

    /// The 3D camera slides along the board to a part out of its view, still
    /// looking the same way from as far, and stays put for one in view.
    func testThe3DCameraSlidesWithoutTurningOrZooming() throws {
        var board = HorizontalBoard.poolEditorBoard(uuid: "reveal", name: "Reveal", url: URL(fileURLWithPath: "/tmp/reveal"))
        board.bounds = HorizontalRect(points: [HorizontalPoint(x: -50 * mm, y: -50 * mm), HorizontalPoint(x: 50 * mm, y: 50 * mm)])
        let near = HorizontalRect(center: HorizontalPoint(x: 0, y: 0), size: 2 * mm)
        let camera = horizonSceneCameraState(framing: near, board: board, current: nil, projection: .perspective)
        XCTAssertNil(horizonSceneCameraState(revealing: near, board: board, current: camera), "in view: left alone")
        XCTAssertNil(horizonSceneCameraState(revealing: near, board: board, current: nil), "no camera yet: nothing to keep")

        let far = HorizontalRect(center: HorizontalPoint(x: 40 * mm, y: -40 * mm), size: 2 * mm)
        let moved = try XCTUnwrap(horizonSceneCameraState(revealing: far, board: board, current: camera))
        let before = try XCTUnwrap(camera.matrix), after = try XCTUnwrap(moved.matrix)
        for column in 0..<3 {
            XCTAssertLessThan(simd_distance(before[column], after[column]), 0.0001, "the same way round")
        }
        XCTAssertEqual(moved.orthographicScale, camera.orthographicScale)
        let target = BoardSceneFactory.scenePoint(far.center, center: board.bounds.center, y: BoardSceneFactory.boardTopHeight)
        let toTarget = target - BoardSceneCameraMath.position(of: after)
        XCTAssertGreaterThan(simd_dot(simd_normalize(toTarget), BoardSceneCameraMath.forward(of: after)), 0.9999, "looking at it")
        let wasLooking = simd_length(BoardSceneCameraMath.position(of: before)
            - BoardSceneFactory.scenePoint(near.center, center: board.bounds.center, y: BoardSceneFactory.boardTopHeight))
        XCTAssertEqual(simd_length(toTarget), wasLooking, accuracy: wasLooking * 0.001, "from as far")
        XCTAssertNil(horizonSceneCameraState(revealing: far, board: board, current: moved), "and then it is in view")
    }

    // MARK: - A part being placed

    @MainActor private final class Spot: ObservableObject {
        @Published var document: HorizontalProjectDocument
        @Published var panes: Set<HorizontalPane> = [.board, .schematic]
        @Published var request = 0
        @Published var highlightedNets = Set<String>()
        @Published var components = Set<String>()
        init(_ archive: HorizontalProjectArchive) {
            document = HorizontalProjectDocument()
            document.archive = archive
        }
    }

    private struct Workspace: View {
        @ObservedObject var spot: Spot
        var project: HorizontalProject
        @SwiftUI.State var nets = Set<String>()
        @SwiftUI.State var highlightedComponents = Set<String>()
        var body: some View {
            ProjectWorkspaceView(project: project, document: $spot.document, visiblePanes: $spot.panes,
                                 selectedNetIDs: $nets, highlightedNetIDs: $spot.highlightedNets,
                                 selectedComponentIDs: $spot.components, highlightedComponentIDs: $highlightedComponents,
                                 spotlightRequest: $spot.request)
        }
    }

    private func settle(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    private func monitors(in view: NSView) -> [TrackpadCanvasMonitor.MonitorView] {
        (view as? TrackpadCanvasMonitor.MonitorView).map { [$0] } ?? view.subviews.flatMap { monitors(in: $0) }
    }

    /// A click on R3 in the board's unplaced column starts placing it, and
    /// R3 is then the workspace's selection: what the schematic boxes in blue,
    /// the Parts pane bands and the 3D view boxes.
    func testAPartBeingPlacedFromTheColumnIsSelectedInTheOtherViews() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let fixture = try BlockLayoutFixture(instances: 1, placeParts: false)
        let instance = try XCTUnwrap(fixture.instances.first)
        try fixture.apply([
            ["op": "place_component", "component": fixture.flat(instance, "R1"), "x_mm": 0, "y_mm": 0],
            ["op": "place_component", "component": fixture.flat(instance, "R2"), "x_mm": 5, "y_mm": 0],
        ])
        let r3 = try XCTUnwrap(try fixture.board.unplacedObjects.first)
        XCTAssertEqual(r3.label, "R3")
        let spot = Spot(fixture.archive)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(false, forKey: HorizontalOperationDefaults.readOnlyOperationKey)
        let app = NSApplication.shared
        let hosted = NSHostingView(rootView: Workspace(spot: spot, project: fixture.project)
            .environmentObject(HorizontalAppearanceSettings(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hosted.frame = window.contentLayoutRect
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in window.close() }

        let ready = await settle(timeout: 15) { self.monitors(in: hosted).contains { !$0.overlayFrames.isEmpty } }
        XCTAssertTrue(ready, "the board with its unplaced column")
        let monitor = try XCTUnwrap(monitors(in: hosted).first { !$0.overlayFrames.isEmpty })
        let column = try XCTUnwrap(monitor.overlayFrames.first)
        XCTAssertTrue(spot.components.isEmpty)

        // R3's row, under the column's title.
        let row = CGPoint(x: column.midX, y: column.minY + 48)
        let inWindow = monitor.convert(NSPoint(x: row.x, y: monitor.bounds.height - row.y), to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            app.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(60))
        }
        let placing = await settle { monitor.overlayFrames.isEmpty }
        XCTAssertTrue(placing, "placing R3, the column gone with its last part")
        let selected = await settle { spot.components.map { $0.lowercased() } == [try! XCTUnwrap(r3.componentID).lowercased()] }
        XCTAssertTrue(selected, "R3 is the workspace's selection while it is placed: \(spot.components)")
    }
}
#endif
