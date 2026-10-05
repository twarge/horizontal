# MCP field findings 10: a board save that keeps to its edit

Planning baseline: `54d007d`. Written October 5, 2026, from three notes
taken on Billo during round [nine](mcp-field-findings-9-plan.md)'s live
check. The user placed C54 in the app, and the save that followed changed
much more than that.

## Findings and changes

31. **An in-app board edit and a save rewrote the board file.**
    - **Before:** after C54's placement and a save, Billo's `board.json`
      went from 1,961,284 to 2,053,833 bytes, with 1,719 changes. Only
      one was meant: the C54 package.
      - **Texts:** 157 of the 162 board texts were written as they draw.
        Each smashed `$RD` became its refdes and `$project_title` became
        "Billo", so they no longer follow a refdes or a title.
      - **Junctions:** 1,561 of the 2,440 junctions gained a `net`, 105
        of them on nets the block doesn't have. Horizon writes only a
        junction's position (`common/junction.cpp`).
    - **Cause:** the model holds what the canvas draws, and the board
      writer, `HorizontalProjectJSONApplicator.apply(board:)`, wrote that
      back for every text and junction on the board, on any board edit.
      - **The texts:** the loader puts the substituted text in
        `HorizontalText.text`, and `patchTexts` wrote `text.text`.
      - **The junctions:** the editor's connectivity pass, which runs
        after every board edit, gives each junction its copper's net, and
        `patchJunctions` wrote every one of them.
    - **Found on the way, the same bug in angles:** the loaders read a
      mirrored free text's angle as it draws, 32768 less the stored one
      (`accumulatedText`), and the writer put that back.
      - **The effect:** each in-app write turned a mirrored text half a
        turn. On Billo, those are 45 bottom-side references.
      - **Why the C54 save looked clean:** it was written twice, first by
        the placement and then by the board sync, which read the first
        write back. The second turn undid the first. A single in-app board
        edit and a save, moving a package say, would have left all 45
        upside down.
    - **Now:** a board read and written back unchanged is the same file,
      byte for byte. On a disk copy of Billo, the load, the editor's
      connectivity pass and the write-back give `board.json` unchanged.
      - **Texts:** a text keeps its stored form as a placeholder
        (`HorizontalTextPlaceholder`: what the file stores, and what that
        drew when read).
        - **A save** writes the stored form while the text still draws
          what it did when read, and whatever it draws once someone has
          typed something else.
        - **A refdes rename** redraws the placeholder too, so `$RD` stays.
        - **Smash** copies a package's own texts, placeholder and all.
          Horizon's smash keeps `$RD` too (`board.cpp`, `smash_package`).
      - **Angles:** the writer turns a mirrored text's drawn angle back
        into the stored one. Board texts and sheet texts share the writer,
        so both are covered.
      - **Junctions:** a save keeps a junction's net up to date where the
        file has one (an MCP edit's cache), and gives one to a new
        junction, as MCP does. It adds no net to a junction the file
        stores without one. The loader works those out from the copper,
        as of round nine. This is the rule wires already follow.
    - **Left as is:** a board file with no `grid_settings` gains them on
      the first in-app save, as it would from Horizon, which always
      writes them (`board.cpp`). Billo's board has them.
32. **A placement dropped three planes from the app's model.**
    - **Before:** Billo has three Inner 2 planes on nets the block no
      longer has: `fc2d9ac9…`, `aab6c966…` and `222b6149…`.
      - **The app** drew them until a placement scheduled a board–netlist
        sync, whose `removePlanesWithDeletedNets` dropped them without a
        word. `board_info` went from 16 planes to 13.
      - **`list_planes`** reads the file and still listed 16. It showed
        the three as not poured, while `planes.json` holds their fills.
    - **What Horizon does:** its `Plane` constructor throws "net … not
      found", and the board drops that plane when it opens
      (`board/plane.cpp`, `load_and_log`). Such a plane can't come back:
      whatever deleted its net left it behind.
    - **Now:**
      - **The loader** leaves such a plane out, as Horizon does, with a
        load diagnostic naming the plane, its layer and the missing net,
        and saying that `remove_plane` takes it out. So the board is the
        same before a sync and after one. `check` reports the diagnostic.
        A plane's polygon stays in the board and is drawn as a polygon.
        The plane's entry stays in the file until an edit removes it.
      - **`list_planes`** marks such a plane `net_missing`.
      - **`retire_net`** used to leave a net's planes behind, still on the
        net it removed, which is how a board comes to have these planes.
        It now removes them and keeps their outlines as polygons. Tracks
        and vias are still left on no net unless `remove_routing` is
        passed, since Horizon allows that and doesn't allow a plane with
        no net.
33. **After the placement, the top undo step had no name.**
    - **Before:** `can_undo` was `""` where "Place Package" was expected,
      so Undo would have taken back something other than the placement.
    - **Cause:** SwiftUI registers an unnamed undo for every assignment to
      a `FileDocument` through its binding. The board sync after a
      placement runs asynchronously, so its write to `document.archive`
      came after "Place Package" as a step of its own. The pour after a
      plane edit was the same. Being a new step, it also cleared Redo when
      a sync followed an Undo.
    - **Now:**
      - **`applyEditedBoard`** assigns the document only when the board
        writer changed a file. `apply(board:)` and `applyPlaneCache` say
        whether they did. After the fix to 31, the sync after a placement
        changes nothing, so it registers nothing.
      - **A follow-up write that does change something,** a sync or a pour
        after a plane edit, goes through `applyFollowUpBoard`. It turns
        off undo registration on the document's undo manager while it
        writes, and marks the document edited itself. Undoing the step
        before it restores the whole board, the follow-up included.
    - **Left as is:** the iPad project view has its own copy of the sync
      and the pour. The main checkout holds uncommitted work in that file,
      so it isn't touched here.

## Verification

- **Swift:** 828 tests, 0 failures, 6 skipped. New tests:
  - **An in-app board edit (31):** a routed board as Horizon writes it.
    It has a bend junction with no net, `$project_title`, a smashed `$RD`
    and mirrored bottom-side texts at 0°, 90°, 180° and 270°.
    - **Read, through the editor's pass, and written back:** reports no
      change, and gives the same bytes.
    - **A moved package:** changes exactly its placement.
    - **A text typed over:** stores what was typed.
    - **A refdes rename:** redraws and keeps `$RD`.
    - **Against the old writes:** the unchanged write-back differs, from
      the text and junction writes, and from the angle write.
  - **A plane on a missing net (32):** the loader leaves it out with a
    diagnostic naming it, and a board sync changes nothing more.
    `list_planes` marks it `net_missing`, and `check` reports it.
    `remove_plane` takes it out of the file.
  - **`retire_net` (32):** it removes the net's plane and keeps the
    outline as a polygon, with no load diagnostics after.
- **Python:** 65 tests, all passing, against this worktree's release build.
- **Billo, on a disk copy:**
  - **Loading:** gives 13 planes, with a diagnostic for each of the three
    orphans, and 32 airwires.
  - **The write-back:** the editor's connectivity pass, with 1,561
    junction nets, and the write-back report no change, and `board.json`
    keeps its bytes. A second write, as the sync makes, also changes
    nothing.
- **Not tested directly:** the view code for 33, `applyEditedBoard` and
  `applyFollowUpBoard`, has no test harness. SwiftUI's unnamed undo
  registration is inferred from `FileDocumentConfiguration.document`'s
  documentation and from the `""` seen live. The live check will tell.
- **Live:** waits for a rebuilt app and a new session.

## Open

None. One Billo follow-up was done:
- **Billo's three orphan planes:** removed on October 5 with `remove_plane`
  through MCP. On a disk context, `board.json` lost exactly the three
  planes and their three polygons, and the other files are unchanged.
  `planes.json` still holds their old fills, which Horizon ignores for a
  plane that isn't there. The next pour drops them.
