# Shipping the MCP server with a sandboxed App Store app

Should Claude Code run Horizontal's MCP server as
`/Applications/Horizontal.app/Contents/MacOS/Horizontal --mcp`, given that the
app is sandboxed and distributed through the Mac App Store? This note works
through what that process could and could not do, compares it with the other
ways to ship the server, and recommends an order.

## How Claude Code runs a server

- **Registration is explicit.** Claude Code finds MCP servers through
  registration only: a user, project or local entry (`claude mcp add`,
  `.mcp.json`), or a plugin that declares one. Nothing discovers a server a
  running app exposes — no well-known file, port or registry.
- **A stdio server is a command Claude Code spawns for each session.** It
  speaks JSON-RPC on stdin and stdout and lives as long as the session.
- **An HTTP server is a URL** that has to be answering when the session
  starts.

## What exists today

- **The server.** `python/horizontal/mcp_server.py` is already a stdio server
  (`mcp.run(transport="stdio")`). Its tool layer is about 4,400 lines of
  Python:

  | File | Lines | What it holds |
  |---|---|---|
  | `mcp_server.py` | 1,450 | tool definitions |
  | `schemas.py` | 1,019 | the result models |
  | `client.py` | 778 | the client |
  | `analysis*.py` | 777 | the noise, transfer and headroom analyses |
  | `_native.py` | 429 | the transports |

- **How it reaches the engine.**
  - In process, through `libHorizontalPy.dylib`.
  - As a subprocess, `horizontal serve`.
  - Live, through the app's loopback listener (`HorizontalLiveServer.swift`:
    an `NWListener` on 127.0.0.1 with a per-launch token).
- **How the live listener is found.** The listener publishes its endpoint
  and token in `live.json` inside the app's container, which other processes
  cannot read. It also publishes them in a holder record beside each open
  project, which they can. The Python package reads the holder record.
- **The app's entitlements.** `app-sandbox`, `network.server`,
  `files.user-selected.read-write`, `files.bookmarks.app-scope` and
  `device.audio-input`. There is no `network.client`.

## What `Horizontal --mcp` would be

The main executable, started by Claude Code with a flag that keeps it out of
SwiftUI and AppKit, would speak MCP on its stdio.

### In its favour

1. **The sandbox does not get in the way of stdio.** The sandbox is applied
   from the executable's own entitlements however it was launched, and the
   descriptors it inherits from Claude Code stay usable.
2. **It shares the app's identity, so it shares its container.** It can read
   `live.json` directly. The token would no longer need to sit at rest beside
   each project, which may be in a synced or shared folder. Discovery would no
   longer depend on the app having been granted the project's containing
   folder.
3. **It may be able to resolve app-scoped bookmarks the GUI saved.** They
   belong to the same code signature. Verify this on a signed build before
   relying on it.
4. **It ships with the engine it talks to.** The op-schema mismatch warnings
   that `connection_status` and `open_project` report between server and
   engine could not happen.
5. **It needs nothing installed.** No uv, no Python, no checkout. That is the
   only form that fits "the app is self-contained" as App Review reads it.

### What it cannot do

1. **It is a second process, not the user's document.** Whatever it does to an
   open document, it has to do through the GUI's live channel. `--mcp` is a
   client of the listener that already exists, not a replacement for it.
2. **It cannot read projects at the paths Claude passes.** The sandbox allows
   its container, user-selected files and resolvable bookmarks, and nothing
   else. Disk contexts — closed projects, CI, scripts — stay with the dylib
   and CLI built from source.
3. **Reaching the GUI over 127.0.0.1 needs `com.apple.security.network.client`,
   which the app does not have.** A Unix-domain socket inside the container
   avoids the entitlement, and both processes can reach it. The socket file's
   permissions and the container's isolation are the authentication, with no
   token.
   - `sun_path` is limited to 104 bytes.
     `~/Library/Containers/com.twarge.app.horizontal/Data/Library/Application Support/Horizontal/live.sock`
     is over that.
   - The container's `tmp` directory
     (`~/Library/Containers/com.twarge.app.horizontal/Data/tmp/live.sock`,
     about 80 bytes) fits.
4. **Anything it spawns inherits its sandbox.** It cannot host the Python
   server as a child. The direction has to be the other way round: an
   unsandboxed process starts the sandboxed one.
5. **It must not become an app instance.** The `@main` App's `main()` has to
   be reached only without the flag. A small entry point checks the arguments
   first: no Dock icon, no document restoration, no LaunchServices
   registration. It exits when stdin closes. The iOS target compiles the same
   entry point, so the check is macOS-only.
6. **It must not start the GUI on its own or keep running after the session.**
   When the app isn't running it says so, and the user opens it.

### A separate helper executable instead

An embedded tool such as `Contents/Helpers/horizontal-mcp` has to be
sandboxed to pass App Store validation.

