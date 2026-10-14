# MCP field findings 33: the board keeps the keyboard, and R turns a moving part

Planning baseline: `33527d8`. Written October 13, 2026. Both items are the
user's, from working on Billo's board in the app, and are recorded in billo's
`docs/horizontal-mcp-notes.md`.

## Findings and changes

104. **Selecting a part on the board moved the keyboard focus to the
     schematic.**
     - **The cause:** since `7af239a` ("One selection for the board, the
       schematic and the 3D view"), `selectComponents` pushes a selection
       made in one canvas into the others. The schematic then reports its
       new selection through `onSelectionDetailsChange`, and
       `setSelectionDetails` gives the keyboard to any pane that reports a
       selection (`activeCanvasCommandPane = pane`). That claim predates the
       shared selection.
       - **What it took over:** the rail's "Keyboard focus" badge, the key
         monitor's `hasKeyboardFocus`, and the menu's
         `activeCanvasCommandActions`.
       - **What that did:** after a click on a board part, M, R and Delete
         acted on the schematic's copy of the selection.
     - **The iPad had it too:** `HorizontalIPadProjectView.setSelectionDetails`
       sets `focusedPane = pane` the same way.
     - **Now:**
       - **The canvas action reports a change:** `selectComponents` returns
         whether the selection actually changed. It compares
         `selectedObjects`, since a part with no symbol on the sheet, or no
         package on the board, changes nothing.
       - **Pushed panes are marked:** the workspace's
         `selectComponents(_:from:)` marks each canvas it changed other than
         the one the selection was made in (`crossProbedPanes`). The four
         canvas callbacks, on macOS and iPad, now pass their own pane.
       - **The marked report keeps the focus where it was:** it still
         updates that pane's inspector.
       - **Elsewhere:** a selection from the live channel, the 3D view or a
         list has no origin, so it leaves the focus alone.
       - **Why only changed panes:** a pane is marked only when it will
         report, so a mark can't outlive the report it stands for and swallow
         a later tap on iPad, where selection is what moves the focus.

105. **R while moving a part on the board didn't turn the preview.**
     - **The cause:** `transformSelection` wrote the turn into `editedBoard`.
       During a move the canvas draws `moveState.originalBoard` (or its
       translated preview), and `commitMove` rebuilds from it, so:
       - the preview never turned;
       - a commit after moving dropped the turn;
       - a commit with no further move, or Esc, left the turn in
         `editedBoard` with no undo step and nothing published, so the
         canvas and the document disagreed;
       - E (mirror) and T (twirl) went the same way.
     - **Now:** `transformSelection` has a move branch, after the
       schematic's.
       - **It turns the current preview:** the turn is about the cursor, or,
         in a keyboard move, the selection's centre where it is now. That
         centre is read from the preview, because `board` is still the
         pre-move board while the move is patched in Metal.
       - **The move carries on from the turned copy:** the branch makes it
         `originalBoard`, restarts the delta, and rebuilds the resident move
         plan and the live airwires.
       - **The board before the move is kept:** `MoveState.boardBeforeMove`
         holds it once a turn has happened.
     - **The commit:**
       - lands a turn even when nothing moved after it;
       - registers its undo against `boardBeforeMove`, so one undo puts
         everything back;
       - rebuilds the Metal scene instead of preserving it.
     - **Esc** discards the turn with the move, since `editedBoard` is no
       longer touched until the commit.

## Tests

- **`BoardMoveRotateTests`** (new, macOS, Metal). Each test mounts a
  `BoardCanvasView` with one placed package, selects it through
  `selectComponents`, and drives the canvas's own key monitor.
  - **104:** `selectComponents` returns true when it changes the selection
    and false when the set is already selected.
  - **Up, R, up, Enter:** one commit, a quarter turn, the move kept, and one
    undo back to the package as it was.
  - **Up, R, Enter:** the turn lands with no further move.
  - **Up, R, Esc:** nothing commits and there's no undo step. The next move
    commits the package unturned (before, it came back turned).
  - **Without the move branch,** all three fail: the commit loses the turn,
    the zero-move turn is lost, and Esc leaves the turn behind.
- **Results:** Swift 892 tests (6 skipped, 0 failures; 889 before plus the
  3 new). The app builds in Xcode for macOS (`/tmp/r33-mac-dd`, 102 s) and
  the iOS Simulator (`/tmp/r33-ios-dd`, 63 s).
- **Left for the app:**
  - **104:** click a part on the board. The keyboard-focus badge should stay
    on the board, and M, R and Delete act there. The same on iPad.
  - **105:** drag a part and press R. The preview turns, the commit keeps
    the turn, one undo puts it back, and Esc discards it.
