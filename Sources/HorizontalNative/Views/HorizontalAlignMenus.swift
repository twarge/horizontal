import SwiftUI

/// Edit ▸ Align and Edit ▸ Distribute, for the board's selection
/// (`BoardAlignment`). Each item is one undoable edit. No key equivalents:
/// the letters are the canvas's tools, and ⌘ with them the menus'.
struct HorizontalAlignMenus: View {
    var actions: HorizontalCanvasCommandActions?

    var body: some View {
        let count = actions?.alignableSelectionCount ?? 0
        Menu("Align") {
            ForEach(BoardAlignOperation.alignments) { operation in
                item(operation, count: count)
                if operation == .right {
                    Divider()
                }
            }
        }
        .disabled(count < 2)
        Menu("Distribute") {
            ForEach(BoardAlignOperation.distributions) { operation in
                item(operation, count: count)
            }
        }
        .disabled(count < 3)
    }

    private func item(_ operation: BoardAlignOperation, count: Int) -> some View {
        Button(operation.title) {
            actions?.dispatch(.alignSelection(operation))
        }
        .disabled(count < operation.minimumCount)
    }
}
