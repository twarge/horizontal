# MCP field findings 9: one airwire answer, a save that shows its leftovers

Planning baseline: `693e644`. Written October 4, 2026, from four notes taken
on Billo during rounds [six](mcp-field-findings-6-plan.md) and
[seven](mcp-field-findings-7-plan.md).

## Findings and changes

21. **The app and MCP gave two airwire answers.**
    - **Before:** on Billo the loader gave 328 airwires and the editor's
      connectivity pass gave 32. Each answer reached a different reader:
      - **The app:** it installs the loaded project as it is and draws the
        loader's 328.
      - **MCP reads:** `get_net`, `list_nets`, `board_info`, `check`,
        `netlist`, `autoroute` and `zoom_to` answer from the editor's pass.
    - **Cause:** both answers come from `HorizontalBoard.generateAirwires`,
      given different junction nets.
      - **The loader:** it reads a junction's net only from a `"net"` key in
        `board.json`. Horizon writes none, and none of Billo's 2,440
        junctions has one.
      - **`generateAirwires`:** it makes a junction a node only when the
        junction has a net. It joins two nodes through a track only when
        both of the track's ends land on nodes.
      - **The effect:** a track ending at a bend joined nothing, so every
        routed connection that bends stayed an airwire. 2,233 of Billo's
        2,378 tracks have an end on a bend, a junction that is neither a pad
        nor a via.
      - **The editor's pass** (`HorizontalBoardConnectivity.recompute`)
        gives each junction the net of its copper first. Its 32 are what
        `check` reports: 29 unrouted connections on 19 nets, and 3 nets the
        plane doesn't reach.
    - **Now:** the loader derives junction nets for its airwires.
      - **The rule:** `resolveBoardConnectivity` gives each junction with
        no stored net the net of the copper at its point, when every layer
        there agrees. That is the rule `recompute` uses. `generateAirwires`
        gets those nets.
      - **Not stored:** the derived nets aren't put on the board, since a
        save writes the board's junction nets into the file.
      - **The result:** on a disk copy of Billo the loader gives 32
        airwires, the same 32 edges as the editor's pass.
    - **Copper that joins two nets:** a first version took a junction's
      net from the tracks and vias meeting at it, and gave 31.
      - **Why:** 22 of Billo's tracks are on copper that touches two nets,
        among them SHIELD, ADC1 IN+, ADC1 IN− and an unnamed net. The
        editor clears those tracks' nets, so their junctions join nothing.
        The loader keeps them.
      - **The fix:** taking the net from the copper island, as the editor
        does, leaves a junction on such copper without a net, and the two
        answers match.
    - **Placing a package in the app:** the same gap opened again there.
      - **Before:** `commitPackagePlacement` regenerated the airwires
        before the connectivity pass, from the board's junction nets as
        loaded. Billo's board has none, so placing a package brought back
        all 328. On the disk copy, regenerating before the pass gives 328
        and after it 32.
      - **Now:** `publishConnectivityResolvedEdit` regenerates them after
        the pass when asked, and package placement asks.
    - **A comment:** the one on `withEditorConnectivity` said the editor
      regenerates airwires after every edit. It now says what the pass
      does and why the two answers agree.
    - **Left as is:** smaller differences in what the two paths feed
      `generateAirwires`. They change nothing on Billo:
      - a pad with no copper polygon;
      - which of a via's nets wins;
      - track nets on copper that joins two nets, which the loader keeps.