- **Inherit doesn't work.** Signed with `com.apple.security.inherit`, it only
  works when the app itself launches it, and Claude Code would be the parent.
- **Its own entitlements mean its own container.** Signed with its own
  entitlements, it has a container of its own. To find the channel it would
  need an App Group container shared with the app, which means more
  provisioning.
- **The only gain is a smaller executable.** The main binary with a flag
  shares the app's identity for free.

### App Review

Guideline 2.4.5 asks that Mac apps be appropriately sandboxed. It also asks
that they:

- be self-contained, installing nothing into shared locations;
- download no code;
- not leave processes running after quit without consent.

So the app must not write `~/.claude.json`, run `claude`, or install a command
into `/usr/local/bin`. The user runs `claude plugin install` themselves.
Settings > Automation now shows those commands with a Copy button for that
reason.

A command-line mode of a sandboxed app is not prohibited as far as the
guidelines say. Describe it in the review notes of the submission that adds
it.

## Options

| | What ships | Cost | What it buys |
|---|---|---|---|
| **A. Native `--mcp`** | The tool layer ported to Swift, inside the app | Large: ~4,400 lines plus the analysis numerics, and two tool surfaces during the move | No dependencies; version-locked; App Store-native |
| **B. `--live-relay`** | A sandboxed stdio relay in the app (~150 lines): it reads `live.json` in the container and relays newline JSON-RPC to the GUI. The Python server spawns it when it finds the app | Small. Needs the container socket, or `network.client` | No token at rest beside projects; discovery without folder grants; one tool surface |
| **C. Plugin with the Python server** | The plugin in this repository, running `uv run --project ${CLAUDE_PLUGIN_ROOT} horizontal-mcp` | Done | One-command install; skills; server and skills pinned together. Needs uv |

## Recommendation

1. **Now: C.** This branch adds the marketplace (`.claude-plugin/marketplace.json`)
   and the plugin rooted at `python/`, so an install carries the server's
   source and lockfile pinned to the same commit as its skills. It also adds
   four skills and the Settings panel. See [claude-code.md](claude-code.md).
2. **Next: B, over a Unix-domain socket in the container.**
   - The GUI listens on both endpoints: TCP for unsandboxed clients (the
     Python package, scripts), and the socket for the relay.
   - `Horizontal --live-relay` lives in the main binary, behind an argument
     check before `HorizontalNativeApp.main()`.
   - `LiveTransport` gains a relay variant, chosen when the app is found at
     `HORIZONTAL_APP` or `/Applications/Horizontal.app`.
   - This is the change that touches entitlements and the app's entry point,
     so it waits for a go-ahead.
3. **Later: A, once the tool surface settles.**
   - The engine already publishes the op vocabulary and its digest (`list_ops`,
     the schema digest), so `apply_ops` and the read tools can be generated
     from it rather than written twice.
   - Port the read tools first. Keep the analyses in Python until they are
     ported.
   - Then point the plugin at the app through a launcher script that prefers
     `--mcp` when the installed app supports it, and falls back to uv.

**What "switch to stdio" means here.** Every option above is a stdio server as
far as Claude Code is concerned. An HTTP endpoint hosted by the app would fail
whenever the app is not running when a session starts, and would need its own
authentication on a port.

## Field notes

These turned up while driving the server against a real project (Cinnamon,
2026-10-14). The full list is items 106–119 in billo's
`docs/horizontal-mcp-notes.md`. It also covers copper shorts that `check`
cannot see, the save and autosave contract, `remap_part` and copper,
junction handles, and stranded wiring.

1. **One live document refused every write.**
   - Errors seen:
     - the load diagnostic "board.json is not a valid project-relative path";
     - `import_pool_part` failing with "pool/parts/cache/<uuid>.json is not a
       valid project-relative path";
     - `render_sheet` replying "The project has no schematic sheets" while
       `open_project` listed four.
   - **Cause.** `HorizontalProjectArchive.replaceRegularFileData` throws
     `invalidRelativePath` when the archive's root is a regular file. That
     document seems to have held a single-file archive, the `.hprj` alone,
     rather than the tree gathered from its manifest.
   - **Recovery.** After the app relaunched and the project was reopened,
     every write worked.
2. **`unsaved_changes` stayed `false`.** `open_project` on an already-open live
   context reported `unsaved_changes: false` after live edits had committed.
   `save` then reported `had_unsaved_changes: true`.
3. **The server's version was empty.** `initialize` reported
   `serverInfo.version` as `""`. It now comes from the package metadata
   (fixed in this branch).
4. **Retiring a net left wires behind.** After `remove_symbol`, `disconnect`
   and `retire_net` on a removed gate's net, two things survived:
   - its junction-to-junction feedback wires;
   - the wire of a test point moved in the same batch, now drawn diagonally.

   `find_dangling` found them and `remove_net_line` cleared them. Pruning what
   those ops strand would save a pass.
