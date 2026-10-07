# MCP field findings 13: pin alternate functions, and what the inspectors edit that MCP cannot

Planning baseline: `14ce06d`. Written October 6, 2026. Item 38 came up while
setting Billo's STM32H757 (U8) pins to the functions their nets need. The
inspector survey is what the user asked for next.

## Findings and changes

38. **No way to read or choose a pin's alternate function.**
    - **Before:**
      - The H757's units list alternates on every port pin. PA5, for
        example, has `SPI1_SCK/I2S1_CK`, `TIM8_CH1N` and ten more.
      - The app's symbol inspector picks them: `pinFunctionsRow` writes
        `components[id].alt_pins[gate/pin]`, through
        `HorizontalProjectJSONApplicator.apply(symbolPinNames:)`.
      - Over MCP, none of the 77 ops wrote `alt_pins`.
      - `get_component` gave each pin's name, direction and net, but no
        alternates and no selection. Finding the choices meant walking part
        → entity → unit with `get_pool_item`. The part alone was 33 KB of
        `pad_map`.
    - **Now:**
      - **Pool index:** `HorizontalDispatchPoolIndex.Pin` carries the unit's
        alternates, read through `HorizontalUnitPin(id:json:)`, so legacy
        `names` arrays count too.
      - **Design index:** `HorizontalDesignPin` carries those alternates, plus
        the component's `alt_pins` entry as a `HorizontalDesignPinSelection`.
      - **`get_component`:** a pin with alternates gives `alternates`, by
        name. The Python tool drops that list unless `alternates=true`. A
        pin with a choice always gives `selected`
        (`{alternates, primary, custom_name}`) and `display_name`, the
        name the symbol draws under `selected_only`.
      - **New op, `set_pin_alternate`:**
        - It takes `pin` with `alternate`, or `assignments` (pin → alternate)
          for many pins in one op.
        - `alternate` is a name, a uuid, a list, or null. A name matches whole
          first, then by one of its "/" parts when that part is unique, so
          `SPI1_SCK` finds `SPI1_SCK/I2S1_CK`. Naming the primary name
          selects it.
        - `use_primary_name`, `custom_name` and `custom_direction` set the
          rest of the entry.
        - It writes upstream's shape: `pin_names` (uuids), `use_primary_name`,
          `use_custom_name`, `custom_name`, `custom_direction`. That's what
          the app's own menu writes.
        - A pin left with nothing chosen loses its entry, which is what the
          primary name means.
      - **Errors:**
        - an unknown name lists the pin's alternates
        - a part matching several alternates lists them as candidates
        - a pin with no alternates points to `custom_name`
        - a bad `custom_direction` lists the valid directions
        - passing both forms is refused
    - **Tests:**
      - `testPinAlternatesAreListedAndChosen` covers listing, whole, part and
        primary names, several at once, a custom name and direction, the
        errors, clearing, and the stored JSON.
      - `test_pin_alternates_are_listed_on_request_and_chosen_by_name` covers
        the Python schema and the `alternates` flag.

39. **No Set all unconnected pins NC / Clear all NC pins.**
    - **Before:** Horizon's symbol context menu has both
      (`ToolSetNotConnectedAll`). The app had neither, and `set_no_connect`
      wanted every pin named.
    - **Now, over MCP:** `set_no_connect` takes `all`, optionally with
      `gate`, and follows upstream's rules:
      - marking adds a null-net connection for each pin with no connection
        at all, and leaves connected pins alone
      - clearing removes each null-net connection
      - `all` with `pin` or `pins` is refused
    - **Now, in the app:** a symbol's right-click menu offers both, under
      upstream's names. Each shows only when it would change a pin of that
      gate, as `can_begin` decides. They run through `applyProjectEdit` as
      one undoable step: "Set All Unconnected Pins NC" or "Clear All NC
      Pins".
    - **Tests:** `testSetAllNoConnectTakesOnlyFreePinsAsHorizonDoes`.

## Inspector survey: fields the app edits that MCP cannot

The survey covered every sidebar inspector: the generic
`HorizontalSelectionPopoverView`, fed by `SchematicCanvasView.selectionProperties`
and `BoardCanvasView.selectionProperties`, plus the navigator, the net-class,
power-net, stackup, rules and export panes.

**Already covered:**
- component refdes, value, part and placement
- free text (`place_text` and `place_board_text` by id)
- nets, net classes, sheets, the title block, track width, rules, inner layer count
- pin alternates, as of this round

These are candidates for later rounds, most useful first:

1. **Editing a via or hole in place:** move it, and set its padstack,
   definition or from-rules source and its parameters. Today the only way is
   remove and re-place, which loses the tracks' attachment.
2. **Track layer**, and width and layer of board lines and arcs. There are no
   board line or arc ops at all.
3. **Plane settings on an existing plane:** net, layer, priority, from-rules,
   fill style, min width, keep orphans, thermals. `place_plane` sets net,
   layer and priority only when creating, and always writes `from_rules: true`.
4. **Package flags:** fixed, omit silkscreen, omit outline.
5. **A symbol's `custom_value`.** It's separate from the component value that
   `set_value` writes.
6. **Size of an existing net label or bus label**, and renaming a bus.
7. **Width of schematic net lines and drawing lines.** There are no schematic
   drawing-line ops.
8. **Editing an existing keepout's class, a dimension's size or mode, and a
   polygon's layer.**
9. **Placing smashed refdes and value texts**, which both text ops refuse,
   and `allow_upside_down` on texts.
10. **Removing a net class, and setting a power net's symbol style on its
    own.** Today the style is only set as a side effect of placing a symbol.
11. **Stackup:** per-layer copper and substrate thickness (`set_stackup`
    sets one value for all), and user layers.
12. **Pool item fields.** `pool_write` replaces a whole item; there's no
    field-level edit.

**Not the same model:** the export sidebar edits app state built from the
project's defaults. `set_export_settings` writes Horizon's project export
settings, which neither that sidebar nor the MCP `export` tool reads.

**Possible app bug:** the net-label text field may not reach the file.
`patchSchematicNetLabels` saves only size, junction and last_net, so a
label's net-name edit in the inspector seems to be lost on save. This needs
a check in the app.
