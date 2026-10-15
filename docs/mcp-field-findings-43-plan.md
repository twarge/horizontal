# MCP field findings 43: Replace no longer asks to reload

Planning baseline: `b3d1229`. Written October 15, 2026. The item is the
user's, from Replace in the Pools pane (round 40), and is numbered 131 for
billo's `docs/horizontal-mcp-notes.md`. It touches item 121's file watcher
(round 35, from the item 121 session).

## Findings and changes

131. **Replace often asked whether to keep my changes or reload from disk.**
     - **The report:** "when I use the part replace command, it often pops up
       note saying that the files on disk have changed and asking me whether I
       want to keep my changes or reload."
     - **The cause:** Replace, like Place, first caches the part into the
       project pool. `cacheLibraryPart` writes the part's files and the pool
       cache manifest (`pool/.horizontal/pool-cache.json`) to disk, and the
       same bytes into the document. Then it applies the `set_part` edit,
       which waits for the next autosave.
       - **What the watcher then saw:** its check found the files holding the
         new pool files and the old block. That is neither the document (new
         pool files, new block) nor the baseline (old pool, old block), nor
         one of the document's recorded writes.
       - **Why that counted:** `HorizontalProjectChangeDetector.classify`
         compared whole fingerprints only, so this mix read as
         `changedOnDisk`. With the edit still unsaved, the user was asked.
       - **"Often", not always:** when the autosave landed before the check
         read the files, they matched the document.
     - **Now:** after the whole-fingerprint comparisons, `classify` compares
       file by file (`holdsOnlyKnownVersions`). The files are the document's
       own when each one holds a version the document knows: the document's,
       the baseline's, or a recorded write's, present or absent alike. The
       baseline then moves to the files as they are.
     - **Still caught:**
       - **A checkout or a pull** writes something none of those had: a
         changed block, a new part, a pool file written over.
       - **A part a pull adds** is in none of them, so it is still a change
         (`testAPartAddedByAPullIsAChangeOnDisk`).
     - **Also covered:** anything else the app writes to the project itself
       and puts in the document too, such as Place's own caching, which had
       the same race.

## Tests

- **`HorizontalProjectDiskChangesTests.testAPartTheAppCachesBeforeTheAutosaveIsTheDocumentsOwn`**
  (new) replays Replace's sequence:
  - a part and the manifest written to disk and into the document, and an
    unsaved block edit: `documentAhead`, not `changedOnDisk`;
  - after the autosave: `inStep`;
  - a cached part then written over from outside: `changedOnDisk`.
  - **Without the fix** the first check is `changedOnDisk`: the prompt.
- **Item 121's eight detector tests** pass unchanged.
- **Results:**
  - **Swift:** 934 tests in HorizontalNativeTests (6 skipped) and 9 in
    HorizontalProjectIOTests, 0 failures.
  - **App builds:** Xcode builds for macOS (`/tmp/r43-mac-dd`) and the iOS
    Simulator (`/tmp/r43-ios-dd`).
- **Left for the app:**
  - **Replace and Place:** Replace a part, and Place one, several times. No
    reload prompt should appear.
  - **A real outside change:** a `git checkout` of a changed file still
    prompts while there are unsaved edits.
