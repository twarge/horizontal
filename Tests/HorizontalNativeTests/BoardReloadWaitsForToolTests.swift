import XCTest
@testable import HorizontalNative

/// The netlist reload a placement asks for waits while the board canvas has
/// a tool in use, so it doesn't replace the board under a move.
@MainActor
final class BoardReloadWaitsForToolTests: XCTestCase {
    func testReturnsAtOnceWithNoToolInUse() async {
        let hold = BoardCanvasToolHold()
        await hold.waitUntilFree()
        XCTAssertFalse(hold.isHeld)
    }

    func testWaitsUntilTheToolIsDone() async {
        let hold = BoardCanvasToolHold()
        hold.set(true)
        var reloaded = false
        let reload = Task { @MainActor in
            await hold.waitUntilFree()
            reloaded = true
        }
        // Long enough for the reload to have run, were it not waiting.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(reloaded)
        hold.set(false)
        await reload.value
        XCTAssertTrue(reloaded)
    }

    func testAToolTakenUpAgainBeforeTheReloadRunsIsWaitedOutToo() async {
        let hold = BoardCanvasToolHold()
        hold.set(true)
        let reload = Task { @MainActor in
            await hold.waitUntilFree()
            return hold.isHeld
        }
        try? await Task.sleep(for: .milliseconds(20))
        // Placed, then moved at once: free and held again in one turn.
        hold.set(false)
        hold.set(true)
        try? await Task.sleep(for: .milliseconds(20))
        hold.set(false)
        let heldWhenReloaded = await reload.value
        XCTAssertFalse(heldWhenReloaded)
    }
}
