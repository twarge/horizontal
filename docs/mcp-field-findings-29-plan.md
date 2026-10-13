# MCP field findings 29: cleaning up the project pool

Planning baseline: `7e6e20c`. Written October 13, 2026. Item 94 is the user's
request, item 92 a finding from checking rounds 23–28 on Billo. Both are
recorded in billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

92. **`list_part_updates` gave every part `references: []` on Billo.** That
    included STM32H757AII6, which U8 uses.
    - **Cause:** `HorizontalPoolCacheUpdater.references(in:)` read only block
      files whose JSON says `"type": "block"`, and Billo's `top_block.json`
      has no `type` key. Its fallback through the schematics and the board
      needs the project, and `HorizontalDispatchPool.libraryReview` didn't
      pass it. The Parts pane passed it, so it wasn't affected.
    - **Now:** with a project, the block files come from its block list
      (`HorizontalPoolCacheUsage.blocks`), as the loader finds them, and the
      dispatch passes the project.

94. **"Provide a command like Horizon where you clean up/remove unused parts
    from the project pool."**
    - **Horizon:** "Clean up Pool Cache" (`pool-prj-mgr-app_win.cpp`
      `cleanup_pool_cache`, `prj-mgr/pool_cache_cleanup_dialog.cpp`) lists
      the cached items the blocks, schematics and board don't use, and the
      3D models no board package chose, each ticked. The project's files
      must be saved first, and the removal can't be undone.
    - **The user's choices:**
      - offer only what nothing in the design reaches;
      - a Parts pane button and a Design menu item;
      - one undoable step;
      - one MCP tool with a dry run.
    - **What counts as used** (`HorizontalPoolCacheUsage.roots`, then
      `HorizontalPoolCacheUpdater.dependencies(of:jsons:)`, now taking any
      roots). The roots are:
      - each component's part, or its entity when it has none;
      - the BOM's concrete parts;
      - each sheet's frame;
      - each board package's alternate package;
      - each via's, via definition's and hole's padstack;
      - each board decal.

      From a part the walk reaches its base, entity and package; an entity's
      units; every symbol of a unit; and a package's padstacks and every one
      of its models.
    - **How an item counts:** by kind and uuid, so a cached copy that a
      project-local item overrides stays, as in Horizon. A package is its
      directory, with the padstacks beside it.
    - **Never offered:** project-local items, `pool.json` and the cache
      manifest.
    - **The model** (`HorizontalPoolCacheCleanup`):
      - `review(archive:project:files:)` lists the items, each with an id
        (`part|<uuid>`, `model|<path>`), kind, name ("MPN / manufacturer"
        for parts), paths and bytes, plus a digest.
      - `removal`/`applying` refuse a pool that changed since the review.
        They review the design again, so nothing it has come to use is
        removed. They drop the removed paths' entries from
        `.horizontal/pool-cache.json`.
    - **Removing files, which nothing could do before:**
      - `HorizontalProjectArchive.removeRegularFile` prunes directories it
        leaves empty and records the path in `removedRelativePaths`.
      - `writeInPlace`, the `.hprj` save, deletes those paths through the
        transaction, then the directories the archive no longer has.
      - Undo installs the earlier archive, which still holds the files and
        has no record of removing them, so the next save writes them back.
      - `HorizontalProjectTransaction.Update.after` is optional, nil
        meaning delete, and it rolls back and forward like a write.
      - A `.horizontal` package saves its whole wrapper, so a removed file
        is simply not written.
    - **App:**
      - "Clean Up…" beside Updates in the Parts pane (macOS and iPad), and
        Design > "Clean Up Project Pool…" (hidden when locked).
      - Both open `HorizontalPoolCleanupSheet`: the items grouped by kind,
        all ticked, with name, first path and size, Select All/None and
        Remove Selected. With nothing to offer it reads "Nothing in the
        project pool is unused."
      - Removing is one undo step, "Clean Up Project Pool", through the same
        `applyLiveArchive` as Update Project Parts.
    - **MCP:** `clean_up_project_pool` (`HorizontalDispatchPool.cleanUp`).
      - A dry run lists `items` and the chosen ones in `remove`, with
        `review_digest` and `would_write`.
      - `remove` takes item ids; left out, every item goes.
      - It's a mutation: `expected_revision`, `operation_id`, `plan_digest`,
        destructive. `HorizontalArchiveFileStore.remove` takes files out.
      - `HorizontalDispatchMutation.perform` counts removed files as
        changed, and on disk commits them as deletions, pruning empty
        directories.

95. **A method-level mutation couldn't reply through MCP.** Found while
    adding 94.
    - **Seen:** the first Python dry run of `clean_up_project_pool` failed
      with `ENGINE_ERROR`: "Input tag 'clean_up_project_pool' found using
      'op' does not match any of the expected tags".
    - **Cause:** `EditResult.normalized_ops` is typed as the `apply_ops`
      union, and these mutations echo one op naming the method, for their
      plan digest. `update_project_parts` returns the same kind of op, so it
      would hit the same refusal; no Python test committed one.
    - **Now:** `EditResult.normalized_ops` also takes a `MethodOperation`
      (`update_project_parts` or `clean_up_project_pool`). It stays out of
      `EditOperation`, so the ops digest is unchanged (`1206efc07823f872`).

