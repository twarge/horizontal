import Foundation
import SwiftUI

@MainActor
final class HorizontalUndoTarget<Value>: ObservableObject {
    private var currentValue: (() -> Value)?
    private var restoreValue: ((Value) -> Void)?

    func configure(
        currentValue: @escaping () -> Value,
        restoreValue: @escaping (Value) -> Void
    ) {
        self.currentValue = currentValue
        self.restoreValue = restoreValue
    }

    func registerUndo(
        from previousValue: Value,
        actionName: String,
        undoManager: UndoManager?
    ) {
        guard let undoManager else {
            return
        }

        undoManager.registerUndo(withTarget: self) { target in
            guard let currentValue = target.currentValue else {
                return
            }

            let redoValue = currentValue()
            target.restoreValue?(previousValue)
            target.registerUndo(from: redoValue, actionName: actionName, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    func removeAllActions(from undoManager: UndoManager?) {
        undoManager?.removeAllActions(withTarget: self)
    }
}
