# MCP field findings 6: what a text draws, one JSON format, named texts, faster dry runs

Planning baseline: `46d71d3`. Written October 3, 2026, from four notes taken
during the live check of [round five](mcp-field-findings-5-plan.md) on Billo,
when the project was renamed from Roxanne to Billo.

## Findings and changes

17. **Smashed board texts could not be found by refdes.**
    - **Before:** on Billo, `list_board_texts` with `smashed: true` and
      `text: "U1"` returned `[]`. Each smashed text stores the template
      `$RD`, and the reply named its owner only by `package` UUID. Finding
      one part's silkscreen reference meant reading all 52 KB and joining
      packages to components by hand.
    - **Now:**
      - Every text that is drawn as something other than what it stores
        says what in `drawn`: `$RD` reads `U1`, and `$project_title R$rev`
        reads `Billo R1B`. The value comes from the loaded board, which
        already substitutes them for drawing, so nothing new decides what a
        text says.
      - A smashed text carries the `refdes` of its part.
      - `text` matches what is stored or what is drawn.
      - A new `component` filter (a refdes or id) keeps only the texts
        smashed out of that part, and implies `smashed`.
      - Texts sort by what they draw, so C1, C2 and C10 come in that order.
    - **Schematic:** `list_texts` gets the same `drawn`, `refdes`,
      `component` and matching, for texts smashed out of symbols
      (`$REFDES`).
18. **Two JSON formats, depending on which path last wrote a file.**
    - **Before:** on Billo, `top_block.json` had last been written by an
      edit made in the app, through `HorizontalProjectJSONApplicator.saveJSON`.
      That writer uses Foundation's pretty-printer: two-space indent,
      `"key" : value`, and a trailing newline. The rename went over MCP, whose editor writes as Horizon EDA
      does: four spaces, `"key": value`, no newline. The 3-field change came
      out as 12,380 lines of diff, and the dry run's `after_bytes` grew by
      31.7 KB for an edit that shrank the file by 8 bytes.
    - **Who wrote what:**
      - Horizon's way, through `HorizontalHorizonJSONWriter`: the MCP
        editor, every pool writer, and Horizon itself.
      - Foundation's way: the app's own edits (the applicator), the
        new-project template, and the schematic clipboard. The clipboard
        wrote a third variant that also escaped `/`.
    - **Now:** all three write through `HorizontalHorizonJSONWriter`. An edit
      in the app and one over MCP leave the same bytes, and a new project
      starts in the format its first edit keeps. The template test that
      pinned the trailing newline now checks Horizon's format instead.
19. **A text could not be named in a batch, and a gone handle showed only
    its UUID.**
    - **Before:**
      - `place_text` with `"id": "t1"` failed:
        `ops[3] place_text: No text t1 on any sheet`. On a text op, `id`
        meant "the text to edit", so a batch could not name a new text and
        refer to it later.
      - When `remove_net_line w1` also removed the two junctions it left
        bare, a later `remove_junction j2` said
        `No junction 1bac7604-… on that sheet`. That was correct but gave
        neither the name nor the reason.
    - **Now, texts:** `place_text` and `place_board_text` make and edit under
      one id.
      - An id that names a text edits it; one that names none makes the
        text under it, as `place_junction` and the other making ops do.
      - So both join the ops that take a batch name, and `remove_text` and
        `remove_board_text` take that name as their `id`. A second
        `place_text` with the same name edits the text the first one made.
      - Making a text needs its words and its place (and a layer on the
        board). A mistyped id on a move or a re-word still fails as not
        found rather than making a stray text.
    - **Now, errors:** an op that fails over something a batch name stood
      for gives the name beside the UUID. If an earlier remove, retire or
      prune op in the batch removed that thing, the error names it. For
      example: `ops[4] remove_junction: No junction j2 (1bac7604-…) on that
      sheet. ops[3] remove_net_line removed it earlier in this batch.` The
      details carry `handle` and `removed_by`.
