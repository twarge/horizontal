#if canImport(AppKit)
import AppKit
import SwiftUI

/// How a canvas puts a menu of its own on screen: a right-click's, or the one
/// a click on overlapping objects asks with.
///
/// The app's pops the menu up, which returns only once the menu has closed:
/// an `NSMenu` runs its own tracking loop until an item is picked or a click
/// elsewhere dismisses it. A test that sends a mounted canvas a right-click
/// passes one that keeps the menu and returns, so it can read what the canvas
/// offered, nothing opens on the screen of whoever is at the Mac, and the run
/// doesn't wait on a click nobody is there to make.
struct HorizontalCanvasMenuPresenter {
    /// Shows `menu` at `location`, in screen coordinates, and returns once
    /// it has closed.
    var present: @MainActor (_ menu: NSMenu, _ location: NSPoint) -> Void

    static var popUp: HorizontalCanvasMenuPresenter {
        HorizontalCanvasMenuPresenter { menu, location in
            menu.popUp(positioning: nil, at: location, in: nil)
        }
    }
}

private struct HorizontalCanvasMenuPresenterKey: EnvironmentKey {
    static var defaultValue: HorizontalCanvasMenuPresenter { .popUp }
}

extension EnvironmentValues {
    var horizonCanvasMenuPresenter: HorizontalCanvasMenuPresenter {
        get { self[HorizontalCanvasMenuPresenterKey.self] }
        set { self[HorizontalCanvasMenuPresenterKey.self] = newValue }
    }
}
#endif
