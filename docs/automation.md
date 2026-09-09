# Automation: dispatch layer, Python package, MCP server

Horizontal's model, exporters, and checks can be driven without the app. One
JSON-RPC entry point, `HorizontalDispatch.call`, serves every headless front
end, and each front end is a thin adapter over it:

| Front end | Where | How it reaches the dispatcher |
|---|---|---|
| `horizontal` command line tool | `Sources/HorizontalCLI` | links `HorizontalNative`, calls it directly |
| `libHorizontalPy.dylib` | `Sources/HorizontalPy` | exports `horizontal_call` / `horizontal_free` (C ABI) |
| `horizontal` Python package | `python/horizontal` | loads the dylib with ctypes, or spawns `horizontal serve` |
| `horizontal-mcp` server | `python/horizontal/mcp_server.py` | the Python package, framed as MCP tools for Claude Code |
| The app | `Sources/HorizontalNative/Dispatch` | the same table, served over authenticated loopback for live state |

The engine is the app's own Swift code. `Sources/HorizontalNative` is a
library target in `Package.swift` (the `@main` App file is excluded and only
the Xcode app target compiles it), so the dispatch code lives inside that
module with internal access to the model, and nothing was duplicated.

## Build

    swift build -c release --product HorizontalPy && swift build -c release --product horizontal
    cd python && uv sync

`make native` does the first line. The Python package finds the dylib in the
checkout's `.build/` (release before debug) or at `HORIZONTAL_DYLIB`.

## Methods

Every request is `{"jsonrpc": "2.0", "id": …, "method": …, "params": {…}}`.
Methods that act on a project take the `handle` that `open_project` returned.
`horizontal methods` prints the live list with parameters.

Native API 2 adds explicit source contexts, snapshot/revision metadata,
guarded edits and recoverable transactions. MCP success results use
`{data, meta}` envelopes; every design edit requires `expected_revision` and
`operation_id`. What this surface does not yet reach is surveyed in
[the completeness plan](mcp-completeness-plan.md).
See [the API 2 and analysis guide](mcp-analysis.md) for migration,
connection diagnostics, typed models, numerical tools and operational limits.

| Method | What it answers |
|---|---|
| `version`, `methods` | API version; the method table |
| `open_project`, `new_project`, `close_project`, `reload_project`, `list_projects` | project handles; opening a path twice returns the same handle; `new_project` writes the template to a path that does not exist yet |
| `save` | writes an open document to its file; a disk context reports `saved: false` because its edits were already written |
| `project_info`, `project_files` | blocks, sheets, counts, diagnostics; files in the captured source |
| `freeze_project`, `analysis_snapshot`, `transaction_status` | immutable read context; electrical evidence; mutation receipt lookup |
| `list_sheets` | sheets in the PDF exporter's page order |
| `list_components`, `get_component` | components with part details; one component with every pin, its net, symbol and board placements |
| `list_nets`, `get_net`, `netlist` | nets with class and flags; one net with its pins, routing counts, and airwire geometry; the whole netlist |
| `bom` | grouped the way the BOM exporter groups |
| `list_symbols` | symbol instances on the sheets: component, gate, placement, and the instance id the schematic ops take |
| `list_net_lines` | the wires on the sheets, with what each end connects — a symbol pin, a junction, a bus ripper or a block port |
| `list_tracks`, `list_vias` | copper, filtered by net or layer; a track end is a pad (naming the component) or a junction. Both wrap their answer in `total`/`truncated`, because a board has thousands |
| `list_net_labels`, `list_power_symbols` | what names a net on a page, with the ids their remove ops take |
| `list_block_instances` | the blocks this block uses, their wired ports, and where each is drawn |
| `autoroute` | best-effort automatic routing of one net's airwires |
| `list_planes`, `list_polygons` | copper pours (and whether each is actually filled) and board polygons; layer 100 is the outline |
| `board_rules` | the design rules as data, the net classes they select, and the stackup |
| `get_pool_item` | one pool item's own JSON — the bytes `pool_write` takes back |
| `pour_planes` | fills every plane, as Update All Planes does |
| `list_texts` | free text on the schematic sheets, with the ids the text ops take |
| `list_parts` | parts the project can use; `scope` widens it from the project pool to the pools it draws from |
| `search_pool` | search those pools by name, description, manufacturer, tag or uuid, filtered by item kind |
| `import_pool_part` | copy a part and its whole dependency chain from a base pool into the project pool cache |
| `board_info` | bounds, stackup, drawing layers, object counts |
| `recompute_connectivity` | the editor's post-edit connectivity pass, in memory |
| `check` | see below |
| `export` | the app's exporters into a directory outside the project |
| `render_sheet`, `render_board` | PNG, base64 or written to a path, via the PDF exporters and Core Graphics; `region` renders part of a sheet or board |
| `list_groups` | Horizon groups (sub-circuit instances) with members by tag and placement |
| `zoom_to`, `render_viewport` | Live channel: frame a component or net in a pane; render what a pane shows |

