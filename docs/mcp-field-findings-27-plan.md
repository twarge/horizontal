# MCP field findings 27: shared dependencies in update review, and keys a search field lost

Planning baseline: `eb1f890`. Written October 13, 2026. Both items came up
while live-checking rounds 23–26 on Billo, and are recorded in billo's
`docs/horizontal-mcp-notes.md`. Item 89 was reported by the user.

## Findings and changes

88. **26 of Billo's parts read `sourceUnavailable` in `list_part_updates`,
    saying a padstack two pools hold was in none.**
    - **Before:**
      - `list_part_updates` gave 50 `current`, 5 `updateAvailable` and 26
        `sourceUnavailable`. All 26 said "The padstack
        3846f4bf-7acf-403a-bc36-771ec675eac9 is not in any browsed pool."
      - That padstack, SMD rectangular, is `padstacks/smd-rect.json` in both
        Twinleaf Pool and the Horizon pool, and `search_pool` finds it in all
        three pools.
      - 1N4148WL2-TP, imported on 2026-10-12, was among the 26 from the
        start. Its own files have recorded origins, but SMD rectangular was
        already cached, so the import recorded none for it.
    - **Cause:**
      - `HorizontalPoolCacheUpdater.review` resolves each source item by its
        recorded origin. Failing that, it takes a pool chosen for the part,
        and failing that, an item exactly one pool holds.
      - An item with no recorded origin that two pools hold was left out.
        The importer then planned from what was resolved, missed the
        padstack, and reported it as in no pool at all.
    - **Now:**
      - Once the part's own source is known, a dependency several pools hold
        with no recorded origin comes from the pool a fresh import of that
        part would take it from. That's `editorPoolURLs(forPoolRoot:)` of
        the part's pool: the pool, the pools it includes, then the other
        base pools. For a Twinleaf part, that's Twinleaf Pool's copy.
      - A cached part that two pools hold with no recorded origin still
        needs its source chosen. That rule is unchanged.
      - If no pool can be picked, the message names the pools that hold the
        item ("The padstack … is in “Left”, “Right”, and nothing records
        which one this part's copy came from.") instead of saying none does.
      - The candidates are grouped once per review, not once per part.

89. **In a pane's search field, letters bound to canvas commands, and
    Delete, did nothing.**
    - **Reported:** "In the parts search field, I can't type freely and I
      can't use backspace. I think the app is eating letters that are
      attached to commands?"
    - **Cause, canvas:**
      - `TrackpadCanvasMonitor.MonitorView` watches the window's key events.
        While an interaction was in progress (`handlesInteractionKeys`:
        placing a part, moving, drawing a wire, track or plane), it handled
        interaction keys before asking whether a text field had focus.
      - Those keys are the command letters (c e i l m n p q r s t v w x /),
        the digits, ⇧L, ⇧V, Delete, Return, Escape and the arrows. So typing
        "tps62172" rotated, placed pads and switched layers, and Delete
        deleted the selection.
      - `handle()` also let those keys reach a canvas without keyboard focus.
    - **Menus, a likely second path:**
      - "Select Net" (⇧L), "Update All Planes" (Q) and "Clear All Planes"
        (⇧Q) were menu shortcuts with no ⌘.
      - The commands file keeps single-key shortcuts off the menus "so text
        fields can opt out cleanly" (the comment above "Select All"), and
        these three broke that convention. If AppKit offers the key to the
        menus first, Q, capital Q and capital L can't be typed in any field,
        and a Q typed there pours the board's planes.
      - Not confirmed: a probe in the test process gave the "q" to the text
        view, but a test app is never active and has no key window, so
        AppKit's key-equivalent path didn't run.
    - **Now:**
      - A focused text field keeps every key, during an interaction as well.
      - An interaction that starts while a text field has focus (Place in
        the Pools pane, say) moves the focus to the canvas, so R, E and
        Escape still act on the placement. Clicking back into the field
        gives it its keys again.
      - The three menu items lose their key equivalents, as the canvas's
        other single-key commands already had (see the comment above
        "Select All"). ⇧L reaches Select Net through the canvas as before.
        Q and ⇧Q are handled by the workspace key monitor next to L
        (highlight), which skips them while a text field has focus. On a
        focused board canvas Q still pours through the canvas, calling the
        same `updateAllBoardPlanes`.

## Tests

- **`testDependencyInTwoPoolsWithoutOriginComesFromThePartsPool`**: a
  padstack with no recorded origin, also held by another pool, reads
  `current`. When the part's pool changes it, the update comes from that
  pool.
- **`testDependencyOnlyInOtherPoolsNamesThemInsteadOfNone`**: a dependency
  held only by two unrelated pools names both and no longer says "not in
  any browsed pool".

  With the old updater both fail, the first with Billo's message.
- **`testFocusedTextFieldKeepsEveryKeyDuringAnInteraction`** (in
  `SchematicKeyboardMoveTests`):
  - An interaction starting while a text view has focus takes the focus,
    asks for keyboard focus once, and R then rotates.
  - With the text view focused again, t, p, s, 6, r, Delete, Escape and
    Return all pass through, and no command runs.

  With the old monitor, the focus stays in the text view and t, p, s, 6,
  r and Delete are taken.
- **Billo, read-only:** the review over Billo's own pool and both base pools
  gives 74 `current` and 7 `updateAvailable` (was 50, 5 and 26
  `sourceUnavailable`, matching the live reply).
  - XFL2010-222MEC and XFL3012-103MEC now also show a symbol the Horizon
    pool has that the cache lacks ("New library item").
  - OPA620 still shows one change, its MPN.
  - The probe took 4.2–4.6 s with the debug build, either way. It was a
    temporary test and isn't committed.
- **Results:** Swift 879 tests (6 skipped, 0 failures). No Python changed.
  The app builds in Xcode (Debug, with its own DerivedData under `/tmp`).
  The release products were rebuilt (`make native`, 09:06) once the live check
  of rounds 23–26 had finished, since the running server used them.
- **Live, on Billo** (app built from `38dbfbe`): `list_part_updates` gives 74
  `current`, 7 `updateAvailable` and 0 `sourceUnavailable`, matching the
  probe. The user can type everything in the search field.
