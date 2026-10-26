# MCP field findings 49: pool links, pool watching, and the canvas

Planning baseline: `b0fa2b4`. Written October 25, 2026. This round covers
items 152–155 in `horizontal-mcp-notes.md`, from the October 21 Jude session
and the October 25 Cinnamon session, and the requests the user added while it
was built: links both ways between pool items on screen, Alternate Parts… on
a symbol, the Replace icon, and three canvas bugs (angled net lines, a
highlight that outlived a page flip, a deleted gate that kept its nets).

## Findings and changes

152. **The Pools pane didn't show what the MCP wrote** until Pools ▸ Rescan
     Pools. The pane keeps its own scan and rescanned only on that command, a
     saved item or a change to the registered pools. `pool_write` cleared the
     library's scan cache, but a live edit reaches disk at the next autosave,
     so a scan in between cached the pool without the new item.
     - **Now: the pools on screen are watched.** `HorizontalPoolWatcher`
       watches every pool the Pools pane browses and every pool an item
       editor's item belongs to, while each is open, through a lease.
       - **What it hears:** on the Mac, FSEvents (item 121's
         `HorizontalDirectoryEvents`), which hears every writer: a `git pull`,
         Horizon, another window, an MCP `pool_write` once its autosave lands.
         On iPad, which has no FSEvents, a file presenter, which hears the
         writes that coordinate: the Files app, iCloud Drive, other apps.
       - **What it does:** once the pool's folder has been quiet for 0.5 s, it
         reads that pool again (`HorizontalPoolLibrary.rescan`). If what the
         pool lists changed, it posts `poolsDidChangeNotification` naming the
         pool. The pane and the item editors listen for it.
       - **Autosave:** a `.horizontal` package is rewritten whole by each
         autosave, so the project pool looks changed every few seconds. The
         rescan compares the new scan with the one it replaces, so a rewrite
         that changes nothing moves nothing on screen. A read overtaken by a
         later change hands its finding to the later read, which still
         announces it.
       - **What is ignored:** paths a scan never reads: hidden files, `.git`,
         `3d_models` and the other skipped folders, and non-JSON files.
     - **The direct signal:** `HorizontalPoolLibrary.invalidateCache()` and
       `invalidateCache(for:)` now post the same notification, so every write
       the app makes itself shows at once: Place and Replace caching a part,
       an import, a copy to a pool, a pool update, the default pool's clone.
       That is the iPad's path for its own writes. The pane coalesces requests
       that come within 60 ms of each other into one rescan, where its own
       invalidations used to bump the scan once each.
     - **Item editors:** an editor's index (its links, its pickers) now
       follows its pools, and resolves parts through their bases.

153. **`remap_part` counted a no-connect pin as connected.** U23 on Cinnamon,
     going from the ADA4523-1 (SD and COM marked no-connect) to an ADA4077-1
     on a plain single op-amp, was refused: "2 connected pins have no
     counterpart by name on the new part: COM, SD". Neither pin was on a net.
     - **Now:** only a pin on a net needs a counterpart. A no-connect mark, or
       a chosen alternate, on a pin the new part lacks is dropped. The reply
       names those pins in `no_connects_dropped` and `alternates_dropped`, as
       an unmapped pad is dropped. A pin on a net with no counterpart is still
       refused.

154. **Nothing found the symbols a unit has.** `search_pool` with `kind:
     symbol` and the unit's uuid returned nothing, and no symbol row named
     its unit.
     - **Now: pool items link both ways, in one index.**
       `HorizontalPoolLibraryItem.references` is what an item names:
       - a symbol: its unit;
       - an entity: its units;
       - a part: its base part, entity and package (an inherited one through
         its base);
       - a package: its padstacks.

       `HorizontalPoolLibraryIndex.users(of:uuid:kind:)` reads those
       backwards: Horizon's Where Used. The scan reads each entity's units and
       each package's padstacks as it parses the file, so nothing is opened
       twice.
     - **search_pool:**
       - **Rows name what they use:** a symbol row gives `unit_id` and `unit`,
         an entity row `unit_ids`, a package row `padstack_ids`, a derived
         part's row `base_id`. Part rows already gave `entity_id` and
         `package_id`.
       - **`uses`** keeps the items that name one item, by uuid or 8+ leading
         digits. `kind: symbol` with a unit lists the symbols that draw it;
         `kind: entity` with a symbol's `unit_id` lists the entities it can
         draw.
       - **`used_by`** keeps the items one item names. `missing_links` names
         any of those that no searched pool holds.
       - **Refusals:** a link shorter than eight digits is `INVALID_ARGUMENT`,
         one that begins several uuids is `AMBIGUOUS_SELECTOR`, and one that
         begins none is `NOT_FOUND`.
     - The index is built only when a link is followed or a symbol row names
       its unit, so a plain search costs what it did.