Coordinates come back in millimetres; angles in degrees (Horizon stores
1/65536 turns).

Two identities are easy to confuse, so both are spelled out. A symbol on a
sheet is `symbol_instance`; `symbol_id` in a component's symbol list is the
same value under the name it shipped with, and analysis evidence still uses
that one. A package on the board is `package_instance` — the key a track's
`pad` endpoint names — while `package_id` is the pool package it draws.

Every write has a read that names what it wrote. `list_symbols`,
`list_net_lines` and `list_texts` cover the schematic ops; `list_tracks` and
`list_vias` cover copper no op writes yet. A write without its read is a
write-only surface: an agent could create a thing and never find it again. Pin names resolve from the placed symbols, and from the
project pool's units for gates without a symbol on any sheet.

### Connectivity on open

The loader's rats' nest is a first pass. The editor re-derives track and via
nets from pad connectivity after every edit and regenerates airwires from
that, and the two can disagree: on Sherlock the loader reports 628 airwires,
the editor pass 450. `open_project` runs the editor pass so headless answers
match what the app shows after any edit.

Poured plane copper counts: a pad or via of the plane's net inside one of
its fragments on that layer is joined to everything else in that fragment,
so a ground pad under a ground fill has no airwire. What remains on a plane
net is a pad the fill does not reach or an unpoured plane; `check` reports
those as informational and anything on a net without a plane as a warning.

### What `check` covers

Load diagnostics, the rules editor's structural validation of the board
rules, unannotated and duplicate reference designators, components without a
part, single-pin and pinless nets, gates with no symbol on any sheet, packages
not placed, and unrouted connections. There is no geometric design rule check
in Horizontal yet, so none here either.

## Edits

`apply` takes operations as data and writes only the files they touched, in
Horizon's own formatting so a change diffs as the lines it changed. `list_ops`
returns the vocabulary with parameters. Components may be named by reference
designator or id, nets by name or id, pins by name (`EN`), by gate and pin
(`Main/EN`), or by ids.

| Op | Effect |
|---|---|
| `ensure_component` | Create a block component from a pool part or entity, returning its id; idempotent by id or refdes |
| `remove_component` | Remove the component, its symbols and the net lines on them, its board package, and turn tracks that ended on its pads into junction-ended tracks |
| `set_value`, `set_refdes`, `set_part`, `set_no_populate` | Component fields; a part swap that changes the entity clears the connections |
| `set_group_tag` | Horizon's group and tag, the fields it uses to copy placement between identical sub-circuits; ids derive from the names |
| `ensure_net`, `rename_net`, `set_net_class`, `retire_net` | Nets; retiring drops the connections and power symbols on it |
| `connect`, `disconnect` | Pin connections; `create_net` makes the net when it is missing |
| `place_symbol`, `remove_symbol` | Schematic placement: draw a gate on a sheet with the symbol for its unit, move it, or take it off with the net lines that ended on it |
| `draw_net_line` | The wire between two pins the block already ties to one net; it records that connection rather than making one, and refuses pins on different nets |
| `place_power_symbol`, `remove_power_symbol` | The ground or supply marker that says a point is on that net. Placing one marks the net as a power net, because that is what it means; the shape (`gnd`, `dot`, `antenna`, `earth`) belongs to the net, so every symbol on it matches |
| `place_net_label`, `remove_net_label` | Names a net on the page — and, placed on more than one sheet, is how a net spans pages |
| `add_sheet`, `rename_sheet`, `remove_sheet` | Pages. A sheet with anything drawn on it is refused rather than deleted quietly, and a schematic keeps at least one |
| `place_text`, `remove_text` | Free text on a sheet: write one, or change the text, position, rotation, size, origin or font of one `list_texts` named. A text Horizon extracted from a symbol with Smash belongs to that symbol and is refused |
| `place_component`, `remove_placement` | Board placement in millimetres and degrees; a placed package moves, an unplaced one gets a package entry the loader completes from the part |
| `place_track`, `remove_track`, `set_track_width` | One straight copper segment per op, between pads, junctions or points; a point becomes a junction, and a junction nothing holds any more is removed with the copper that held it |
| `place_polygon`, `remove_polygon` | A closed polygon on a board layer. Layer 100 is the outline — the shape the board is cut to, and a board without one has no shape however complete it otherwise looks |
| `place_plane`, `remove_plane` | A copper pour: a polygon on a copper layer, filled with one net. Defining it does not fill it; `pour_planes` does, and drops fill that reaches nothing on its net |
| `add_block_instance`, `remove_block_instance`, `connect_block_port` | Using one block inside another, and wiring its ports to nets here |
| `place_block_symbol`, `remove_block_symbol` | Drawing a block instance on a sheet, with the symbol that block defines for itself |
| `set_stackup` | How many inner copper layers the board has, and the copper and dielectric thicknesses |
| `add_net_class`, `rename_net_class` | Net classes. Their electrical parameters live in the board rules, not here |
| `place_via`, `remove_via` | A via on a net at a point, sharing the junction with any copper already there. Its padstack defaults to what the board's other vias use |
| `copy_group_layout` | Lay one group out like another: every member with a matching tag gets the same relative placement and rotation around an anchor, and the tracks, junctions and vias inside the source group are cloned onto the target's pads |

