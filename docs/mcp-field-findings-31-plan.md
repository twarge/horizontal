# MCP field findings 31: a pool cleanup leaves hidden files alone

Planning baseline: `4ad374c`. Written October 13, 2026. Item 98 came from
the live check of round 30 and is recorded in billo's
`docs/horizontal-mcp-notes.md`.

## Findings and changes

98. **A cleanup offered a Finder `.DS_Store` as a 3D model.** Helios's dry
    run listed `3d_models/cache/.DS_Store` (6,148 bytes) among its six items,
    as `kind: "model"`.
    - **The cause:** the review offered every file under `3d_models/cache`
      that no kept package names. A package's directory also took any
      hidden file in it.
    - **Horizon does the same:** `pool-prj-mgr-app_win.cpp` lists every
      regular file under `3d_models/cache` as a model. The user chose to skip
      hidden files instead.
    - **A second problem, found by the test:** the review counted hidden
      files, and Billo's pool has a `.DS_Store` at its top. If Finder
      rewrote one between the dry run and the removal, the removal refused
      with "The project pool changed since it was reviewed".
    - **Now:** `HorizontalPoolCacheCleanup.reviewedFiles` drops every path
      with a component that starts with a dot before a review and before the
      removal compares its files with it.
      - **What that means:** hidden files are never offered or removed, and
        don't count toward `review_digest`.
      - **What it keeps:** the cache manifest, `.horizontal/pool-cache.json`,
        which a removal rewrites.
      - **Where it applies:** the app's sheet (macOS and iPad) and MCP all go
        through `review` and `removal`.
    - **What this leaves behind:** a removed package's directory stays if the
      archive holds a hidden file in it. When the archive doesn't hold that
      file (Finder wrote it after the project was read), the existing
      pruning removes the directory as before, since it counts a
      directory holding only `.DS_Store` as empty.

## Tests

- **`testCleanUpLeavesHiddenFilesAlone`** (`HorizontalDispatchPoolTests`).
  The project imports an unused part. Then hidden files are written:
  `.DS_Store` at the pool's top, in `3d_models/cache`, in `parts/cache`
  and in the package's directory, and `3d_models/cache/.thumbnails/stray.step`.
  - **The review:** the archive has every hidden file, but only the part's
    six items are offered. None of their paths is hidden, and the
    manifest still counts.
  - **Finder rewrites them:** the review digest is unchanged, and the
    removal succeeds and takes none of them.
  - **Through MCP**, after `reload_project`: the dry run's `remove` is the
    six ids. The commit writes no hidden file but the manifest, removes the
    package, and leaves every hidden file with its contents.
  - **Without the fix**, all four checks fail. The review offers the two
    model-cache files, the package takes its `.DS_Store`, the digest
    changes, and the removal refuses because the pool changed.
- **Results:** Swift 889 tests (6 skipped, 0 failures) and Python 75 OK. The
  app builds in Xcode for macOS (`/tmp/r31-mac-dd`, 96 s) and the iOS
  Simulator (`/tmp/r31-ios-dd`, 47 s). The release products were rebuilt on
  `main` at 21:37.
- **Helios, through the rebuilt worker** (a disk context and a dry run that
  wrote nothing): five parts, with `remove_bytes` 4,571. Before, it was six
  items and 10,719 bytes, the sixth being `3d_models/cache/.DS_Store`
  (6,148 bytes).
- **In the app (the user, 2026-10-13):** after an Xcode rebuild, the Clean
  Up sheet works.
