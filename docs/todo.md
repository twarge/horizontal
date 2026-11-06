# To do

Features the app does not have yet, and controls that claim more than they do.
Paths are relative to `Sources/HorizontalNative/` unless they start elsewhere.
Tick an item off when it lands on main, with the commit that did it.

## Try in the running app

Everything ticked on 2026-11-05 is covered by tests, but none of it has been
tried in a running app except the 3D Controls panel, seen in a Mac build.

- [ ] Layer Mode: Current only, Current and adjacent (fa5534a, 05c0799).
- [ ] The airwire filter button, popover and Design ▸ Filter Airwires… (80c82fb).
- [ ] The rules checks: results sidebar sections, red and yellow markers, the
      toolbar badge, Show Rule (8161b8c).
- [ ] Differential pairs: the inspector's row, Set/Clear Differential Pair in
      the Design and right-click menus, the schematic's pair colour (eaef9d0,
      2cf5db0, 80bc147).
- [ ] The track HUD readouts and the Length Tuning window, on the Mac and as a
      sheet on the iPad (eaef9d0).
- [ ] Tune Track (571cdfc).
- [ ] Select More, + and =, and a double-click on a track (4f8cea0).
- [ ] Block instances kept laid out alike, U to edit one alone, Copy Layout to
      Other Instances (88401a5).
- [ ] The 3D Controls panel on the iPad, and the via plating field's focus
      ring (f15a707).

## Controls that claim more than they do

- [x] The rules window marked 13 rule kinds "Check" where 2 were checked. It
      now says "Check" from `HorizontalBoardRuleKind.checksInHorizontal`, and
      every kind it names is checked (8161b8c).
- [x] The board's Layer Mode picker did nothing. Current only and Current and
      adjacent now draw, and the picker shows only in the board's 2D layer rail
      (fa5534a, 05c0799).
- [x] Design ▸ Filter Airwires… was always disabled. It opens the airwire
      filter (80c82fb).
- [ ] Clear All Planes only empties the fills drawn on screen; it is not an edit.
- [ ] The "Shove" router setting (`routerShove`,
      `Model/HorizontalBoardToolSettings.swift:34`) does nothing, and the
      `#if canImport(HorizontalPushShoveRouter)` blocks in
      `Views/BoardCanvasView.swift` are dead code from the removed vendored
      router. Comments still describe it as vendored or "not-yet-vendored"
      (`Views/BoardCanvasView.swift`, `Model/HorizontalBoardToolSettings.swift:25`).

## Board DRC

Since 8161b8c every board rule family is checked, in the app's background check
and results sidebar and in MCP `check`.

- [x] Track width: each track's width within its rule's minimum and maximum.
- [x] Hole size, for board, via and pad holes; the rule is parsed now.
- [x] Copper to keepout (`clearance_copper_keepout`).
- [x] Same-net clearance (`clearance_same_net`).
- [x] Silkscreen to exposed copper.
- [x] Preflight checks.
- [x] Plane priorities (fill order).
- [x] Net ties.
- [x] Height restrictions; the rules window lists the kind now.
- [x] The results sidebar shows what only MCP `check` found before: copper
      joining two nets, a plane over another net's pad, unrouted connections.

## Differential pairs and length tuning

Pairing, the readouts, the Length Tuning window, the diffpair rule and
single-track tuning have landed; `docs/length-tuning.md` is the design study and
marks its steps 1 to 4 done. KiCad's PNS router (GPLv3) can't be used or read for
what remains; it has to be built clean-room, as `docs/push-shove-router.md`
explains.

- [x] Set and Clear Differential Pair: the net inspector's Diff pair row on the
      schematic and the board, the Design menu and the right-click menu, and
      MCP `set_diffpair` / `clear_diffpair`. The schematic draws a pair in the
      Diff Pair colour; highlighting a net deliberately doesn't reach its
      partner (eaef9d0, 2cf5db0, 80bc147).
- [x] Length readouts: the selected tracks' layers and total length, the
      spacing and gap of two parallel ones, a net's routed length and its skew
      against its partner (eaef9d0).
- [x] Length Tuning window: measure the selected tracks or their nets, choose a
      reference, see each net's difference from it in millimetres and
      picoseconds (eaef9d0).
- [x] Design study, `docs/length-tuning.md` (eaef9d0).
- [x] The diffpair rule is read: the route inspector shows a paired net's
      partner, rule and gap (571cdfc).
- [x] Single-track tuning: Tune Track lays a meander to a target, the Length
      Tuning window's reference by default, with style, corners, amplitude and
      spacing, shrinking where clearance blocks it, as one undo step (571cdfc).
- [ ] Tune arcs and tracks at odd angles; Tune Track takes only straight
      tracks in the eight routing directions.
- [ ] Pair member offsetting in whole nanometres (study step 5).
- [ ] Coupled diff-pair routing: the fat-centreline route at the rule's width
      and gap, with uncoupled fan-out gates (step 6), and via pairs at the
      rule's via gap (step 7).
- [ ] Diff-pair tuning and skew tuning (step 8).

