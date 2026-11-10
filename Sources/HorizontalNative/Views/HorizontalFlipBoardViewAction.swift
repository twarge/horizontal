import SwiftUI

/// View ▸ Flip Board View: the front window's board turned over
/// (`HorizontalBoardViewState.flip`), as F on the board canvas does.
private struct HorizontalFlipBoardViewActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var horizonFlipBoardViewAction: (() -> Void)? {
        get { self[HorizontalFlipBoardViewActionKey.self] }
        set { self[HorizontalFlipBoardViewActionKey.self] = newValue }
    }
}
