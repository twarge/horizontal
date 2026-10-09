# horizontal (Python)

Python bindings and an MCP server for Horizontal. The engine is the app's own
Swift model, exposed through one JSON-RPC dispatch call.

Build the native pieces once in the checkout:

    swift build -c release --product HorizontalPy && swift build -c release --product horizontal

Then, from this directory:

    uv run python -c 'import horizontal; p = horizontal.open("~/Repositories/sherlock/Sherlock Horizon/Sherlock.hprj"); print(p.title, len(p.nets()))'

The package finds `libHorizontalPy.dylib` in the checkout's `.build/` (release
first, then debug), or wherever `HORIZONTAL_DYLIB` points. `isolated=True`
runs `horizontal serve` in a subprocess instead.

When Horizontal has the project open, `horizontal.open` returns the app's
live document instead: reads see unsaved edits, `project.highlight(...)` and
`project.select(...)` drive the canvases, and `project.apply(...)` lands as
one undoable step. The app advertises its loopback port and token in
`~/Library/Application Support/Horizontal/live.json` (inside the sandbox
container for sandboxed builds). Use `source="live"` or `source="disk"` to
select explicitly. The default, `source="auto"`, chooses once when opened;
later calls keep that source. `prefer_live=False` remains a Python alias for
disk selection.

The MCP server:

    uv run horizontal-mcp

is what `.mcp.json` at the repository root launches for Claude Code. Set
`HORIZONTAL_PROJECT` to make the `path` argument of every tool optional.

Version 0.2 requires native API 2. Rebuild both native products and the app,
then restart the MCP client connection. MCP uses an isolated native worker by
default; `HORIZONTAL_ISOLATED=0` opts into ctypes without hard cancellation.
`connection_status` reports selected binaries and their SHA-256 fingerprints,
API compatibility, live discovery/authentication, and open contexts.

MCP results now have `data` and `meta` fields. Retain `project_ref` and the
`revision` from the read you used to decide an edit. All MCP design edits
require that `expected_revision` and a unique `operation_id`; a timeout must
be resolved through `transaction_status`, not a blind repeat. Python returns
plain data and exposes the envelope metadata as `project.last_metadata`.

`analysis_snapshot`, `validate_analysis`, and the four `analyze_*` tools work
from pinned schematic evidence. Analyses run in bounded subprocess jobs and
can export plots, numerical data, model assumptions, schematic crops and a
replayable request. See [API 2 and analysis](../docs/mcp-analysis.md) for the
workflow, supported models, and recovery guarantees.

# MCP edit contracts

