import Foundation

/// Whether the board canvas has a tool in use with a board of its own: a
/// move, a placement, a route that has laid something. The canvas says so
/// here, and the host's netlist reload waits on it: a board replaced under
/// such a tool ends it (`syncRevision`), so a part moved straight after it
/// was placed sprang back to where it was placed when the reload the
/// placement asked for landed.
@MainActor
final class BoardCanvasToolHold {
    private(set) var isHeld = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func set(_ held: Bool) {
        isHeld = held
        guard !held else {
            return
        }
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }

    /// Returns once no tool is in use; at once when none is.
    func waitUntilFree() async {
        while isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
