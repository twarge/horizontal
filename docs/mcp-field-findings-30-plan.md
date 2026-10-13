# MCP field findings 30: smaller replies, and pools a worker can find

Planning baseline: `3386800`. Written October 13, 2026. Items 91 and 93 came
from checking rounds 27–28 on Billo, and 96 and 97 from checking round 29.
All four are recorded in billo's `docs/horizontal-mcp-notes.md`.

## Findings and changes

91. **The server called itself stale when only Swift had changed.** After
    rounds 27–28 merged, `open_project` and `connection_status` warned "This
    MCP server's code changed after it started (commit eb1f890 -> 38dbfbe);
    its tool schemas are the old ones. Ask the user to restart the server".
    At the same time, `changed_since_start` read `[]` and the schema digest
    matched the engine.
    - **Cause:** `_server_identity` counted any move of `HEAD` as stale,
      whatever the commits touched.
    - **Now:** when `HEAD` moved, `git diff --name-only` between the two
      commits, limited to the package directory, says what changed. The server
      is stale only if a file there changed, by that diff or by mtime.
      - **Otherwise:** `connection_status` gives `checkout_moved: true` and
        a `note` that the tool schemas are current, and there's no restart
        warning.
      - **When git can't say** (an unknown commit, say), a moved checkout
        still counts as stale, as before.

93. **`list_part_updates` replies were 135–159 KB on Billo.** That's too big
    to read inline (Claude Code saved each to a file). 139 KB of the 159 KB
    was the `before` and `after` text of each change's file.
    - **Now:** a change gives `before_bytes` (null for a new item) and
      `after_bytes`. The texts come only with `include_contents`.
    - The review and its `review_digest` are the same either way.

96. **A `clean_up_project_pool` dry run gave each item three times:** as an
    id in `normalized_ops`, as a row in `items`, and as the same row again in
    `remove`. That was about 35 KB for Billo's 74 items.
    - **Now:** `remove` is the ids removed (or that would be), in `items`
      order, and `remove_bytes` is their size. `items` still describes
      each one.

97. **A worker couldn't find Twinleaf Pool.** In a disk context, Billo's
    review read 79 of 82 parts `sourceUnavailable`, against none live.
    - **The cause:** Billo's project pool includes `48801d92…` (Twinleaf
      Pool), which is registered only in the app. A worker has its own user
      defaults, and Twinleaf Pool is neither `$HORIZON_POOL` nor a
      `horizon-pool` checkout.
    - **The messages hid that:** 70 rows read "No unambiguous source for this
      part", the same words as for a part several pools hold.
    - **What worked:** `pool_path` gave a reply byte-identical to the live one.

    Changes:
    - **Found nearby:** `HorizontalPoolLibrary.includedPoolURLs` looks for
      an included uuid nothing else resolved in the directories around the
      pool (`nearbyPoolURLs`).
      - **Where:** each of the four directories above it, where
        `horizon-pool` is looked for too, and two levels into each. Billo's
        project pool is `~/Repositories/billo/Billo Horizon/pool`, and
        Twinleaf Pool is `~/Repositories/twinleaf-horizon/Twinleaf Pool`.
      - **What it stays out of:** it stops short of the home directory (the
        real one, from `getpwuid`, not a sandbox container's), whose children
        are the folders macOS asks permission for. It skips hidden
        directories and symlinks.
      - **What it never looks for:** every project pool shares one uuid, so
        an include of that, or of the null uuid, would match another
        project's pool.
      - **Memory:** a hit is kept for the life of the process and checked on
        use. A miss is kept until `invalidateCache()`, which the app calls on
        Refresh, imports and registry changes, and a review calls at its
        start.
    - **Named:** `HORIZONTAL_POOLS`, colon-separated directories, joins
      `HORIZON_POOL` in `basePoolURLs`. It's for pools a worker can't
      otherwise reach, set in the MCP server's `.mcp.json` entry.
    - **Said once:**
      - `list_part_updates` and `search_pool` give `missing_pools`: each
        included uuid no found pool has, with `included_by` and a
        `message` saying how to supply it. `search_pool` leaves it out when
        `pool_path` narrows the search on purpose.
      - "Source library … is not registered or available" adds "(Project
        pool includes it)" when it does.
      - A part with no recorded origin now reads "No browsed pool holds this
        part. It may come from pool …, which … includes, but no pool found
        here is that one." when no pool holds it. When several do, it reads
        "No unambiguous source for this part: “A”, “B” hold it."

