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
container for sandboxed builds); pass `prefer_live=False` to bypass it.

The MCP server:

    uv run horizontal-mcp

is what `.mcp.json` at the repository root launches for Claude Code. Set
`HORIZONTAL_PROJECT` to make the `path` argument of every tool optional.
