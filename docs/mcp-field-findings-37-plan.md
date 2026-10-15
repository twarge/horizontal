# MCP field findings 37: a keyboard move turns about what it moves

Planning baseline: `3121daf`. Written October 15, 2026. The item came from
the session working on item 121: one of item 122's tests failed for it when
run on its own and passed in the full suite. It is numbered 123 for billo's
`docs/horizontal-mcp-notes.md`.

## Findings and changes

123. **R, E and T during an arrow-key move turned about the mouse pointer.**
     - **The symptom:**
       `BoardMoveRotateTests.testRDuringAMoveTurnsWhatMovesAndTheCommitKeepsTheTurnAndTheMove`
       failed in the other session. It got x = 11 000 000 where 10 000 000
       was expected, and y = −9 000 000 where more than 10 000 000 was
       expected. It passed here, alone, in its class and in the suite, ten
       times out of ten.
     - **What the numbers say:** the package was at (10, 11) mm when R came,
       and ended at (11, −10) mm before the second up key. That is a quarter
       turn about the world origin.
     - **The cause:** the order of the tests had nothing to do with it; where
       the real pointer was did.
       - **The pivot:** R, E and T turn and flip about `lastCursorWorldPoint`
         when there is one, and only otherwise about the selection's centre.
       - **The real pointer:** the canvas samples the pointer 60 times a
         second. The test window opens at the bottom-left of the screen, so a
         pointer resting there became the cursor. On that test's empty board
         the window maps to the world origin.
       - **Reproduced:** a synthetic `mouseMoved` over the canvas just before
         R gives the other session's numbers exactly.
     - **It was a product bug as well as a test one:**
       - **What 105 meant:** its plan says the turn is about the cursor or,
         in a keyboard move, about the selection's centre where it is now.
       - **What the code did:** it never told the two apart. During an
         arrow-key move with the mouse resting anywhere on the canvas, R threw
         the part across the board to turn about the pointer.
       - **The schematic** had the same rule for R, E and T, so it did the
         same with symbols.
     - **Now:** a new `transformPivotCursor` on both canvases is the cursor,
       except while a move that doesn't track the cursor (`tracksCursor:
       false`, the arrow keys' move) is under way. There it is nil, so the
       selection's centre is the pivot.
       - **Where it applies:** mirror, rotate and twirl use it on both
         canvases, and so does the board's in-place turn (122).
       - **Unchanged:** a drag move, and R, E and T outside a move, still turn
         about the cursor. Paste placement still tracks the cursor.

## Tests

- **`BoardMoveRotateTests`:** each of its four R presses now comes right after
  a synthetic pointer rests on the canvas, away from the part
  (`restPointer(in:)`), as a user's pointer might during a keyboard move.
  - **With the fix:** all four pass, whatever the real pointer does.
  - **Without it:** the first test fails with the other session's numbers.
- **`SchematicKeyboardMoveTests.testRDuringAKeyboardMoveTurnsAboutTheSelectionNotThePointer`**
  (new): up, R, Enter on a symbol, once with the pointer resting on the
  canvas and once without.
  - **With the fix:** both commit the same turned symbol, near where the up
    key took it.
  - **Without it:** the resting pointer threw the symbol to (21.25, 82.5) mm.
- **Results:**
  - **Swift:** 909 tests (6 skipped, 0 failures), the 908 from before plus the
    new one.
  - **App builds:** Xcode builds for macOS (`/tmp/r37-mac-dd`) and the iOS
    Simulator (`/tmp/r37-ios-dd`).
- **Left for the app:**
  - **Keyboard move:** select a part on the board, press an arrow key, leave
    the mouse anywhere on the canvas and press R. The part should turn in
    place, not jump to the pointer.
  - **Schematic:** the same with a symbol.
  - **Drag move:** R should still turn the part about the pointer.
