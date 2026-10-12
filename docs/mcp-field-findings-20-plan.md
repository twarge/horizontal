# MCP field findings 20: a derived part, read through its base everywhere

Planning baseline: `9c0b767`. Written October 12, 2026. Item 65 came up
while round 19 was written. The user asked for it to be fixed and for a
systematic look at everywhere else a part's base is inherited. That look
found items 66–71, fixed here, and 72–73, left open.

## How Horizon resolves a derived part

From `horizon/src/pool/part.cpp` (`3d4e309e`), `block.cpp` and `board.cpp`:

- **MPN, value, manufacturer, datasheet, description:** each is stored as
  `[inherited, value]`. When inherited and the part has a base, it is the
  base's attribute (recursively), whatever value is stored. Horizon's
  "create part from part" stores a copy of the base's value then, which goes
  stale when the base changes. With no base, the stored value stands.
- **The value shown:** the value attribute, or the MPN when that is empty
  (`get_value`).
- **Entity, package, pad map:** always the base's.
- **Tags:** the part's own, plus the base's when `inherit_tags`.
- **Model:** the base's own `model` when `inherit_model` (default true).
- **Flags** (base_part, exclude_bom, exclude_pnp): set or clear, or inherit,
  which means the base's (clear with no base). The BOM leaves out
  `exclude_bom` parts and the pick-and-place `exclude_pnp` ones.
- **Prefix:** `override_prefix` yes, no or inherit (the base's). A
  component's refdes prefix is its part's (`Component::get_prefix`).
- **Parametric data and orderable MPNs:** never inherited.

## The survey

Every reader of part JSON in `Sources/`, against those rules. Counts are
over Billo's three pools (its project pool, Twinleaf Pool, horizon-pool:
1,711 parts, 780 derived).

