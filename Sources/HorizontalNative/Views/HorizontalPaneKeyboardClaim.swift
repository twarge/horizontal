import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// A pane without a canvas — the Pools pane, the Parts pane — takes the
    /// window's keyboard when it is clicked anywhere: its list, its search,
    /// its preview, a link in it. `claim` makes it the keyboard-focused pane,
    /// so no canvas's key monitor takes its keys (⌘C, ⌘A, Delete, single
    /// letters) and the Edit menu's canvas commands stand down; and a view
    /// outside the pane that has the keyboard — the canvas last clicked, a
    /// field being edited elsewhere — gives it up, so what the click lands on
    /// (selectable text, the table, a field) takes it, or nothing does. A
    /// canvas takes it back when it is clicked.
    ///
    /// `leadingInset` is the part of the pane under the navigator sidebar,
    /// whose clicks are the sidebar's. macOS only: on iPadOS keys go to the
    /// first responder, which a tap already moves.
    func claimsKeyboardOnClick(leadingInset: CGFloat = 0, _ claim: @escaping () -> Void) -> some View {
        #if os(macOS)
        background {
            HorizontalPaneKeyboardClaim(onClaim: claim)
                .padding(.leading, leadingInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct HorizontalPaneKeyboardClaim: NSViewRepresentable {
    var onClaim: () -> Void

    func makeNSView(context: Context) -> ClaimView {
        let view = ClaimView()
        view.onClaim = onClaim
        return view
    }

    func updateNSView(_ view: ClaimView, context: Context) {
        view.onClaim = onClaim
    }

    /// Lies under the pane and takes no clicks itself: a local monitor sees
    /// each mouse-down in the window before the view under it does.
    final class ClaimView: NSView {
        var onClaim: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.claim(for: event)
                return event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func claim(for event: NSEvent) {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
            let frame = convert(bounds, to: nil)
            guard frame.contains(event.locationInWindow) else { return }
            // The hosting view that holds SwiftUI's own focus is an ancestor
            // of every pane, and stays.
            if let responder = window.firstResponder as? NSView, !isDescendant(of: responder),
               !Self.isWithin(responder, frame) {
                window.makeFirstResponder(nil)
            }
            onClaim?()
        }

        /// A responder in the pane keeps the keyboard (its search field
        /// mid-edit, its table); one elsewhere gives it up. A field's
        /// editor counts as the field it edits.
        private static func isWithin(_ responder: NSView, _ frame: NSRect) -> Bool {
            var view: NSView = responder
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                view = field
            }
            let responderFrame = view.convert(view.bounds, to: nil)
            return frame.contains(NSPoint(x: responderFrame.midX, y: responderFrame.midY))
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
#endif