155. **Live calls timed out while the app sat idle.** In the October 25
     Cinnamon session a `save`, three `get_pool_item` calls, a `live_state`
     and a `pool_write` dry run each failed with `TIMEOUT`. `connection_status`
     gave `latency_ms` 15,954, then 11,649. The app was a Debug build at 0.4%
     CPU throughout, while Xcode and another session's Python tests loaded
     the machine.
     - **The likely cause: App Nap.** In the background the app runs at
       background priority, and on a loaded machine it waited seconds for the
       main thread. The activity that keeps it at user priority began only
       once a request had been read, which was itself waiting at nap priority.
       One slow request then timed out and closed the client's socket, and the
       calls queued behind it failed with it. This wasn't reproduced; it fits
       an idle app answering a 2 ms request in 12–16 s.
     - **Now, in the app:** `HorizontalLiveActivity` keeps App Nap off while
       any live client is connected. It begins when the listener accepts a
       connection, before the hop to the main actor, and ends when the last
       connection closes. An MCP client holds its connection for the session,
       so this holds while an agent works with the app. It keeps no thread
       busy and allows idle system sleep. The listener's queue is
       user-initiated.
     - **Now, in the client:**
       - **The TIMEOUT error says what happened:** which method didn't answer
         and in how long, and that the next call on the context reconnects.
         It already did reconnect; nothing said so.
       - **`connection_status` explains a closed context:** it gives
         `closed_by`, with the code, method and time of what closed it.
       - **`get_pool_item` is retried:** it joins the reads that are retried
         once on a fresh connection after a timeout.
     - **Two ids, one name:** the notes' "the engine at a new instance_id" read
       two different ids as one. A context's `instance_id` names its
       document's open in the app; the live engine's names the app's
       dispatcher. `connection_status` now says so.

## The user's requests

- **Links between pool items, both ways, on screen.** The Pools pane's
  preview linked forward for parts only. Now every kind links both ways:
  - a symbol: its unit, and the entities that can draw it;
  - a unit: the symbols that draw it, and the entities using it;
  - an entity: its units and their symbols, and its parts;
  - a part: what it did before, and its derived parts;
  - a package: its padstacks and its parts;
  - a padstack: its packages.

  Units and entities show them in their tables. Symbols, packages and
  padstacks show them under the drawing. A link goes to its item in the list.
  A field shows its first 24 links, then "and N more…", which lists them all
  with a search: the pane's search now matches the uuids an item names, so
  an entity's uuid among the parts lists its parts. The context menu's
  "Show …" entries gain the same items.
- **And in the item editors.** The unit, entity and part editors have link
  rows in their header grids, and the canvas editors (symbol, package,
  padstack, frame, decal) in their sidebars. A symbol's unit, beside Change
  Unit…, is a link, and the part editor's entity, package and base part are.
  A link opens its item: on the Mac in a window of its own, as Edit does; on
  iPad pushed onto the editor cover's stack, with Back.
- **Alternate Parts…** in a symbol's right-click menu, and in a package's on
  the board: the Pools pane, opened if hidden, on the parts that can replace
  the component's, with the Replace banner. Showing the parts brings the
  banner back even where it was closed for that selection.
- **Replace's icon** is `rectangle.2.swap`, on the toolbar button and the
  banner.

## Canvas bugs found on the way

- **A net line at an angle couldn't be selected.** Clicks, hover and the
  right-click menu were hit-tested at the grid-snapped cursor, not at the
  pointer. Commit `60b7b7f` narrowed the hit box to 7 pt; it didn't cause
  this.
  - **Why only angled lines:** a horizontal or vertical wire lies on a grid
    line, so a click near it snaps onto it. A wire at an angle runs between
    grid points, so a click right on it snapped up to half a millimetre off:
    11 pt at 20 pt/mm, outside the hit box.
  - **The board too:** tracks at angles other than 45°, and off-grid tracks
    at any angle, had the same problem.
  - **Now:** `InteractiveCanvasView` gives both canvases a
    `HorizontalCanvasPointer`. Its `snapped` point is for what a tool puts
    down; its `raw` point is for what a click, a hover or the menu hits, as
    Horizon hit-tests the pointer. Add Vertex still bends a wire at the
    snapped point.
- **A highlight outlived a page flip.** On the Mac a highlight was cleared
  only as a side effect of the selection changing. A sheet flip empties the
  selection and keeps the highlight, so the next empty click changed nothing,
  and nothing cleared it. The same held for a highlight from the MCP, the
  voice commands or the Parts pane, which come with no selection. Escape at
  rest never cleared anything, and on iPad a tap never cleared a highlight.
  - **Now, as Horizon does:** a click or rubber-band that hits nothing and
    replaces the selection ends the highlight
    (`HorizontalCanvasModeSupport.clearsHighlight`). Escape with no tool
    active empties the selection and ends the highlight (Horizon's
    `handle_action_key`), on the schematic and the board, on the Mac and
    iPad.
