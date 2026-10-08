# MCP field findings 15: hidden alternates, no-op edits, pin order, check groups

Planning baseline: `078fa9e`. Written October 8, 2026. Items 44–49 came up
during round 14's live check on Billo that morning. Round 14 passed; these
are what it showed could be better.

## Findings and changes

44. **Turning a symbol custom_only on its own gave no warning.**
    - **Before:** committing `set_symbol_display` Port A → `custom_only` hid
      12 alternates U8's pins already had, and the reply had no `warnings`.
      Round 14's check only covered alternates chosen in the same batch.
    - **Now:** `HorizontalProjectEditor.warnings()` also takes every symbol
      the batch set to `custom_only`. For one of those, it warns about each
      pin of its gate whose `alt_pins` entry chooses an alternate and has no
      custom name. The message is the same: the instance, the sheet, the
      pins, and the `set_symbol_display` that fixes it. The op's description
      says so.

45. **A committed reply read `normalized_ops: []`.**
    - **Before:** Swift leaves `normalized_ops` out of a compact commit on
      purpose: only the dry run's copy is replayed. The Python `EditResult`
      defaulted the missing field to `[]`, which reads as "nothing applied".
    - **Now:** `EditResult` drops the key when the engine didn't send it
      (`omit_ops_not_sent`, by `model_fields_set`). The Python test that
      expected `[]` now expects the key to be absent.

46. **Edits that changed nothing weren't reported as such.**
    - **Before:**
      - `set_pin_alternate` PA0 → `TIM2_CH1`, which PA0 already had, read
        `pins_count: 1`.
      - A batch that set a mode and set it back replied `applied: 3` and
        `undo_name` "… (3 edits)".
      - Committed live, either would have pushed an undo step that undoes
        nothing.
    - **Now:**
      - **The mutation pipeline:** when no file changes, the reply gives
        `unchanged: true`, a `note`, and no `undo_name`.
        - A live commit installs nothing, so the document and its undo
          stack stay as they were.
        - A disk commit still records its receipt, so `operation_id`
          replay works, but doesn't bump the generation.
        - Either way `after_revision` equals the revision it started from.
      - **`set_pin_alternate`:** marks each pin whose entry ends up as it
        was with `unchanged: true`, and the change lists them in
        `unchanged_pins`, which a compact reply keeps.
      - **`undo_name`:** counts only the pins that change, so "PA2 again,
        PA10 cleared" is "Set Pin Alternate".

47. **Pin lists came in uuid or plain string order.**
    - **Before:** `set_no_connect all` gave PC15, PC8, PC13, PC9, … (unit
      pin uuid order). `get_component` gave PA0, PA1, PA10, PA11, …, PA2.
    - **Now:**
      - The design index sorts a component's pins within each gate by
        `localizedStandardCompare`, so they read PA1, PA2, PA10. That
        covers `get_component` and everything else that lists them.
      - `set_no_connect all` sorts the pins it took by name the same way.
      - `pins` and `pin_names` stay parallel lists. A list of
        `{pin, pin_name}` would have broken `pins` for existing callers.

48. **`symbol_id` in `get_component` `symbols` was the instance again.**
    - **Before:** `symbol_id` and `symbol_instance` held the same uuid. In
      `list_symbols`, `symbol` is the pool symbol, so `symbol_id` read like
      one.
    - **Now:**
      - `symbols` gives `symbol_instance` (list_symbols' `id`) and `symbol`
        (the pool symbol, as list_symbols gives it). `symbol_id` is gone.
      - `HorizontalDesignSymbolPlacement` carries `poolSymbolID` for it.
      - Analysis image export, the one reader of `symbol_id`, reads
        `symbol_instance`. It falls back to `symbol_id` for evidence
        pinned before this change.

49. **`check` listed every finding one by one.**
    - **Before:** on Billo, 49 "Not placed on the board" warnings, one per
      package, plus 19 airwire lines.
    - **Now:**
      - Findings that share a level, category and title, more than three of
        them, come back as one message. It has `count`, and `refdes` or
        `nets` with the names in their usual order.
      - A detail they all share stays `detail`. Otherwise `details` maps
        each name to its own ("Cell Thermistor +": "1 airwire remain.").
      - `counts` still counts every finding.
      - `full: true` (Swift `check`, Python `check(full=True)` and the MCP
        tool) lists them one by one as before.
      - `full` joined the dispatch layer's boolean parameters.

## Tests

- **`testNoOpEditsHiddenAlternatesPinOrderAndGroupedChecks`** covers:
  - natural pin order in `get_component` and in `set_no_connect all`'s
    `pin_names`
  - `symbol_instance` and `symbol` matching `list_symbols`, and no
    `symbol_id`
  - the warning from a lone `set_symbol_display` custom_only, and none after
    selected_only
  - a re-chosen alternate: `unchanged` on the pin, `unchanged_pins`, the
    batch's `unchanged`, no `undo_name`, an empty `would_write`, and the
    revision kept
  - a mode set and set back, which also nets to `unchanged`
  - "Set Pin Alternate" for a batch where one of two pins changes
  - `check` grouping four undrawn components, and `full` listing them
- **`test_edit_replies_are_compact_unless_verbose`** (Python): a compact
  commit has no `normalized_ops` key.
- Not covered by a unit test: a live no-op commit leaving the app's undo
  stack alone. That's for the live check.