Live commits update the open document and remain unsaved until `save`. Its
`verified: true` response checks that disk matches the document snapshot; it
does not establish that a canvas frame has been presented.
Use `source="live"` when an edit must reach the open window; automatic source
selection can fall back to disk if the live document cannot be discovered.
The sandboxed app needs access to the containing project folder to publish its
live connection record (see [live discovery](../docs/automation.md#finding-the-channel-from-outside-the-container)).

Dry runs return `status: "preview"`, `written: []`, and `would_write` paths.
`applied` is the legacy count of staged changes in a preview. Feed
`normalized_ops` back unchanged with `before_revision` as `expected_revision`
and the returned `plan_digest`; boolean fields remain JSON booleans. A commit
returns `status: "committed"` and `durability: "disk"` or
`"unsaved_document"`, or `"unchanged"` when the batch left every file as it
was. Use a fresh `operation_id` for the commit.

MCP edit replies are compact unless the tool is called with `verbose: true`:
each change keeps its ids, scalars and counts, and the echoed operations, file
previews and project summary are left out. A dry run keeps `normalized_ops`,
since those are what get replayed. `timing` gives the milliseconds spent
editing, loading the staged project, comparing diagnostics, and committing.

Mutations get `HORIZONTAL_MUTATION_TIMEOUT` seconds (default 180) rather than
the 30 a read gets. When a mutation's reply is lost anyway, the client reopens
the connection — through the holder record beside the project, as discovery
does — and asks `transaction_status` for that `operation_id` before
returning. The engine answers one request at a time, so that question waits for
the mutation to finish. A committed receipt is returned as the result; a
failure is raised with `outcome: "not_committed"` and is safe to resend. A
connection lost by an earlier call is reopened before the next one is sent, so
a timeout does not strand the `project_ref`.

`connection_status` names the server — PID, start time, package version and
commit — and says `stale` with the files when its code changed after it
started; the live engine's op list is compared with the server's schema. A
"reconnect" in the client may keep the old process, so these, and the
`warnings` `open_project` returns, are how a stale server shows itself. The
`apply_ops` description carries the schema digest the engine's `version`
reports as `ops_digest`. Opening a document that already has a context
returns that context and its `project_ref`.

Reads are summaries by default. `list_components` leaves out package pads
(`include_terminals`). `get_component` lists only a large part's connected and
no-connect pins (`all_pins` for every one), narrows with `pins`, `pin_regex` and
`connected`, and `group_pins` summarises supply and ground pins by net.
`list_net_lines` gives one-line ends ("U8.PA13", "junction:<id>") and
`[x, y]` points; the mark lists drop repeated sheet and net uuids. `verbose`
returns the full rows. `find_dangling` and `find_overlaps` answer the usual
questions about the wiring without reading it all.

`board_info.drawing_layers` lists the renderable layer IDs and names for that
project. `render_board` accepts either `layers=["Top Copper"]` (using the
actual advertised names) or `layer_ids=[0]`, never both. Omitted or empty
selectors use exporter defaults. Invalid choices return `valid_layers` in the
structured error. `list_tracks` and its net filter use resolved connectivity,
including original tracks with no stored net field; a null net means the
model could not assign a unique net.

Schematic editing supports:

- `list_junctions`: IDs, sheet IDs, positions, and resolved nets. Junction and
  wire queries derive nets from connected pins and labels when native Horizon
  files omit cached net fields. Floating or conflicting segments return null;
  coincident coordinates do not join separate junctions.
- `place_junction`: `{op, id?, sheet?, net, x_mm, y_mm}`. Coincident junctions
  are reused on the same net, and a coincident junction with no net takes this
  one. Supply an ID when another operation in the same batch needs to refer to it.
- `draw_net_line`: `{op, id?, sheet?, from, to}`. Each endpoint is
  `{kind: "pin", symbol: "symbol-instance-uuid", pin: "pin name or uuid"}`,
  `{kind: "pin", component: "U8", gate?: "Main", pin: "PA13(JTMS/SWDIO)"}`, or
  `{kind: "junction", junction: "junction-uuid"}`. Both ends must be on the
  same sheet and logical net; a junction with no net takes the other end's.
  The older `component`, `pin`, `to_component`, `to_pin` form remains
  supported; do not mix forms. Use `connect` first to establish a pin's block
  connection — the error says whether a pin is unknown, on no net, or marked
  no-connect. `list_symbols` provides instance IDs; `place_symbol` takes an
  `id` so one batch can place and wire a symbol.
- `remove_net_line {line}`, `remove_junction {junction, cascade?}` and
  `prune_sheet {sheet?}` delete drawing: a junction goes with its wires,
  labels and power symbols, and junctions left holding nothing are collected.
  `remove_sheet {sheet, force: true}` clears a page outright.
- `terminate_pin {component, pin, net?, kind?, length_mm?}` draws a stub out of
  a pin, in the direction it points after the symbol's rotation and mirror,
  ending in a label or power symbol facing away from it.
- `set_no_connect {component, pin | pins | all, gate?, no_connect?, disconnect?}` (`all`: every pin on no net,
  or every NC mark when clearing — Horizon's Set all unconnected pins NC / Clear all NC pins) and
  `set_symbol_display {component | symbol_instance, pin_display_mode?, display_all_pads?}`.
- `set_pin_alternate {component, pin, alternate | assignments, use_primary_name?, custom_name?, custom_direction?}`
  picks a pin's function from the alternates its unit offers. `alternate` is a
  name (whole, or one "/" part of it when that is unique: `SPI1_SCK` finds
  `SPI1_SCK/I2S1_CK`), a uuid, a list, or null for the primary name;
  `assignments` maps many pins at once. `get_component(alternates=true)` lists
  the choices, and a pin with one chosen gives `selected` and `display_name`.
- `set_net_line_endpoint`: `{op, line, end: "from" | "to", endpoint, sheet?}`
  preserves the existing wire ID and net. Both ends must resolve to pins or
  junctions whose current logical nets agree with the wire.
- `remap_part`: `{op, component, part, pin_map?, symbols?, pad_map?}`. `part`
  must be imported. `pin_map` maps explicit old `gateUUID/pinUUID` paths to
  target paths; pins it leaves out are matched by gate and pin name, and
  pins sharing a name (VSS) pair up in a stable order. Together they must cover
  every connected or wired pin, or the error names the ones left over. `symbols` selects a
  pool symbol for each target gate if its unit has several choices. Drawn
  gates map one-to-one. Routed pad references follow the logical mapping;
  use `pad_map` (old pad UUID to target pad UUID) when more than one target
  pad maps to a pin. It must agree with `pin_map`. Unmapped connected pins or
  routed pads reject the whole transaction. The operation preserves symbol,
  wire, track and package instance IDs and placement, while changing the
  component's part/entity and endpoints. Pool/library items remain unchanged.

These operations work inside `apply_ops` (Python: `Project.apply`) and share
its revision checks, dry run, transaction, and single live undo step. A new
pin can be connected and drawn in the same batch after `remap_part`.
