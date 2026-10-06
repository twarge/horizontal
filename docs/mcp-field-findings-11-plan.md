# MCP field findings 11: the canvas's airwires, and a save that says it looked

Planning baseline: `be20463`. Written October 6, 2026, from the two items
left open in Billo's notes after round [ten](mcp-field-findings-10-plan.md)'s
live check passed.

## Findings and changes

29. **`render_viewport` couldn't show airwires, and nothing said whose
    airwires `board_info` counted.**
    - **Before:** a render of Billo's board pane at 110 dpi came back with
      no airwires.
      - **The render:** `render_viewport` runs the board PDF exporter over
        the dispatch's copy of the project and crops it to the pane's
        visible rectangle. The exporter draws fabrication drawings and has
        no airwires.
      - **The counts:** `board_info` and `check` gave 32 airwires on 22
        nets. For a live document the dispatch takes the document's model
        and runs the editor's connectivity pass over it again
        (`withEditorConnectivity`), so that's its own answer, not the
        canvas's.
      - **The effect:** item 21's question was whether the canvas draws
        airwires only where `check` reports them. That could only be judged
        by eye.
    - **Why the two can differ:** the canvas doesn't draw `board.airwires`
      as it stands. It draws a scene cached under a key of the board's id,
      a revision and object counts (`metalElementBucketsCacheKey`). It
      keeps the previous scene too, and a placement seeds a merged scene
      without a rebuild. A change the key misses leaves the old airwires
      on screen, and the model can't show that.
    - **Now:**
      - **The scene keeps its airwires:** `BoardMetalElementBuckets` keeps
        the airwires its connection-line batch was built from. A merge
        takes them from the addition when that batch is replaced, as a
        placement does, and appends them otherwise.
      - **The canvas reports them:** each time `boardMetalLineBatch` hands
        a scene over, cached or not, the board canvas records that scene's
        airwires and its Connections switch (`HorizontalDrawnAirwires`).
        Like the visible rectangle, the record lives outside SwiftUI state
        (`HorizontalLiveCanvasAirwires`). The live document reads it
        through the canvas's command actions, as `drawnAirwires`, on macOS
        and iPad. It's nil when the board pane is hidden, or when no layer
        is drawn in Metal.
      - **`render_viewport` on the board** draws airwires over the
        exporter's render, as 1.5-pixel blue dashes. They're the canvas's
        airwires, or `check`'s when the canvas gives none. The overlay goes
        on the raster through the exporter's own page mapping, now shared
        as `PageMapping`. The PDF isn't touched, so fabrication drawings
        are unchanged. `airwires: false` leaves them off.
      - **The reply's `airwires`** gives:
        - `source`: "canvas", or "connectivity".
        - `count`, `nets`, and `in_view` (how many cross the region).
        - `shown`, from the Connections switch, with a note when it's off.
        - `matches_check`, and `differences` for each net whose segments
          differ: `canvas` and `check` counts, and `only_canvas` and
          `only_check`. Segments are compared end to end in whole
          nanometres, in either order, so the same airwire drawn the other
          way round still matches.
      - **`board_info`** gains `airwires`:
        - `source` "connectivity", with a note saying what `counts.airwires`
          is.
        - For a live document, `canvas`: the same comparison, or null when
          the board pane isn't up.
    - **Left as is:**
      - **During a drag:** the moving nets' live airwires are drawn in an
        overlay. The record is the resident scene under it.
      - **The rest of the render:** it's still the exporter's style, not a
        capture of the Metal canvas (`docs/automation.md`, "What comes
        next"). `render_board` draws no airwires.
30. **A live save left `leftovers` out of its reply when there were none.**
    - **Before:** `save` added `leftovers` only when the list wasn't empty
      (`HorizontalDispatchMethods.swift`, `save`). An app from before
      `54d007d` never checks, and its reply is the same, so a reply alone
      couldn't tell "none" from "not checked". Seen on the item 26 save,
      and again on October 6 after round ten's undo.
    - **Now:** a live save always gives `leftovers`, an empty list when the
      folder held none. The note still comes only with a leftover. The
      Python `save` tool says so.

## Verification

- **Swift:** 854 tests, 0 failures, 6 skipped. New tests:
  - **A merge (29):** a merged scene's airwires come from the addition
    when its connection lines are replaced, and are appended otherwise.
  - **`render_viewport` and `board_info` (29),** through a registered live
    document:
    - **No canvas:** `source` is "connectivity", and `board_info`'s
      `canvas` is null.
    - **A canvas that agrees:** `matches_check` is true.
    - **A canvas with an airwire `check` lacks:** `matches_check` is false,
      the net comes back as `canvas` 1, `check` 0, `only_canvas` 1, and
      `in_view` counts the straight horizontal airwire.
    - **The pixels:** more than 10 airwire-blue pixels across the render's
      middle, and none with `airwires: false`.
    - **Direction:** the same airwire reversed matches.
  - **A clean save (30):** gives `leftovers` as an empty list.
- **Python:** 65 tests OK, against this worktree's release build
  (`make python-test`).
- **iOS:** `make ios` builds, so the iPad view's change compiles.
- **Billo, on a disk copy:** a scratch render of the whole board at 300 dpi,
  with its 32 airwires, put them where the model says. They fan into J2's
  pins at x ≈ 82 mm, and one runs from MP1's centre (3.5, 0) to
  (16.5, −3). The scratch test wasn't kept.
- **Not tested directly:** the view code. There's no harness for:
  - `BoardCanvasView` recording its scene's airwires;
  - the macOS and iPad documents reading them through the board pane's
    command actions.
  The live check will tell.
- **Live:** waits for a rebuilt app and a new session.

## Open

None.
