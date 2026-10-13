# MCP field findings 24: a part list gives the value a part stores

Planning baseline: `6f66768`. Written October 12, 2026. Item 84 was found
while fixing round 23 and recorded in billo's `docs/horizontal-mcp-notes.md`
as a question. The user answered it: "I don't think the project row should
give the MPN when no value is stored. The MPN appears under the MPN column
anyhow."

## Finding and change

84. **A part read two values, depending on which row listed it.**
    - **Before:**
      - `HorizontalPoolPart.value` was the part's `displayValue`: its value,
        or its MPN when it stores none, as Horizon's `Part::get_value` gives
        a component's value.
      - So a `list_parts` project row gave the MPN as `value`, beside `mpn`
        and `name`. A base-pool or `search_pool` row, read from the scan,
        gave what the file stores.
      - On Billo, 31 of the 90 cached parts read their MPN on the project
        row and "" on the `scope=pools` row, 27FLZ-SM2-TB, AD4003BCPZ-RL7 and
        BLM18AG601SN1D among them. The app's Parts pane, whose Value column
        sits beside its MPN column, showed those parts' MPN twice.
    - **Horizon:** its pool database has no value column, and its part
      browser lists MPN, Manufacturer, Description, Package and Tags.
      `Part::get_value` is what a component on the part shows.
    - **Now:**
      - `HorizontalPoolPart` keeps both. `value` is what the part stores,
        through its base, and empty when it has none. `displayValue` is
        `Part::get_value`, the same as `HorizontalPartRecord`'s.
      - Both are stored rather than one computed from the other.
        `HorizontalPoolPart.mpn` falls back to the uuid's first eight
        characters, which `Part::get_value` would never show.
      - Part lists use `value`: the `list_parts` project rows (now matching
        the base-pool and `search_pool` rows) and the Parts pane's Value
        column and its search, where an empty value shows "-".
      - What a component shows keeps `displayValue`: placing a part
        (`HorizontalSchematic`'s component details and info) and the
        `set_value` warning about a part's own value hiding the one written.
      - `list_parts`' description says what `value` is.
    - **Unchanged:** `get_component`'s `value`, `part_value` and
      `effective_value` (round 20, item 67). They describe a component, and
      for U8 they still read "STM32H757AII6".

## Tests

- **`testAPartListGivesTheValueAPartStoresAndAComponentStillShowsItsMPN`**
  covers a part storing no value:
  - its project row, base-pool row and `search_pool` row all give "";
  - `mpn` is the MPN;
  - the project's `HorizontalPoolPart` gives `value` "" and `displayValue`
    the MPN.
- **The Parts pane's Value column** needs a look in the app.
- **Results:** Swift 873 tests (6 skipped, 0 failures), Python 74 OK. The
  release products were rebuilt, and the app builds in Xcode (Debug, with
  its own DerivedData under `/tmp`).
- **On a copy of Billo,** through the release worker with Twinleaf Pool
  reachable: all 82 Twinleaf-cached parts give the same `value` on the
  project row as on the `scope=pools` row. 32 project rows give "" (the 31
  above and OPA620), and none gives its MPN.
