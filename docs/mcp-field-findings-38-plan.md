# MCP field findings 38: R on a part at rest turns it in place

Planning baseline: `c6ccae2`. Written October 15, 2026. The item is the
user's, from the app after item 123, and is numbered 124 for billo's
`docs/horizontal-mcp-notes.md`.

## Findings and changes

124. **R on a selected part that isn't moving turned it about the cursor,
     not about the part.**
     - **The report:** "If the part is selected but not in an active move,
       it still rotates around the cursor, not the part center."
     - **The cause:** item 123's `transformPivotCursor` was nil only in a
       move made with the arrow keys. Outside a move it was still the cursor,
       so with the pointer anywhere on the canvas R, E and T jumped the
       selection to turn about it. The schematic did the same with symbols.
     - **Now:** `transformPivotCursor` is the cursor only in a move that
       follows it (`tracksCursor`: M, or a drag), where the pointer is holding
       what moves. Everywhere else the selection's centre is the pivot, on
       both canvases:
       - **What the centre is:** for a single part, its origin (a package's
         position, a symbol's), so it turns in place and stays on its grid.
       - **Unchanged:** placing a package or a pool item, pasting, and Rotate
         Around Center already turned about the part or the placement.

## Tests

- **`BoardMoveRotateTests.testRAtRestTurnsThePartInPlaceWhereverThePointerRests`**
  (new): with a pointer resting on the canvas away from the part, R commits a
  quarter turn with the package where it was. With item 123's rule it lands
  at (10, −10) mm, turned about the pointer.
- **`BoardMoveRotateTests.testRInAMoveThatFollowsThePointerStillTurnsAboutThePointer`**
  (new): M starts a move that follows the pointer, and R and Enter commit the
  turn about the pointer, away from where the part was. With a rule that
  never uses the pointer, it stays put and the test fails.
- **`SchematicKeyboardMoveTests.testRAtRestTurnsTheSymbolInPlaceWhereverThePointerRests`**
  (new): the same as the first, for a symbol. With item 123's rule it lands at
  (20, 82.5) mm.
- **Results:**
  - **Swift:** 912 tests (6 skipped, 0 failures), the 909 from before plus the
    three new ones.
  - **App builds:** Xcode builds for macOS (`/tmp/r38-mac-dd`) and the iOS
    Simulator (`/tmp/r38-ios-dd`).
- **Left for the app:**
  - **At rest:** select a part on the board, leave the mouse elsewhere on the
    canvas and press R, then E. The part should turn and flip in place. Do the
    same with a symbol on the schematic.
  - **Moving:** R during a drag or M move should still turn about the pointer.
