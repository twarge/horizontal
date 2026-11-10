import XCTest
@testable import HorizontalNative

/// Design ▸ Measure Distance (`BoardMeasureState`, `BoardMeasurement`): the
/// arithmetic, what the readout says, and how the clicks go.
final class BoardMeasureDistanceTests: XCTestCase {
    private func mm(_ x: Double, _ y: Double) -> HorizontalPoint {
        HorizontalPoint(x: x * 1_000_000, y: y * 1_000_000)
    }

    func testTheRunAcrossAndUpTheDistanceAndTheAngle() {
        let measurement = BoardMeasurement(from: mm(1, 2), to: mm(4, -2))
        XCTAssertEqual(measurement.dx, 3_000_000)
        XCTAssertEqual(measurement.dy, -4_000_000)
        XCTAssertEqual(measurement.distance, 5_000_000)
        XCTAssertEqual(measurement.angle, -53.13, accuracy: 0.01)
        XCTAssertEqual(measurement.text, "Δx +3.000 mm   Δy \u{2212}4.000 mm   d 5.000 mm   α \u{2212}53.1°")
    }

    func testARunAlongOneAxisSaysThatAxisAlone() {
        XCTAssertEqual(BoardMeasurement(from: mm(0, 0), to: mm(-2.5, 0)).text, "Δx \u{2212}2.500 mm")
        XCTAssertEqual(BoardMeasurement(from: mm(0, 0), to: mm(0, 0.001)).text, "Δy +0.001 mm")
        XCTAssertEqual(BoardMeasurement(from: mm(1, 1), to: mm(1, 1)).text, "d 0.000 mm")
        XCTAssertEqual(BoardMeasurement(from: mm(1, 1), to: mm(1, 1)).angle, 0)
    }

    func testTheMeasurementFollowsTheCursorUntilTheSecondClickHoldsIt() {
        var state = BoardMeasureState()
        XCTAssertNil(state.measurement)
        XCTAssertTrue(state.statusText.contains("click the first point"))

        state.click(at: mm(0, 0))
        XCTAssertTrue(state.move(to: mm(1, 1)))
        XCTAssertEqual(state.measurement, BoardMeasurement(from: mm(0, 0), to: mm(1, 1)))
        XCTAssertTrue(state.statusText.contains("click the second point"))

        state.click(at: mm(3, 0))
        XCTAssertFalse(state.move(to: mm(9, 9)), "a held measurement doesn't follow the cursor")
        XCTAssertEqual(state.measurement, BoardMeasurement(from: mm(0, 0), to: mm(3, 0)))
        XCTAssertEqual(state.statusText, "Measure: Δx +3.000 mm   click to measure again   Esc leaves the tool")

        state.click(at: mm(5, 5))
        XCTAssertNil(state.to, "the next click starts another")
        XCTAssertEqual(state.measurement, BoardMeasurement(from: mm(5, 5), to: mm(5, 5)))
    }
}

#if os(macOS)
import AppKit
import SwiftUI

/// The measure tool on the canvas: it starts on a locked board, since it
/// changes nothing, takes Esc to leave, and edits nothing on the way.
@MainActor
final class BoardMeasureDistanceCanvasTests: XCTestCase {
    @MainActor private final class State: ObservableObject {
        var committed: [HorizontalBoard] = []
        var actions: HorizontalCanvasCommandActions?
    }

    private struct Canvas: View {
        @ObservedObject var state: State
        @SwiftUI.State private var viewport = CanvasViewport()
        let board: HorizontalBoard
        let toolSettings = HorizontalBoardToolSettings()
        var body: some View {
            BoardCanvasView(board: board, viewport: $viewport, displayOptions: BoardDisplayOptions(), isReadOnly: true,
                onBoardChange: { state.committed.append($0) },
                onCanvasCommandActionsChange: { state.actions = $0 },
                toolSettings: toolSettings)
        }
    }

    private func settle(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testMeasuringStartsOnALockedBoardAndEscLeavesIt() async throws {
        guard HorizontalMetalBackdropView.isSupported else { throw XCTSkip("Metal device required") }
        let state = State()
        _ = NSApplication.shared
        let hosted = NSHostingView(rootView: Canvas(state: state, board: HorizontalGerberExportFixture.board())
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
        XCTAssertEqual(state.actions?.canMeasureDistance, true, "offered on a locked board")

        state.actions?.dispatch(.measureDistance)
        let measuring = await settle { state.actions?.canCancelInteraction == true }
        XCTAssertTrue(measuring, "the tool is on")
        state.actions?.dispatch(.cancelInteraction)
        let left = await settle { state.actions?.canCancelInteraction == false }
        XCTAssertTrue(left, "Esc leaves it")
        XCTAssertTrue(state.committed.isEmpty, "and nothing was edited")
    }
}
#endif
