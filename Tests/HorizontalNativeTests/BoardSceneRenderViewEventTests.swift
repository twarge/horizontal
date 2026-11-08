#if canImport(AppKit)
import AppKit
import simd
import XCTest
@testable import HorizontalNative

/// The Mac's 3D view takes its mouse and scroll events itself — RealityKit
/// brings no camera control of its own — so a drag turns the camera, a
/// right-drag pans it, the scroll wheel zooms, and a click that did not drag
/// picks the part under it. Events are handed to the view directly.
@MainActor
final class BoardSceneRenderViewEventTests: XCTestCase {
    private let size = NSSize(width: 400, height: 300)

    private func view() -> BoardSceneRenderView {
        let view = BoardSceneRenderView(frame: NSRect(origin: .zero, size: size))
        let board = HorizontalBoard.poolEditorBoard(uuid: "events", name: "Events", url: URL(fileURLWithPath: "/tmp/events"))
        let asset = BoardSceneModelLibrary.shared.boxAsset(
            size: SIMD3(4, 1, 4),
            materials: [BoardSceneMaterialSpec(color: BoardSceneColor(red: 0.5, green: 0.5, blue: 0.5))]
        )
        var description = BoardSceneDescription(board: board, center: .zero, boardThickness: 1.6, boardWidth: 40, boardDepth: 40)
        description.boardBoxMin = SIMD3(-20, -1.1, -20)
        description.boardBoxMax = SIMD3(20, 0.5, 20)
        description.models = [BoardSceneModelPlacement(
            packageID: "a", componentID: "c-a", group: .model, explodeFactor: 3,
            asset: asset, transform: simd_float4x4(translation: SIMD3(0, 1.1, 0))
        )]
        let scene = BoardSceneEntities(description: description)
        scene.applyDisplayOptions(BoardDisplayOptions(), copperColor: .orange, materialColors: HorizontalBoardColors(silkscreen: nil, solderMask: nil, substrate: nil), layerColors: [:])
        view.show(scene)
        // Looking straight down at the part from 100 mm.
        view.rig.apply(HorizontalSceneCameraState(matrix: BoardSceneCameraMath.lookAt(position: SIMD3(0, 100, 0), target: .zero, up: SIMD3(0, 0, -1))))
        return view
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    func testADragTurnsTheCameraAndReportsWhereItEndedUp() {
        let view = view()
        var reported: HorizontalSceneCameraState?
        view.onCameraStateChange = { reported = $0 }
        var picked = false
        view.onPick = { _, _ in picked = true }
        let start = view.rig.state
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 260, y: 150)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 260, y: 150)))
        XCTAssertNotEqual(view.rig.state, start)
        XCTAssertEqual(view.rig.orbit.distance, 100, accuracy: 0.01, "turned about what it looks at")
        XCTAssertEqual(reported, view.rig.state, "the camera is reported when the drag ends")
        XCTAssertFalse(picked, "a drag is no click")
    }

    func testARightDragPansAndTheScrollWheelZooms() throws {
        let view = view()
        view.rightMouseDown(with: mouse(.rightMouseDown, at: NSPoint(x: 200, y: 150)))
        view.rightMouseDragged(with: mouse(.rightMouseDragged, at: NSPoint(x: 240, y: 150)))
        view.rightMouseUp(with: mouse(.rightMouseUp, at: NSPoint(x: 240, y: 150)))
        XCTAssertLessThan(view.rig.orbit.position.x, 0, "panned: the board follows the drag right")
        XCTAssertEqual(view.rig.orbit.distance, 100, accuracy: 0.01)

        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertLessThan(view.rig.orbit.distance, 100, "a wheel turned up zooms in")
    }

    func testAClickPicksThePartUnderItAndShiftExtends() {
        let view = view()
        var picks = [(String?, Bool)]()
        view.onPick = { picks.append(($0, $1)) }
        // The view's centre, then a corner that shows only board.
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 201, y: 151)))
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150), modifiers: .shift))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 200, y: 150), modifiers: .shift))
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 20)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 20, y: 20)))
        XCTAssertEqual(picks.count, 3)
        XCTAssertEqual(picks[0].0, "c-a")
        XCTAssertFalse(picks[0].1)
        XCTAssertEqual(picks[1].0, "c-a")
        XCTAssertTrue(picks[1].1, "shift extends")
        XCTAssertNil(picks[2].0, "the board is no part")
    }

    func testEventsPassThroughWhileTheToolbarHasThePointer() {
        let view = view()
        view.ignoresSceneMouseEvents = true
        let start = view.rig.state
        view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 200, y: 150)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 260, y: 150)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 260, y: 150)))
        XCTAssertEqual(view.rig.state, start)
        XCTAssertNil((view as NSView).hitTest(NSPoint(x: 200, y: 150)))
    }
}
#endif
