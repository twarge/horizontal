# MCP field findings 21: base parts and part-less components, as Horizon has them

Planning baseline: `86d5fd3`. Written October 12, 2026. Items 72–73 were
left open by round 20. The user asked for both to match Horizon.

## Findings and changes

72. **The Parts pane and `list_parts` hid every part another one derives
    from.**
    - **Horizon:** the part browser hides only parts flagged `base_part`,
      through the pool database's `flag_base_part`
      (`pool_browser_part.cpp`). That is `Part::get_flag(BASE_PART)`, so a
      flag set to inherit counts.
    - **Before:** `HorizontalPoolPart.loadAll` hid any part some other part
      names as its base. On Billo, 21 project-pool parts are used as a base
      and 11 are flagged. So 10 that Horizon offers were hidden, among them
      TPS62172DSGT, which U2 uses.
    - **Now:**
      - `loadAll` drops the parts whose resolved `isBasePart` is set. Billo
        lists 90 parts, up from 80.
      - `list_parts` pool rows (`scope` "pools" or "all") leave out flagged
        base parts too. Before, a project-pool base part could come back
        through them.
      - `search_pool` still finds flagged base parts, as Horizon's pool
        browser does, and marks each row `base_part: true`.
      - `HorizontalPoolLibraryItem.isBasePart` carries the flag, resolved
        through the base by `resolvingInheritance`.
    - **Unchanged:** `list_part_updates` still leaves bases out of its own
      list unless a component uses one. It updates a base as a dependency
      of the parts derived from it, which is a different question from what
      to offer for placement.

73. **The BOM listed components with no part.**
    - **Horizon:** `Block::get_BOM` takes a component only `if
      (comp.part)`. Its pick-and-place goes over board packages, which only
      parts have.
    - **Now:** the BOM export and the `bom` tool skip a component with no
      part. `bom` names them in `without_part`, next to `excluded`. Billo has
      none.
    - **Checked, no change:** Horizon makes one BOM row per part, while
      Horizontal groups rows by their MPN, value, manufacturer, package,
      description and datasheet. On Billo both give 65 rows: 198 components
      on 65 parts.

## Tests

- **`testOnlyFlaggedBasePartsAreHiddenAndAPartlessComponentIsNotOnTheBOM`**
  covers:
  - a flagged base and a part inheriting its flag, both hidden from
    `list_parts` with `scope` "project" and "all";
  - an orderable part with a variant, both listed;
  - `search_pool` marking exactly the two flagged parts `base_part`;
  - an entity-only component in `without_part`, and absent from the `bom`
    rows and the exported CSV.
- Swift 867 tests (6 skipped), Python 68, all pass.
