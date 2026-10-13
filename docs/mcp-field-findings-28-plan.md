# MCP field findings 28: leaving a search field

Planning baseline: `38dbfbe`. Written October 13, 2026. Item 90 was reported
by the user while checking round 27 on Billo, and is recorded in billo's
`docs/horizontal-mcp-notes.md`.

## Finding and change

90. **Once a pane's search field had the keyboard, nothing gave it back to the
    canvas, and the canvas still showed the keyboard-focus badge.**
    - **Reported** after round 27 let the field keep its keys: "I can't
      unfocus the search box. Escape and clicking in another view should
      probably cancel search? The view target on the schematic and board
      should be exclusive of the search box."
    - **Cause:**
      - A click on the canvas set the pane's keyboard focus
        (`onRequestKeyboardFocus`) but left the field editor first
        responder. The canvas's key monitor defers to a focused field, so
        its keys went on reaching the field.
      - Neither search field (Pools pane, Parts pane) did anything with
        Escape.
      - The rail's "Keyboard focus" badge ("This view receives keyboard
        commands") followed only the pane last clicked, so it showed on the
        schematic or board while the field had the keyboard.
      - Before round 27 this was mostly hidden. During a placement the canvas
        took the keys anyway, and outside one its commands did nothing while
        the field had focus.
    - **Now:**
      - A left click on the canvas makes the canvas first responder, ending
        editing in a field elsewhere (`takeFocusFromTextInput`). A click on a
        text field or view drawn over the canvas is left to it.
      - Escape in the Pools and Parts search fields leaves the field and
        keeps its text (`leavesFieldOnEscape`). The keyboard goes back to the
        pane with the badge.
      - The workspace key monitor watches the window's first responder and
        reports whether a text field has it. While one does, no canvas shows
        the badge.
      - A click elsewhere in a pane (the parts list, say) already took the
        keyboard. Neither a click nor Escape clears the search, so the
        results stay there to place from.

## Tests

- **`testClickOnTheCanvasTakesTheKeyboardFromATextField`**: with a text field
  beside the canvas focused, a click on the canvas makes the canvas first
  responder and asks for keyboard focus once. A text view drawn over the
  canvas keeps the keyboard when clicked. Without the change, the field
  editor stays first responder.
- **`testWorkspaceReportsWhenATextFieldHasTheKeyboard`**: the workspace key
  monitor reports false, then true when a field takes the keyboard, then
  false when it gives it up. This also shows that `NSWindow.firstResponder`
  is observable as used.
- Escape in a SwiftUI field isn't covered by a unit test. It uses
  `onKeyPress(.escape)`, as `HorizontalSuggestionFields` does.
- **Results:** Swift 881 tests (6 skipped, 0 failures). No Python changed.
  The app builds in Xcode (Debug, with its own DerivedData under `/tmp`).
  The release products were rebuilt with round 27's (`make native`, 09:06).
- **Live:** the user checked the build from `2a051cb` on Billo: a canvas click
  and Escape leave the field, the badge hides while the field has the
  keyboard, and typing works throughout.
