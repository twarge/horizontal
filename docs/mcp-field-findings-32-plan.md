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
       `parametric_formatted`), so `voltage` "3.0" reads "3 V", under the
       column's display name.
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
    - `${p:voltage}` reads "3.0" without a table and "3 V" once the project
      pool has one;
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
- **Results:** see below.