20. **Live dry runs spent 13–17 s in `load_ms`.**
    - **Measured, on a disk copy of Billo in a debug build (the app was a
      Debug build too):** a 2-op dry run took 4.7 s, and 4.5 s of it was
      loading the staged project.
      - **The board load:** generating airwires took 1.76 s of it.
      - **The editor's connectivity pass, run on top:** regenerating them
        took another 1.72 s.
      - **Everything else:** archive write, the 42 MB `planes.json`,
        schematics, pool. About 0.7 s together.
    - **Why live was three times that:** the app was in the background.
      `ps -M` showed its main thread at priority 4 with the throttled
      flag. App Nap had put it at background priority, on the efficiency
      cores, and nothing the live server did said a request was waiting.
    - **Changes:**
      - **App Nap:** the live server holds a
        `.userInitiatedAllowingIdleSystemSleep` activity for each request,
        so it runs at the priority the user's own edits get.
      - **Airwires:** a node of a poured net was tested against every
        vertex of every fragment of the pour. On Billo that is up to 467
        nodes, an outline of 15,445 vertices and 225 paths per fragment, on
        each layer. `HorizontalBoard.PlanePath` skips a path whose box does
        not hold the point. On a long path it files edges by height band,
        so a point walks only the edges that span its height, with the
        crossing test unchanged. The answers are the same; airwires went
        from 1.7 s to 0.2 s.
      - **The connectivity pass:** a live dry run no longer gives the staged
        project the editor's connectivity pass. A live document installs
        the project as loaded, and the session derives its own afterwards.
        A disk context still gets it, since it reads from that project.
      - **The "before" load:** the diagnostics a commit compares against
        used to load the whole project as it was, the first time after
        every outside change. They are now loaded only when the edit leaves
        diagnostics. With none, nothing can have been introduced. That
        load was the 5 s `diagnostics_ms` of the rename's dry run.
    - **What the note guessed:** it suggested caching the parsed snapshot by
      `snapshot_id`. That would not have helped: every dry run stages a new
      snapshot, and no load was repeated for an unchanged one.
    - **Found along the way:** on Billo the editor's pass gives 32 airwires
      where the loader gives 328. The app installs a loaded project as it
      is, so it draws the loader's, while MCP reads (`get_net`, `check`)
      answer from the editor's. That is outside
      this round; see Open.

## Verification

- **Swift:** 816 tests, 0 failures, 6 skipped.
  `HorizontalMCPFieldFindingsTests` has 26. The four new ones cover:
  - a part's smashed texts on the board and a sheet: by `component`, with
    `refdes` and `drawn`, matched by what they draw, with free text alone
    by default;
  - an edit through the applicator written in Horizon's format, differing
    from the MCP-written file by the one changed line;
  - texts made, edited and removed by name in one batch; a mistyped id on a
    move still refused; and the junction a wire's removal took, named with
    the op that took it;
  - `PlanePath.contains` against `HorizontalBoardOutlines.contains` on 24
    polygons of 3 to 532 vertices, at 1,500 points each plus every
    vertex, on a half-unit grid so points land on vertex heights.
- The template test now checks each file is in Horizon's format.
- **Python:** 63 tests, all passing, run against this branch's release
  build. One new test covers `drawn`, named texts and the `component`
  filter.
- **Billo, on a disk copy (debug build):**
  - **Dry run:** the same 2-op dry run took 1.4 s, down from 4.7 s.
    `load_ms` went from 4,560 to 1,211, `HorizontalProject.load` from 2,385
    to 843 ms, and `withEditorConnectivity` from 1,813 to 258 ms.
  - **Airwires:** the loader's 328 and the editor's 32 are the same edges
    before and after the change. Only the order of an airwire's two ends
    differs, and that already varied from run to run with dictionary order.
- **Live:** waits for a rebuilt app and a new session. The App Nap change
  can only be seen there.

## Open

- **Two airwire answers:** the loader and the editor's connectivity pass
  disagree on Billo, 328 airwires against 32. The app shows one and the MCP
  reads report the other. Which is right needs looking at a net where they
  differ.
