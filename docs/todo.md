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
- [ ] Move a track's connection point; move an arc track's centre.
- [ ] Drag (D) takes one track at a time, where Horizon drags every selected
      track that can; no iPad button for it.
- [ ] Locked copper: draw it marked; have the automation ops (`remove_track`,
      `remove_via`, moves) refuse it; a package moved with a locked track on
      its pad still stretches the track.

## Board tools

- [ ] Pictures on the board: not modelled or drawn.
- [ ] Draw a net tie on the board.
- [ ] Draw connection lines, and back-annotate them to the schematic.
- [ ] Swap placement, paste placement.
- [ ] Scale, and Move by keyboard (both disabled "to do" entries in the board's
      right-click menu).
- [ ] Rotate and mirror dimensions and decals; they can only be moved.
- [ ] Highlight a net class.
- [ ] Panels and included boards: they load and draw, but can't be moved,
      placed or managed.
- [ ] Import DXF onto the board; it exists only in the package and decal
      editors.
- [ ] Lines to Tracks.
- [ ] Swap Nets.
- [ ] Draw height restriction areas; the check reads those in the file.
- [ ] Groups and tags on the iPad; the popover is on the Mac's board rail only.
- [ ] Keys for Align, Distribute, Measure Distance and the selection filter.

## Schematic

- [ ] Swap and exchange gates.
- [ ] Place a junction on its own.
- [ ] Disconnect a pin (board only in the GUI).
- [ ] Pictures: kept in the file (`Model/Schematic/HorizontalSchematic.swift:594`) but not
      drawn or importable.
- [ ] Tables.
- [ ] Align and distribute.
- [ ] Back-annotation from the board.
- [ ] iPad schematic rail: Annotate, Place Block and Net Classes
      (`Views/HorizontalIPadProjectView.swift`).

## Pools

- [ ] Edit a pool's included pools (they are only resolved when reading,
      `Model/Pool/HorizontalPoolLibrary.swift:646-675`).
- [ ] Deleting a pool item checks the pools for its users, not the open
      projects; Horizon's "delete dependents as well" is not offered.
- [ ] Contribute changes back to a shared pool: commit, push, pull request.
      Today pools clone and fast-forward pull only (`Model/Git/`).
