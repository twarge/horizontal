# MCP field findings 26: a pool reached through a symlink

Planning baseline: `88f0e89`. Written October 13, 2026. Item 85 was found
while checking round 23 on a copy of Billo and recorded in billo's
`docs/horizontal-mcp-notes.md`.

## Finding and change

85. **A pool reached through a symlink scanned as empty, and reached two ways
    it was listed twice.**
    - **Before:**
      - A copy of Billo in `/tmp/r23` had `/tmp/r23/horizon-pool` as a symlink
        to the horizon-pool checkout. `search_pool` listed "Horizon default
        pool. Use this one!" there with `item_count` 0 and no `unreadable`.
      - With `HORIZON_POOL` set to a symlink to Twinleaf Pool, Twinleaf read
        0 items too.
      - Set to the real horizon-pool path, it read 1,860 items. The
        symlinked spelling was listed a second time with 0.
    - **Cause:**
      - `HorizontalPoolLibrary.scan` walks a pool with a `FileManager`
        enumerator rooted at the pool directory. An enumerator doesn't
        descend into a root that is a link.
      - `accessError` lists the directory through the link without trouble,
        so nothing said why it came back empty.
      - The pool lists (`basePoolURLs`, `editorPoolURLs`, the Pools pane's
        `browsedPools`, `search_pool`'s `pool_path`) de-duplicated on
        `standardizedFileURL.path`, which doesn't resolve links.
      - The padstack catalog walks `<pool>/padstacks`, whose linked parent
        the system resolves, so it was not affected.
    - **Now:**
      - `HorizontalPoolLibrary.canonicalURL` gives a pool directory one URL
        however it was reached: symlinks resolved, then standardized. That is
        the form `HorizontalPoolCacheProvenance.relativePath` and the cache
        updater's source match already used.
      - `items(inPool:)` scans from it and caches by it, as does
        `invalidateCache(for:)`, and each item carries it as its `poolURL`.
      - Every pool list adds pools by it, so a pool reached through a link is
        listed as the directory it points to, once.
      - In the Pools menu, a registered pool keeps the path it was added by,
        so finding it among the browsed pools (the Registered Pools section,
        and Remove) compares canonical paths.
    - **Unchanged on Billo:** none of its pool paths goes through a link, so
      every path the tools give stays as it was.

## Tests

- **`testAPoolReachedThroughASymlinkIsScannedAndListedOnce`** covers a pool
  registered by a symlink:
  - its part is found;
  - it is listed once, at the real path, with items;
  - registered by both paths, it is still one pool;
  - a scan by the link gives items with the canonical pool;
  - `pool_path` by the link finds the part.

  With `canonicalURL` standardizing only (the old behaviour), it fails as
  the finding did: no part found, `item_count` 0, the link's path listed.
- **Results:** Swift 876 tests (6 skipped, 0 failures), Python 74 OK. The
  release products were rebuilt, and the app builds in Xcode (Debug, with
  its own DerivedData under `/tmp`).
- **The finding's repro, rerun** on the `/tmp/r23` copy through the release
  worker:
  - With `HORIZON_POOL` the link to Twinleaf Pool, Twinleaf reads 2,362
    items (was 0) at `/Users/kornack/Repositories/twinleaf-horizon/Twinleaf
    Pool`.
  - The horizon-pool reached through the linked ancestor reads 1,860 (was 0)
    at its real path.
  - With `HORIZON_POOL` the real horizon-pool path, it is listed once (was
    twice).
  - With both base pools reachable, all 90 cached parts give the same
    `value` on their project and `scope=pools` rows (round 24).