### A live edit is not saved until it is saved

An edit against a document the app has open becomes one undoable step in that
document and nothing more: the result says `durability: "unsaved_document"`
and means it. `save` writes it, `project_info` reports `unsaved_changes`, and
a task that edits a live document is not finished without one. A disk edit
needs none of this — it committed with its transaction — and `save` says so
rather than failing.

Saving goes through the document system rather than around it: SwiftUI's
`DocumentGroup` offers no API for it, so the document is found by URL through
`NSDocumentController` and written with `writeSafely`, which keeps the
read-only guard, the write notification the pool editors listen for, and the
edited flag all behaving as they do when the user presses Save. Targeting by
URL rather than sending the Save action matters: an automation client is never
the key window.

Two things had to be right for that to work at all. An edit arriving through
the live channel registers its undo with whichever undo manager the view can
reach, and when the app is not frontmost — which is every automation edit —
that is a fallback manager the document system knows nothing about. So the
document was never marked as changed: Save stayed disabled, closing the window
offered no prompt, and `save` wrote nothing while reporting that there was
nothing to write. `applyLiveArchive` now tells the document directly.

And `save` no longer trusts that flag. After saving it captures the file's
snapshot and compares it with the document's; a mismatch is an error naming
both, not a success. The reply's `source` says which context answered — `live`
saved a document, `disk` means the context asked was a disk one whose edits
were already committed, which is the answer to give when the edit went
somewhere else.

A batch is validated and applied in memory first; a failing operation writes
nothing. `dry_run` returns normalized operations, changed-file previews and a
plan digest. Disk commits journal all file replacements and recover interrupted
batches; live commits install one undoable archive. Pool items and operations
can share the same batch. The complete staged project is loaded before commit.

Routing here is manual. `place_track` draws the segment it is told to draw; it
does not find a path, and nothing on this surface autoroutes. An agent routes
by reading the airwires from `get_net` and placing the segments itself, and
`check` reports what is still unrouted. Arcs are the app's alone — every track
placed here is straight.

Two refusals are worth knowing about. A track joins its ends, so ends on
different nets would tie those nets together: that is refused rather than
written, and an explicit `net` that disagrees with the ends is refused too.
And nothing guesses a width: `width_mm` may be left out only when the board
states a `track_width` rule covering that net's class on that layer, in which
case the change says `width_from: "track_width rule"`. A board with no such
rule insists on an explicit width rather than inventing a plausible one.

On the schematic the ops cover components, wires, free text, net labels, power
symbols and the sheets themselves; buses, bus rippers, net ties, block symbols,
title block values and a sheet's drawn lines, arcs and pictures are still the
app's alone.

Net labels and power symbols both sit on a junction, and both share one with
anything already at that point rather than stacking. Removing either takes the
junction with it when nothing else needs it — the same rule the copper ops
follow.

Three things to know. Horizon shows a part's own value over the component's,
so `set_value` on a part-backed component records a note saying so. A
component created through the netlist alone is drawn on no sheet, which
`place_symbol` fixes and `check` reports until it is. And a project an editor
has open cannot be edited on disk: see below.

