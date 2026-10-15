# MCP field findings 35: an open document notices its files changing

Planning baseline: `6d468d8`. Written October 14, 2026. The item came from
the Cinnamon edits and is recorded in billo's `docs/horizontal-mcp-notes.md`.
Autosave in place is the right behaviour for a Mac document and stays as it
is. What was missing is the other half: noticing when something else writes
the files.

## Findings and changes

121. **An open document didn't notice its files changing on disk, and its
     next autosave wrote them back.**
     - **The symptom:** something other than the app changed the files beside
       an open `.hprj`. That could be a git `checkout`, `pull`, `stash`,
       `reset` or `rebase`, a sync client, or a script.
       - The document kept its own copy, and the canvases and live reads went
         on showing it.
       - The next edit's autosave wrote every file that differed from disk
         (`writeInPlace` skips only identical ones) back over the change.
     - **The cause:** the document system presents only the `.hprj`, and
       nothing watched the files the project references. Disk contexts
       refused an edit when their files changed ("Project files changed on
       disk"); live documents never compared.
     - **Now:**
       - **Watching:** `HorizontalProjectFileWatcher` (macOS) follows the
         project's folder through FSEvents, which sees writes from any
         process, not only coordinated ones. It ignores:
         - paths the project doesn't read, such as exports beside a `.hprj`;
         - `.git` and `.horizontal-transactions`;
         - Finder's `.DS_Store` and `._*`, and safe-save temporaries;
         - what the project's `.gitignore` leaves out.
       - **Reading:** once the folder has been quiet for half a second, the
         watcher reads the project off the main thread.
       - **Comparing:** `HorizontalProjectFingerprint` gives each file a
         digest, and `HorizontalProjectChangeDetector` (ProjectIO) expects the
         files to hold one of:
         - what the document holds;
         - what they held when last seen in step;
         - something the document wrote since. `didWriteNotification`
           already posted the archive of every save, autosave included; the
           watcher records it on the saving thread, before the files land.

         Anything else is a change from outside.
       - **Nothing unsaved:** the window reloads as Revert does. The project
         is loaded from the files, the canvases and the live channel follow,
         undo starts over, and the document's change count and modification
         date are reset so the reload isn't saved back or taken for another
         program's edit.
       - **Edits not yet autosaved:** the window asks "Changed on Disk" with
         two choices:
         - **Reload from Disk** discards those edits.
         - **Keep My Version** accepts what the files hold as seen, and lets
           the document's save write its version over them.

         Until it is answered:
         - the document's saves wait: `HorizontalDocumentSaving.holdSaves`
           runs as an activity, which the document system's saves queue
           behind;
         - the live channel refuses `apply` and `save` with
           `STALE_REVISION`.
       - **A live edit right after a change:** an edit arriving before the
         half-second check doesn't wait for it.
         - `applyLiveArchive` calls `checkNow`, which reads the files there
           and then.
         - A read that looks like a change is read again 150 ms later, and
           believed only when two reads agree, since an autosave or a
           checkout can be halfway through.
         - If the files changed, the edit is refused with `STALE_REVISION`
           after the reload (or the question).
     - **What this leaves alone:**
       - **Read-only documents** hold only their `.hprj`. They reload the
         project, but keep the archive they have, so nothing is marked
         edited that can't be saved.
       - **The iPad app** has no watcher.
       - **A `.horizontal` package changed from outside** is watched and
         reloaded the same way. Its archive has no manifest, though, so a
         write the watcher sees from another open package counts as possibly
         its own. That costs a fingerprint, and matches nothing.

## Tests

- **`HorizontalProjectDiskChangesTests`** (new, ProjectIO), on a `.hprj`
  fixture written to a temporary folder. Eight tests:
  - **The document's own writes:**
    - an autosave of the document is in step;
    - an autosave overtaken by a newer edit is the document's own;
    - Finder and git droppings are not changes.
  - **Changes from outside:**
    - a checkout under the document is a change on disk;
    - a part added by a pull is a change on disk.
  - **After a change:**
    - a state the user chose to keep isn't reported again;
    - without a document copy (read-only), the baseline decides.
  - **What the project reads:** exports beside the project and files at
    its top level are not tracked.
- **`HorizontalProjectFileWatcherTests`** (new, macOS), through real FSEvents
  on a temporary folder:
  - a change from outside is reported once;
  - the document's own write (posted, then written in place) is not;
  - exports and `.DS_Store` beside the project are not;
  - `checkNow` sees a change the schedule hasn't read yet.
- **Results:**
  - **Swift:** 904 native tests (6 skipped), the 900 from before plus the
    four watcher tests, and the eight new ProjectIO tests.
    `RouterRealBoardHarnessTests.testRoutingBetweenRealPads` failed once on
    its one-second budget (1.19 s while Xcode was building) and passed on
    its own.
  - **App builds:** Xcode builds for macOS and the iOS Simulator
    (`/tmp/r35-ios-dd`).
- **Left for the app:**
  1. **A checkout reloads silently.** Open a project from a git checkout,
     wait for it to settle, then `git checkout` a branch that changes its
     board, or `git stash` an edit. The window should show the other branch
     within a second. Undo should be empty.
  2. **An edit, then a checkout, asks.** Make an edit and, before it
     autosaves, `git checkout -- board.json`.
     - The window should ask "Changed on Disk".
     - **Reload from Disk** shows the file as checked out.
     - **Keep My Version** puts the edit back on disk.
  3. **An MCP edit right after a checkout is refused.** Send `apply_ops`
     within half a second of a checkout. It should fail with
     `STALE_REVISION`, and `open_project` should then show the files'
     version.
