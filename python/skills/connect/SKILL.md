---
name: connect
description: Set up or connect Codex or Claude Code to Horizontal and diagnose its MCP connection. Use for plugin onboarding, connecting to an open board or project, missing Horizontal tools, unavailable live state, or DOCUMENT_OPEN, AUTH_FAILED and TIMEOUT errors.
---

# Connect to Horizontal

The horizontal MCP server reads and edits Horizon EDA projects (`.hprj`, `.horizontal`) through Horizontal's own model. It reaches a project one of two ways:

- **live**: the document open in the Horizontal app, over the app's loopback channel. Reads see unsaved edits, `select`, `highlight` and `zoom_to` drive the canvases, and every `apply_ops` lands as one undoable step that the document autosaves, as the app does for any edit. `save` writes now and verifies, for the moment before a commit or an export.
- **disk**: the project's files, through the native engine in a worker process. Edits write files directly, and are refused with `DOCUMENT_OPEN` while the app holds the project, because the app would overwrite them.

Work live whenever the user has the project open. Confirm it before editing.

## 1. Are the tools there?

For plugin onboarding, establish a live connection to the user's project and
report the project title and selected source. Setup is complete only after a
read succeeds; do not edit the design as part of setup.

If no `horizontal` tools are available, check that the plugin is installed and
enabled in the current client, then check whether its server started. Adding a
repository folder alone does not register the server.

- The plugin runs the server with `uv`. Check whether it is installed before recommending `brew install uv`. A desktop client may need to be restarted after installation to pick up its updated environment.
- **Codex:** install with `codex plugin marketplace add twarge/horizontal`, then `codex plugin add horizontal@twarge`. Start a new chat. `codex mcp list` shows manual server entries; inspect them for an old checkout path before changing anything. `codex mcp remove horizontal` removes a manual entry when the user wants to replace it with the plugin. The plugin bundles both the server and these skills; do not add a second manual server during onboarding.
- **Claude Code:** install with `claude plugin marketplace add twarge/horizontal`, then `claude plugin install horizontal@twarge`. Start a new session. A user-scope or project-scope server named `horizontal` overrides the plugin's (local > project > user > plugin). `claude mcp list` shows which one is in use. A stale user-scope entry is removed with `claude mcp remove horizontal -s user` when the user wants to replace it.

Both launchers request Python 3.13; uv downloads it if needed. The first start
also installs locked dependencies and may outlast a client's connection timeout.
For Codex, `codex mcp list --json` reports the resolved command, arguments, working
directory and environment. If tools are still missing after installation, use
that configuration to finish dependency setup: run the same uv command and
environment, replacing the final `horizontal-mcp` argument with
`python -c "pass"`. Report any installation error, then restart the connection
or start a new chat after successful setup. Do not change the user's Python or
install dependencies into the plugin's source folder.

## 2. Which app is answering?

Call `connection_status`. It reports discovery, authentication, engine versions and which app bundle answered, with no project open. An installed copy and an Xcode build (`DerivedData/…/Horizontal.app`) are told apart by `bundle`. A warning that the server's op schema differs from the engine's means one of them is out of date: say so before editing.

## 3. Reach the user's document

1. Use the project path supplied by the user, a matching `.hprj` or `.horizontal` in the working folder, or a document listed by `live_state`. If only a board name is known and discovery lists no matching document, ask for its project location. Call `live_state` with that path. Without a path, "unavailable" proves nothing: the sandboxed app's discovery file is unreadable from outside its container, so the project's own holder records are often the only way in. Do not request access to the private app container to work around that.
2. If it is still unavailable, ask the user to check, in order:
   - a document is open in Horizontal;
   - **Settings > MCP Server > Enable MCP Server** is on (the channel is off until it is turned on; older versions label the section Automation);
   - the app has access to the project's *containing folder*, so it can publish its endpoint beside the project. Opening only a `.horizontal` package may not grant that; the app's Grant Access action does.
3. Call `open_project` with `source: "live"` and read `data.source` in the reply. Only `"live"` means you are talking to the open document. `held_by` names whoever holds the project.

Every tool takes `path` (or the `project_ref` that `open_project` returned). Setting `HORIZONTAL_PROJECT` in the server's environment makes `path` optional.

## Headless work (disk contexts)

The App Store app on its own gives live mode. Disk contexts — editing closed projects, CI, scripts — need the native engine: `libHorizontalPy.dylib` or the `horizontal` command line tool, built from a source checkout with `make native` and found through the checkout's `.build/`, or pointed at with `HORIZONTAL_DYLIB` / `HORIZONTAL_CLI`. If `open_project` with `source: "disk"` fails because neither was found, tell the user rather than working around it.

## Reading errors

Every failure is `{"error": {"code", "message", "retryable", "outcome", "details"}}`.

- `outcome: "not_committed"` — nothing changed; fix the request and resend.
- `outcome: "unknown"` — a mutation's reply was lost. Call `transaction_status` with its `operation_id` before retrying, or you may apply it twice.
- `DOCUMENT_OPEN` — you asked for disk while the app holds the project. Reopen with `source: "live"`.
- `AUTH_FAILED` — the app restarted and its token changed. Call `open_project` again.
- An `ENGINE_ERROR` naming a project file path on a live edit (for example "board.json is not a valid project-relative path") means the open document cannot write that file. Ask the user to close the project and reopen it from its `.hprj`, then retry, and report the message.
