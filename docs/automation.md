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
`operation_id`. See [the API 2 and analysis guide](mcp-analysis.md) for migration,
connection diagnostics, typed models, numerical tools and operational limits.

| Method | What it answers |
|---|---|
| `version`, `methods` | API version; the method table |
| `open_project`, `close_project`, `reload_project`, `list_projects` | project handles; opening a path twice returns the same handle |
| `project_info`, `project_files` | blocks, sheets, counts, diagnostics; files in the captured source |
| `freeze_project`, `analysis_snapshot`, `transaction_status` | immutable read context; electrical evidence; mutation receipt lookup |
| `list_sheets` | sheets in the PDF exporter's page order |
| `list_components`, `get_component` | components with part details; one component with every pin, its net, symbol and board placements |
| `list_nets`, `get_net`, `netlist` | nets with class and flags; one net with its pins, routing counts, and airwire geometry; the whole netlist |
| `bom` | grouped the way the BOM exporter groups |
| `list_parts` | the project pool's parts |
| `board_info` | bounds, stackup, drawing layers, object counts |
| `recompute_connectivity` | the editor's post-edit connectivity pass, in memory |
| `check` | see below |
| `export` | the app's exporters into a directory outside the project |
| `render_sheet`, `render_board` | PNG, base64 or written to a path, via the PDF exporters and Core Graphics; `region` renders part of a sheet or board |
| `list_groups` | Horizon groups (sub-circuit instances) with members by tag and placement |
| `zoom_to`, `render_viewport` | Live channel: frame a component or net in a pane; render what a pane shows |

Coordinates come back in millimetres; angles in degrees (Horizon stores
1/65536 turns). Pin names resolve from the placed symbols, and from the
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
part, single-pin and pinless nets, packages not placed, and unrouted
connections. There is no geometric design rule check in Horizontal yet, so
none here either.

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
| `place_component`, `remove_placement` | Board placement in millimetres and degrees; a placed package moves, an unplaced one gets a package entry the loader completes from the part |
| `copy_group_layout` | Lay one group out like another: every member with a matching tag gets the same relative placement and rotation around an anchor, and the tracks, junctions and vias inside the source group are cloned onto the target's pads |

A batch is validated and applied in memory first; a failing operation writes
nothing. `dry_run` returns normalized operations, changed-file previews and a
plan digest. Disk commits journal all file replacements and recover interrupted
batches; live commits install one undoable archive. Pool items and operations
can share the same batch. The complete staged project is loaded before commit.

Two things to know. Horizon shows a part's own value over the component's,
so `set_value` on a part-backed component records a note saying so. And the
app does not reload files that change under an open document, so headless
writes are for projects the app is not holding; the live channel is the path
for edits while it is.

## Live channel

While a document is open, Horizontal serves the same dispatcher over a
loopback socket. `~/Library/Application Support/Horizontal/live.json`
(inside the sandbox container when the build is sandboxed) names the
ephemeral port and a per-launch token; the file is mode 0600, the listener
binds to 127.0.0.1 only, and every request line carries `"auth": <token>`.
The Python package and the MCP server look for that file first, so opening a
project the app holds returns the app's document: reads see unsaved edits,
`select` and `highlight` change what the canvases show, and `apply` lands as
one undoable step named for the edit. `live_state` lists the open documents
with their selection.

The channel is off until it is turned on: Settings > Automation > Enable MCP
Server, stored as `HorizontalLiveServerEnabled` in the app's defaults. With
it off the Python package and the MCP server still read and write project
files on disk, but cannot reach a document the app is holding. With it on the
listener starts with the first document and stops with the last, and the
switch takes effect at once rather than at the next open or close.

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
