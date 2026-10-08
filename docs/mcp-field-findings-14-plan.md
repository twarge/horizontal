# MCP field findings 14: what a symbol draws, empty pin-function entries, undo names

Planning baseline: `7ca754f`. Written October 8, 2026. Items 40–43 came up on
October 7, while setting the 31 pin functions of Billo's STM32H757 (U8) in
one `set_pin_alternate` op. That was round 13's live check, and it passed.

## Findings and changes

40. **A chosen alternate a symbol never draws, and nothing said so.**
    - **Before:**
      - U8's Port A symbol had `pin_display_mode: custom_only`, the only one
        of nine U8 gates that wasn't `selected_only`.
      - After the edit, `get_component` gave PA0 `display_name`
        `TIM2_CH1/TIM2_ETR`, but the sheet still drew `PA0`, and so did the
        other eight Port A pins.
      - Neither the `set_pin_alternate` reply nor `get_component` mentioned
        the mode. A render showed the problem, and reading
        `top_schematic.json` explained it.
    - **Now:**
      - **Design index:** `HorizontalDesignSymbolPlacement` carries
        `pinDisplayMode`. `HorizontalDesignPin.drawnName(mode:)` gives the
        name a symbol in a mode draws. It mirrors the sheet loader's
        `expandedPinName` (all, alt_only, custom_only, both, selected_only),
        without the overline markup.
      - **`get_component`:**
        - Each of `symbols` gives its `pin_display_mode`.
        - A pin gives `drawn_as`, a list of `{symbol_instance, sheet,
          pin_display_mode, name}`, for every placed symbol of its gate that
          draws something other than `display_name`.
        - `display_name` is now `drawnName(mode: "selected_only")`.
      - **`apply_ops`:** the reply gives `warnings` when a placed symbol
        will not draw an alternate the batch chose.
        - `HorizontalProjectEditor.warnings()` runs once the whole batch has
          run, so a `set_symbol_display` in the same batch counts.
        - It flags a symbol of the pin's gate that shows `custom_only`,
          unless the pin also got a custom name.
        - The warning names the symbol instance, the sheet and the pins, and
          gives the `set_symbol_display` that fixes it.
        - `warnings` is a top-level list of strings, so a compact reply
          keeps it.

41. **`get_component` hid empty `alt_pins` entries.**
    - **Before:**
      - U8 had 16 entries on Port C, all with `pin_names: []`, which is what
        the app's pin-function dialog leaves behind.
      - The design index dropped the 15 with `use_primary_name: false`. The
        one with `true` came back as `selected` `primary: true`.
      - They draw the primary name, so they're harmless. But the dry run
        showed 9 unexpected "changed" paths, and only the file explained
        them.
    - **Now:**
      - The index keeps every entry.
      - `selected` gains `redundant: true` when the entry chooses no
        alternate and no custom name, so it draws what no entry would
        (`HorizontalDesignPinSelection.isRedundant`).
      - `display_name` is then the primary name.
      - `set_pin_alternate` with `alternate` null already removed such an
        entry. Its parameter description now says so.

42. **Every MCP edit undid as "Apply 1 Edit".**
    - **Before:** `HorizontalDispatchMutation` named the live undo step
      "Apply N Edit(s)", so `can_undo` couldn't tell a 31-pin alternate
      change from a display-mode change.
    - **Now:**
      - A mutation's result may carry `undo_name`, and the live commit uses
        it as the undo action. The old label is the fallback.
      - **`apply_ops`:** `HorizontalDispatchMethods.undoName` titles the
        op as Horizon titles its tools:
        - one op: "Set Pin Alternate (31 pins)" when the change lists
          several pins, otherwise just the op ("Ensure Net")
        - the same op several times: "Place Text ×3"
        - mixed ops: "Set Pin Alternate, Set Symbol Display (2 edits)", and
          beyond three kinds "… and N more"
      - **The other tools:** `pool_write` "Write Pool Items",
        `update_project_parts` "Update Parts", `import_pool_part` "Import
        Part", `pour_planes` "Update All Planes", `autoroute` "Autoroute".
      - The reply gives `undo_name` too.

43. **`set_no_connect` replied with pin uuids only.**
    - **Before:** the 8 pins `all` chose on Port C came back as `gate/pin`
      uuids, and checking them meant matching against `get_component`.
    - **Now:** both forms (pins and `all`) give `pin_names` beside `pins`, in
      the same order.

## Tests

- **`testPinAlternatesSayWhatEachSymbolDraws`** covers:
  - the custom_only warning, and `drawn_as` with the symbol's mode
  - no warning when the same batch fixes the mode, and `drawn_as` under
    `both`
  - a redundant entry written into `top_block.json` read back with
    `redundant`, then removed by null
  - `pin_names` from `set_no_connect all`
  - the `undo_name` of a single, a mixed and a no-connect batch
- **`HorizontalLiveServerTests`:** the live apply now expects the undo step
  "Ensure Net".
