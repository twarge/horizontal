# MCP field findings 32: sheet warnings in check, custom values, sheet frames

Planning baseline: `33527d8`. Written October 13, 2026. All three items came
from the user working on Billo: 99 from "Label missing" markers on the canvas
that `check` didn't mention, 100 from wanting an LTC6655 reference to show its
MPN under its value, and 101 from two of Billo's sheets having no frame.

## Findings and changes

99. **`check` didn't report the warnings the schematic canvas draws.** The
    canvas marks Horizon's sheet warnings (`HorizontalSchematicWarnings`):
    Label missing, Pin connected to net, Power sym missing, Pin on line, Zero
    length line, Duplicate net name, Need 'show port' net label, Duplicate
    refdes and the rest. `check` never ran them, so a sheet the user saw
    covered in markers read clean through MCP.
    - **The rules, once:** `HorizontalSchematicWarnings.findings` is the old
      `evaluate` body. Each warning carries its position, the canvas's words,
      a title without what they name ("Pin connected to net"), and the net,
      component and pin it is about. `evaluate`, which the canvas calls, now
      groups the findings into markers exactly as before.
    - **In `check`:** every sheet of every block, through
      `HorizontalDesignIndex.schematics(of:)`, each sheet evaluated against its
      block's sheets as the canvas does. Every finding is one message:
      - `level` "warning", `category` "schematic", `title` the stem;
      - `sheet`, `sheet_name`, `sheet_id`, `x_mm`, `y_mm`, and `message`, the
        canvas's text;
      - `net` when it is about a named net, and `refdes` and `pin` when it is
        about a part's pin or symbol;
      - `block` and `block_id` on a sub-block's sheet;
      - `detail`, all of that as a sentence: "Sheet 2 (Power) at (x, y) mm:
        Pin connected to net: NA (U2 pin A)", or "Sheet 1 (Sheet 1) at (x, y)
        mm, net SWDIO" for a Label missing."
    - **Left out:** Duplicate refdes, which check already reports as the
      annotation error "Duplicate reference designator" (a review fix, below).
    - **Grouping:** check's existing rule applies. More than three with one
      title come back as one message with `count`, the `refdes` or `nets` they
      name, and `details`. Messages with the same name sort by block, sheet,
      then top to bottom and left to right, so a run reads the same each time.
    - The method summary, the Python docstring and check's `note` say so.