| Reader | Before | Now |
|---|---|---|
| Pool scan (`search_pool`, `list_parts` pool rows, the app's library browser, `import_pool_part` by MPN) | the derived part's own file only: stale copies read and matched, base tags missing (item 65) | resolved through the base in any scanned pool |
| `HorizontalPoolPart` (Parts pane, `list_parts`, edits naming a part, the hidden-value warning) | inherited flag followed; value heuristic (item 70); prefix override ignored (68) | the shared resolver |
| Schematic loader (`$VALUE`/`$MPN` texts, `get_component`, BOM, in-app placement) | inherited flag followed; value heuristic (70); flags not read (66) | the shared resolver, flags carried |
| Board loader (board texts, pick-and-place) | as the schematic's | the shared resolver, flags carried |
| `HorizontalDispatchPoolIndex.partValue` (`get_component` `part_value`) | no fall-back to the MPN (67) | `displayValue` |
| `ensure_component` | entity prefix only (68); a part another derives from not found in a `.horizontal` package (69) | the part's prefix; the pool index finds it |
| `list_part_updates` names | the file's own MPN (71) | resolved |
| BOM export, `bom`, pick-and-place export | flags ignored (66) | excluded |
| 3D model (`resolvePartModelID`) | follows the whole chain where Horizon takes one level | unchanged: with Horizon's package check, the two agree on all 121 three-level chains in the pools |
| Pool preview (`HorizontalPoolPreview`) | follows the inherited flag through the chain | unchanged |
| Parametric data (search, `get_component`, electrical values) | the part's own | unchanged, as Horizon |
| The part editor | its own model of inheritance, for editing it | not audited |

## Findings and changes

65. **Search rows read a derived part's own file.** On Billo,
    C1608X5R1C106M080AB read manufacturer "" (its base says TDK), and a
    "TDK" search found 16 parts without it. Across the pools, 131 derived
    parts store a stale value under an inherited flag (Billo's
    BLM18AG601SN1D read "base 0603 ferrite bead"), and 735 inherit tags the
    rows didn't show. **Now:** `HorizontalPoolLibrary.resolvingInheritance`
    runs over every scanned pool together and rewrites each derived part's
    name (its MPN), manufacturer, value, description, tags and package. The
    dispatch scan and the app's library browser call it. Round 19's
    `packages()` no longer walks the chain itself.

66. **The BOM and pick-and-place ignored exclude_bom and exclude_pnp.**
    Twelve parts in the pools set them, and Billo uses four: Screw Mount M3
    (MP1–2), Test Point Clamp (TP1), Test pad (TP2–7) and TC2030-CTX-NL (J4).
    Horizon's BOM leaves all ten out, and Horizontal's had them. **Now:**
    `HorizontalComponentDetails` carries `excludeFromBOM` and `excludeFromPnP`,
    resolved through the base, and the BOM export, the `bom` tool and the
    pick-and-place export skip them. `bom` gives `excluded`. Billo's BOM
    goes from 69 lines and 208 components to 65 and 198.

67. **`get_component` gave a part with no value an empty part value.** U8
    read `value` "STM32H757AII6" but `part_value` "", `effective_value` ""
    and `value_source` "component". **Now:** `partValue` is the value Horizon
    shows, the MPN when the part has no value, so U8 reads STM32H757AII6 and
    "part" throughout.

68. **A part's refdes prefix override was ignored.** `ensure_component`
    without a refdes, and placing a part in the app, used the entity's
    prefix. **Now:** `HorizontalPoolPart.prefixOverride` (set or inherited),
    then the entity's. No part in Billo's pools sets `override_prefix: yes`,
    and 103 inherit it, so nothing changes there today.

69. **An edit couldn't name a part another one derives from, in a
    `.horizontal` package.** `HorizontalPoolPart.loadAll` leaves such parts
    out, and `poolPart` won't read a package's pool off disk. The round 20
    test found it: `ensure_component` with the base part failed "No pool
    part …". **Now:** `poolPart` falls back to
    `HorizontalDispatchPoolIndex.poolPart`, read from the snapshot, staged
    pool items included. A `.hprj` project like Billo already read it off
    disk.

70. **The value of a derived part was patched by a heuristic.** The
    loaders resolved the base's value with its MPN fall-back already
    applied, then guessed the fall-back back out. `HorizontalPoolPart`
    guessed with the base's value instead, so a derived part whose own value
    equals its base's showed its MPN. **Now:** the resolver keeps the value
    attribute and the value shown apart, and every loader uses it.

71. **`list_part_updates` named a derived part by its file's MPN.**
    **Now:** resolved through the base in the reviewed files.

## Left open

72. **The Parts pane and `list_parts` hide parts another part derives
    from.** Horizon's part browser hides parts flagged `base_part`. On Billo,
    21 project-pool parts are used as a base, but only 11 are flagged. So
    `list_parts` leaves out 10 that Horizon would offer:
    - four orderable parts: TPS62172DSGT (which U2 uses),
      ADP7118AUJZ-3.3-R7, ADP7118AUJZ-R7 and TPME227K016R0025;
    - six bases by name: C1210x, C1608, "base 0402 resistor",
      "base 0603 ferrite bead", "base 0805 capacitor" and
      "base 1210 capacitor".

    Following Horizon would add all ten to the Parts pane, so it is the
    user's call. Edits can name them since item 69.

73. **The BOM lists components with no part.** Horizon's BOM leaves them
    out. Billo has none.

## Tests

- **`testPartInheritanceFollowsHorizonsRules`** checks the resolver on a
  three-level chain with stale copies. It covers attributes two levels up,
  the MPN fall-back, the tag union, entity and package, a flag inherited
  from the root, one clear there, and an inherited prefix. With no base
  readable, stored values stand and flags clear. It also checks the JSON
  form through a lookup, and that a part that is its own base stops.
- **`testADerivedPartReadsThroughItsBaseInSearchesValuesTheBOMAndRefdes`**
  covers:
  - a search row's manufacturer, description, value, tags and package
    through the base, a "TDK" match, and no match on the stale copy;
  - a derived part whose value equals its base's;
  - `get_component` on a part with no value, and a derived part's
    manufacturer, description and datasheet;
  - two "TP?" components named through a set and an inherited prefix;
  - `bom` rows and `excluded`, and BOM and pick-and-place CSVs without the
    test pads.
- **`test_the_bom_says_what_it_leaves_out`** (Python): the description
  names `exclude_bom`, and an empty project gives `excluded: []`.
- Swift 866 tests (6 skipped), Python 68, all pass.
