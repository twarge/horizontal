# To do

## Differential pairs and length tuning

- [ ] Tune arcs and tracks at odd angles; Tune Track takes only straight
      tracks in the eight routing directions.
- [ ] Pair member offsetting in whole nanometres (study step 5).
- [ ] Coupled diff-pair routing: the fat-centreline route at the rule's width
      and gap, with uncoupled fan-out gates (step 6), and via pairs at the
      rule's via gap (step 7).
- [ ] Diff-pair tuning and skew tuning (step 8).

## Routing

- [ ] Push and shove (steps 4–7 of `docs/push-shove-router.md`).
- [ ] Highlight what blocks a route; the finder already names the obstacle.
- [ ] Drag a track keeping its 45° slopes, and drag a via.
- [ ] Move a track's connection point; move an arc track's centre.
- [ ] Lock and unlock tracks and vias, and Unlock All. `locked` is read now,
      and block layout sync leaves locked copper alone, but nothing sets it.
- [ ] Place a standalone via (stitching) and set a via's net. Both are MCP-only
      or missing; the inspector shows the net read-only.

## Board tools

Available only as MCP ops so far:

- [ ] Groups and tags: set, rename, clear and highlight them (`set_group_tag`).
      A block instance can be selected whole (Select Instance, 88401a5).
- [ ] Copy placement and tracks between groups that aren't block instances,
      such as atopile's (`copy_group_layout`).

Not built at all:

- [ ] Pictures on the board: not modelled or drawn.
- [ ] Draw a net tie on the board.
- [ ] Draw connection lines, and back-annotate them to the schematic.
- [ ] Align and distribute.
- [ ] Swap placement, paste placement.
- [ ] Scale, and Move by keyboard (both disabled "to do" entries in the board's
      right-click menu).
- [ ] Rotate and mirror dimensions and decals; they can only be moved.
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
- [ ] Pictures: kept in the file (`Model/Schematic/HorizontalSchematic.swift:594`) but not
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
      `Model/Pool/HorizontalPoolLibrary.swift:646-675`).
- [ ] Contribute changes back to a shared pool: commit, push, pull request.
      Today pools clone and fast-forward pull only (`Model/Git/`).

## 