## Routing

The track tool routes around obstacles (grid search, stopping at the nearest
legal point), removes loops, starts on copper and takes its width from the
rules.

- [ ] Push and shove (steps 4–7 of `docs/push-shove-router.md`).
- [ ] Highlight what blocks a route; the finder already names the obstacle.
- [ ] Drag a track keeping its 45° slopes, and drag a via.
- [ ] Move a track's connection point; move an arc track's centre.
- [x] Select More, + and Select More stopping at vias, =, and a double-click
      on a track (4f8cea0).
- [ ] Lock and unlock tracks and vias, and Unlock All. `locked` is read now,
      and block layout sync leaves locked copper alone, but nothing sets it.
- [ ] Place a standalone via (stitching) and set a via's net. Both are MCP-only
      or missing; the inspector shows the net read-only.

## Board tools

Available only as MCP ops so far:

- [ ] Place a board hole (`place_hole`; the Place Hole tool runs only in the
      padstack editor).
- [ ] Add a keepout, or turn a polygon into one (`place_keepout`).
- [ ] Groups and tags: set, rename, clear and highlight them (`set_group_tag`).
      A block instance can be selected whole (Select Instance, 88401a5).
- [ ] Copy placement and tracks between groups that aren't block instances,
      such as atopile's (`copy_group_layout`).

Built:

- [x] Copy placement and tracks between block instances: Copy Layout to Other
      Instances, and instances laid out alike stay alike as either is edited
      (88401a5).
- [x] Airwire filter: a board rail button and popover, saved with the board's
      view (80c82fb).
- [x] Place decal: Design ▸ Place Decal… chooses one from the pools, R turns
      it, E flips it, S sets its scale, and the decal is cached into the
      project pool; the Pools pane's Place puts one on the board too, and
      MCP's `place_decal` places one the same way (`remove_decal` takes it
      off). A placed decal's scale and flip can't be changed afterwards.

Not built at all:

- [ ] Pictures on the board: not modelled or drawn.
- [ ] Draw a net tie on the board.
- [ ] Draw connection lines, and back-annotate them to the schematic.
- [ ] Align and distribute.
- [ ] Swap placement, paste placement.
- [ ] Scale, and Move by keyboard (both disabled "to do" entries in the board's
      right-click menu).
- [ ] Rotate and mirror dimensions and decals; they can only be moved.
- [ ] Update or clear a single plane.
- [ ] Selection filter, by object type.
- [ ] Highlight a net class.
- [ ] A flip-view command and key; the mirrored bottom view is reachable only
      through automation, voice and DRC findings.
- [ ] Panels and included boards: they load and draw, but can't be moved,
      placed or managed.
- [ ] Import DXF onto the board; it exists only in the package and decal
      editors.
- [ ] Measure tool, between two points. Design ▸ Measure Tracks measures track
      lengths only.
- [ ] Lines to Tracks.
- [ ] Swap Nets.
- [ ] Draw height restriction areas; the check reads those in the file.

## Schematic

- [ ] Swap and exchange gates.
- [ ] Change a placed symbol's variant (MCP `place_symbol` takes `symbol`).
- [ ] Mark a single pin no-connect (Set all / Clear all exist; one pin is MCP
      `set_no_connect` only).
- [ ] Place a junction on its own.
- [ ] Manage Buses: remove a bus or member, rename members (MCP `remove_bus`
      only).
- [ ] Disconnect a pin (board only in the GUI).
- [ ] Pictures: kept in the file (`Model/HorizontalSchematic.swift:594`) but not
      drawn or importable.
- [ ] Tables.
- [ ] Align and distribute.
- [ ] Back-annotation from the board.
- [ ] Pin display mode in the inspector (MCP `set_symbol_display` only).
- [ ] Off-sheet references toggle in the net label inspector (MCP only).
- [ ] Remap a part to another entity in the GUI (MCP `remap_part` only).
- [ ] iPad schematic rail: Annotate, Place Block and Net Classes
      (`Views/HorizontalIPadProjectView.swift`).

## Pools

- [ ] Create a new pool.
- [ ] Delete a pool item.
- [ ] Edit a pool's included pools (they are only resolved when reading,
      `Model/HorizontalPoolLibrary.swift:646-675`).
- [ ] Contribute changes back to a shared pool: commit, push, pull request.
      Today pools clone and fast-forward pull only (`Model/Git/`).

## Outputs

- [ ] Netlist file export (MCP `netlist` returns JSON only).
- [ ] Stock and ordering columns in the BOM export (stock shows only in the
      Parts pane).

## Tests

- [ ] `RouterRealBoardHarnessTests`' one-second route budget fails whenever
      other builds load the machine (1–2.5 s at load averages of 20 to 160),
      and passes alone. Make the budget hold under load or measure it apart
      from the suite.
- [ ] `SchematicClipboardTests`' Move to Other Sheet tests place by the real
      pointer and fail now and then, in the full suite and alone (a7eac56,
      4f8cea0). Make the placement independent of where the mouse is.
