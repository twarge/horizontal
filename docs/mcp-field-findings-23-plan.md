# MCP field findings 23: where a cached part came from, part rows, and which app answered

Planning baseline: `2ee14f0`. Written October 12, 2026. Items 80–83 came
from the live check of round 22 on Billo (the check itself is recorded in
billo's `docs/horizontal-mcp-notes.md`). Item 80 is the user's point.

## Findings and changes

80. **One row for a part cached in the project pool named only the project
    pool.**
    - **The user:** "If a part is in the project and another pool, it should
      either show two rows or it should show one row with both pools."
    - **Before, in the Pools pane:**
      - Round 22 (item 77) made All Pools show one row per item, the project
        pool's copy, and its Pool column read "Project pool". Nothing on
        TPS62172DSGT's row said Twinleaf Pool. The only trace was "Open in
        Twinleaf Pool" in its context menu (`openTargets`).
      - The search matched the kept row's `poolName`, after de-duplication.
        So under All Pools, "twinleaf tps62172" gave only TPS62172QDSGTQ1.
        The user checked this live.
    - **Before, over MCP:** `list_parts` project rows and `search_pool` rows
      read `pool` "Project pool" and nothing else. Telling where TPS62172DSGT
      came from took `scope=pools` (1.09 MB) and a join on uuid.
    - **Horizon:** one row per uuid, with a coloured source box: local green,
      cached blue ("Item is cached from an included pool"), overriding local
      purple, included orange, overridden red
      (`PoolBrowser::pool_item_source_from_db`, `create_pool_item_source_cr`
      and `install_pool_item_source_tooltip` in `widgets/pool_browser.cpp`).
      It doesn't name the source pool.
    - **Now, in the model:** `HorizontalPoolLibrary.holders(items)` gives the
      names of the pools holding each item, by kind and uuid, in scan order
      (the project pool first). A pool with two copies is named once.
      `HorizontalPoolLibrary.pools(holding:own:holders:)` puts a row's own
      pool first, and `naming(_:holders:)` fills a new
      `HorizontalPoolLibraryItem.pools` with it.
    - **Now, in the Pools pane:**
      - `visibleItems` names every row's pools, in All Pools and in one
        pool's view alike. The Pool column shows `poolsLabel`, e.g.
        "Project pool · Twinleaf Pool". It sorts by that label, and its help
        reads "This row is Project pool's copy. Also in Twinleaf Pool."
      - The search (`HorizontalPoolBrowserView.matches`) matches the label.
        So "twinleaf tps62172" finds TPS62172DSGT again under All Pools,
        while "horizon tps62172" finds nothing.
    - **Now, over MCP:** every `list_parts` row, in every scope, and every
      `search_pool` item has `pools`, the pools holding it, its own first.
      The project scope now scans the pools too. Scans are cached per pool,
      and a project with no pool to start from still lists its parts.
    - **Not done:** marking a cached copy that differs from its source. The
      project's part review (`list_part_updates`, and the Parts pane's
      Updates sheet) already says so, dependencies included. A second,
      part-file-only comparison here would disagree with it whenever only a
      dependency changed. The tool descriptions point to `list_part_updates`.