### One block at a time

`apply` edits one block: the top one unless `block` names another, and the
result says which. Blocks are named by their file, the way `list_sheets`
reports them. A sub-block has no board — its components are instantiated
wherever that block is used, so there is no single package to place for them —
so its board file is not even loaded and every board operation on one fails
saying why.

The two halves disagree on scope, deliberately: **writes are scoped to one
block, reads are not.** `list_nets` and `list_components` report the whole
project, so an edit made in a sub-block is visible in a read that names no
block at all. `written` in the result says which file actually changed.

`add_block_instance` uses one block inside another, `connect_block_port` wires
its ports to nets here, and `place_block_symbol` draws it — using the symbol
that block defines for itself, so a block with no `symbol_filename` cannot be
drawn and says so rather than inventing a shape.

### Routing is manual, and autoroute is honest about it

`autoroute` tries a net's airwires on one layer. It walks around one obstacle
at a time and gives up after trying both ways past each, so on a dense board it
completes a few percent and reports the rest — the harness in
`RouterRealBoardHarnessTests` measures exactly this and prints the numbers to
`/tmp/router-harness.txt`. What it does write has been checked clear of the
board's clearances; what it cannot route stays an airwire, is listed in
`unrouted` with what blocked it, and `place_track` draws those by hand.

### Who has the project open

The app does not reload files that change under an open document, so a disk
write while it holds a project loses one edit or the other. The live channel
cannot answer whether it does — that channel is off until the user turns it
on, and its absence proves nothing. So every process that opens a document
writes a record in the project's transaction directory and holds an advisory
lock on it for as long as the document is open. `project_info` reports them as
`held_by`, with `editable` false, and a disk `apply` refuses with
`DOCUMENT_OPEN` naming the holder; a `dry_run` plans anyway and reports the
holder in `blocked_by`. Liveness needs no process table: a record another
process can lock belonged to one that has exited, and is deleted on sight.

The transaction directory sits beside the project and keeps its lock and
receipts for good, so it writes a `.gitignore` of `*` into itself — a project
in a git working tree does not have to know it is there.

## Live channel

While a document is open, Horizontal serves the same dispatcher over a
loopback socket. `~/Library/Application Support/Horizontal/live.json`
(inside the sandbox container when the build is sandboxed) names the
ephemeral port and a per-launch token; the file is mode 0600, the listener
binds to 127.0.0.1 only, and every request line carries `"auth": <token>`.
The Python package and the MCP server look for that file first, so opening a
project the app holds returns the app's document: reads see unsaved edits,
`select` and `highlight` change what the canvases show, and `apply` lands as
one undoable step named for the edit. `live_state` reports the channel's status and, when it answers, the open
documents with their selection; given a project path it also reports that
project's `held_by` and looks beside the project for the endpoint. An
unavailable channel without a path means the app is not running, has no
document open, or has the channel switched off, and it cannot say which.
`held_by` is the answer that does not depend on the channel at all.

The channel is off until it is turned on: Settings > Automation > Enable MCP
Server, stored as `HorizontalLiveServerEnabled` in the app's defaults. With it
on the listener starts with the first document and stops with the last, and
the switch takes effect at once rather than at the next open or close. With it
off there is no way in: disk writes are refused while the app holds the
project, which is the point.

### Finding the channel from outside the container

`live.json` is the app's own copy, and a sandboxed build writes it inside
`~/Library/Containers/com.twarge.app.horizontal/…`, which macOS refuses to
every other process — reading it returns `Operation not permitted` regardless
of file mode. A client that only had that path could never reach a sandboxed
app.

So the listener also publishes itself in each open project's holder record,
beside the project: `{"host", "port", "token"}`, rewritten when the channel
starts and cleared when it stops. A client that can read the project can read
that, which is the same authority it already needed. `find_live_for(project)`
tries the discovery files first and falls back to the records; `open_project`
with `source="live"` uses it, and `live_state` takes an optional project path
for the same reason.

The token is therefore at rest beside the project, in a file this process
writes mode 0600 — the same protection `live.json` has, in a place a client
can actually read. Anyone who can read that file as the owning user can drive
automation on whatever documents the app has open, so a project directory
shared with another user, or synced somewhere with looser permissions, widens
who can do that. Holder records are named `*.lock` and `*.json` under
`.horizontal-transactions/<digest>/holders/`, and the directory ignores itself
in git.