## Tests

- **`testRemovedFilesAreDeletedOnSaveAndAnEarlierArchiveRestoresThem`**
  (`HorizontalProjectArchiveTests`):
  - removal prunes the archive;
  - a missing file or a directory is refused;
  - `writeInPlace` deletes exactly the removed files, and the package
    directory with them, leaving a sibling package;
  - a second save deletes nothing;
  - the earlier archive writes the files back;
  - writing a removed file again clears its record.
- **`testAnUpdateWithoutBytesDeletesItsFile`**
  (`HorizontalProjectTransactionTests`): a deletion commits, a failed
  commit restores the file, and interrupted `prepared` and `committed`
  journals roll back and forward.
- **`testCleanUpReviewOffersOnlyWhatNothingInTheDesignReaches`**
  (`HorizontalDispatchPoolTests`):
  - **The setup:** a used part, a BOM concrete part, a sheet frame, a board
    decal and a via padstack, with the block's `type` key removed.
  - **The result:** only a stray part, a stray padstack, an unused frame
    and a stray model are offered. `references` with the project gives
    R1 (note 92).
- **`testCleanUpDryRunListsAndTheCommitRemovesFilesAndManifestEntries`:**
  - an imported, unused part's six items are listed, and a dry run writes
    nothing;
  - with a component on the part, nothing is listed;
  - committing two of them, with `plan_digest` and `review_digest`, deletes
    those files and manifest entries only;
  - removing the rest deletes the package directory, and then nothing is
    left;
  - an unknown id is refused.
- **`testMountedLiveCleanUpIsOneUndoStep`:** on a live document the files
  leave the archive, not the disk, and one undo restores them.
- **Python:** `clean_up_project_pool` is a destructive mutation needing
  `expected_revision` and `operation_id`, and a dry run on an empty pool
  gives `items: []`.
- **Python:** `test_method_level_mutations_echo_their_op_without_joining_apply_ops`
  covers 95.
- **Results:**
  - Swift 884 tests (6 skipped, 0 failures) and Python 75 OK.
  - The app builds in Xcode for macOS (with its own DerivedData under
    `/tmp`) and for the iOS Simulator (`/tmp/r29-ios-dd`).
  - The release products were rebuilt.
  - `BoardPlanePourTests.testProgressIsReportedOncePerPlaneInOrder` failed
    once in a full run ([1, 3, 2]) and passed 6/6 on its own and in the
    next full run. It's unrelated, and looks timing-dependent.
- **Billo, read-only:** a probe reviewed Billo's own files.
  - It took 65 ms: 357 pool files and 76 roots.
  - **Offered:** 74 items: 16 parts, 6 entities, 19 units, 19 symbols, 7
    packages, 6 3D models and 1 frame.
  - **The parts:** among them AD4080BBCZ, XC7A100T-1CSG324I and
    STM32G484VEH6 (from before the redesign), 1N4148WL2-TP, S25FL128LAGNFA010,
    LT6656AIDC-3#TRMPBF with its base LT6656x, C1210C107M4PACTU with C1210x and
    "base 1210 capacitor", and four RMCF0402 resistors.
  - **Against the BOM:** none of them is in it, and the parts the BOM leaves
    out (test pads, test point clamps, screw mounts, TC2030) are kept.
  - **References:** 69 parts have them, and U8 reads STM32H757AII6.
- **Live, 2026-10-13:** server and Debug app at `3386800`, on Billo.
  - **94, the dry run:** `clean_up_project_pool` gave the probe's 74 items.
    `edit_ms` was 129, and `undo_name` "Clean Up Project Pool".
    - **Against the files:** no component uses any of the 16 parts.
    - **The frame:** six sheets use `51b16a87…`, the pool's `default_frame`,
      which is kept. The offered frame, `6bec849d…`, is used by nothing.
  - **95:** both method-level dry runs (`clean_up_project_pool`, and
    `update_project_parts` for TPS62170DSGT) echo their op in
    `normalized_ops`.
  - **92:** 69 parts have `references`, and U8 reads STM32H757AII6. One more
    row than before: TPS62172DSGT, which U2 uses itself, reads
    `updateAvailable`. Before 92 it was taken for an unused base.
  - **88, through the worker:** with `pool_path` Twinleaf Pool, the review is
    byte-identical to the live one. Without it, 79 rows read
    `sourceUnavailable` (round 30's item 97).
  - **94 in the app (the user):** Remove Selected took all 74 and was saved
    at 11:08.
    - **On disk:** exactly the 74 files are gone, with no empty directory
      left. The design files are untouched. Billo.hprj and the manifest were
      rewritten with the same bytes, and the manifest now equals Billo's
      last commit.
    - **Reopened:** the snapshot is `088a45c7…`, the dry run's
      `after_snapshot_id`. `pool_part_count` went 91 → 76, since one of the
      16 was flagged `base_part`. `check` still gives 0 errors, 68 warnings
      and 2 info.