## Tests

- **`testPartUpdateReviewGivesFileTextOnlyOnRequest`**
  (`HorizontalDispatchPoolTests`, 93):
  - by default a change has `path`, `fields`, `before_bytes` and
    `after_bytes`, but no texts;
  - with `include_contents`, the texts are as long as the sizes said;
  - the `review_digest` is the same either way.
- **`testAnIncludedPoolBesideTheProjectIsFoundWithoutRegistration`** (97).
  The stock pool gets a uuid of its own, so no stray pool in the temporary
  directory, which the search reaches, can answer for it.
  - **Unregistered and not included:** the part reads `sourceUnavailable`,
    "Source library … is not registered or available."
  - **Included by the project pool:** the pool is found beside the project,
    and the part reads `current`.
    - **What the include lists:** besides the stock pool, an absent uuid
      (written in uppercase), the project-pool uuid and the null uuid.
    - **`missing_pools`:** only the absent one, `included_by` "Project
      pool".
    - **`search_pool`:** lists the found pool at its path and gives the
      same `missing_pools`, except with `pool_path`.
  - **Moved three levels deeper:** the message adds "(Project pool
    includes it)", and `missing_pools` names both pools.
- **`testAPartWithNoRecordedSourceSaysWhyItHasNone`:** the three wordings of
  `unresolvedSourceMessage`, with repeated holders named once.
- **`testHorizontalPoolsNamesPoolsAWorkerCannotOtherwiseSee`:** a pool
  outside every search is a base pool once `HORIZONTAL_POOLS` names it (with
  a nonexistent path beside it).
- **`testCleanUpDryRunListsAndTheCommitRemovesFilesAndManifestEntries`**
  (96): `remove` is the ids in `items` order, and `remove_bytes` their
  total, for a full dry run and for a chosen two.
- **Python:**
  - **91:** `test_status_names_the_server_and_notices_it_going_stale` adds
    three cases, all with a moved commit:
    - with no package diff, `checkout_moved` and a note, and no restart
      warning;
    - with `mcp_server.py` in the diff, stale and named;
    - when git can't say, stale with the commit in the warning.

    `_package_diff("HEAD", "HEAD")` is `[]`.
  - **93:** `list_part_updates` advertises `include_contents`, and an empty
    project's review has the same digest with it.
  - **96:** an empty clean-up dry run gives `remove: []` and
    `remove_bytes: 0`.
- **Caught on the way:** `HorizontalDispatchValidation` types parameters by
  name, so `include_contents` had to join its booleans. Without that it was
  refused as "must be a string".
- **Results:** Swift 888 tests (6 skipped, 0 failures) and Python 75 OK.
  The app builds in Xcode for macOS (`/tmp/r30-mac-dd`, 1:34) and the iOS
  Simulator (`/tmp/r30-ios-dd`, 49 s), and the release products were
  rebuilt.
- **Billo, through the rebuilt worker** (a disk context, after the user's
  pool cleanup: 69 review rows):

  | Call | Reply | Time | Statuses |
  |---|---|---|---|
  | default | 19,220 bytes | 3.15 s, 2.91 s again | 61 current, 8 updateAvailable |
  | `include_contents` | 158,737 bytes | 2.83 s | the same |
  | `pool_path` Twinleaf Pool | 19,220 bytes | 6.20 s | the same |

  - **Twinleaf Pool is found** with no `pool_path` and no `missing_pools`.
    Before, the same review read 79 of 82 parts `sourceUnavailable`.
  - **The replies agree:** all three give one `review_digest`. The default
    reply equals the `pool_path` one, and equals the `include_contents` one
    without its texts.
  - **The search** costs about a quarter of a second, once per process.
