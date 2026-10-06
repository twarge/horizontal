# MCP field findings 12: board_info's canvas, and a render that shows what the pane does

Planning baseline: `32155bb`. Written October 6, 2026, from round
[eleven](mcp-field-findings-11-plan.md)'s live check on Billo and what the user
saw in it.

## Findings and changes

34. **`board_info` never gave `canvas` for a live document.**
    - **Before:** Billo was open live with the board pane up, and
      `render_viewport` read the canvas's airwires fine (32 on 22 nets,
      matching). `board_info` replied only `source` "connectivity", with the
      disk note ("over the files") and no `canvas` key. The same held after a
      placement and an undo.
    - **Why:** the live channel answers some reads off the main actor
      (`HorizontalLiveServer.prepareRead`), and `board_info` is one of them.
      They run against `detachedReadSession`'s copy of the entry, which has no
      live document. `airwiresSourceJSON` took a missing `entry.live` to mean
      a disk context. And `canvasAirwires` would have returned nil off the
      main thread anyway. Round eleven's test called the dispatch directly,
      which skips that path.
    - **Now:** `detachedReadSession` runs on the main actor when the live
      channel prepares a read. When the entry is live, it reads the canvas's
      airwires there, as a value, into the copy's `liveCanvas`.
      `airwiresSourceJSON` and `canvasAirwires` take that as the live answer.
      So `board_info` gives `canvas`, or null when the pane is hidden, with
      the live note, whichever path answers it.
35. **The app autosaves an edit made in it.** Seen in round eleven's live
    check. This is intended `DocumentGroup` behaviour, and the user wants it
    left alone. **Closed, no change.**
36. **`render_viewport` drew airwires with the pane's Connections switch
    off.**
    - **Before:** with the switch off, the reply said `shown: false` and the
      render drew them anyway, with a note. The tool renders "what the pane
      currently shows", and the pane showed none.
    - **Now:** by default the render does what the switch does. The reply
      says `drawn: false`, with a note that `airwires: true` draws them
      anyway. `airwires: false` still leaves them off with the switch on. The
      counts and the comparison with `check` come back either way. The Python
      tool's `airwires` defaults to unset rather than `True`.
37. **A fitted render held little detail of the board.**
    - **Before:** Billo fitted (`zoom` 0) came back 2255 × 1798 px. But the
      pane showed 191 × 152 mm, its notes and dimension lines included, so
      the 86 mm board got about 1000 px across. That's 11.8 px/mm, or about
      6 px for an 0402 pad. `dpi` is the exporter's page's, and the page is
      scaled to fit the board, so `dpi` 110 came to about 300 on the board.
      Nothing in the reply said so.
    - **Now:**
      - **`region`:** a `{min_x_mm, …}` region renders only that part of
        what the pane shows, clipped to it. The dpi is raised so the
        picture's longer side is what the whole view's would have been, and
        `max_pixels` still caps it. A region outside the view is an error
        that gives the view.
      - **The reply** gives `view` (what the pane shows) beside `region`
        (what was drawn), and `px_per_mm`.
      - **Left as is:** moving the pane with `zoom_to` still works for
        detail, but it changes what the user sees; `region` doesn't.

Escape while placing a package was raised too. It already cancels the
placement, and the user confirmed it works, so it isn't an item. One small
thing seen in passing: `cancelPackagePlacement` leaves `selectedUnplacedObjectID`
set, where a commit clears it.

## Verification

- **Totals:** Swift ran 856 tests, 0 failures, 6 skipped. Python ran 65
  tests, OK (`make python-test`, against this worktree's release build).
  No iPad code changed, so `make ios` wasn't run.
- **Swift:** `HorizontalLiveServerTests`, with two new tests:
  - **`board_info` through `prepareRead` (34):** gives `canvas` null, with
    the live note, while the pane is hidden. With a canvas holding a stale
    airwire it gives `count` 1 and `matches_check: false`.
  - **The switch and a region (36, 37):** with the switch off, the render
    draws no airwire pixels and says `drawn: false`, and `airwires: true`
    draws them. A region 20 × 30 mm in a 40 × 40 mm view, asked for past its
    top, comes back clipped to the view. It has the whole render's height
    and 4/3 its `px_per_mm`. A region outside the view is an error.
  - The round eleven test's stale airwire now has the switch on, since it
    counts the pixels drawn.
- **Live:** waits for a rebuilt app and a new session.

## Open

None.