100. **Custom values had no editor and no MCP op.** A symbol's
     `custom_value` replaces what its `$VALUE` text draws (Horizon's
     `SchematicSymbol::get_custom_value`). The inspector had a bare text
     field, and MCP couldn't read or set it.
     - **One interpolation:** `HorizontalSymbolCustomValue` holds Horizon's
       `interpolate_text` and `get_custom_value`. Before, the sheet loader and
       the canvas each had one of their own. The canvas used a regex, so an
       edit could redraw a value differently from the next load. The loader,
       the canvas, MCP and the dialog now all go through this one.
       - `${value}` is the part's value (its MPN when it has none), else the
         component's.
       - Without a part, `${mpn}`, `${mfr}`, `${desc}`, `${pkg}` and
         `${p:…}` read "None", as in Horizon. With a part, an empty field
         reads empty rather than "None".
       - A variable that names nothing stays as written.
     - **`${p:<column>}` reads as Horizon formats it:** a part's parametric
       values come through the pool's parametric table (Horizon's
       `parametric_formatted`), so `voltage` "3.0" reads "3.000 V" in a
       three-digit column, under the column's display name. (The first cut
       read "3 V"; see the review fixes below.)
       - The loader reads the tables (`tables.json` of the project pool and
         the pools it draws from, the project's winning) only once a part
         names a table, and keeps the result on `HorizontalComponentDetails`
         as `parametricFields`.
       - **Unlike Horizon:** when the table can't be found (a pool the process
         can't reach), the stored values stand in under their own keys, which
         is what Horizontal drew before. Horizon would leave `${p:…}` as
         written.
     - **MCP:**
       - **`set_custom_value`** takes `component` (and optionally `gate`) or
         `symbol_instance`, and `custom_value`. The value is trimmed as
         Horizon trims it, and "" or null removes the key, as Horizon writes a
         symbol without one.
       - **`get_component`'s `symbols`** give `custom_value` (null for none)
         and `drawn_value`, what `$VALUE` draws.
       - **Python:** a `SetCustomValue` model, which refuses a call naming
         neither or both of component and symbol_instance, and one without
         custom_value. The apply_ops and get_component docstrings say so.
     - **The app: Horizon's Edit Custom Value dialog**
       (`HorizontalCustomValueSheet`), with three columns:
       - **Insert:** rows that put a variable at the cursor. Value; and with
         a part, MPN, Manufacturer, Description, Package and one "Param:
         <display name>" row per parametric value.
       - **Edit:** the text, opening on `${value}` and a line break when the
         symbol has none.
       - **Preview:** what the symbol will draw, live. When the text is empty
         that's the plain value, which is what clearing it draws.
       - **Reached** from an "Edit…" button beside the inspector's Custom
         Value field and from the symbol's context menu ("Edit Custom
         Value…"), on macOS and the iPad.
       - **OK** is one undo step, "Edit Custom Value", through the same path
         as the inspector field. Leaving the editor on the `${value}` it
         opened with for a symbol that had none stores nothing, where Horizon
         would store `${value}`.
       - **The inspector** gained a general row action (`actionID`,
         `actionTitle`) for the button. The canvas gained an
         `editCustomValue` command.

101. **A sheet's frame could only be chosen when the sheet was made.**
     `add_sheet` took a `frame`, and the app had only View ▸ Frame, which
     shows or hides frames. Billo has two sheets with none.
     - **Where frames come from:** the loader draws a sheet's frame from the
       project pool's `frames/cache/<uuid>.json` and nowhere else. A frame
       only a base pool has draws nothing until it is copied there.
       `add_sheet` checked only that the frame was a uuid.
     - **`set_sheet_frame`** takes `sheet` (an index, name or uuid) and
       `frame`, a frame uuid or "none" (or null).
       - **The check:** the frame must be in the project pool's cache, read
         through the transaction's store, so `pool_items` in the same
         apply_ops count.
       - **A frame elsewhere is refused**, saying where it is: "Frame Stock A4
         (…) is in Stock, not the project pool, … get_pool_item reads it, and
         pool_write puts it in the project pool, or pass it as pool_items in
         this apply_ops". One in no pool at all points to `search_pool` kind
         frame.
       - **"none" removes the key**, as Horizon writes a sheet without a
         frame. The reply gives the frame, its name and the previous frame.
       - **`add_sheet`'s `frame`** goes through the same check. A new sheet
         still follows the last sheet's frame unchecked.
     - **`list_sheets`** gives each sheet's `frame`: `{uuid, name}`, null for
       none, and a null name when the project pool lacks the frame. Python's
       `Sheet` record has a typed `frame`. `HorizontalSchematicSheet` carries
       `frameID` and `frameName`.
     - **Not added:** a frame import. `import_pool_part` takes parts only. A
       frame is one file with no dependencies, which `get_pool_item` and
       `pool_write` already move.
     - **The app: a Frame menu** on a sheet's context menu in the project
       navigator, beside Rename…, on macOS and the iPad.
       - It lists the project pool's frames (`HorizontalSchematic.availableFrames`,
         read at load, since a live document's project is loaded from a
         temporary copy) and None. A frame the sheet names that the pool
         lacks shows as "(not in the project pool)".
       - A choice goes through the archive and a reload, as a rename does
         (`HorizontalProjectJSONApplicator.apply(sheetFrame:)`), so the frame
         and its title block are drawn. It is one undo step, "Set Sheet
         Frame".

## Tests

- **99**
  - **`testCheckReportsTheWarningsEachSheetDraws`**
    (`HorizontalMCPFieldFindingsTests`), on two sheets: a wire on SWDIO with
    no label, a pin wired and labelled, and a part on page 2 with four pins
    on nets and no wires.
    - **Same set as the canvas:** `check full`'s located messages are exactly
      what `evaluate` gives for each loaded sheet, by sheet, message and
      position, one each.
    - **Label missing:** names SWDIO, sheet 1 and its name, with the
      position in the detail.
    - **The pins on page 2:** each names its net, U2, its pin, "Power" and
      the canvas's words.
    - **Grouped:** without `full`, the four are one message with `count` 4
      and four `details`, and both forms count the same warnings.
  - **`testCheckReportsSheetWarningsOnASubBlocksSheets`**
    (`HorizontalProjectEditorTests`): a pin on the sub-block's port net with
    no wire is reported with `block` "sub_block", its `block_id`, sheet 1,
    VOUT, R7 and pin 1.
  - The existing `SchematicWarningsTests` pass unchanged against the
    refactored `evaluate`.