81. **`list_parts` pool replies ran to a megabyte, and `search_pool` part rows
    had another shape.**
    - **Before:**
      - `scope=pools` and `scope=all` replied about 1.09 MB on Billo (up from
        904 KB and 883 KB before round 22), too big for a client to read
        inline.
      - Three pairs repeat on every row: `id` = `uuid`, `name` = `mpn` and
        `detail` = `manufacturer`.
      - `search_pool`'s part rows had 14 keys, without `id`, `mpn`,
        `entity_id`, `gate_count` or `refdes_prefix`.
    - **Now:**
      - `list_parts` takes `fields`, as `list_components` does (`uuid`
        always), and `pool`: only the parts a pool holds, by the name rows'
        `pools` give it. A cached part is held by its source pool too. A
        `pool` that holds none of the listed parts is an `INVALID_ARGUMENT`
        naming the pools that do. Both are in the MCP layer, as
        `list_components`' are.
      - `search_pool` takes `fields` (`uuid` and `kind` always).
      - A `search_pool` part row is built by the same
        `HorizontalDispatchPool.partRow` as a `list_parts` base-pool row, so
        it has the same keys, plus `base_part` on a flagged part. On the
        project pool's own copy, `refdes_prefix` and `gate_count` come from
        the project's part, as on a `list_parts` project row.
    - **Kept:** the 19 keys, now 20 with `pools`. Dropping the duplicates
      would break callers, and `fields` gets the same saving.
    - **Left alone:** a project row's `value` is the part's effective value
      (its MPN when it stores none, as Horizon's `Part::get_value` gives it),
      while a scanned row's is what the file stores. On Billo, 31 of the 90
      cached parts read their MPN on the project row and "" on the base-pool
      row. Which `value` a pool row should carry is the user's call (billo's
      notes, item 84).

82. **`connection_status` couldn't say which app answered.**
    - **Before:** the engine's `build.executable` was "Horizontal" alone.
      /Applications/Horizontal.app 1.3.0 (build 13.1, from 2026-09-14) is
      installed beside the Xcode build, and the Debug build reports
      `host_version` "1.0". The live check used `ps` on the holder pid to see
      which one was running.
    - **Now:** `version`'s `build` adds `path` (the executable), `bundle`
      (the `.app`, in an app) and `bundle_version` (`CFBundleVersion`). An
      installed copy and an Xcode build, or two DerivedData folders, now read
      differently. `connection_status`'s description says so, and that none
      of it shows whether the app is current: the commit stamp stays dropped
      (round 22, item 78).

83. **A `connection_status` context row had two shapes.**
    - **Before:** right after `open_project`, a context had 11 keys, without
      `api_version` or `origin`. After any other call it had 13. The client
      seeded `last_metadata` with five keys from the open summary, and the
      next reply's `meta` replaced it.
    - **Now:** `client.META_KEYS` names what a reply's `meta` holds, in its
      JSON order, and the seed takes those keys from the summary.

## Tests

- **`testEveryRowNamesThePoolsHoldingItAndSearchPartRowsReadAsListPartsRows`**
  (80, 81) covers:
  - `pools` before and after a part is cached, in each `list_parts` scope;
  - `search_pool`'s part row reading as the `list_parts` project row, keys,
    refdes prefix and gate count included;
  - a cached entity naming both pools, without the part keys.
- **`testARowNamesEveryPoolHoldingItAndTheSearchFindsItByAnyOfThem`** (80)
  covers:
  - `visibleItems` naming the pools in All Pools and in each pool's view;
  - the label;
  - "twinleaf tps62172", "project tps62172" and "horizon tps62172";
  - a pool with a cache copy and its own named once.
- **`testVersionDescribesTheOpVocabulary`** (82) checks `build.path`,
  `executable` and that only an app reports `bundle`.
- **Python:**
  - `test_part_lists_narrow_to_a_pool_and_to_the_fields_asked_for` (81)
    covers `pool` (a cached part held by its source too, and an unknown pool
    naming the known ones) and `fields` on both tools.
  - `test_a_context_reads_the_same_before_and_after_its_first_call` (83).
- **The Pool column** has no unit test. It needs a look in the app.
- **Results:** Swift 872 tests (6 skipped, 0 failures), Python 74 OK. The
  release products were rebuilt, and the app builds in Xcode (Debug, with
  its own DerivedData under `/tmp`).
- **On a copy of Billo,** through the release worker with both base pools
  reachable: the default `list_parts` gave 90 rows of 20 keys, 82 of them
  ["Project pool", "Twinleaf Pool"]. The first call took 0.62 s, scanning
  the pools, and later ones 0.01 s. `search_pool "tps62172"` gave
  TPS62172DSGT with ["Project pool", "Twinleaf Pool"], "U" and 1.