An edit through the channel runs the same ops over the document's in-memory
archive, then the workspace reloads its model from that archive, points the
model's URLs back at the real project, and pushes the previous archive and
model onto the undo stack.

`zoom_to` frames a component or net: on the board, the package's pads or
everything on the net; on the schematic, the symbol's sheet, switching the
navigator to it first. The canvases expose their visible world rectangle and
a frame request through their command actions, and `CanvasViewport.framing`
computes the zoom and pan. `render_viewport` renders that visible rectangle
through the drawing exporters, cropped to the region, so it is the exporter's
style rather than a screenshot of the Metal canvas.

## Python

    import horizontal
    project = horizontal.open("~/Repositories/sherlock/Sherlock Horizon/Sherlock.hprj")
    project.component("U3")["pins"]
    project.net("Sync PPS")
    project.check()["counts"]
    project.export(["bom", "gerber"], target_directory="/tmp/sherlock-out")
    png = project.render_sheet(name="ADC", dpi=150)
    project.apply([
        {"op": "ensure_net", "name": "P1V8"},
        {"op": "connect", "component": "U3", "pin": "PA1", "net": "P1V8"},
    ])
    project.place("R14", x_mm=12.5, y_mm=4, angle_deg=90)

`horizontal.Session(isolated=True)` runs the engine in a `horizontal serve`
subprocess instead of in-process, for untrusted inputs or when a crash must
not take the interpreter down. Both transports speak the same JSON-RPC.

## MCP

`.mcp.json` at the repository root launches `uv run --project python
horizontal-mcp` for Claude Code. Each tool takes the project path; setting
`HORIZONTAL_PROJECT` makes it optional, which is what the Sherlock repository's
`.mcp.json` does. To register the server for every project instead:

    claude mcp add --scope user horizontal -- uv run --project ~/Repositories/horizontal/python horizontal-mcp

## atopile

`horizontal-ato sync <board.kicad_pcb> <project> [--create] [--dry-run]
[--sync-positions]` brings an atopile build into a project. atopile writes
its design to a KiCad board file whose footprints carry `atopile_address`,
the picked part (LCSC id, manufacturer, part number, value, datasheet), and
pads with nets; that file is the seam, read with a small s-expression parser
rather than atopile's internals, which are not a public API (and whose CLI is
in maintenance mode as of 0.15).

Each distinct footprint becomes a unit (a pin per pad name), an entity with
a Main gate, a box symbol, a package with the pads, silkscreen, courtyard,
and refdes texts, and padstacks with explicit shapes for the pad geometry;
each picked part becomes a Horizon part with the pad map. Ids are UUIDv5
from the design (address, footprint geometry, LCSC id), so the same input
yields the same ids every run and a re-sync is a no-op.

Nets are matched to the project's nets by the pads on them (Jaccard over
component-pin pairs, at least half), so a net atopile renamed keeps its id
and its tracks and is renamed; unmatched nets are created; nets only used by
removed components are retired. Components are created from the part with
the module path as Horizon group and the leaf name as tag, placed where the
board file has them (existing ones keep their placement unless
`--sync-positions`), and connected pin by pin; components this tool made
that the design no longer has are removed. After applying, the pad-to-net
map is read back and compared with the design; any mismatch fails the run.

The sync runs headless or against the document open in Horizontal, where
the pool items and the edits land together as one undoable step.

Module layouts transfer through Horizon's groups. Lay one instance out, then
`horizontal-ato copy-layout project --from usb_c[0] --to usb_c[1]` (or
`copy_group_layout` from Python or MCP) gives the other instance the same
placement and routing, anchored where its first member already sits or at
an explicit position and rotation. `horizontal-ato groups` lists the
instances and what is placed.

## Tests

`Tests/HorizontalNativeTests/HorizontalDispatchTests.swift` drives the
dispatcher through JSON text against the new-document template: error codes,
the method table, project summary, checks, renders, and export path rules.

## What comes next

1. **Track and drawing ops.** The vocabulary covers the netlist, package
   placement, and group layout copy; freehand copper, planes, and schematic
   drawing edits still go through the app.
2. **A true canvas capture** for `render_viewport`, which today renders the
   visible region in the exporter's style rather than the Metal canvas.
3. **atopile follow-ups**: 3D models and rounded-rectangle pad shapes in
   generated packages, and a PCB backend proposal upstream once the bridge
   has seen real projects.