- **100**
  - **`testCustomValuesFillInAsHorizonsDo`**, on the model:
    - interpolation of each variable, case-insensitively, braced or not;
    - parametric columns formatted through a table and in key order, raw
      under their keys without one;
    - "None" without a part, and what names nothing left as written;
    - the Insert rows, with and without a part;
    - what OK stores, and inserting at a cursor and over a selection.
  - **`testSetCustomValueIsStoredDrawnAndCleared`**, through MCP on a part
    whose symbol has a `$VALUE` text:
    - the trimmed value is stored and given back;
    - `drawn_value` is "3.0 V\nLTC6655BHMS8-3", and the loaded sheet draws
      that same text;
    - `${p:voltage}` reads "3.0" without a table and "3.000 V" once the
      project pool has one;
    - "" and null both remove the key;
    - a missing value, an unknown symbol instance and a non-string are
      refused.
- **101**
  - **`testASheetsFrameIsSetListedRefusedAndCleared`:**
    - a frame written with `pool_write` is set (named in upper case) and
      listed with its name, drawn by the loader, and offered in
      `availableFrames`;
    - an absent frame is refused by `set_sheet_frame` and `add_sheet`, as are
      a non-uuid and a missing sheet, and nothing changes;
    - a new sheet follows the frame;
    - "none" and null take it away, with no key left.
  - **`testTheFrameMenuSetsAndClearsASheetsFrameInTheArchive`:** the app's
    applicator sets and clears the frame in an archive, and the reloaded
    sheet draws it and then doesn't.
  - **`testAFrameOnlyABasePoolHasIsRefusedUntilItIsBroughtIn`**
    (`HorizontalDispatchPoolTests`):
    - a frame in the registered Stock pool is refused, naming it, the pool
      and `pool_write`;
    - read with `get_pool_item` and passed as `pool_items` in the same
      apply_ops, it is cached and set, and `list_sheets` names it.
- **Python:** `test_custom_values_sheet_frames_and_sheet_warnings_through_the_typed_surface`.
  - Through the MCP tools, `set_custom_value` and `set_sheet_frame` (with
    its frame in `pool_items`) round-trip in `get_component` and
    `list_sheets`, and clear.
  - `check` gives the pin's warning with its title, net, refdes, pin, sheet
    and position.
  - The schema refuses a set_custom_value with no target, with both
    targets, or with no value, and a set_sheet_frame with no frame. The
    engine refuses an absent frame.
  - `test_the_schema_matches_the_engine_and_says_which_it_is` still matches
    with the two new ops.

## Results

- **Swift:** 896 tests (6 skipped, 0 failures), 52.6 s of tests in a 1:26
  run. That's the 889 before plus the seven above.
- **Python:** 76 OK. `make python-test` took 4:14, most of it the release
  build of the worktree's own dylib and CLI.
- **Xcode:** the app builds for macOS (`/tmp/r32-mac-dd`, 103 s) and the iOS
  Simulator (`/tmp/r32-ios-dd`, 48 s), with no warnings in the files this
  round touched.
- **Not yet checked live** (the work was done in a worktree, verified by
  tests only, and Billo was not opened):
  - **99:** `check` on Billo, and how many sheet warnings it adds to the 68
    warnings it gave before. Also how long it takes, since it evaluates every
    sheet the way the canvas evaluates the one on screen.
  - **100:** the Edit Custom Value dialog on macOS and the iPad: the Insert
    rows putting text at the cursor, the live preview, OK as one undo step,
    and the "Edit…" button and context-menu item reaching it. Then the
    LTC6655 showing "${value}\n${mpn}".
  - **101:** the navigator's Frame menu on Billo's two sheets without a frame,
    choosing the frame the other sheets use, then undo.
  - **The server and the release products on `main`** need rebuilding after
    a merge, and the MCP server a new session, for the new ops and fields.

## Review fixes

1. **`${p:…}` didn't format as Horizon does.** `formatQuantity` printed the
   fewest digits it needed ("10 kΩ"), and so did the part editor through it.
   It is now a port of `PoolParametric::Column::format`
   (`pool_parametric.cpp`):
   - **SI columns:** the value is scaled to a prefix and printed fixed to the
     column's digits, trailing zeros kept: "10.00 kΩ", "3.000 V".
   - **Other columns:** digits are significant digits, as `%g` prints them
     ("0.123 %", "1.23e+05 %").
   - **`no_milli`:** milli becomes micro below 100 and the plain unit from
     100 up.
   - **The rest:**
     - no digits means six;
     - a negative keeps its sign;
     - the number is followed by a space even when prefix and unit are empty;
     - an empty value reads "N/A";
     - a stored value that isn't a number reads as 0, as `istringstream`
       leaves it.
   - **Locale:** classic formatting with the user's decimal separator, as
     Horizon's `get_locale()` gives it.
   - **Unlike Horizon:** the scaling stops at tera. Horizon's loop runs on to
     10^15, which has no prefix and throws.
   - **The part editor's field** shows the same text, except that an empty
     value stays empty to type into rather than reading "N/A". What is typed
     still goes through `parseQuantity`, which reads "4.70 kΩ".
