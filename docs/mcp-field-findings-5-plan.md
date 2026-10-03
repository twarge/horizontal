# MCP field findings 5: names, a project title, and free text

Planning baseline: `f91c28e`. Written October 3, 2026, from three notes taken
during the live check of [round four](mcp-field-findings-4-plan.md) on Billo,
and while trying to rename the project from Roxanne to Billo.

## Findings and changes

14. **A batch could not name what it made, and a failure did not say which
    op.**
    - **Before:** a batch gave two junctions the ids `"s1"` and `"s2"` so
      later `draw_net_line` ops could name them. The reply was
      `INVALID_ARGUMENT` "id must be a UUID.", with empty details. The batch
      had four ops, and nothing said which one failed. Every id a batch mints
      needed a `uuidgen` first. `place_symbol` was no different, despite what
      the `apply_ops` text implied.
    - **Names:** an op that makes something under an id (`place_junction`,
      `place_symbol`, `draw_net_line`, `ensure_component`, `ensure_net`, and
      the `add_` ops for buses, members, net ties, net classes and block
      instances) may now give a short name instead.
      - `HorizontalEditHandles` rewrites the batch before anything runs. Each
        name becomes a UUID wherever a later op refers to that kind of thing:
        a wire end's `junction`, `symbol` or `component`, a `line`, `net`,
        `bus`, `instance` and so on.
      - A name stands for its own kind only. A junction called `GND` leaves
        every net field alone, and a track's ends, which name board
        junctions, are never touched.
      - The UUID is name-based, from the revision, the kind and the name. A
        dry run and its commit therefore mint the same ones, and the plan
        digest still matches when the commit cannot reuse the staged edit.
      - The reply's `handles` maps each name to its UUID, and the normalized
        ops carry the UUIDs.
      - One name naming two things is refused.
    - **Errors:** a failing op's error now starts `ops[3] place_junction:`,
      and the error's `details` carry `op_index` and `op`. This applies both
      to an op the engine cannot read and to one that fails as it runs.
15. **The project could not be renamed.**
    - **Before:** "Roxanne" was in `project_meta` in the top block, in the
      schematic's own `title_block_values`, and in seven export settings
      across three files. No op reached any of them. The silkscreen and the
      fab notes print `$project_title`.
    - **Now, `set_project_meta`:** sets or removes title-block values.
      - They live in the top block, which is where the board and Horizon
        read them.
      - The schematic's copies, for the whole schematic and per sheet, win
        on the sheets they cover. A key a copy already holds is changed
        there too, so the sheets and the board agree. The logic is
        `HorizontalTitleBlockChanges`, which the app's own editor now shares
        (see below).
      - Values are trimmed, and blank or `null` removes a key, as in that
        editor.
    - **Now, `set_export_settings` and `export_settings`:** a field merge
      into one kind of the export settings Horizon EDA keeps: gerber, odb,
      pick_and_place, board_step, board_pdf, bom or schematic_pdf.
      - Only fields the settings already hold are accepted, each with the
        type it has. A misspelt key or a number where a string belongs would
        stop Horizon opening the project.
      - A project with no settings of that kind is refused rather than given
        a partial object.
      - `export_settings` reads them back.
      - Horizontal's own `export` names its files after the project file and
        reads none of this, which the docs now say.
16. **`list_board_texts` returned 52 KB to show 8 texts.**
    - **Before:** on Billo, 154 of the board's 162 texts are reference
      designators smashed out of packages.
    - **Now:** `list_board_texts` and `list_texts` leave smashed texts out
      unless `smashed` is passed. Both describe themselves as free text, and
      a smashed text belongs to its package or symbol. `text` keeps only
      texts containing a string, ignoring case.

## Found along the way: the app's own title-block editor

The information panel's Project Metadata fields had the same blind spot, and
a second one.
- **Copies:** they wrote only the top block's `project_meta`. On Billo,
  renaming the title there would have changed the board's silkscreen and
  left every schematic title block saying Roxanne, because the schematic's
  own copy wins on its sheets.
- **Redraw:** they patched the in-memory project and the archive, but the
  loader bakes title-block values into each sheet's frame and the board's
  texts. Even without a copy, the drawing kept the old value until the
  document was reopened, and the change was not on the undo stack.
- **Now:** an edit goes through `HorizontalProjectJSONApplicator.apply(titleBlockChanges:)`,
  which patches the block (the project file when there is no block) and the
  copies that hold the key. Then `applyLiveArchive` reloads, redraws, and
  records "Edit Project Metadata" for undo, as sheet rename and reorder do
  since `2114efa`. An edit that changes nothing records nothing.
- **Fields:** since applying an edit reloads the project, a field now applies
  its value on Return or when it loses focus, not at every keystroke. An
  undo or an automation edit updates a field that is not being typed in.
- **iPad:** the iPad project view has no metadata editor, so it was not
  affected.

## Verification

- **Swift:** 811 tests, 0 failures, 6 skipped. `HorizontalMCPFieldFindingsTests`
  has 22. The five new ones cover:
  - names in a batch: kinds kept apart, the same UUIDs on a commit that
    cannot reuse its dry run, and a clash refused;
  - op-located errors, both from reading an op and from running it;
  - title-block values reaching the block and both schematic copies;
  - export settings: refused when absent, merged when present, strict on
    fields and types;
  - smashed board texts left out unless asked, and the text filter.

  The editor test of a symbol's smashed text now asks for smashed texts.
  `HorizontalSheetEditingTests` has one more. In it, a project keeps
  "Roxanne" in the block, the schematic's copy and one sheet's copy. A
  block-only edit, which is what the panel used to do, leaves both framed
  sheets drawing "Roxanne R1B". `apply(titleBlockChanges:)` makes them,
  and the board's `$project_title`, read Billo after a reload. Blank removes
  a key everywhere, and an unchanged value changes nothing.
- **Python:** 62 tests, all passing, including one on names and
  op-located errors and one on project meta, export settings and the text
  filters.
- **Billo, on a disk copy (debug build):**
  - `list_board_texts` returned 8 texts in 3,199 bytes, against 162 texts
    and 52,266 bytes with `smashed`.
  - `export_settings` was 4,625 bytes and listed the 8 Roxanne fields.
  - One batch did the rename: `set_project_meta` plus 6 `set_export_settings`
    ops. Its verbose dry run was 4,153 bytes, it wrote 3 files, and the
    commit reused the dry run in 0.3 s.
  - The diff is those 8 fields and the 2 title keys in the block and in the
    schematic copy, and nothing else. No "Roxanne" is left in any file.
  - Junctions named `s1` and `s2` came back as name-based UUIDs. A failing
    second op read "ops[1] place_junction: No net NOPE."
