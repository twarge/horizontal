# MCP field findings 22: list_parts rows, refused exports, the Parts pane, and a quit app

Planning baseline: `4f4c08c`. Written October 12, 2026. Items 74–79 came
from the live check of rounds 19–21 on Billo (the check itself is recorded
in billo's `docs/horizontal-mcp-notes.md`). Items 77 and 79 include requests
the user made during it.

## Findings and changes

74. **`list_parts` pool rows gave the manufacturer as `description`.**
    - **Before:** with `scope` "pools", all 1,560 rows on Billo had
      `description` equal to `manufacturer`. C1608X5R1C106M080AB read "TDK",
      where `search_pool` read "Multilayer ceramic chip capacitor".
      `listParts` set `json["description"] = item.detail` after
      `HorizontalDispatchPool.itemJSON` had already set it to the part's
      description, and a part's `detail` is its manufacturer. The line dated
      from `ce18ef8`, before `itemJSON` gave parts a description.
    - **Now:** the line is gone, so the row keeps the description.

75. **`list_parts`'s scopes didn't do what its description said.**
    - **Before:** "pools" also listed the project pool's own parts, from its
      cache, so on Billo it gave the same 1,560 uuids as "all". In "all", the
      project rows and the base-pool rows had different keys, though the code
      said "One row shape throughout".
    - **Now:**
      - "pools" lists the base pools only. A part the project has cached is
        listed as its base pool holds it, marked `in_project_pool`. The
        project pool is still scanned, since a derived part's base may live
        only there.
      - "all" lists the project's parts, then the base pools' parts it
        doesn't have.
      - Every row has the same 19 keys. A project row gains `uuid`, `kind`,
        `name`, `detail`, `package_id`, `pool`, `pool_path` and `path`
        (`HorizontalPoolPart.fileURL`, kept by `loadAll`).
      - A base-pool row gains `entity_id`, resolved through its base
        (`HorizontalPoolLibraryItem.partEntityID`). It also gains
        `refdes_prefix` and `gate_count`, which are null on a base-pool row
        because a scan doesn't open entities.
      - `package` and `package_id` are always present, null when unknown.
      - The tool's description says all of this.

76. **A live export to a folder the sandboxed app can't write failed with
    Cocoa's wording, as data.**
    - **Before:** exporting to `/tmp` replied `status` "error", `files: []`,
      "…You don't have permission to save the file "Billo BOM.csv" in the
      folder…", with no error code and no hint. The same export from a disk
      context, which runs in the worker, wrote both files.
    - **Now, in the engine:**
      - `export` first checks that it can create the folder and write a
        file in it (`requireWritable`, which removes its probe). If it
        can't, it fails before any exporter runs, with a new code:
        `PERMISSION_DENIED` (-32010).
      - The error's details carry `target_directory`, `sandboxed` and
        `reason`, and the message says what to do in the app's case.
    - **Now, in the server:**
      - When a live export is refused that way, `export` compares the open
        document's snapshot with the project's files, through a fresh disk
        context in the worker.
      - If they match, the worker exports the files and the reply says
        `via` "worker", with the snapshot and a note. The disk context is
        then closed.
      - If they don't, the error stands, extended with both snapshots and
        "save first". Any other export error is passed on unchanged.
      - The tool's description says so.

77. **The Parts pane listed a part once per pool, and couldn't show one pool.**
    - **Before:**
      - `filteredItems` filtered by category and search text only. So a
        part cached in the project pool appeared once per pool holding it:
        TPS62172DSGT under Project pool and under Twinleaf Pool, and the
        same for C1608X5R1C106.
      - The Pools menu listed the browsed pools and "Add Pool…", with no way
        to look at one pool.
    - **Horizon:**
      - It keeps one row per uuid: a later pool's copy overrides the
        earlier one and records it as `last_pool_uuid`
        (`PoolUpdater::handle_override`).
      - Its browser has a pool selector ("All pools", "<pool> (This)", each
        included pool) that filters on `pool_uuid` (`pool_selector.cpp`,
        `pool_browser.cpp`).
    - **Now:**
      - With every pool in view, the list shows one row per item: the first
        pool's copy, which is the project pool's.
      - Pools > View, a submenu the user asked for, picks All Pools or one
        browsed pool. One pool shows its own items, cached copies included.
      - While one pool is viewed, the Pools button shows its name and its
        help says how to go back. The empty list names the pool.
      - Revealing an item the viewed pool doesn't hold switches back to All
        Pools, and so does a search reveal. A pool that stops being browsed
        stops being viewed.
      - The logic is `HorizontalPoolBrowserView.visibleItems`.

78. **`connection_status` reported a context on a quit app as connected.**
    - **Before:**
      - After the user quit the app, the old context still read
        `connected: true`, with the dead app's engine, until `open_project`
        replaced it. `connected` was `not transport.closed`, and a live
        transport is only marked closed once a call fails on it.
      - The finding also noted that nothing tells a stale app build from a
        current one. The engine's `build.modified` is the launch time under
        Xcode, since Run re-signs the binary, and the schema digest only
        moves when the edit ops change.
    - **Now:**
      - `LiveTransport.alive()` asks the socket, without sending anything,
        whether its peer has closed. It peeks one byte without blocking, and
        if a call holds the lock, the connection is taken as in use.
        `connection_status` reports `connected` from it.
      - Its description now says what `connected` means and why
        `build.modified` can't show whether the app is current.
    - **Tried and dropped (the user's choice):** an Xcode build phase that
      recorded the commit (and a dirty flag) in the app for the engine to
      report, and for `connection_status` and `open_project` to compare with
      the server's checkout.
      - The project enables user-script sandboxing, whose profile allows
        each declared input as a literal path only. So `git` can't read
        `.git`, and a sandboxed test build recorded `null`.
      - Two ways round it were offered: turning the sandbox off for the app
        target, or reading `.git/logs/HEAD`, which fails the build where that
        file is missing, such as a linked worktree. The user chose to drop
        the stamp instead. A stale app still can't be told from a current
        one.

79. **The Parts pane's toolbar kept its text when the pane was narrow.**
    - **The user's request:** drop the text and keep the icon and, on
      menus, the picker triangle.
    - **Now:**
      - The toolbar is a `ViewThatFits` of two rows. The full row has the
        labels, and the search field asks for at least 160 pt. The compact
        row has icons only, and the field asks for 80 pt.
      - In the compact row, the kind pop-up becomes a menu showing the
        kind's icon, with the kinds inside as an inline picker.
      - The icon-only style is set on each label rather than on the row, so
        a menu's own items keep their titles. Each control's help names it.

## Tests

- **`testPoolRowsKeepTheirDescriptionListTheBasePoolsCopyAndShareOneShape`**
  (74, 75) covers:
  - a base-pool row's description;
  - a cached part listed by "pools" from Stock, marked `in_project_pool`,
    and once by "all";
  - the same keys in every scope, with null `refdes_prefix` and
    `gate_count` on the base-pool row;
  - the `path` of the project row.
- **`testAnExportToAFolderThisProcessCannotWriteIsAPermissionError`** (76)
  checks a read-only folder and a folder inside one. Both give -32010
  `PERMISSION_DENIED` with the details, nothing is written, and a writable
  folder still exports with the probe removed.
- **`testAllPoolsShowsOneRowPerItemAndOnePoolShowsItsOwn`** (77) checks
  `visibleItems` with every pool, the base pool and the project pool in view.
  A uuid shared by two kinds stays two items, and a trailing slash names the
  same pool.
- **Python:**
  - `test_alive_sees_the_app_go_without_sending` and
    `test_alive_does_not_eat_a_pending_reply_or_wait_on_a_call` (78).
  - `test_a_context_whose_app_has_gone_reads_as_disconnected` (78).
  - `test_a_refused_live_export_runs_in_the_worker_when_the_files_match`
    (76) covers the match, the mismatch with "save first", and another
    error passed through.
- **79** has no unit test. It needs a look in the app.
- **Results:** Swift 870 tests (6 skipped, 0 failures), Python 72 OK. The app builds in Xcode (Debug).