2. **A custom value that drew nothing stopped later edits redrawing.** The
   canvas found the `$VALUE` text by the value it last drew, and did nothing
   when that was empty.
   - **Now:** the loader records, on each placement, which texts draw
     `$VALUE` (`valueTextIDs`): the symbol's own, or a smashed symbol's sheet
     texts. The canvas redraws those by id.
   - **Fallback:** the old match by drawn text is kept only for a symbol the
     loader never saw.
3. **A part named but not read still counted as a part.** It filled
   `${mpn}` and the rest with nothing, and the dialog offered rows that
   insert nothing.
   - **Now:** `HorizontalComponentDetails.partMissing` is set when the
     loader can't read the part, and `HorizontalSymbolCustomValue.hasPart`
     (Horizon's `component->part`) counts only a part that was read. So an
     unread part reads "None", and the dialog offers only Value.
4. **Duplicate refdes twice, and the cost of check.**
   - **The duplicate:** the sheet warning "Duplicate refdes" repeated the
     annotation error "Duplicate reference designator". check leaves it out
     now; the canvas still draws it.
   - **The cost:** timed on Roxanne, read from disk and not written: 7
     sheets, 276 symbols, 3,507 pins, 1,192 wires. The sheet warnings took
     about 620 ms in a debug build, 329 ms of it on the FPGA sheet.
     - **Where it went:** the pin loop parsed the pin's id again for every
       wire, once per pin and wire, to ask whether any wire ended on it.
       Finding a node's junction scanned every junction, labels were matched
       segment by segment, and the root sort described each node twice per
       comparison.
     - **Now:** one pass collects every wire end, so a pin or port asks a set.
       Junctions are found by point in a map built in the order the scan
       went, so where several share a point the same one is found. Labels
       and power symbols are sets of nodes. The roots are described once.
     - **The answers are the same:** the warning tests pass unchanged, and
       check still equals the canvas.
     - **Timing:** 75 ms in a debug build (FPGA 33 ms). The whole check is
       20 ms through the release CLI, over four runs. Roxanne draws no sheet
       warnings, so this measures the evaluation, not a long report.
5. **`set_custom_value` took a symbol_instance together with a component
   or gate,** and quietly used the instance. Both the op and the Python
   model now refuse the mix.
6. **Frames come only from the project pool's `frames/cache/`.** That is
   the loader's limit, and `set_sheet_frame`, `add_sheet` and the Frame menu
   keep to it. Horizon also accepts a project-local frame, one kept elsewhere
   in the project pool, which it finds through its pool database. A frame
   like that is refused here, saying where it is.

**Left as they are, as asked:**
- **Whitespace-only custom value:** one in a file counts as none, though
  Horizon would draw the whitespace.
- **An unterminated `${`** is kept as written, where Horizon's
  `interpolate_text` drops it and everything after it.
- **Inserting with text selected** replaces the selection, where Horizon's
  `insert_at_cursor` inserts beside it.

**Tests:**
- **`testParametricTablesLoadAndFormat`** checks Horizon's output for SI,
  significant-digit, `no_milli`, negative, empty, non-numeric, no-digits,
  no-unit, too-small and comma-separator cases.
- **The round's tests** now read "3.000 V" and "250.00 nV".
- **`testCustomValuesFillInAsHorizonsDo`** adds an unread part ("None", only
  Value offered) and an empty field of a read part (empty).
- **`testSetCustomValueIsStoredDrawnAndCleared`** adds:
  - the loader naming the one text that draws `$VALUE`, which draws the
    value;
  - that text drawing "" for an empty `${desc}`, still under the same id;
  - symbol_instance with a component, or with a gate, refused.
- **`testCheckReportsTheWarningsEachSheetDraws`** adds two components given
  one refdes: one annotation error, no "Duplicate refdes" in check, and the
  canvas still drawing it.
- **Python** adds symbol_instance with a gate to the schema refusals.

**Results:**
- **Swift:** 896 tests (6 skipped, 0 failures), 55.7 s of tests in a 1:09
  run.
- **Python:** 76 OK (`make python-test` 2:56, with the release rebuild).
- **Xcode:** macOS 72 s (`/tmp/r32-mac-dd`) and iOS Simulator 26 s
  (`/tmp/r32-ios-dd`), with no warnings in the files touched.
