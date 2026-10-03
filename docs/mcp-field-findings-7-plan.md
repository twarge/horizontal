# MCP field findings 7: a search that finds smashed texts, a save that keeps to its edit

Planning baseline: `e241344`. Written October 3, 2026, from two notes taken
during the live check of [round six](mcp-field-findings-6-plan.md) on Billo.

## Findings and changes

24. **A refdes search found nothing unless smashed was passed too.**
    - **Before:** on Billo, `list_board_texts` with `text: "U1"` returned
      `[]`. U1's reference is a smashed text, and smashed texts were left
      out unless `smashed` was passed. `component` implied `smashed`, but
      `text` did not, and an empty reply gave no hint why. Round six's own
      checklist needed `smashed: true` beside `text: "U1"`.
    - **Now:** a `text` search looks through smashed texts too, as a
      `component` filter does, on `list_board_texts` and `list_texts`.
      `smashed: false` keeps them out of a search. A listing with neither
      filter still gives free text alone, so the default reply on a
      populated board stays small. Each smashed text is still marked
      `from_smash`, with its part's `refdes`.
    - **The Python client:** it passed `smashed or None`, so `False` never
      reached the engine. It now passes `smashed` whenever it is given.
25. **A save after an edit in the app rewrote more than the edit.**
    - **Before:** in round six's live check, moving the text "Amplifier"
      one grid step on Billo's Interface sheet and saving changed its
      `shift[0]` from 178.75 to 180 mm, as intended. The format was right.
      But the save, through `HorizontalProjectJSONApplicator`, also:
      - **No-connects:** wrote all 15 of Billo's no-connect marks (on J4,
        U1, U2, U6, U7, U10, U12, U13, U18 and U27–U29) as `{}` instead of
        `{"net": null}`. `.notConnected` removed `net` rather than writing
        `null`. Horizon EDA reads it with `j.at("net")`
        (`src/block/component.cpp`), so it logs "error loading connection"
        for each and loses the mark on its next save. Horizontal reads `{}`
        as a no-connect, so only Horizon EDA was affected. This has been
        there since `3d46d7c`. MCP saves install the whole project and never
        took this path, so round six's writer was the first to show it as a
        clean diff.
      - **Wires:** gave all 64 wires on the edited sheet a `net`. Horizon's
        `LineNet::serialize` writes only `from` and `to`.
      - **The moved text:** wrote `allow_upside_down: false` on it. Horizon
        writes that key only when it is true.
      - **The grid:** added `grid_settings` at the top of
        `top_schematic.json`. Horizon keeps no grid in a schematic file, and
        Horizontal's loader gives a schematic its fixed 1.25 mm grid without
        reading one.
    - **Now:**
      - **No-connects:** `.notConnected` is written as `"net": null`. The
        app's model makes `.notConnected` only from a connection entry it
        loaded without a net, and it never removes an entry, so this writes
        back exactly the marks it read. A file an earlier save left with
        `{}` gets `null` back on its next in-app save.
      - **Wires:** a wire's `net` is written only where the file already
        stores one, or for a wire that is new. Horizontal's connectivity
        uses a stored wire net as a fallback for an island with nothing
        else naming its net. So one an MCP edit left is kept up to date,
        not dropped, and a new wire gets one as `draw_net_line` gives it.
        Junctions were already written back as loaded.
      - **Texts:** `allow_upside_down` is written only when it is true, and
        removed when it is turned off, as Horizon and the pool editors
        already do. This applies to sheet and board texts.
      - **The grid:** the schematic save no longer writes `grid_settings`,
        and drops one an earlier save left, since nothing reads it. The
        board keeps its grid as before.
    - **Left as is:** the 64 wires on Billo's Interface sheet keep the
      `net` the 18:23 save gave them. Horizon ignores them, and Horizontal
      keeps them correct from now on.

## Verification

- **Swift:** 818 tests, 0 failures, 6 skipped.
  `HorizontalMCPFieldFindingsTests` has 28. Both new tests failed against
  `e241344`'s sources (4 failures) and pass now:
  - **A search through smashed texts:** a board text and a sheet text
    named "R1", marked smashed, are found by `text: "r1"` on
    `list_board_texts` and `list_texts`, and kept out by
    `smashed: false`. A listing with no filter still gives free text
    alone.
  - **An in-app save that keeps to its edit:** the files are set up as
    the 18:23 save left Billo: wires with no `net`, a stray
    `grid_settings`, and a no-connect written as `{}`. A text is moved
    through the applicator. The block then differs only in that
    no-connect, which is back to `{"net": null}`. The schematic differs
    only in the text's `shift[0]` and the dropped grid. Turning
    `allow_upside_down` on then writes `true`.
- **Python:** 64 tests, all passing, against this branch's debug CLI and
  release build. The new test marks a board text smashed on disk and
  checks that a search finds it and `smashed=False` keeps it out.
- **Billo, on a disk copy (debug build):** this was the save of round
  six's live check reversed: "Amplifier" moved back a grid step and the
  Interface sheet applied, from the files as the 18:23 save left them.
  - **`top_block.json`:** came out byte-identical to the file before
    18:23 (SHA-1 `59da700e…`). All 15 no-connects are `"net": null` again.
  - **`top_schematic.json`:** against the files as they are now, it drops
    `grid_settings` and the text's `allow_upside_down: false`, and moves
    the text back. Against the file before 18:23, the only difference is
    the `net` on the 64 Interface wires, which stays. It is in Horizon's
    format.
- **Live:** waits for a rebuilt app and a new session.

## Open

- **MCP's `place_text` omits `layer` on a sheet text.** Horizon writes
  `"layer": 0`. Five of Billo's notes lack it. Horizon reads a missing
  layer as 0, so nothing is lost, but its next save will add the key.
