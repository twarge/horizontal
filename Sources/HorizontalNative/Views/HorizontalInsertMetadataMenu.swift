import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Gives the text field this modifies an Insert Metadata ▸ submenu at the
    /// foot of its right-click menu: each of `items` as its `$key` with what
    /// it stands for in this design beneath, choosing one inserting `$key`
    /// where the cursor is. No items, no submenu. macOS only; on iOS the
    /// field is as it was.
    @ViewBuilder
    func insertMetadataMenu(_ items: [HorizontalTextVariableItem]) -> some View {
        #if os(macOS)
        background(HorizontalInsertMetadataAnchor(items: items))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Marks where a text field with an Insert Metadata menu is. SwiftUI's
/// `.contextMenu` never reaches a text field being edited — its field
/// editor builds the menu through SwiftUI's own text field — so the menu is
/// added to that one as it opens: an app-local monitor sees the right-click
/// first, finds the field under it and the anchor marking it, and pops up the
/// field editor's own menu with the submenu after it.
private struct HorizontalInsertMetadataAnchor: NSViewRepresentable {
    var items: [HorizontalTextVariableItem]

    func makeNSView(context: Context) -> HorizontalInsertMetadataAnchorView {
        let view = HorizontalInsertMetadataAnchorView()
        view.items = items
        return view
    }

    func updateNSView(_ view: HorizontalInsertMetadataAnchorView, context: Context) {
        view.items = items
    }
}

final class HorizontalInsertMetadataAnchorView: NSView {
    var items: [HorizontalTextVariableItem] = []

    /// Clicks go through to the field.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            HorizontalInsertMetadataMenu.shared.unregister(self)
        } else {
            HorizontalInsertMetadataMenu.shared.register(self)
        }
    }
}

@MainActor
final class HorizontalInsertMetadataMenu: NSObject {
    static let shared = HorizontalInsertMetadataMenu()

    static let title = "Insert Metadata"

    private let anchors = NSHashTable<HorizontalInsertMetadataAnchorView>.weakObjects()
    private var monitor: Any?

    func register(_ anchor: HorizontalInsertMetadataAnchorView) {
        anchors.add(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func unregister(_ anchor: HorizontalInsertMetadataAnchorView) {
        anchors.remove(anchor)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let (menu, editor) = contextMenu(for: event) else {
            return event
        }
        NSMenu.popUpContextMenu(menu, with: event, for: editor)
        return nil
    }

    /// The menu a right-click `event` opens on a field with an Insert
    /// Metadata anchor, and the field editor it acts on: the field editor's
    /// own menu, Cut, Copy, Paste and the rest, with the submenu after it.
    /// Nil where the click isn't on such a field, which then gets the click
    /// as it would have. A field not being edited is begun on, the cursor
    /// where the click was.
    func contextMenu(for event: NSEvent) -> (NSMenu, NSTextView)? {
        guard let window = event.window,
              let field = textField(at: event.locationInWindow, in: window),
              field.isEditable, field.isEnabled,
              let anchor = anchor(for: field, at: event.locationInWindow, in: window),
              !anchor.items.isEmpty else {
            return nil
        }
        let begins = field.currentEditor() == nil
        if begins {
            guard window.makeFirstResponder(field) else { return nil }
        }
        guard let editor = field.currentEditor() as? NSTextView else {
            return nil
        }
        // A field just begun on has all its text selected, which an insertion
        // would replace: the cursor goes where the click was. In one already
        // being edited, as a right-click in a text view does, a click outside
        // the selection moves the cursor there and one on it keeps it, for
        // the insertion to replace.
        let clicked = editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil))
        let index = clicked == NSNotFound ? (editor.string as NSString).length : clicked
        if begins || !NSLocationInRange(index, editor.selectedRange()) {
            editor.setSelectedRange(NSRange(location: index, length: 0))
        }
        let menu = editor.menu(for: event) ?? NSMenu()
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(Self.submenuItem(anchor.items, editor: editor))
        return (menu, editor)
    }

    /// Insert Metadata ▸ with an item a key: `$key`, and what it stands for
    /// beneath it.
    static func submenuItem(_ items: [HorizontalTextVariableItem], editor: NSTextView) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for item in items {
            let insertion = HorizontalInsertMetadataAction(code: item.code, editor: editor)
            let menuItem = NSMenuItem(title: item.code, action: #selector(HorizontalInsertMetadataAction.insert(_:)), keyEquivalent: "")
            menuItem.target = insertion
            menuItem.representedObject = insertion
            menuItem.subtitle = item.value.isEmpty ? "No value" : item.value
            menuItem.toolTip = item.title
            submenu.addItem(menuItem)
        }
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }

    private func textField(at point: NSPoint, in window: NSWindow) -> NSTextField? {
        guard let content = window.contentView else { return nil }
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if let editor = current as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
                return field
            }
            if let field = current as? NSTextField {
                return field
            }
            view = current.superview
        }
        return nil
    }

    /// The anchor marking `field`: one in its window over the click and the
    /// field both.
    private func anchor(for field: NSTextField, at point: NSPoint, in window: NSWindow) -> HorizontalInsertMetadataAnchorView? {
        let fieldFrame = field.convert(field.bounds, to: nil)
        let fieldCentre = NSPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        return anchors.allObjects.first { anchor in
            guard anchor.window === window else { return false }
            let frame = anchor.convert(anchor.bounds, to: nil).insetBy(dx: -1, dy: -1)
            return frame.contains(point) && frame.contains(fieldCentre)
        }
    }
}

/// One Insert Metadata item's action: `$key` typed into the field editor
/// over its selection, so the field, and whatever its text binds to, hears of
/// it as of anything typed.
final class HorizontalInsertMetadataAction: NSObject {
    let code: String
    private weak var editor: NSTextView?

    init(code: String, editor: NSTextView) {
        self.code = code
        self.editor = editor
    }

    @objc func insert(_ sender: Any?) {
        guard let editor else { return }
        editor.insertText(code, replacementRange: editor.selectedRange())
    }
}
#endif
