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