- **A deleted gate kept its nets.** Deleting one gate of a part whose other
  gates stay sent it back to the unplaced list still on its nets, so placed
  again it came back wired to them, and its pads kept their airwires.
  - **The canvas:** it re-ended the gate's wires on junctions, but never took
    the gate's pins off their nets.
  - **The writer:** even had it done so, the save would have dropped the
    change. It worked out which gates the sheet drew after taking the
    deleted symbol out, so the deleted gate counted as never drawn.
  - **Now:** `HorizontalSchematicSheet.disconnectGate` is Horizon's
    `disconnect_symbol`: the gate leaves every net and no-connect mark, and
    each pin goes into `removedConnections`. The writer reads the gates drawn
    before it patches the sheet. A gate the sheet drew before and that no
    sheet draws now also loses its connections in the block, whatever the
    sheet's copy says.
  - Upstream erases them only when the sheet has wires, since its erase sits
    inside the wire loop; that reads as an oversight and isn't copied.

## Follow-up: remove_symbol does what the canvas does

The user asked for this once the round was in (`13f2fb1`). `remove_symbol`
kept the component's connections and deleted the wires to the symbol.

- **Now it does what the canvas delete does, and Horizon's
  `disconnect_symbol`:**
  - **Wires:** each wire that ended on a pin of the symbol ends on a junction
    where the pin was, one per pin, on the wire's net
    (`removed.net_lines_re_ended`). Without `keep_wiring` the cleanup then
    takes what serves nothing, as before. With it, the stubs stay on their
    junctions, as the canvas leaves them.
  - **Nets:** the gate leaves every net and no-connect mark
    (`removed.disconnected`), so placed again it starts unconnected. A gate
    the op doesn't remove, or one that isn't drawn, keeps what it has.
  - **Copper:** the reply's warnings name pads with copper whose pins left
    their nets, as `disconnect` does.
- **Tests changed:**
  - `HorizontalProjectEditorTests`: R2's pins are on no net after its symbol
    goes, where the test expected the netlist untouched.
  - `HorizontalMCPFieldFindings44Tests`: the cleanup now counts four wires
    rather than two, since the two wires to R1's pins now stay on junctions
    until it.
  - `HorizontalMCPFieldFindingsTests`: terminate_pin names the net again
    after the move.

## Not changed
- **`search_pool` on a live document** still reads the project pool from
  disk, so an item `pool_write` has just written appears there once the
  autosave lands, as it now does in the Pools pane. `get_pool_item` reads
  through the document, as before.
- **No navigator keyboard hand-off:** after a page flip from the navigator,
  its list keeps the keyboard, so Escape reaches the canvas after a click on
  it. Handing the keyboard back is a UX call, since the navigator uses the
  arrow keys.

## Tests

- **Swift:** 16 in `HorizontalMCPFieldFindings49Tests`:
  - remap_part dropping no-connects, and still refusing a pin on a net;
  - search_pool's `uses`, `used_by`, row links, `missing_links` and
    refusals;
  - each kind's links both ways, derived parts, the 24-link cap and its
    search, and an editor's links and open action;
  - the watcher's path filter, an FSEvents round trip (a new file announced
    once; the same bytes written again, not announced; the lease released),
    and the cache invalidation's notification;
  - `HorizontalLiveActivity` counting connections;
  - the angled wire's hit at the raw point where the snapped one misses;
  - the highlight rule, and a mounted canvas where Escape at rest ends a
    highlight with no selection behind it.

  `SchematicDeletionTests` gains a mounted test that deletes a gate on the
  canvas, checks the block, every sheet's copy, the gate placed again and
  Undo, and checks the writer-only path in the existing gate test.
- **Changed test:** `HorizontalPoolPreviewTests` expected an entity, a
  symbol and a package to link only to what they name. They now link to what
  names them too (the entity's part, the symbol's entity, the package's
  parts), after it.
- **The whole suite:** 1,195 run, 10 skipped. The only failures were that
  test's three old expectations, which pass updated.
- **iOS:** the app builds for the iOS Simulator, the file presenter and the
  editor cover's stack included.
- **Python:** `test_mcp` and `test_transports` gain search_pool's links, the
  schema's new parameters, `closed_by`, the timeout message and the
  remembered error. Of 88, test_ato's sync fails as it does on HEAD.
  `test_pool_reach_and_the_state_of_the_live_channel` failed once while the
  Swift suite ran beside it, and passes alone and in a second full run.
- **Op digest:** unchanged; `remap_part`'s schema changed only its
  description.

## Needs

- **An Xcode rebuild**, so the live app runs the new engine, the watcher and
  the canvas fixes.
- **A new session**, so the MCP server loads the new `search_pool`
  parameters and descriptions.

## To check

- **On Cinnamon:**
  - `search_pool` `kind: symbol` `uses: <the ADA4077-1's unit>` lists its
    symbols.
  - A dry run of U23's remap from the ADA4523-1 gives `no_connects_dropped`.
- **On Jude:** `pool_write` a part with the Pools pane open. It appears
  within seconds of the autosave, with no Rescan.
- **In the app:**
  - A symbol's preview links to its entities, and an entity's editor links to
    its units and symbols.
  - Alternate Parts… on a symbol opens the parts with the Replace banner.
  - An angled wire selects with a click, and so does an off-grid track.
  - Highlight a net, flip the sheet, and click empty canvas or press Escape:
    the highlight goes.
  - Delete one gate of a two-gate part and place it again: its pins are on no
    net.