22. **A save left a safe-save file beside the project file.**
    - **Before:** after the 17:04 save on October 3, `Billo Horizon/` held
      `Billo.hprj.sb-ec53240b-ZysDK4`, byte-identical to `Billo.hprj`. That
      save was an MCP save, round five's rename. The file was gone by about
      18:20, and no save since has left one: the in-app saves at 18:23 and
      20:31, and the saves at 15:10 and 15:29 on October 4.
    - **What writes `Billo.hprj`:** only AppKit's `NSDocument` safe save,
      under SwiftUI's `DocumentGroup`.
      - **No app code** makes or removes a `.sb-` file.
      - **The sibling JSON files** go through `HorizontalProjectTransaction`
        (`Data.write(.atomic)`, and only when they changed).
      - **The name:** `<name>.sb-<hex>-<chars>` is, as far as we know, the
        sandbox's name for a safe save's temporary file beside the file it
        replaces.
    - **The likely cause, not shown:** an MCP save calls `writeSafely`
      directly. That's deliberate: the queued save would have to finish on
      the main thread, which is the one answering the request. It skips what
      `NSDocument.save(to:…)` wraps around `writeSafely`, its queueing with
      an autosave and its coordinated write. That is the likeliest way a
      save's last step, removing the temporary file, could be skipped.
    - **Now:** a live save's reply names any `<project file>.sb-*` beside
      the file in `leftovers`.
      - **Each entry** says whether it is `same_as_file`, with a note.
      - **Nothing is deleted:** such a file may be the copy that was moved
        aside.
    - **Left as is:** the direct `writeSafely`. Using the queued save means
      answering a live request off the main thread. That's a larger change,
      and without a reproduction it couldn't be shown to help.
23. **The MCP tests ran a binary `make` doesn't build.**
    - **Before:** `test_mcp.py` and `test_stdio.py` pinned
      `.build/debug/horizontal`, but `make python-test` builds only the
      release products. On `e241344` the tests ran a debug CLI from before
      rounds three to six, and six failed on ops it didn't have.
    - **Now:** both tests take their CLI from `tests/cli_under_test.py`.
      - **The choice:** `HORIZONTAL_CLI` if it is set. Otherwise the
        checkout's release build, then its debug one, the order the server
        takes.
      - **Found from the tests' own checkout:** run from `tests/`,
        `find_cli` resolved through the virtualenv's installed package and
        picked the main checkout's CLI.
      - **A stale binary:** a CLI older than any Swift source in the
        checkout fails at import, naming the binary and the newer source,
        and says to run `make native`.
      - **The Makefile:** its comment on `python-test` now says it runs
        against the release dylib and CLI.
26. **MCP's `place_text` left `layer` off a sheet text.**
    - **Before:** Horizon writes `"layer": 0` on every sheet text. Five of
      Billo's notes, written by `place_text`, have none. Horizon reads a
      missing one as 0, but its next save adds the key.
    - **Now:** `place_text` writes `"layer": 0` on a new text. A text it
      touches without one gets it too, so passing only an `id` repairs one.
      A new text has exactly the eight keys Horizon writes.

## Verification

- **Swift:** 825 tests, 0 failures, 6 skipped. New tests:
  - **A bend with no stored net (item 21):** a pad-to-pad route through a
    bend, with the junction nets taken out of `board.json` as Horizon would
    write it.
    - **The loader:** gives 0 airwires on that net and stores no junction
      nets.
    - **The editor's pass and `get_net`:** give 0 too.
    - **The placement order:** regenerating after the pass gives 0.
    - **Against `693e644`:** the loader gave 1.
  - **Leftovers (item 22):** the leftover finder names only the project
    file's own `.sb-` files and says which match it. A live save whose
    document leaves one reports it and leaves it on disk.
  - **Layer (item 26):** a new sheet text has Horizon's eight keys,
    `"layer": 0` among them. A text with no `layer` gets it when touched,
    and nothing else about it changes. Against `693e644` it had no
    `layer`.
- **Python:** 65 tests, all passing, against this branch's release CLI,
  picked by `cli_under_test`. Before `make native` ran here, the picker
  refused the worktree's debug CLI, which was older than the edited
  sources.
- **Billo, on a disk copy:** the loader and the editor's pass each give
  32 airwires, the same edges, where the loader gave 328 before.
  Regenerating as package placement now does gives 32 too, and 328 in the
  old order.
- **Not tested directly:** the reorder in `commitPackagePlacement` is
  inside the board canvas, which no test drives through a placement. The
  model calls it makes are tested.
- **Live:** waits for a rebuilt app and a new session.

## Open

- **Billo's copper that touches two nets.** It is a design question on
  Billo, not a finding about Horizontal. The 22 tracks include copper on
  SHIELD, ADC1 IN+, ADC1 IN− and an unnamed net.
