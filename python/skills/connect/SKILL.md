---
name: connect
description: Connect Claude to Horizontal and diagnose the connection. Use before the first edit in a session, or when the horizontal MCP tools are missing, live_state reads "unavailable", open_project returns source "disk" for a project the user has open, or a call fails with DOCUMENT_OPEN, AUTH_FAILED or TIMEOUT.
---

# Connect to Horizontal

The horizontal MCP server reads and edits Horizon EDA projects (`.hprj`, `.horizontal`) through Horizontal's own model. It reaches a project one of two ways:

- **live**: the document open in the Horizontal app, over the app's loopback channel. Reads see unsaved edits, `select`, `highlight` and `zoom_to` drive the canvases, and every `apply_ops` lands as one undoable step. The app autosaves in place, so committed edits can reach disk without `save`; call `save` to be sure, and to verify the files.
- **disk**: the project's files, through the native engine in a worker process. Edits write files directly, and are refused with `DOCUMENT_OPEN` while the app holds the project, because the app would overwrite them.

Work live whenever the user has the project open. Confirm it before editing.

## 1. Are the tools there?

If no `horizontal` tools are available, the server did not start.

- The plugin runs the server with `uv`. Ask the user to install it (`brew install uv`) and restart the session.
- A user-scope or project-scope server named `horizontal` overrides the plugin's (local > project > user > plugin). `claude mcp list` in a terminal shows which one is in use. A stale user-scope entry is removed with `claude mcp remove horizontal -s user`.

## 2. Which app is answering?

Call `connection_status`. It reports discovery, authentication, engine versions and which app bundle answered, with no project open. An installed copy and an Xcode build (`DerivedData/…/Horizontal.app`) are told apart by `bundle`. A warning that the server's op schema differs from the engine's means one of them is out of date: say so before editing.

## 3. Reach the user's document

1. Call `live_state` with the project path. Without a path, "unavailable" proves nothing: the sandboxed app's discovery file is unreadable from outside its container, so the project's own holder records are often the only way in.
2. If it is still unavailable, ask the user to check, in order:
   - a document is open in Horizontal;
   - **Settings > Automation > Enable MCP Server** is on (the channel is off until it is turned on);
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
